/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "IGListAdapterInternal.h"

#if !__has_include(<IGListDiffKit/IGListDiffKit.h>)
#import "IGListAssert.h"
#else
#import <IGListDiffKit/IGListAssert.h>
#endif
#import "IGListAdapterUpdater.h"

#import "IGListAdapterDelegateAnnouncer.h"
#import "IGListArrayUtilsInternal.h"
#import "IGListDebugger.h"
#import "IGListDefaultExperiments.h"
#import "IGListSectionControllerInternal.h"
#import "IGListSupplementaryViewSource.h"
#import "IGListTransitionData.h"
#import "IGListUpdatingDelegate.h"
#import "UICollectionViewLayout+InteractiveReordering.h"
#import "UIScrollView+IGListKit.h"
#import "UIViewController+IGListAdapterInternal.h"

typedef struct OffsetRange {
    CGFloat min;
    CGFloat max;
} OffsetRange;

@implementation IGListAdapter {
    NSMapTable<UICollectionReusableView *, IGListSectionController *> *_viewSectionControllerMap;
    // An array of blocks to execute once batch updates are finished
    NSMutableArray<void (^)(void)> *_queuedCompletionBlocks;
    NSHashTable<id<IGListAdapterUpdateListener>> *_updateListeners;
}

- (void)dealloc {
    [self.sectionMap reset];
}


#pragma mark - Init

- (instancetype)initWithUpdater:(id <IGListUpdatingDelegate>)updater
                 viewController:(UIViewController *)viewController
               workingRangeSize:(NSInteger)workingRangeSize {
    IGAssertMainThread();
    IGParameterAssert(updater);

    if (self = [super init]) {
        NSPointerFunctions *keyFunctions = [updater objectLookupPointerFunctions];
        NSPointerFunctions *valueFunctions = [NSPointerFunctions pointerFunctionsWithOptions:NSPointerFunctionsStrongMemory];
        NSMapTable *table = [[NSMapTable alloc] initWithKeyPointerFunctions:keyFunctions valuePointerFunctions:valueFunctions capacity:0];
        _sectionMap = [[IGListSectionMap alloc] initWithMapTable:table];

        _globalDelegateAnnouncer = [IGListAdapterDelegateAnnouncer sharedInstance];
        _displayHandler = [IGListDisplayHandler new];
        _workingRangeHandler = [[IGListWorkingRangeHandler alloc] initWithWorkingRangeSize:workingRangeSize];
        _updateListeners = [NSHashTable weakObjectsHashTable];

        _viewSectionControllerMap = [NSMapTable mapTableWithKeyOptions:NSMapTableObjectPointerPersonality | NSMapTableStrongMemory
                                                          valueOptions:NSMapTableStrongMemory];

        _updater = updater;
        _viewController = viewController;

        [viewController associateListAdapter:self];

        _experiments = IGListDefaultExperiments();

        [IGListDebugger trackAdapter:self];
    }
    return self;
}

- (instancetype)initWithUpdater:(id<IGListUpdatingDelegate>)updater
                 viewController:(UIViewController *)viewController {
    return [self initWithUpdater:updater
                  viewController:viewController
                workingRangeSize:0];
}

- (UICollectionView *)collectionView {
    return _collectionView;
}

- (void)setCollectionView:(UICollectionView *)collectionView {
    IGAssertMainThread();

    // if collection view has been used by a different list adapter, treat it as if we were using a new collection view
    // this happens when embedding a UICollectionView inside a UICollectionViewCell that is reused
    if (_collectionView != collectionView || _collectionView.dataSource != self) {
        // if the collection view was being used with another IGListAdapter (e.g. cell reuse)
        // destroy the previous association so the old adapter doesn't update the wrong collection view
        static NSMapTable<UICollectionView *, IGListAdapter *> *globalCollectionViewAdapterMap = nil;
        if (globalCollectionViewAdapterMap == nil) {
            globalCollectionViewAdapterMap = [NSMapTable weakToWeakObjectsMapTable];
        }
        [globalCollectionViewAdapterMap removeObjectForKey:_collectionView];
        [[globalCollectionViewAdapterMap objectForKey:collectionView] setCollectionView:nil];
        [globalCollectionViewAdapterMap setObject:self forKey:collectionView];

        // dump old registered section controllers in the case that we are changing collection views or setting for
        // the first time
        _registeredCellIdentifiers = [NSMutableSet new];
        _registeredNibNames = [NSMutableSet new];
        _registeredSupplementaryViewIdentifiers = [NSMutableSet new];
        _registeredSupplementaryViewNibNames = [NSMutableSet new];

        // We can't just swap out the collectionView, because we might have on-going or pending updates.
        // `_updater` can take care of that by wrapping the change in `performDataSourceChange`.
        [_updater performDataSourceChange:^{
            if (self->_collectionView.dataSource == self) {
                // Since we're not going to sync the previous collectionView anymore, lets not be its dataSource.
                self->_collectionView.dataSource = nil;
            }
            self->_collectionView = collectionView;
            self->_collectionView.dataSource = self;

            [self _updateCollectionViewDelegate];

            // Sync the dataSource <> adapter for a couple of reasons:
            // 1. We might not have synced on -setDataSource, so now is the time to try again.
            // 2. Any in-flight `performUpdatesAnimated` were cancelled, so lets make sure we have the latest data.
            [self _updateObjects];

            // The sync between the collectionView <> adapter will happen automically, since
            // we just changed the `collectionView.dataSource`.
        }];

        if (@available(iOS 10.0, tvOS 10, *)) {
            _collectionView.prefetchingEnabled = NO;
        }

        [_collectionView.collectionViewLayout ig_hijackLayoutInteractiveReorderingMethodForAdapter:self];
        [_collectionView.collectionViewLayout invalidateLayout];
    }
}

- (void)setDataSource:(id<IGListAdapterDataSource>)dataSource {
    if (_dataSource == dataSource) {
        return;
    }

    [_updater performDataSourceChange:^{
        self->_dataSource = dataSource;

        // Invalidate the collectionView internal section & item counts, as if its dataSource changed.
        self->_collectionView.dataSource = nil;
        self->_collectionView.dataSource = self;

        // Sync the dataSource <> adapter
        [self _updateObjects];

        // The sync between the collectionView <> adapter will happen automically, since
        // we just changed the `collectionView.dataSource`.
    }];
}

// reset and configure the delegate proxy whenever this property is set
- (void)setCollectionViewDelegate:(id<UICollectionViewDelegate>)collectionViewDelegate {
    IGAssertMainThread();
    IGWarn(![collectionViewDelegate conformsToProtocol:@protocol(UICollectionViewDelegateFlowLayout)],
           @"UICollectionViewDelegateFlowLayout conformance is automatically handled by IGListAdapter.");

    if (_collectionViewDelegate != collectionViewDelegate) {
        _collectionViewDelegate = collectionViewDelegate;
        [self _createProxyAndUpdateCollectionViewDelegate];
    }
}

- (void)setScrollViewDelegate:(id<UIScrollViewDelegate>)scrollViewDelegate {
    IGAssertMainThread();

    if (_scrollViewDelegate != scrollViewDelegate) {
        _scrollViewDelegate = scrollViewDelegate;
        [self _createProxyAndUpdateCollectionViewDelegate];
    }
}

- (void)_updateObjects {
    if (_collectionView == nil) {
        // If we don't have a collectionView, we can't do much.
        return;
    }
    id<IGListAdapterDataSource> dataSource = _dataSource;
    NSArray *uniqueObjects = objectsWithDuplicateIdentifiersRemoved([dataSource objectsForListAdapter:self]);
    [self _updateObjects:uniqueObjects dataSource:dataSource];
}

- (void)_createProxyAndUpdateCollectionViewDelegate {
    // there is a known bug with accessibility and using an NSProxy as the delegate that will cause EXC_BAD_ACCESS
    // when voiceover is enabled. it will hold an unsafe ref to the delegate
    _collectionView.delegate = nil;

    self.delegateProxy = [[IGListAdapterProxy alloc] initWithCollectionViewTarget:_collectionViewDelegate
                                                                 scrollViewTarget:_scrollViewDelegate
                                                                      interceptor:self];
    [self _updateCollectionViewDelegate];
}

- (void)_updateCollectionViewDelegate {
    // set up the delegate to the proxy so the adapter can intercept events
    // default to the adapter simply being the delegate
    _collectionView.delegate = (id<UICollectionViewDelegate>)self.delegateProxy ?: self;
}


#pragma mark - Scrolling

- (void)scrollToObject:(id)object
    supplementaryKinds:(nullable NSArray<NSString *> *)supplementaryKinds
       scrollDirection:(UICollectionViewScrollDirection)scrollDirection
        scrollPosition:(UICollectionViewScrollPosition)scrollPosition
      additionalOffset:(CGFloat)additionalOffset
              animated:(BOOL)animated {
    IGAssertMainThread();
    IGParameterAssert(object != nil);

    const NSInteger section = [self sectionForObject:object];
    if (section == NSNotFound) {
        return;
    }

    UICollectionView *collectionView = self.collectionView;

    // We avoid calling `[collectionView layoutIfNeeded]` here because that could create cells that will no longer be visible after the scroll.
    // Note that we get the layout attributes from the `UICollectionView` instead of the `collectionViewLayout`, because that will generate the
    // necessary attributes without creating the cells just yet.

    NSIndexPath *indexPathFirstElement = [NSIndexPath indexPathForItem:0 inSection:section];

    const OffsetRange offset = [self _offsetRangeForIndexPath:indexPathFirstElement
                                           supplementaryKinds:supplementaryKinds
                                              scrollDirection:scrollDirection];

    const CGFloat offsetMid = (offset.min + offset.max) / 2.0;
    const CGFloat collectionViewWidth = collectionView.bounds.size.width;
    const CGFloat collectionViewHeight = collectionView.bounds.size.height;
    const UIEdgeInsets contentInset = collectionView.ig_contentInset;
    CGPoint contentOffset = collectionView.contentOffset;
    switch (scrollDirection) {
        case UICollectionViewScrollDirectionHorizontal: {
            switch (scrollPosition) {
                case UICollectionViewScrollPositionRight:
                    contentOffset.x = offset.max - collectionViewWidth + contentInset.right;
                    break;
                case UICollectionViewScrollPositionCenteredHorizontally: {
                    const CGFloat insets = (contentInset.left - contentInset.right) / 2.0;
                    contentOffset.x = offsetMid - collectionViewWidth / 2.0 - insets;
                }
                    break;
                case UICollectionViewScrollPositionLeft:
                case UICollectionViewScrollPositionNone:
                case UICollectionViewScrollPositionTop:
                case UICollectionViewScrollPositionBottom:
                case UICollectionViewScrollPositionCenteredVertically:
                    contentOffset.x = offset.min - contentInset.left;
                    break;
                default: /* unexpected */
                    IGLK_UNEXPECTED_SWITCH_CASE_ABORT(UICollectionViewScrollPosition, scrollPosition);
            }
            const CGFloat maxOffsetX = collectionView.contentSize.width - collectionView.frame.size.width + contentInset.right;
            const CGFloat minOffsetX = -contentInset.left;
            contentOffset.x += additionalOffset;
            contentOffset.x = MIN(contentOffset.x, maxOffsetX);
            contentOffset.x = MAX(contentOffset.x, minOffsetX);
            break;
        }
        case UICollectionViewScrollDirectionVertical: {
            switch (scrollPosition) {
                case UICollectionViewScrollPositionBottom:
                    contentOffset.y = offset.max - collectionViewHeight + contentInset.bottom;
                    break;
                case UICollectionViewScrollPositionCenteredVertically: {
                    const CGFloat insets = (contentInset.top - contentInset.bottom) / 2.0;
                    contentOffset.y = offsetMid - collectionViewHeight / 2.0 - insets;
                }
                    break;
                case UICollectionViewScrollPositionTop:
                case UICollectionViewScrollPositionNone:
                case UICollectionViewScrollPositionLeft:
                case UICollectionViewScrollPositionRight:
                case UICollectionViewScrollPositionCenteredHorizontally:
                    contentOffset.y = offset.min - contentInset.top;
                    break;
                default: /* unexpected */
                    IGLK_UNEXPECTED_SWITCH_CASE_ABORT(UICollectionViewScrollPosition, scrollPosition);
            }
            // If we don't call [collectionView layoutIfNeeded], the collectionView.contentSize does not get updated.
            // So lets use the layout object, since it should have been updated by now.
            const CGFloat maxHeight = collectionView.collectionViewLayout.collectionViewContentSize.height;
            const CGFloat maxOffsetY = maxHeight - collectionView.frame.size.height + contentInset.bottom;
            const CGFloat minOffsetY = -contentInset.top;
            contentOffset.y += additionalOffset;
            contentOffset.y = MIN(contentOffset.y, maxOffsetY);
            contentOffset.y = MAX(contentOffset.y, minOffsetY);
            break;
        }
        default: /* unexpected */
            IGLK_UNEXPECTED_SWITCH_CASE_ABORT(UICollectionViewScrollDirection, scrollDirection);
    }

    [collectionView setContentOffset:contentOffset animated:animated];
}

- (nullable NSIndexPath *)indexPathForFirstVisibleItem {
    const CGPoint contentOffset = self.collectionView.contentOffset;
    const UIEdgeInsets contentInset = self.collectionView.contentInset;
    const CGPoint point = CGPointMake(contentOffset.x + contentInset.left, contentOffset.y + contentInset.top);
    return [self.collectionView indexPathForItemAtPoint:point];
}

- (CGFloat)offsetForFirstVisibleItemWithScrollDirection:(UICollectionViewScrollDirection)scrollDirection {
    NSIndexPath *const indexPath = [self indexPathForFirstVisibleItem];
    if (indexPath) {
        const OffsetRange offset = [self _offsetRangeForIndexPath:indexPath supplementaryKinds:nil scrollDirection:scrollDirection];
        switch (scrollDirection) {
            case UICollectionViewScrollDirectionHorizontal:
                return self.collectionView.contentInset.left + self.collectionView.contentOffset.x - offset.min;
            case UICollectionViewScrollDirectionVertical:
                return self.collectionView.contentInset.top + self.collectionView.contentOffset.y - offset.min;
            default: /* unexpected */
                IGLK_UNEXPECTED_SWITCH_CASE_ABORT(UICollectionViewScrollDirection, scrollDirection);
        }
    } else {
        return 0;
    }
}

- (OffsetRange)_offsetRangeForIndexPath:(NSIndexPath *)indexPath
                     supplementaryKinds:(nullable NSArray<NSString *> *)supplementaryKinds
                        scrollDirection:(UICollectionViewScrollDirection)scrollDirection {
    const NSUInteger section = indexPath.section;

    // collect the layout attributes for the cell and supplementary views for the first index
    // this will break if there are supplementary views beyond item 0
    NSMutableArray<UICollectionViewLayoutAttributes *> *attributes = nil;

    const NSInteger numberOfItems = [self.collectionView numberOfItemsInSection:section];
    if (numberOfItems > 0) {
        attributes = [self _layoutAttributesForItemAndSupplementaryViewAtIndexPath:indexPath
                                                                supplementaryKinds:supplementaryKinds].mutableCopy;

        if (numberOfItems > 1) {
            NSIndexPath *indexPathLastElement = [NSIndexPath indexPathForItem:(numberOfItems - 1) inSection:section];
            UICollectionViewLayoutAttributes *lastElementattributes = [self _layoutAttributesForItemAndSupplementaryViewAtIndexPath:indexPathLastElement
                                                                                                                 supplementaryKinds:supplementaryKinds].firstObject;
            if (lastElementattributes != nil) {
                [attributes addObject:lastElementattributes];
            }
        }
    } else {
        NSMutableArray *supplementaryAttributes = [NSMutableArray new];
        for (NSString* supplementaryKind in supplementaryKinds) {
            UICollectionViewLayoutAttributes *supplementaryAttribute = [self _layoutAttributesForSupplementaryViewOfKind:supplementaryKind atIndexPath:indexPath];
            if (supplementaryAttribute != nil) {
                [supplementaryAttributes addObject: supplementaryAttribute];
            }
        }
        attributes = supplementaryAttributes;
    }

    OffsetRange offset = (OffsetRange) { .min = 0, .max = 0 };
    for (UICollectionViewLayoutAttributes *attribute in attributes) {
        const CGRect frame = attribute.frame;
        CGFloat originMin;
        CGFloat endMax;
        switch (scrollDirection) {
            case UICollectionViewScrollDirectionHorizontal:
                originMin = CGRectGetMinX(frame);
                endMax = CGRectGetMaxX(frame);
                break;
            case UICollectionViewScrollDirectionVertical:
                originMin = CGRectGetMinY(frame);
                endMax = CGRectGetMaxY(frame);
                break;
            default: /* unexpected */
                IGLK_UNEXPECTED_SWITCH_CASE_ABORT(UICollectionViewScrollDirection, scrollDirection);
        }

        // find the minimum origin value of all the layout attributes
        if (attribute == attributes.firstObject || originMin < offset.min) {
            offset.min = originMin;
        }
        // find the maximum end value of all the layout attributes
        if (attribute == attributes.firstObject || endMax > offset.max) {
            offset.max = endMax;
        }
    }

    return offset;
}

#pragma mark - Editing

- (void)performUpdatesAnimated:(BOOL)animated completion:(IGListUpdaterCompletion)completion {
    IGAssertMainThread();

    id<IGListAdapterDataSource> dataSource = self.dataSource;
    id<IGListUpdatingDelegate> updater = self.updater;
    UICollectionView *collectionView = self.collectionView;
    if (dataSource == nil || collectionView == nil) {
        IGLKLog(@"Warning: Your call to %s is ignored as dataSource or collectionView haven't been set.", __PRETTY_FUNCTION__);
        IGLK_BLOCK_CALL_SAFE(completion, NO);
        return;
    }

    [self _enterBatchUpdates];

    __weak __typeof__(self) weakSelf = self;
    IGListTransitionDataBlock sectionDataBlock = ^IGListTransitionData *{
        __typeof__(self) strongSelf = weakSelf;
        IGListTransitionData *transitionData = nil;
        if (strongSelf) {
            NSArray *toObjects = objectsWithDuplicateIdentifiersRemoved([dataSource objectsForListAdapter:strongSelf]);
            transitionData = [strongSelf _generateTransitionDataWithObjects:toObjects dataSource:dataSource];
        }
        return transitionData;
    };

    IGListTransitionDataApplyBlock applySectionDataBlock = ^void(IGListTransitionData *data) {
        __typeof__(self) strongSelf = weakSelf;
        if (strongSelf) {
            // temporarily capture the item map that we are transitioning from in case
            // there are any item deletes at the same
            strongSelf.previousSectionMap = [strongSelf.sectionMap copy];
            [strongSelf _updateWithData:data];
        }
    };

    IGListUpdaterCompletion outerCompletionBlock = ^(BOOL finished){
        __typeof__(self) strongSelf = weakSelf;
        if (strongSelf == nil) {
            IGLK_BLOCK_CALL_SAFE(completion,finished);
            return;
        }

        // release the previous items
        strongSelf.previousSectionMap = nil;
        [strongSelf _notifyDidUpdate:IGListAdapterUpdateTypePerformUpdates animated:animated];
        IGLK_BLOCK_CALL_SAFE(completion,finished);
        [strongSelf _exitBatchUpdates];
    };

    [updater performUpdateWithCollectionViewBlock:[self _collectionViewBlock]
                                         animated:animated
                                 sectionDataBlock:sectionDataBlock
                            applySectionDataBlock:applySectionDataBlock
                                       completion:outerCompletionBlock];
}

- (void)reloadDataWithCompletion:(nullable IGListUpdaterCompletion)completion {
    IGAssertMainThread();

    id<IGListAdapterDataSource> dataSource = self.dataSource;
    UICollectionView *collectionView = self.collectionView;
    if (dataSource == nil || collectionView == nil) {
        IGLKLog(@"Warning: Your call to %s is ignored as dataSource or collectionView haven't been set.", __PRETTY_FUNCTION__);
        if (completion) {
            completion(NO);
        }
        return;
    }

    NSArray *uniqueObjects = objectsWithDuplicateIdentifiersRemoved([dataSource objectsForListAdapter:self]);

    __weak __typeof__(self) weakSelf = self;
    [self.updater reloadDataWithCollectionViewBlock:[self _collectionViewBlock]
                                  reloadUpdateBlock:^{
                                      // purge all section controllers from the item map so that they are regenerated
                                      [weakSelf.sectionMap reset];
                                      [weakSelf _updateObjects:uniqueObjects dataSource:dataSource];
                                  } completion:^(BOOL finished) {
                                      [weakSelf _notifyDidUpdate:IGListAdapterUpdateTypeReloadData animated:NO];
                                      if (completion) {
                                          completion(finished);
                                      }
                                  }];
}

- (void)reloadObjects:(NSArray *)objects {
    IGAssertMainThread();
    IGParameterAssert(objects);

    NSMutableIndexSet *sections = [NSMutableIndexSet new];

    // use the item map based on whether or not we're in an update block
    IGListSectionMap *map = [self _sectionMapUsingPreviousIfInUpdateBlock:YES];

    [objects enumerateObjectsUsingBlock:^(id object, NSUInteger idx, BOOL *stop) {
        // look up the item using the map's lookup function. might not be the same item
        const NSInteger section = [map sectionForObject:object];
        const BOOL notFound = section == NSNotFound;
        if (notFound) {
            return;
        }
        [sections addIndex:section];

        // reverse lookup the item using the section. if the pointer has changed the trigger update events and swap items
        if (object != [map objectForSection:section]) {
            [map updateObject:object];
            [[map sectionControllerForSection:section] didUpdateToObject:object];
        }
    }];

    UICollectionView *collectionView = self.collectionView;
    IGAssert(collectionView != nil, @"Tried to reload the adapter without a collection view");
    [self.updater reloadCollectionView:collectionView sections:sections];
}

- (void)addUpdateListener:(id<IGListAdapterUpdateListener>)updateListener {
    IGAssertMainThread();
    IGParameterAssert(updateListener != nil);

    [_updateListeners addObject:updateListener];
}

- (void)removeUpdateListener:(id<IGListAdapterUpdateListener>)updateListener {
    IGAssertMainThread();
    IGParameterAssert(updateListener != nil);

    [_updateListeners removeObject:updateListener];
}

- (void)_notifyDidUpdate:(IGListAdapterUpdateType)update animated:(BOOL)animated {
    for (id<IGListAdapterUpdateListener> listener in _updateListeners) {
        [listener listAdapter:self didFinishUpdate:update animated:animated];
    }
}


#pragma mark - List Items & Sections

- (nullable IGListSectionController *)sectionControllerForSection:(NSInteger)section {
    IGAssertMainThread();

    return [self.sectionMap sectionControllerForSection:section];
}

- (NSInteger)sectionForSectionController:(IGListSectionController *)sectionController {
    IGAssertMainThread();
    IGParameterAssert(sectionController != nil);

    return [self.sectionMap sectionForSectionController:sectionController];
}

- (IGListSectionController *)sectionControllerForObject:(id)object {
    IGAssertMainThread();
    IGParameterAssert(object != nil);

    return [self.sectionMap sectionControllerForObject:object];
}

- (id)objectForSectionController:(IGListSectionController *)sectionController {
    IGAssertMainThread();
    IGParameterAssert(sectionController != nil);

    const NSInteger section = [self.sectionMap sectionForSectionController:sectionController];
    return [self.sectionMap objectForSection:section];
}

- (id)objectAtSection:(NSInteger)section {
    IGAssertMainThread();

    return [self.sectionMap objectForSection:section];
}

- (NSInteger)sectionForObject:(id)item {
    IGAssertMainThread();
    IGParameterAssert(item != nil);

    return [self.sectionMap sectionForObject:item];
}

- (NSArray *)objects {
    IGAssertMainThread();

    return self.sectionMap.objects;
}

- (id<IGListSupplementaryViewSource>)_supplementaryViewSourceAtIndexPath:(NSIndexPath *)indexPath {
    IGListSectionController *sectionController = [self sectionControllerForSection:indexPath.section];
    return [sectionController supplementaryViewSource];
}

- (NSArray<IGListSectionController *> *)visibleSectionControllers {
    IGAssertMainThread();
    return [[self.displayHandler visibleListSections] allObjects];
}

- (NSSet *)_visibleObjectsSet __attribute__((objc_direct)) {
    IGAssertMainThread();

    NSArray<UICollectionViewCell *> *visibleCells = [self.collectionView visibleCells];
    NSMutableSet *visibleObjects = [NSMutableSet new];
    for (UICollectionViewCell *cell in visibleCells) {
        IGListSectionController *sectionController = [self _sectionControllerForCell:cell];
        IGAssert(sectionController != nil, @"Section controller nil for cell %@", cell);
        if (sectionController != nil) {
            const NSInteger section = [self sectionForSectionController:sectionController];
            if (section != NSNotFound) {
                id object = [self objectAtSection:section];
                IGAssert(object != nil, @"Object not found for section controller %@ at section %li", sectionController, (long)section);
                if (object != nil) {
                    [visibleObjects addObject:object];
                }
            }
        }
    }
    return visibleObjects;
}

- (NSArray *)visibleObjects {
    return [[self _visibleObjectsSet] allObjects];
}

- (NSIndexSet *)indexesOfVisibleObjects {
    /*
        This is a naive implementation, going through all objects and checking if they are visible.
        It is not optimized for performance, but it is correct.

        In the future, this could potentially be optimized by getting the index paths of visible cells,
        and converting those index paths into a range of object indexes within `self.objects`.
    */

    NSSet *visibleObjects = [self _visibleObjectsSet];
    NSMutableIndexSet *indexSet = [NSMutableIndexSet indexSet];
    NSUInteger idx = 0;
    for (id object in self.objects) {
        if ([visibleObjects containsObject:object]) {
            [indexSet addIndex:idx];
        }
        idx++;
    }
    return [indexSet copy];
}

- (NSArray<UICollectionViewCell *> *)visibleCellsForObject:(id)object {
    IGAssertMainThread();
    IGParameterAssert(object != nil);

    const NSInteger section = [self.sectionMap sectionForObject:object];
    if (section == NSNotFound) {
        return [NSArray new];
    }

    NSArray<UICollectionViewCell *> *visibleCells = [self.collectionView visibleCells];
    UICollectionView *collectionView = self.collectionView;
    NSPredicate *controllerPredicate = [NSPredicate predicateWithBlock:^BOOL(UICollectionViewCell* cell, NSDictionary* bindings) {
        NSIndexPath *indexPath = [collectionView indexPathForCell:cell];
        return indexPath.section == section;
    }];

    return [visibleCells filteredArrayUsingPredicate:controllerPredicate];
}

#pragma mark - Layout

- (CGSize)sizeForItemAtIndexPath:(NSIndexPath *)indexPath {
    IGAssertMainThread();
    id<IGListAdapterPerformanceDelegate> performanceDelegate = self.performanceDelegate;
    [performanceDelegate listAdapterWillCallSize:self];

    IGListSectionController *sectionController = [self sectionControllerForSection:indexPath.section];
    const CGSize size = [sectionController sizeForItemAtIndex:indexPath.item];
    const CGSize positiveSize = CGSizeMake(MAX(size.width, 0.0), MAX(size.height, 0.0));

    [performanceDelegate listAdapter:self didCallSizeOnSectionController:sectionController atIndex:indexPath.item];
    return positiveSize;
}

- (CGSize)sizeForSupplementaryViewOfKind:(NSString *)elementKind atIndexPath:(NSIndexPath *)indexPath {
    IGAssertMainThread();
    id <IGListSupplementaryViewSource> supplementaryViewSource = [self _supplementaryViewSourceAtIndexPath:indexPath];
    if ([[supplementaryViewSource supportedElementKinds] containsObject:elementKind]) {
        const CGSize size = [supplementaryViewSource sizeForSupplementaryViewOfKind:elementKind atIndex:indexPath.item];
        return CGSizeMake(MAX(size.width, 0.0), MAX(size.height, 0.0));
    }
    return CGSizeZero;
}


#pragma mark - Private API

- (IGListCollectionViewBlock)_collectionViewBlock {
     __weak __typeof__(self) weakSelf = self;
    return ^UICollectionView *{ return weakSelf.collectionView; };
}

- (IGListTransitionData *)_generateTransitionDataWithObjects:(NSArray *)objects dataSource:(id<IGListAdapterDataSource>)dataSource {
    IGListSectionMap *map = self.sectionMap;

    if (!dataSource) {
        return [[IGListTransitionData alloc] initFromObjects:map.objects
                                                   toObjects:@[]
                                        toSectionControllers:@[]];
    }

#if defined(DEBUG) && DEBUG
    for (id object in objects) {
        IGAssert([object isEqualToDiffableObject:object], @"Object instance %@ not equal to itself. This will break infra map tables.", object);
    }
#endif

    NSMutableArray<IGListSectionController *> *sectionControllers = [[NSMutableArray alloc] initWithCapacity:objects.count];
    NSMutableArray *validObjects = [[NSMutableArray alloc] initWithCapacity:objects.count];

    // push the view controller and collection context into a local thread container so they are available on init
    // for IGListSectionController subclasses after calling [super init]
    IGListSectionControllerPushThread(self.viewController, self);

    [objects enumerateObjectsUsingBlock:^(id object, NSUInteger idx, BOOL *stop) {
        // infra checks to see if a controller exists
        IGListSectionController *sectionController = [map sectionControllerForObject:object];

        // if not, query the data source for a new one
        if (sectionController == nil) {
            sectionController = [dataSource listAdapter:self sectionControllerForObject:object];
        }

        if (sectionController == nil) {
            IGLKLog(@"WARNING: Ignoring nil section controller returned by data source %@ for object %@.",
                    dataSource, object);
            return;
        }

        if ([sectionController isMemberOfClass:[IGListSectionController class]]) {
            // If IGListSectionController is not subclassed, it could be a side effect of a problem. For example, nothing stops
            // dataSource from returning a plain IGListSectionController if it doesn't recognize the object type, instead of throwing.
            // Why not throw here then? Maybe we should, but in most cases, it feels like an over reaction. If we don't know how to render
            // a single item, terminating the entire app might not be necessary. The dataSource should be the one who decides if throwing is appropriate.
            IGFailAssert(@"Ignoring IGListSectionController that's not a subclass from data source %@ for object %@", NSStringFromClass([dataSource class]), NSStringFromClass([object class]));
            return;
        }

        // in case the section controller was created outside of -listAdapter:sectionControllerForObject:
        sectionController.collectionContext = self;
        sectionController.viewController = self.viewController;

        [sectionControllers addObject:sectionController];
        [validObjects addObject:object];
    }];

#if defined(DEBUG) && DEBUG
    IGAssert([NSSet setWithArray:sectionControllers].count == sectionControllers.count,
             @"Section controllers array is not filled with unique objects; section controllers are being reused");
#endif

    // clear the view controller and collection context
    IGListSectionControllerPopThread();

    return [[IGListTransitionData alloc] initFromObjects:map.objects
                                               toObjects:validObjects
                                    toSectionControllers:sectionControllers];
}

- (void)_updateObjects:(NSArray *)objects dataSource:(id<IGListAdapterDataSource>)dataSource {
    [self _updateWithData:[self _generateTransitionDataWithObjects:objects dataSource:dataSource]];
}

// this method is what updates the "source of truth"
// this should only be called just before the collection view is updated
- (void)_updateWithData:(IGListTransitionData *)data {
    IGParameterAssert(data);

    // Should be the first thing called in this function.
    _isInObjectUpdateTransaction = YES;

    IGListSectionMap *map = self.sectionMap;

    // Note: We use an array, instead of a set, because the updater should have dealt with duplicates already.
    NSMutableArray *updatedObjects = [NSMutableArray new];

    for (id object in data.toObjects) {
        // check if the item has changed instances or is new
        const NSInteger oldSection = [map sectionForObject:object];
        if (oldSection == NSNotFound || [map objectForSection:oldSection] != object) {
            [updatedObjects addObject:object];
        }
    }

    [map updateWithObjects:data.toObjects sectionControllers:data.toSectionControllers];

    // now that the maps have been created and contexts are assigned, we consider the section controller "fully loaded"
    for (id object in updatedObjects) {
        [[map sectionControllerForObject:object] didUpdateToObject:object];
    }

    [self _updateBackgroundView];

    // Should be the last thing called in this function.
    _isInObjectUpdateTransaction = NO;
}

- (void)_updateBackgroundView {
    const BOOL shouldDisplay = [self _itemCountIsZero];

    if (shouldDisplay) {
        UIView *backgroundView = [self.dataSource emptyViewForListAdapter:self];
        // don't do anything if the client is using the same view
        if (backgroundView != _collectionView.backgroundView) {
            // collection view will just stack the background views underneath each other if we do not remove the previous
            // one first. also fine if it is nil
            [_collectionView.backgroundView removeFromSuperview];
            _collectionView.backgroundView = backgroundView;
        }
    }

    _collectionView.backgroundView.hidden = !shouldDisplay;
}

- (BOOL)_itemCountIsZero {
    __block BOOL isZero = YES;
    [self.sectionMap enumerateUsingBlock:^(id  _Nonnull object, IGListSectionController * _Nonnull sectionController, NSInteger section, BOOL * _Nonnull stop) {
        if (sectionController.numberOfItems > 0) {
            isZero = NO;
            *stop = YES;
        }
    }];
    return isZero;
}

- (IGListSectionMap *)_sectionMapUsingPreviousIfInUpdateBlock:(BOOL)usePreviousMapIfInUpdateBlock {
    // if we are inside an update block, we may have to use the /previous/ item map for some operations
    IGListSectionMap *previousSectionMap = self.previousSectionMap;
    if (usePreviousMapIfInUpdateBlock && [self isInDataUpdateBlock] && previousSectionMap != nil) {
        return previousSectionMap;
    } else {
        return self.sectionMap;
    }
}

- (NSArray<NSIndexPath *> *)indexPathsFromSectionController:(IGListSectionController *)sectionController
                                                    indexes:(NSIndexSet *)indexes
                                 usePreviousIfInUpdateBlock:(BOOL)usePreviousIfInUpdateBlock {
    NSMutableArray<NSIndexPath *> *indexPaths = [NSMutableArray new];

    IGListSectionMap *map = [self _sectionMapUsingPreviousIfInUpdateBlock:usePreviousIfInUpdateBlock];
    const NSInteger section = [map sectionForSectionController:sectionController];
    if (section != NSNotFound) {
        [indexes enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
            [indexPaths addObject:[NSIndexPath indexPathForItem:idx inSection:section]];
        }];
    }
    return indexPaths;
}

- (NSIndexPath *)indexPathForSectionController:(IGListSectionController *)controller
                                         index:(NSInteger)index
                    usePreviousIfInUpdateBlock:(BOOL)usePreviousIfInUpdateBlock {
    IGListSectionMap *map = [self _sectionMapUsingPreviousIfInUpdateBlock:usePreviousIfInUpdateBlock];
    const NSInteger section = [map sectionForSectionController:controller];
    if (section == NSNotFound) {
        return nil;
    } else {
        return [NSIndexPath indexPathForItem:index inSection:section];
    }
}

- (NSArray<UICollectionViewLayoutAttributes *> *)_layoutAttributesForItemAndSupplementaryViewAtIndexPath:(NSIndexPath *)indexPath
                                                                                      supplementaryKinds:(NSArray<NSString *> *)supplementaryKinds {
    NSMutableArray<UICollectionViewLayoutAttributes *> *attributes = [NSMutableArray new];

    UICollectionViewLayoutAttributes *cellAttributes = [self _layoutAttributesForItemAtIndexPath:indexPath];
    if (cellAttributes) {
        [attributes addObject:cellAttributes];
    }

    for (NSString *kind in supplementaryKinds) {
        UICollectionViewLayoutAttributes *supplementaryAttributes = [self _layoutAttributesForSupplementaryViewOfKind:kind atIndexPath:indexPath];
        if (supplementaryAttributes) {
            [attributes addObject:supplementaryAttributes];
        }
    }

    return attributes;
}

- (nullable UICollectionViewLayoutAttributes *)_layoutAttributesForItemAtIndexPath:(NSIndexPath *)indexPath {
    return [self.collectionView layoutAttributesForItemAtIndexPath:indexPath];
}

- (nullable UICollectionViewLayoutAttributes *)_layoutAttributesForSupplementaryViewOfKind:(NSString *)elementKind
                                                                               atIndexPath:(NSIndexPath *)indexPath {
    return [self.collectionView layoutAttributesForSupplementaryElementOfKind:elementKind atIndexPath:indexPath];
}

- (void)mapView:(UICollectionReusableView *)view toSectionController:(IGListSectionController *)sectionController {
    IGAssertMainThread();
    IGParameterAssert(view != nil);
    IGParameterAssert(sectionController != nil);
    [_viewSectionControllerMap setObject:sectionController forKey:view];
}

- (nullable IGListSectionController *)sectionControllerForView:(UICollectionReusableView *)view {
    IGAssertMainThread();
    return [_viewSectionControllerMap objectForKey:view];
}

- (nullable IGListSectionController *)_sectionControllerForCell:(UICollectionViewCell *)cell {
    IGAssertMainThread();
    return [_viewSectionControllerMap objectForKey:cell];
}

- (void)removeMapForView:(UICollectionReusableView *)view {
    IGAssertMainThread();
    [_viewSectionControllerMap removeObjectForKey:view];
}

- (void)_deferBlockBetweenBatchUpdates:(void (^)(void))block {
    IGAssertMainThread();
    if (_queuedCompletionBlocks == nil) {
        block();
    } else {
        [_queuedCompletionBlocks addObject:block];
    }
}

- (void)_enterBatchUpdates {
    _queuedCompletionBlocks = [NSMutableArray new];
}

- (void)_exitBatchUpdates {
    NSArray *blocks = [_queuedCompletionBlocks copy];
    _queuedCompletionBlocks = nil;
    for (void (^block)(void) in blocks) {
        block();
    }
}

- (BOOL)isInDataUpdateBlock {
    return self.updater.isInDataUpdateBlock;
}

#pragma mark - UIScrollViewDelegate

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    id<IGListAdapterPerformanceDelegate> performanceDelegate = self.performanceDelegate;
    [performanceDelegate listAdapterWillCallScroll:self];

    // forward this method to the delegate b/c this implementation will steal the message from the proxy
    id<UIScrollViewDelegate> scrollViewDelegate = self.scrollViewDelegate;
    if ([scrollViewDelegate respondsToSelector:@selector(scrollViewDidScroll:)]) {
        [scrollViewDelegate scrollViewDidScroll:scrollView];
    }
    NSArray<IGListSectionController *> *visibleSectionControllers = [self visibleSectionControllers];
    for (IGListSectionController *sectionController in visibleSectionControllers) {
        [[sectionController scrollDelegate] listAdapter:self didScrollSectionController:sectionController];
    }

    [performanceDelegate listAdapter:self didCallScroll:scrollView];
}

- (void)scrollViewWillBeginDragging:(UIScrollView *)scrollView {
    // forward this method to the delegate b/c this implementation will steal the message from the proxy
    id<UIScrollViewDelegate> scrollViewDelegate = self.scrollViewDelegate;
    if ([scrollViewDelegate respondsToSelector:@selector(scrollViewWillBeginDragging:)]) {
        [scrollViewDelegate scrollViewWillBeginDragging:scrollView];
    }
    NSArray<IGListSectionController *> *visibleSectionControllers = [self visibleSectionControllers];
    for (IGListSectionController *sectionController in visibleSectionControllers) {
        [[sectionController scrollDelegate] listAdapter:self willBeginDraggingSectionController:sectionController];
    }
}

- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView willDecelerate:(BOOL)decelerate {
    // forward this method to the delegate b/c this implementation will steal the message from the proxy
    id<UIScrollViewDelegate> scrollViewDelegate = self.scrollViewDelegate;
    if ([scrollViewDelegate respondsToSelector:@selector(scrollViewDidEndDragging:willDecelerate:)]) {
        [scrollViewDelegate scrollViewDidEndDragging:scrollView willDecelerate:decelerate];
    }
    NSArray<IGListSectionController *> *visibleSectionControllers = [self visibleSectionControllers];
    for (IGListSectionController *sectionController in visibleSectionControllers) {
        [[sectionController scrollDelegate] listAdapter:self didEndDraggingSectionController:sectionController willDecelerate:decelerate];
    }
}

- (void)scrollViewDidEndDecelerating:(UIScrollView *)scrollView {
    // forward this method to the delegate b/c this implementation will steal the message from the proxy
    id<UIScrollViewDelegate> scrollViewDelegate = self.scrollViewDelegate;
    if ([scrollViewDelegate respondsToSelector:@selector(scrollViewDidEndDecelerating:)]) {
        [scrollViewDelegate scrollViewDidEndDecelerating:scrollView];
    }
    NSArray<IGListSectionController *> *visibleSectionControllers = [self visibleSectionControllers];
    for (IGListSectionController *sectionController in visibleSectionControllers) {
        id<IGListScrollDelegate> scrollDelegate = [sectionController scrollDelegate];
        if ([scrollDelegate respondsToSelector:@selector(listAdapter:didEndDeceleratingSectionController:)]) {
            [scrollDelegate listAdapter:self didEndDeceleratingSectionController:sectionController];
        }
    }
}

#pragma mark - IGListCollectionContext

- (CGSize)containerSize {
    return self.collectionView.bounds.size;
}

- (UITraitCollection *)traitCollection {
    return self.collectionView.traitCollection;
}

- (UIEdgeInsets)containerInset {
    return self.collectionView.contentInset;
}

- (UIEdgeInsets)adjustedContainerInset {
    return self.collectionView.ig_contentInset;
}

- (CGSize)insetContainerSize {
    UICollectionView *collectionView = self.collectionView;
    return UIEdgeInsetsInsetRect(collectionView.bounds, collectionView.ig_contentInset).size;
}

- (CGPoint)containerContentOffset {
    return self.collectionView.contentOffset;
}

- (IGListCollectionScrollingTraits)scrollingTraits {
    UICollectionView *collectionView = self.collectionView;
    return (IGListCollectionScrollingTraits) {
        .isTracking = collectionView.isTracking,
        .isDragging = collectionView.isDragging,
        .isDecelerating = collectionView.isDecelerating,
    };
}

- (CGSize)containerSizeForSectionController:(IGListSectionController *)sectionController {
    const UIEdgeInsets inset = sectionController.inset;
    return CGSizeMake(self.containerSize.width - inset.left - inset.right,
                      self.containerSize.height - inset.top - inset.bottom);
}

- (NSInteger)indexForCell:(UICollectionViewCell *)cell sectionController:(nonnull IGListSectionController *)sectionController {
    IGAssertMainThread();
    IGParameterAssert(cell != nil);
    IGParameterAssert(sectionController != nil);
    NSIndexPath *indexPath = [self.collectionView indexPathForCell:cell];
    IGAssert(indexPath == nil
             || indexPath.section == [self sectionForSectionController:sectionController],
             @"Requesting a cell from another section controller is not allowed.");
    return indexPath != nil ? indexPath.item : NSNotFound;
}

- (__kindof UICollectionViewCell *)cellForItemAtIndex:(NSInteger)index
                                    sectionController:(IGListSectionController *)sectionController {
    IGAssertMainThread();
    IGParameterAssert(sectionController != nil);

    // if this is accessed while a cell is being dequeued or displaying working range elements, just return nil
    if (_isDequeuingCell || _isSendingWorkingRangeDisplayUpdates) {
        return nil;
    }

    NSIndexPath *indexPath = [self indexPathForSectionController:sectionController index:index usePreviousIfInUpdateBlock:YES];
    // prevent querying the collection view if it isn't fully reloaded yet for the current data set
    if (indexPath != nil
        && indexPath.section < [self.collectionView numberOfSections]) {
        // only return a cell if it belongs to the section controller
        // this association is created in -collectionView:cellForItemAtIndexPath:
        UICollectionViewCell *cell = [self.collectionView cellForItemAtIndexPath:indexPath];

        if ([self _sectionControllerForCell:cell] == sectionController) {
            return cell;
        }
    }
    return nil;
}

- (__kindof UICollectionReusableView *)viewForSupplementaryElementOfKind:(NSString *)elementKind
                                                                 atIndex:(NSInteger)index
                                                       sectionController:(IGListSectionController *)sectionController {
    IGAssertMainThread();
    IGParameterAssert(sectionController != nil);

    // if this is accessed while a cell is being dequeued or displaying working range elements, just return nil
    if (_isDequeuingSupplementaryView || _isSendingWorkingRangeDisplayUpdates) {
        return nil;
    }

    NSIndexPath *indexPath = [self indexPathForSectionController:sectionController index:index usePreviousIfInUpdateBlock:YES];
    // prevent querying the collection view if it isn't fully reloaded yet for the current data set
    if (indexPath != nil
        && indexPath.section < [self.collectionView numberOfSections]) {
        // only return a supplementary view if it belongs to the section controller
        UICollectionReusableView *view = [self.collectionView supplementaryViewForElementKind:elementKind atIndexPath:indexPath];

        if ([self sectionControllerForView:view] == sectionController) {
            return view;
        }
    }
    return nil;
}

- (nullable UICollectionViewLayoutAttributes *)layoutAttributesForItemAtIndex:(NSInteger)index sectionController:(IGListSectionController *)sectionController {
    NSIndexPath *const indexPath = [self indexPathForSectionController:sectionController index:index usePreviousIfInUpdateBlock:NO];
    return [_collectionView.collectionViewLayout layoutAttributesForItemAtIndexPath:indexPath];
}

- (NSArray<UICollectionViewCell *> *)fullyVisibleCellsForSectionController:(IGListSectionController *)sectionController {
    const NSInteger section = [self sectionForSectionController:sectionController];
    if (section == NSNotFound) {
        // The section controller is not in the map, which can happen if the associated object was deleted or after a full reload.
        return @[];
    }

    NSMutableArray *cells = [NSMutableArray new];
    UICollectionView *collectionView = self.collectionView;
    NSArray *visibleCells = [collectionView visibleCells];

    for (UICollectionViewCell *cell in visibleCells) {
        if ([collectionView indexPathForCell:cell].section == section) {
            const CGRect cellRect = [cell convertRect:cell.bounds toView:collectionView];
            if (CGRectContainsRect(UIEdgeInsetsInsetRect(collectionView.bounds, collectionView.contentInset), cellRect)) {
                [cells addObject:cell];
            }
        }
    }
    return cells;
}

- (NSArray<UICollectionViewCell *> *)visibleCellsForSectionController:(IGListSectionController *)sectionController {
    const NSInteger section = [self sectionForSectionController:sectionController];
    if (section == NSNotFound) {
        // The section controller is not in the map, which can happen if the associated object was deleted or after a full reload.
        return @[];
    }

    NSMutableArray *cells = [NSMutableArray new];
    UICollectionView *collectionView = self.collectionView;
    NSArray *visibleCells = [collectionView visibleCells];

    for (UICollectionViewCell *cell in visibleCells) {
        if ([collectionView indexPathForCell:cell].section == section) {
            [cells addObject:cell];
        }
    }
    return cells;
}

- (NSArray<NSIndexPath *> *)visibleIndexPathsForSectionController:(IGListSectionController *) sectionController {
    const NSInteger section = [self sectionForSectionController:sectionController];
    if (section == NSNotFound) {
        // The section controller is not in the map, which can happen if the associated object was deleted or after a full reload.
        return @[];
    }

    NSMutableArray *paths = [NSMutableArray new];
    UICollectionView *collectionView = self.collectionView;
    NSArray *visiblePaths = [collectionView indexPathsForVisibleItems];

    for (NSIndexPath *path in visiblePaths) {
        if (path.section == section) {
            [paths addObject:path];
        }
    }
    return paths;
}

- (void)deselectItemAtIndex:(NSInteger)index
          sectionController:(IGListSectionController *)sectionController
                   animated:(BOOL)animated {
    IGAssertMainThread();
    IGParameterAssert(sectionController != nil);
    NSIndexPath *indexPath = [self indexPathForSectionController:sectionController index:index usePreviousIfInUpdateBlock:NO];
    [self.collectionView deselectItemAtIndexPath:indexPath animated:animated];
}

- (void)selectItemAtIndex:(NSInteger)index
        sectionController:(IGListSectionController *)sectionController
                 animated:(BOOL)animated
           scrollPosition:(UICollectionViewScrollPosition)scrollPosition {
    IGAssertMainThread();
    IGParameterAssert(sectionController != nil);
    NSIndexPath *indexPath = [self indexPathForSectionController:sectionController index:index usePreviousIfInUpdateBlock:NO];
    [self.collectionView selectItemAtIndexPath:indexPath animated:animated scrollPosition:scrollPosition];
}

- (__kindof UICollectionViewCell *)dequeueReusableCellOfClass:(Class)cellClass
                                          withReuseIdentifier:(NSString *)reuseIdentifier
                                         forSectionController:(IGListSectionController *)sectionController
                                                      atIndex:(NSInteger)index {
    IGAssertMainThread();
    IGParameterAssert(sectionController != nil);
    IGParameterAssert(cellClass != nil);
    IGParameterAssert(index >= 0);
    UICollectionView *collectionView = self.collectionView;
    IGAssert(collectionView != nil, @"Dequeueing cell of class %@ with reuseIdentifier %@ from section controller %@ without a collection view at index %li", NSStringFromClass(cellClass), reuseIdentifier, sectionController, (long)index);
    NSString *identifier = IGListReusableViewIdentifier(cellClass, nil, reuseIdentifier);
    NSIndexPath *indexPath = [self indexPathForSectionController:sectionController index:index usePreviousIfInUpdateBlock:NO];
    if (![self.registeredCellIdentifiers containsObject:identifier]) {
        [self.registeredCellIdentifiers addObject:identifier];
        [collectionView registerClass:cellClass forCellWithReuseIdentifier:identifier];
    }
    return [self _dequeueReusableCellWithReuseIdentifier:identifier forIndexPath:indexPath forSectionController:sectionController];
}

- (__kindof UICollectionViewCell *)dequeueReusableCellOfClass:(Class)cellClass
                                         forSectionController:(IGListSectionController *)sectionController
                                                      atIndex:(NSInteger)index {
    return [self dequeueReusableCellOfClass:cellClass withReuseIdentifier:nil forSectionController:sectionController atIndex:index];
}

- (__kindof UICollectionViewCell *)dequeueReusableCellFromStoryboardWithIdentifier:(NSString *)identifier
                                                              forSectionController:(IGListSectionController *)sectionController
                                                                           atIndex:(NSInteger)index {
    IGAssertMainThread();
    IGParameterAssert(sectionController != nil);
    IGParameterAssert(identifier.length > 0);
    IGAssert(self.collectionView != nil, @"Reloading adapter without a collection view.");
    NSIndexPath *indexPath = [self indexPathForSectionController:sectionController index:index usePreviousIfInUpdateBlock:NO];
    return [self _dequeueReusableCellWithReuseIdentifier:identifier forIndexPath:indexPath forSectionController:sectionController];
}

- (UICollectionViewCell *)dequeueReusableCellWithNibName:(NSString *)nibName
                                                  bundle:(NSBundle *)bundle
                                    forSectionController:(IGListSectionController *)sectionController
                                                 atIndex:(NSInteger)index {
    IGAssertMainThread();
    IGParameterAssert([nibName length] > 0);
    IGParameterAssert(sectionController != nil);
    IGParameterAssert(index >= 0);
    UICollectionView *collectionView = self.collectionView;
    IGAssert(collectionView != nil, @"Dequeueing cell with nib name %@ and bundle %@ from section controller %@ without a collection view at index %li.", nibName, bundle, sectionController, (long)index);
    NSIndexPath *indexPath = [self indexPathForSectionController:sectionController index:index usePreviousIfInUpdateBlock:NO];
    if (![self.registeredNibNames containsObject:nibName]) {
        [self.registeredNibNames addObject:nibName];
        UINib *nib = [UINib nibWithNibName:nibName bundle:bundle];
        [collectionView registerNib:nib forCellWithReuseIdentifier:nibName];
    }
    return [self _dequeueReusableCellWithReuseIdentifier:nibName forIndexPath:indexPath forSectionController:sectionController];
}

- (UICollectionViewCell *)_dequeueReusableCellWithReuseIdentifier:(NSString *)identifier forIndexPath:(NSIndexPath *)indexPath forSectionController:(IGListSectionController *)sectionController {
    // These will cause a crash in iOS 18
    IGAssert(_dequeuedCells.count == 0, @"Dequeueing more than one cell (%@) for indexPath %@, section controller %@,", identifier, indexPath, sectionController);
    IGAssert(_isDequeuingCell, @"Dequeueing a cell (%@) without a request from the UICollectionView for indexPath %@, section controller %@", identifier, indexPath, sectionController);

    UICollectionViewCell *const cell = [self.collectionView dequeueReusableCellWithReuseIdentifier:identifier forIndexPath:indexPath];
    if (_isDequeuingCell && cell) {
        [_dequeuedCells addObject:cell];
    }
    return cell;
}

- (__kindof UICollectionReusableView *)dequeueReusableSupplementaryViewOfKind:(NSString *)elementKind
                                                         forSectionController:(IGListSectionController *)sectionController
                                                                        class:(Class)viewClass
                                                                      atIndex:(NSInteger)index {
    IGAssertMainThread();
    IGParameterAssert(elementKind.length > 0);
    IGParameterAssert(sectionController != nil);
    IGParameterAssert(viewClass != nil);
    IGParameterAssert(index >= 0);
    UICollectionView *collectionView = self.collectionView;
    IGAssert(collectionView != nil, @"Dequeueing cell of class %@ from section controller %@ without a collection view at index %li with supplementary view %@", NSStringFromClass(viewClass), sectionController, (long)index, elementKind);
    NSString *identifier = IGListReusableViewIdentifier(viewClass, elementKind, nil);
    NSIndexPath *indexPath = [self indexPathForSectionController:sectionController index:index usePreviousIfInUpdateBlock:NO];
    if (![self.registeredSupplementaryViewIdentifiers containsObject:identifier]) {
        [self.registeredSupplementaryViewIdentifiers addObject:identifier];
        [collectionView registerClass:viewClass forSupplementaryViewOfKind:elementKind withReuseIdentifier:identifier];
    }
    return [self _dequeueReusableSupplementaryViewOfKind:elementKind withReuseIdentifier:identifier forIndexPath:indexPath forSectionController:sectionController];
}

- (__kindof UICollectionReusableView *)dequeueReusableSupplementaryViewFromStoryboardOfKind:(NSString *)elementKind
                                                                             withIdentifier:(NSString *)identifier
                                                                       forSectionController:(IGListSectionController *)sectionController
                                                                                    atIndex:(NSInteger)index {
    IGAssertMainThread();
    IGParameterAssert(elementKind.length > 0);
    IGParameterAssert(identifier.length > 0);
    IGParameterAssert(sectionController != nil);
    IGParameterAssert(index >= 0);
    IGAssert(self.collectionView != nil, @"Dequeueing Supplementary View from storyboard of kind %@ with identifier %@ for section controller %@ without a collection view at index %li", elementKind, identifier, sectionController, (long)index);
    NSIndexPath *indexPath = [self indexPathForSectionController:sectionController index:index usePreviousIfInUpdateBlock:NO];
    return [self _dequeueReusableSupplementaryViewOfKind:elementKind withReuseIdentifier:identifier forIndexPath:indexPath forSectionController:sectionController];
}

- (__kindof UICollectionReusableView *)dequeueReusableSupplementaryViewOfKind:(NSString *)elementKind
                                                         forSectionController:(IGListSectionController *)sectionController
                                                                      nibName:(NSString *)nibName
                                                                       bundle:(NSBundle *)bundle
                                                                      atIndex:(NSInteger)index {
    IGAssertMainThread();
    IGParameterAssert([nibName length] > 0);
    IGParameterAssert([elementKind length] > 0);
    UICollectionView *collectionView = self.collectionView;
    IGAssert(collectionView != nil, @"Reloading adapter without a collection view.");
    NSIndexPath *indexPath = [self indexPathForSectionController:sectionController index:index usePreviousIfInUpdateBlock:NO];
    if (![self.registeredSupplementaryViewNibNames containsObject:nibName]) {
        [self.registeredSupplementaryViewNibNames addObject:nibName];
        UINib *nib = [UINib nibWithNibName:nibName bundle:bundle];
        [collectionView registerNib:nib forSupplementaryViewOfKind:elementKind withReuseIdentifier:nibName];
    }
    return [self _dequeueReusableSupplementaryViewOfKind:elementKind withReuseIdentifier:nibName forIndexPath:indexPath forSectionController:sectionController];
}

- (__kindof UICollectionReusableView *)_dequeueReusableSupplementaryViewOfKind:(NSString *)elementKind
                                                           withReuseIdentifier:(NSString *)identifier
                                                                  forIndexPath:(NSIndexPath *)indexPath
                                                          forSectionController:(IGListSectionController *)sectionController {
    // These will cause a crash in iOS 18
    IGAssert(_dequeuedSupplementaryViews.count == 0, @"Dequeueing more than one supplementary-view (%@) for indexPath %@, section controller %@,", identifier, indexPath, sectionController);
    IGAssert(_isDequeuingSupplementaryView, @"Dequeueing a supplementary-view (%@) without a request from the UICollectionView for indexPath %@, section controller %@", identifier, indexPath, sectionController);

    UICollectionReusableView *const view = [self.collectionView dequeueReusableSupplementaryViewOfKind:elementKind withReuseIdentifier:identifier forIndexPath:indexPath];
    if (_isDequeuingSupplementaryView && view) {
        [_dequeuedSupplementaryViews addObject:view];
    }
    return view;
}

- (void)performBatchAnimated:(BOOL)animated updates:(void (^)(id<IGListBatchContext>))updates completion:(void (^)(BOOL))completion {
    IGAssertMainThread();
    IGParameterAssert(updates != nil);
    IGWarn(self.collectionView != nil, @"Performing batch updates without a collection view.");

    [self _enterBatchUpdates];
    __weak __typeof__(self) weakSelf = self;
    [self.updater performUpdateWithCollectionViewBlock:[self _collectionViewBlock] animated:animated itemUpdates:^{
        // the adapter acts as the batch context with its API stripped to just the IGListBatchContext protocol
        updates(weakSelf);
    } completion: ^(BOOL finished) {
        [weakSelf _updateBackgroundView];
        [weakSelf _notifyDidUpdate:IGListAdapterUpdateTypeItemUpdates animated:animated];
        if (completion) {
            completion(finished);
        }
        [weakSelf _exitBatchUpdates];
    }];
}

- (void)scrollToSectionController:(IGListSectionController *)sectionController
                          atIndex:(NSInteger)index
                   scrollPosition:(UICollectionViewScrollPosition)scrollPosition
                         animated:(BOOL)animated {
    IGAssertMainThread();
    IGParameterAssert(sectionController != nil);

    NSIndexPath *indexPath = [self indexPathForSectionController:sectionController index:index usePreviousIfInUpdateBlock:NO];
    [self.collectionView scrollToItemAtIndexPath:indexPath atScrollPosition:scrollPosition animated:animated];
}

- (void)invalidateLayoutForSectionController:(IGListSectionController *)sectionController
                                  completion:(void (^)(BOOL finished))completion {
    __weak __typeof__(self) weakSelf = self;

    // do not call -[UICollectionView performBatchUpdates:completion:] while already updating. defer it until completed.
    [self _deferBlockBetweenBatchUpdates:^{
        // Note that we calculate the `NSIndexPaths` after the batch update, otherwise they're be wrong.
        [weakSelf _invalidateLayoutForSectionController:sectionController completion:completion];
    }];
}

- (void)_invalidateLayoutForSectionController:(IGListSectionController *)sectionController
                                   completion:(void (^)(BOOL finished))completion {
    const NSInteger section = [self sectionForSectionController:sectionController];
    if (section == NSNotFound) {
        // The section controller is not in the map, which can happen if the associated object was deleted or after a full reload.
        if (completion) {
            completion(NO);
        }
        return;
    }

    const NSInteger items = [_collectionView numberOfItemsInSection:section];

    NSMutableArray<NSIndexPath *> *indexPaths = [NSMutableArray new];
    for (NSInteger item = 0; item < items; item++) {
        [indexPaths addObject:[NSIndexPath indexPathForItem:item inSection:section]];
    }

    UICollectionViewLayout *layout = _collectionView.collectionViewLayout;
    UICollectionViewLayoutInvalidationContext *context = [[[layout.class invalidationContextClass] alloc] init];
    [context invalidateItemsAtIndexPaths:indexPaths];

    [_collectionView performBatchUpdates:^{
        [layout invalidateLayoutWithContext:context];
    } completion:completion];
}

#pragma mark - IGListBatchContext

- (void)reloadInSectionController:(IGListSectionController *)sectionController atIndexes:(NSIndexSet *)indexes {
    IGAssertMainThread();
    IGParameterAssert(indexes != nil);
    IGParameterAssert(sectionController != nil);
    UICollectionView *collectionView = self.collectionView;
    IGAssert(collectionView != nil, @"Tried to reload the adapter from %@ without a collection view at indexes %@.", sectionController, indexes);

    if (indexes.count == 0) {
        return;
    }

    /**
     UICollectionView is not designed to support -reloadSections: or -reloadItemsAtIndexPaths: during batch updates.
     Internally it appears to convert these operations to a delete+insert. However the transformation is too simple
     in that it doesn't account for the item's section being moved (naturally or explicitly) and can queue animation
     collisions.

     If you have an object at section 2 with 4 items and attempt to reload item at index 1, you would create an
     NSIndexPath at section: 2, item: 1. Within -performBatchUpdates:, UICollectionView converts this to a delete
     and insert at the same NSIndexPath.

     If a section were inserted at position 2, the original section 2 has naturally shifted to section 3. However,
     the insert NSIndexPath is section: 2, item: 1. Now the UICollectionView has a section animation at section 2,
     as well as an item insert animation at section: 2, item: 1, and it will throw an exception.

     IGListAdapter tracks the before/after mapping of section controllers to make precise NSIndexPath conversions.
     */
    [indexes enumerateIndexesUsingBlock:^(NSUInteger index, BOOL *stop) {
        NSIndexPath *fromIndexPath = [self indexPathForSectionController:sectionController index:index usePreviousIfInUpdateBlock:YES];
        NSIndexPath *toIndexPath = [self indexPathForSectionController:sectionController index:index usePreviousIfInUpdateBlock:NO];
        // index paths could be nil if a section controller is prematurely reloading or a reload was batched with
        // the section controller being deleted
        if (fromIndexPath != nil && toIndexPath != nil) {
            [self.updater reloadItemInCollectionView:collectionView fromIndexPath:fromIndexPath toIndexPath:toIndexPath];
        }
    }];
}

- (void)insertInSectionController:(IGListSectionController *)sectionController atIndexes:(NSIndexSet *)indexes {
    IGAssertMainThread();
    IGParameterAssert(indexes != nil);
    IGParameterAssert(sectionController != nil);
    UICollectionView *collectionView = self.collectionView;
    IGAssert(collectionView != nil, @"Inserting items from %@ without a collection view at indexes %@.", sectionController, indexes);

    if (indexes.count == 0) {
        return;
    }

    NSArray *indexPaths = [self indexPathsFromSectionController:sectionController indexes:indexes usePreviousIfInUpdateBlock:NO];
    [self.updater insertItemsIntoCollectionView:collectionView indexPaths:indexPaths];

    if (![self isInDataUpdateBlock]) {
        [self _updateBackgroundView];
    }
}

- (void)deleteInSectionController:(IGListSectionController *)sectionController atIndexes:(NSIndexSet *)indexes {
    IGAssertMainThread();
    IGParameterAssert(indexes != nil);
    IGParameterAssert(sectionController != nil);
    UICollectionView *collectionView = self.collectionView;
    IGAssert(collectionView != nil, @"Deleting items from %@ without a collection view at indexes %@.", sectionController, indexes);

    if (indexes.count == 0) {
        return;
    }

    NSArray *indexPaths = [self indexPathsFromSectionController:sectionController indexes:indexes usePreviousIfInUpdateBlock:YES];
    [self.updater deleteItemsFromCollectionView:collectionView indexPaths:indexPaths];

    if (![self isInDataUpdateBlock]) {
        [self _updateBackgroundView];
    }
}

- (void)invalidateLayoutInSectionController:(IGListSectionController *)sectionController atIndexes:(NSIndexSet *)indexes {
    IGAssertMainThread();
    IGParameterAssert(indexes != nil);
    IGParameterAssert(sectionController != nil);
    UICollectionView *collectionView = self.collectionView;
    IGAssert(collectionView != nil, @"Invalidating items from %@ without a collection view at indexes %@.", sectionController, indexes);

    if (indexes.count == 0) {
        return;
    }

    NSArray *indexPaths = [self indexPathsFromSectionController:sectionController indexes:indexes usePreviousIfInUpdateBlock:NO];
    UICollectionViewLayout *layout = collectionView.collectionViewLayout;
    UICollectionViewLayoutInvalidationContext *context = [[[layout.class invalidationContextClass] alloc] init];
    [context invalidateItemsAtIndexPaths:indexPaths];
    [layout invalidateLayoutWithContext:context];
}

- (void)moveInSectionController:(IGListSectionController *)sectionController fromIndex:(NSInteger)fromIndex toIndex:(NSInteger)toIndex {
    IGAssertMainThread();
    IGParameterAssert(sectionController != nil);
    IGParameterAssert(fromIndex >= 0);
    IGParameterAssert(toIndex >= 0);
    UICollectionView *collectionView = self.collectionView;
    IGAssert(collectionView != nil, @"Moving items from %@ without a collection view from index %li to index %li.",
             sectionController, (long)fromIndex, (long)toIndex);

    NSIndexPath *fromIndexPath = [self indexPathForSectionController:sectionController index:fromIndex usePreviousIfInUpdateBlock:YES];
    NSIndexPath *toIndexPath = [self indexPathForSectionController:sectionController index:toIndex usePreviousIfInUpdateBlock:NO];

    if (fromIndexPath == nil || toIndexPath == nil) {
        return;
    }

    [self.updater moveItemInCollectionView:collectionView fromIndexPath:fromIndexPath toIndexPath:toIndexPath];
}

- (void)reloadSectionController:(IGListSectionController *)sectionController {
    IGAssertMainThread();
    IGParameterAssert(sectionController != nil);
    UICollectionView *collectionView = self.collectionView;
    IGAssert(collectionView != nil, @"Reloading items from %@ without a collection view.", sectionController);

    IGListSectionMap *map = [self _sectionMapUsingPreviousIfInUpdateBlock:YES];
    const NSInteger section = [map sectionForSectionController:sectionController];
    if (section == NSNotFound) {
        return;
    }

    NSIndexSet *sections = [NSIndexSet indexSetWithIndex:section];
    [self.updater reloadCollectionView:collectionView sections:sections];

    if (![self isInDataUpdateBlock]) {
        [self _updateBackgroundView];
    }
}

- (void)moveSectionControllerInteractive:(IGListSectionController *)sectionController
                               fromIndex:(NSInteger)fromIndex
                                 toIndex:(NSInteger)toIndex NS_AVAILABLE_IOS(9_0) {
    IGAssertMainThread();
    IGParameterAssert(sectionController != nil);
    IGParameterAssert(fromIndex >= 0);
    IGParameterAssert(toIndex >= 0);
    UICollectionView *collectionView = self.collectionView;
    IGAssert(collectionView != nil, @"Moving section %@ without a collection view from index %li to index %li.",
             sectionController, (long)fromIndex, (long)toIndex);
    IGAssert(self.moveDelegate != nil, @"Moving section %@ without a moveDelegate set", sectionController);

    if (fromIndex != toIndex) {
        id<IGListAdapterDataSource> dataSource = self.dataSource;

        NSArray *previousObjects = [self.sectionMap objects];

        if (self.isLastInteractiveMoveToLastSectionIndex) {
            self.isLastInteractiveMoveToLastSectionIndex = NO;
        }
        else if (fromIndex < toIndex) {
            toIndex -= 1;
        }

        NSMutableArray *mutObjects = [previousObjects mutableCopy];
        id object = [previousObjects objectAtIndex:fromIndex];
        [mutObjects removeObjectAtIndex:fromIndex];
        [mutObjects insertObject:object atIndex:toIndex];

        NSArray *objects = [mutObjects copy];

        // inform the data source to update its model
        [self.moveDelegate listAdapter:self moveObject:object from:previousObjects to:objects];

        // update our model based on that provided by the data source
        NSArray<id<IGListDiffable>> *updatedObjects = [dataSource objectsForListAdapter:self];
        [self _updateObjects:updatedObjects dataSource:dataSource];
    }

    // even if from and to index are equal, we need to perform the "move"
    // iOS interactively moves items, not sections, so we might have actually moved the item
    // to the end of the preceeding section or beginning of the following section
    [self.updater moveSectionInCollectionView:collectionView fromIndex:fromIndex toIndex:toIndex];
}

- (void)moveInSectionControllerInteractive:(IGListSectionController *)sectionController
                                 fromIndex:(NSInteger)fromIndex
                                   toIndex:(NSInteger)toIndex NS_AVAILABLE_IOS(9_0) {
    IGAssertMainThread();
    IGParameterAssert(sectionController != nil);
    IGParameterAssert(fromIndex >= 0);
    IGParameterAssert(toIndex >= 0);

    [sectionController moveObjectFromIndex:fromIndex toIndex:toIndex];
}

- (void)revertInvalidInteractiveMoveFromIndexPath:(NSIndexPath *)sourceIndexPath
                                      toIndexPath:(NSIndexPath *)destinationIndexPath NS_AVAILABLE_IOS(9_0) {
    UICollectionView *collectionView = self.collectionView;
    IGAssert(collectionView != nil, @"Reverting move without a collection view from %@ to %@.",
             sourceIndexPath, destinationIndexPath);

    // revert by moving back in the opposite direction
    [collectionView moveItemAtIndexPath:destinationIndexPath toIndexPath:sourceIndexPath];
}

- (NSIndexPath *_Nullable)indexPathForItemAtPoint:(CGPoint)point {
    return [self.collectionView indexPathForItemAtPoint:point];
}

- (CGPoint)convertPoint:(CGPoint)point fromView:(nullable UIView *)view {
    return [self.collectionView convertPoint:point fromView:view];
}

@end
