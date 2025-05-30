/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import <XCTest/XCTest.h>

#import <OCMock/OCMock.h>

#import <IGListKit/IGListKit.h>

#import "IGListAdapterInternal.h"
#import "IGListAdapterUpdateTester.h"
#import "IGListAdapterUpdater.h"
#import "IGListAdapterUpdaterInternal.h"
#import "IGListTestCase.h"
#import "IGListTestCollectionViewLayout.h"
#import "IGListTestHelpers.h"
#import "IGListTestOffsettingLayout.h"
#import "IGListUpdateTransactionBuilder.h"
#import "IGTestCell.h"
#import "IGTestDelegateController.h"
#import "IGTestDelegateDataSource.h"
#import "IGTestObject.h"

@interface IGListAdapterE2ETests : IGListTestCase
@end

@implementation IGListAdapterE2ETests

- (void)setUp {
    self.workingRangeSize = 2;

    self.dataSource = [IGTestDelegateDataSource new];
    [super setUp];
}

- (void)test_whenSettingUpTest_thenCollectionViewIsLoaded {
    [self setupWithObjects:@[
        genTestObject(@1, @2),
        genTestObject(@2, @3)
    ]];
    XCTAssertEqual(self.collectionView.numberOfSections, 2);
    XCTAssertEqual([self.collectionView numberOfItemsInSection:0], 2);
    XCTAssertEqual([self.collectionView numberOfItemsInSection:1], 3);
}

- (void)test_whenUsingStringValue_thenCellLabelsAreConfigured {
    [self setupWithObjects:@[
        genTestObject(@0, @"Foo"),
        genTestObject(@1, @"Bar")
    ]];

    IGTestCell *cell = (IGTestCell*)[self.collectionView cellForItemAtIndexPath:genIndexPath(0, 0)];
    XCTAssertEqualObjects(cell.label.text, @"Foo");
    XCTAssertEqual(cell.delegate, [self.adapter sectionControllerForObject:self.dataSource.objects[0]]);
}

- (void)test_whenUpdating_withEqualObjects_thatCellConfigurationDoesntChange {
    [self setupWithObjects:@[
        genTestObject(@0, @"Foo"),
        genTestObject(@1, @"Bar")
    ]];

    // Get the section controller before we change the data source or perform updates
    id c0 = [self.adapter sectionControllerForObject:self.dataSource.objects[0]];

    // Set equal but new-instance objects on the data source
    self.dataSource.objects = @[
        genTestObject(@0, @"Foo"),
        genTestObject(@1, @"Bar")
    ];

    // Perform updates on the adapter and check that the cell config uses the same section controller as before the updates
    XCTestExpectation *expectation = genExpectation;
    [self.adapter performUpdatesAnimated:YES completion:^(BOOL finished) {
        IGTestCell *cell = (IGTestCell*)[self.collectionView cellForItemAtIndexPath:genIndexPath(0, 0)];
        XCTAssertEqualObjects(cell.label.text, @"Foo");
        XCTAssertNotNil(cell.delegate);
        XCTAssertEqual(cell.delegate, c0);
        XCTAssertEqual(cell.delegate, [self.adapter sectionControllerForObject:self.dataSource.objects[0]]);
        [expectation fulfill];
    }];
    [self waitForExpectationsWithTimeout:30 handler:nil];
}

- (void)test_whenReloadingItem_cellConfigurationChanges {
    [self setupWithObjects:@[
        genTestObject(@0, @"Foo"),
        genTestObject(@1, @"Bar")
    ]];

    // make sure our cells are propertly configured
    IGTestCell *cell1 = (IGTestCell*)[self.collectionView cellForItemAtIndexPath:genIndexPath(0, 0)];
    IGTestCell *cell2 = (IGTestCell*)[self.collectionView cellForItemAtIndexPath:genIndexPath(1, 0)];
    XCTAssertEqualObjects(cell1.label.text, @"Foo");
    XCTAssertEqualObjects(cell2.label.text, @"Bar");

    // Change the string value of both instances in the data source
    IGTestObject *item1 = self.dataSource.objects[0];
    item1.value = @"Baz";
    IGTestObject *item2 = self.dataSource.objects[1];
    item2.value = @"Quz";

    // Only reload the first item, not the second
    [self.adapter reloadObjects:@[item1]];

    // The collection view will likely create new cells
    cell1 = (IGTestCell*)[self.collectionView cellForItemAtIndexPath:genIndexPath(0, 0)];
    cell2 = (IGTestCell*)[self.collectionView cellForItemAtIndexPath:genIndexPath(1, 0)];

    // Make sure that the cell in the first section was reloaded
    XCTAssertEqualObjects(cell1.label.text, @"Baz");
    // The cell in the second section should not be reloaded and should equal the string value from setup
    XCTAssertEqualObjects(cell2.label.text, @"Bar");
}

- (void)test_whenObjectEqualityChanges_thatSectionCountChanges {
    [self setupWithObjects:@[
        genTestObject(@1, @2),
        genTestObject(@2, @2)
    ]];

    self.dataSource.objects = @[
        genTestObject(@1, @2),
        genTestObject(@2, @3), // updated to 3 items (from 2)
        genTestObject(@3, @2), // insert new object
    ];

    XCTestExpectation *expectation = genExpectation;
    [self.adapter performUpdatesAnimated:YES completion:^(BOOL finished2) {
        XCTAssertEqual(self.collectionView.numberOfSections, 3);
        XCTAssertEqual([self.collectionView numberOfItemsInSection:0], 2);
        XCTAssertEqual([self.collectionView numberOfItemsInSection:1], 3);
        XCTAssertEqual([self.collectionView numberOfItemsInSection:2], 2);
        [expectation fulfill];
    }];
    [self waitForExpectationsWithTimeout:30 handler:nil];
}

- (void)test_whenUpdatesComplete_thatCellsExist {
    [self setupWithObjects:@[
        genTestObject(@1, @2),
        genTestObject(@2, @2),
    ]];
    XCTestExpectation *expectation = genExpectation;
    [self.adapter performUpdatesAnimated:YES completion:^(BOOL finished) {
        XCTAssertNotNil([self.collectionView cellForItemAtIndexPath:[NSIndexPath indexPathForItem:0 inSection:0]]);
        XCTAssertNotNil([self.collectionView cellForItemAtIndexPath:[NSIndexPath indexPathForItem:1 inSection:0]]);
        XCTAssertNotNil([self.collectionView cellForItemAtIndexPath:[NSIndexPath indexPathForItem:0 inSection:1]]);
        XCTAssertNotNil([self.collectionView cellForItemAtIndexPath:[NSIndexPath indexPathForItem:1 inSection:1]]);
        [expectation fulfill];
    }];
    [self waitForExpectationsWithTimeout:30 handler:nil];
}

- (void)test_whenReloadDataCompletes_thatCellsExist {
    [self setupWithObjects:@[
        genTestObject(@1, @2),
        genTestObject(@2, @2)
    ]];
    XCTestExpectation *expectation = genExpectation;
    [self.adapter reloadDataWithCompletion:^(BOOL finished) {
        XCTAssertNotNil([self.collectionView cellForItemAtIndexPath:[NSIndexPath indexPathForItem:0 inSection:0]]);
        XCTAssertNotNil([self.collectionView cellForItemAtIndexPath:[NSIndexPath indexPathForItem:1 inSection:0]]);
        XCTAssertNotNil([self.collectionView cellForItemAtIndexPath:[NSIndexPath indexPathForItem:0 inSection:1]]);
        XCTAssertNotNil([self.collectionView cellForItemAtIndexPath:[NSIndexPath indexPathForItem:1 inSection:1]]);
        [expectation fulfill];
    }];
    [self waitForExpectationsWithTimeout:30 handler:nil];
}

- (void)test_whenSectionControllerInsertsIndexes_thatCountsAreUpdated {
    [self setupWithObjects:@[
        genTestObject(@1, @2),
        genTestObject(@2, @2)
    ]];

    IGTestObject *object = self.dataSource.objects[0];
    IGListSectionController *sectionController = [self.adapter sectionControllerForObject:object];

    XCTestExpectation *expectation = genExpectation;
    [sectionController.collectionContext performBatchAnimated:YES updates:^(id<IGListBatchContext> batchContext) {
        object.value = @3;
        [batchContext insertInSectionController:sectionController atIndexes:[NSIndexSet indexSetWithIndex:2]];
    } completion:^(BOOL finished2) {
        XCTAssertEqual([self.collectionView numberOfSections], 2);
        XCTAssertEqual([self.collectionView numberOfItemsInSection:0], 3);
        [expectation fulfill];
    }];
    [self waitForExpectationsWithTimeout:30 handler:nil];
}

- (void)test_whenSectionControllerDeletesIndexes_thatCountsAreUpdated {
    // 2 sections each with 2 objects
    [self setupWithObjects:@[
        genTestObject(@1, @2),
        genTestObject(@2, @2)
    ]];

    IGTestObject *object = self.dataSource.objects[0];
    IGListSectionController *sectionController = [self.adapter sectionControllerForObject:object];

    XCTestExpectation *expectation = genExpectation;
    [sectionController.collectionContext performBatchAnimated:YES updates:^(id<IGListBatchContext> batchContext) {
        object.value = @1;
        [batchContext deleteInSectionController:sectionController atIndexes:[NSIndexSet indexSetWithIndex:0]];
    } completion:^(BOOL finished2) {
        XCTAssertEqual([self.collectionView numberOfSections], 2);
        XCTAssertEqual([self.collectionView numberOfItemsInSection:0], 1);
        [expectation fulfill];
    }];
    [self waitForExpectationsWithTimeout:30 handler:nil];
}

- (void)test_whenSectionControllerReloadsIndexes_thatCellConfigurationUpdates {
    [self setupWithObjects:@[
        genTestObject(@1, @"a"),
        genTestObject(@2, @"b")
    ]];
    XCTAssertEqual([self.collectionView numberOfSections], 2);
    IGTestCell *cell = (IGTestCell *)[self.collectionView cellForItemAtIndexPath:[NSIndexPath indexPathForItem:0 inSection:0]];
    XCTAssertEqualObjects(cell.label.text, @"a");

    IGTestObject *object = self.dataSource.objects[0];
    IGListSectionController *sectionController = [self.adapter sectionControllerForObject:object];

    XCTestExpectation *expectation = genExpectation;
    [sectionController.collectionContext performBatchAnimated:YES updates:^(id<IGListBatchContext> batchContext) {
        object.value = @"c";
        [batchContext reloadInSectionController:sectionController atIndexes:[NSIndexSet indexSetWithIndex:0]];
    } completion:^(BOOL finished2) {
        XCTAssertEqual([self.collectionView numberOfSections], 2);
        IGTestCell *updatedCell = (IGTestCell *)[self.collectionView cellForItemAtIndexPath:[NSIndexPath indexPathForItem:0 inSection:0]];
        XCTAssertEqualObjects(updatedCell.label.text, @"c");
        [expectation fulfill];
    }];
    [self waitForExpectationsWithTimeout:30 handler:nil];
}

- (void)test_whenSectionControllerReloads_thatCountsAreUpdated {
    [self setupWithObjects:@[
        genTestObject(@1, @2),
        genTestObject(@2, @2)
    ]];

    IGTestObject *object = self.dataSource.objects[0];
    IGListSectionController *sectionController = [self.adapter sectionControllerForObject:object];

    XCTestExpectation *expectation = genExpectation;
    [sectionController.collectionContext performBatchAnimated:YES updates:^(id<IGListBatchContext> batchContext) {
        object.value = @3;
        [batchContext reloadSectionController:sectionController];
    } completion:^(BOOL finished2) {
        XCTAssertEqual([self.collectionView numberOfSections], 2);
        XCTAssertEqual([self.collectionView numberOfItemsInSection:0], 3);
        [expectation fulfill];
    }];
    [self waitForExpectationsWithTimeout:30 handler:nil];
}

- (void)test_whenSectionControllerReloads_withPreferItemReload_thatCountsAreUpdated {
    [self setupWithObjects:@[
        genTestObject(@1, @2),
        genTestObject(@2, @2)
    ]];

    IGTestObject *object = self.dataSource.objects[0];
    IGListSectionController *sectionController = [self.adapter sectionControllerForObject:object];

    // Prefer to use item reloads for section reloads if available.
    [(IGListAdapterUpdater *)self.adapter.updater setPreferItemReloadsForSectionReloads:YES];

    XCTestExpectation *expectation = genExpectation;
    [sectionController.collectionContext performBatchAnimated:YES updates:^(id<IGListBatchContext> batchContext) {
        object.value = @3;
        [batchContext reloadSectionController:sectionController];
    } completion:^(BOOL finished2) {
        XCTAssertEqual([self.collectionView numberOfSections], 2);
        XCTAssertEqual([self.collectionView numberOfItemsInSection:0], 3);
        [expectation fulfill];
    }];
    [self waitForExpectationsWithTimeout:30 handler:nil];
}

- (void)test_whenPerformingUpdates_withSectionControllerMutations_thatCollectionCountsAreUpdated {
    [self setupWithObjects:@[
        genTestObject(@1, @2),
        genTestObject(@2, @2)
    ]];
    IGTestObject *object1 = self.dataSource.objects[0];
    IGTestObject *object2 = self.dataSource.objects[1];

    // insert a new object in front of the one we are doing an item-level insert on
    self.dataSource.objects = @[
        genTestObject(@3, @1), // new
        object1,
        object2,
    ];

    IGListSectionController *sectionController1 = [self.adapter sectionControllerForObject:object1];
    IGListSectionController *sectionController2 = [self.adapter sectionControllerForObject:object2];

    [self.adapter performUpdatesAnimated:YES completion:nil];

    XCTestExpectation *expectation = genExpectation;
    [sectionController1.collectionContext performBatchAnimated:YES updates:^(id<IGListBatchContext> batchContext) {
        object1.value = @1;
        object2.value = @3;
        [batchContext deleteInSectionController:sectionController1 atIndexes:[NSIndexSet indexSetWithIndex:0]];
        [batchContext insertInSectionController:sectionController2 atIndexes:[NSIndexSet indexSetWithIndex:2]];
        [batchContext reloadInSectionController:sectionController2 atIndexes:[NSIndexSet indexSetWithIndex:0]];
    } completion:^(BOOL finished2) {
        // 3 sections now b/c of the insert
        XCTAssertEqual([self.collectionView numberOfSections], 3);
        XCTAssertEqual([self.collectionView numberOfItemsInSection:0], 1);
        XCTAssertEqual([self.collectionView numberOfItemsInSection:1], 1);
        XCTAssertEqual([self.collectionView numberOfItemsInSection:2], 3);
        [expectation fulfill];
    }];
    [self waitForExpectationsWithTimeout:30 handler:nil];
}

- (void)test_whenSectionControllerMoves_withSectionControllerMutations_thatCollectionViewWorks {
    [self setupWithObjects:@[
        genTestObject(@1, @2),
        genTestObject(@2, @2)
    ]];

    IGTestObject *object = self.dataSource.objects[0];
    self.dataSource.objects = @[
        genTestObject(@2, @2),
        object, // moved from 0 to 1
    ];

    IGListSectionController *sectionController = [self.adapter sectionControllerForObject:object];

    // queue the update that performs the section move
    [self.adapter performUpdatesAnimated:YES completion:nil];

    XCTestExpectation *expectation = genExpectation;

    // queue an item update that gets batched with the section move
    [sectionController.collectionContext performBatchAnimated:YES updates:^(id<IGListBatchContext> batchContext) {
        object.value = @3;
        [batchContext insertInSectionController:sectionController atIndexes:[NSIndexSet indexSetWithIndex:2]];
    } completion:^(BOOL finished2) {
        XCTAssertEqual([self.collectionView numberOfSections], 2);
        // the object we are tracking should now be in section 1 and have 3 items
        XCTAssertEqual([self.collectionView numberOfItemsInSection:1], 3);
        [expectation fulfill];
    }];
    [self waitForExpectationsWithTimeout:30 handler:nil];
}

- (void)test_whenItemIsRemoved_withSectionControllerMutations_thatCollectionViewWorks {
    // 2 sections each with 2 objects
    [self setupWithObjects:@[
        genTestObject(@2, @2),
        genTestObject(@1, @2)
    ]];
    IGTestObject *object = self.dataSource.objects[1];

    // object at index 1 deleted
    self.dataSource.objects = @[
        genTestObject(@2, @2),
    ];

    IGListSectionController *sectionController = [self.adapter sectionControllerForObject:object];

    [self.adapter performUpdatesAnimated:YES completion:nil];

    XCTestExpectation *expectation = genExpectation;
    [sectionController.collectionContext performBatchAnimated:YES updates:^(id<IGListBatchContext> batchContext) {
        object.value = @1;
        [batchContext deleteInSectionController:sectionController atIndexes:[NSIndexSet indexSetWithIndex:0]];
    } completion:^(BOOL finished2) {
        XCTAssertEqual([self.collectionView numberOfSections], 1);
        [expectation fulfill];
    }];

    [self waitForExpectationsWithTimeout:30 handler:nil];
}

- (void)test_whenPerformingUpdates_withUnequalItem_withItemMoving_thatCollectionViewCountsUpdate {
    [self setupWithObjects:@[
        genTestObject(@1, @2),
        genTestObject(@2, @2),
    ]];

    self.dataSource.objects = @[
        genTestObject(@3, @2),
        genTestObject(@1, @3), // moved from index 0 to 1, value changed from 2 to 3
        genTestObject(@2, @2),
    ];

    XCTestExpectation *expectation = genExpectation;
    [self.adapter performUpdatesAnimated:YES completion:^(BOOL finished2) {
        XCTAssertEqual([self.collectionView numberOfSections], 3);
        XCTAssertEqual([self.collectionView numberOfItemsInSection:1], 3);
        [expectation fulfill];
    }];
    [self waitForExpectationsWithTimeout:30 handler:nil];
}

- (void)test_whenPerformingUpdates_withItemMoving_withSectionControllerReloadIndexes_thatCollectionViewCountsUpdate {
    [self setupWithObjects:@[
        genTestObject(@1, @2),
        genTestObject(@2, @3),
    ]];

    IGListSectionController *sectionController = [self.adapter sectionControllerForObject:self.dataSource.objects[0]];

    self.dataSource.objects = @[
        genTestObject(@2, @3),
        genTestObject(@1, @2), // moved from index 0 to 1
    ];

    [self.adapter performUpdatesAnimated:YES completion:nil];

    XCTestExpectation *expectation = genExpectation;
    [sectionController.collectionContext performBatchAnimated:YES updates:^(id<IGListBatchContext> batchContext) {
        [batchContext reloadInSectionController:sectionController atIndexes:[NSIndexSet indexSetWithIndex:0]];
    } completion:^(BOOL finished2) {
        XCTAssertEqual([self.collectionView numberOfSections], 2);
        XCTAssertEqual([self.collectionView numberOfItemsInSection:0], 3);
        XCTAssertEqual([self.collectionView numberOfItemsInSection:1], 2);
        [expectation fulfill];
    }];
    [self waitForExpectationsWithTimeout:30 handler:nil];
}

- (void)test_whenPerformingUpdates_withSectionControllerReloadIndexes_withItemDeleted_thatCollectionViewCountsUpdate {
    [self setupWithObjects:@[
        genTestObject(@1, @2), // item that will be deleted
        genTestObject(@2, @3),
    ]];

    IGListSectionController *sectionController = [self.adapter sectionControllerForObject:self.dataSource.objects[0]];

    self.dataSource.objects = @[
        genTestObject(@2, @3),
    ];

    [self.adapter performUpdatesAnimated:YES completion:nil];

    XCTestExpectation *expectation = genExpectation;
    [sectionController.collectionContext performBatchAnimated:YES updates:^(id<IGListBatchContext> batchContext) {
        [batchContext reloadInSectionController:sectionController atIndexes:[NSIndexSet indexSetWithIndex:0]];
    } completion:^(BOOL finished2) {
        XCTAssertEqual([self.collectionView numberOfSections], 1);
        XCTAssertEqual([self.collectionView numberOfItemsInSection:0], 3);
        [expectation fulfill];
    }];
    [self waitForExpectationsWithTimeout:30 handler:nil];
}

- (void)test_whenPerformingUpdates_withNewItemInstances_thatSectionControllersEqual {
    [self setupWithObjects:@[
        genTestObject(@1, @2),
        genTestObject(@2, @2)
    ]];

    // grab section controllers before updating the objects
    NSArray *beforeupdateObjects = self.dataSource.objects;
    IGListSectionController *sectionController1 = [self.adapter sectionControllerForObject:beforeupdateObjects.firstObject];
    IGListSectionController *sectionController2 = [self.adapter sectionControllerForObject:beforeupdateObjects.lastObject];

    self.dataSource.objects = @[
        genTestObject(@1, @3), // new instance, value changed from 2 to 3
        genTestObject(@2, @2), // new instance but unchanged
    ];

    XCTestExpectation *expectation = genExpectation;
    [self.adapter performUpdatesAnimated:YES completion:^(BOOL finished2) {
        XCTAssertEqual([self.collectionView numberOfSections], 2);
        XCTAssertEqual([self.collectionView numberOfItemsInSection:0], 3);
        XCTAssertEqual([self.collectionView numberOfItemsInSection:1], 2);

        NSArray *afterupdateObjects = [self.adapter objects];
        // pointer equality
        XCTAssertEqual([self.adapter sectionControllerForObject:afterupdateObjects.firstObject], sectionController1);
        XCTAssertEqual([self.adapter sectionControllerForObject:afterupdateObjects.lastObject], sectionController2);

        [expectation fulfill];
    }];

    [self waitForExpectationsWithTimeout:30 handler:nil];
}

- (void)test_whenPerformingMultipleUpdates_withNewItemInstances_thatSectionControllersReceiveNewInstances {
    [self setupWithObjects:@[
        genTestObject(@1, @2),
        genTestObject(@2, @2),
    ]];

    id object = self.dataSource.objects[0];
    IGTestDelegateController *sectionController = [self.adapter sectionControllerForObject:object];

    // test delegate controller counts the number of times it receives -didUpdateToItem:
    XCTAssertEqual(sectionController.updateCount, 1);

    self.dataSource.objects = @[
        object, // same object instance
        genTestObject(@3, @2),
    ];

    XCTestExpectation *expectation = genExpectation;
    [self.adapter performUpdatesAnimated:YES completion:^(BOOL finished2) {
        XCTAssertEqual(sectionController, [self.adapter sectionControllerForObject:[self.adapter objects][0]]);

        // should not have received -didUpdateToItem: since the instance did not change
        XCTAssertEqual(sectionController.updateCount, 1);

        self.dataSource.objects = @[
            genTestObject(@1, @2), // new instance but equal
            genTestObject(@3, @2),
        ];

        [self.adapter performUpdatesAnimated:YES completion:^(BOOL finished3) {
            XCTAssertEqual(sectionController, [self.adapter sectionControllerForObject:[self.adapter objects][0]]);

            // a new instance was used, make sure the section controller was updated
            XCTAssertEqual(sectionController.updateCount, 2);

            [expectation fulfill];
        }];
    }];
    [self waitForExpectationsWithTimeout:30 handler:nil];
}

- (void)test_whenQueryingCollectionContext_withNewItemInstances_thatSectionMatchesCurrentIndex {
    [self setupWithObjects:@[
        genTestObject(@1, @2),
        genTestObject(@2, @2),
    ]];

    IGTestDelegateController *sectionController = [self.adapter sectionControllerForObject:self.dataSource.objects[0]];

    XCTestExpectation *expectation = genExpectation;
    [self.adapter performUpdatesAnimated:YES completion:^(BOOL finished2) {
        self.dataSource.objects = @[
            genTestObject(@2, @2),
            genTestObject(@1, @2), // new instance but equal
            genTestObject(@3, @2),
        ];

        __block BOOL executedUpdateBlock = NO;
        __weak __typeof__(sectionController) weakSectionController = sectionController;
        sectionController.itemUpdateBlock = ^{
            executedUpdateBlock = YES;
            XCTAssertEqual(weakSectionController.section, 1);
        };

        [self.adapter performUpdatesAnimated:YES completion:^(BOOL finished3) {
            XCTAssertTrue(executedUpdateBlock);

            [expectation fulfill];
        }];
    }];

    [self waitForExpectationsWithTimeout:30 handler:nil];
}

- (void)test_whenSectionControllerMutates_withReloadData_thatSectionControllerMutationIsApplied {
    [self setupWithObjects:@[
        genTestObject(@1, @2),
        genTestObject(@2, @2),
    ]];
    IGTestObject *object = self.dataSource.objects[0];
    IGListSectionController *sectionController = [self.adapter sectionControllerForObject:object];

    [sectionController.collectionContext performBatchAnimated:YES updates:^(id<IGListBatchContext> batchContext) {
        object.value = @3;
        [batchContext insertInSectionController:sectionController atIndexes:[NSIndexSet indexSetWithIndex:2]];
    } completion:nil];

    XCTestExpectation *expectation = genExpectation;
    [self.adapter reloadDataWithCompletion:^(BOOL finished2) {
        XCTAssertEqual([self.collectionView numberOfSections], 2);

        // check that the count of items in section 0 was updated from the previous batch update block
        XCTAssertEqual([self.collectionView numberOfItemsInSection:0], 3);
        [expectation fulfill];
    }];
    [self waitForExpectationsWithTimeout:30 handler:nil];
}

- (void)test_whenContentOffsetChanges_withPerformUpdates_thatCollectionViewWorks {
    // this test layout changes the offset in -prepareLayout which occurs somewhere between the update block being
    // applied and the completion block
    self.collectionView.collectionViewLayout = [IGListTestOffsettingLayout new];

    [self setupWithObjects:@[
        genTestObject(@1, @2),
        genTestObject(@2, @2),
        genTestObject(@3, @2),
    ]];

    // remove the last object to check that we don't access OOB section controller when the layout changes the offset
    self.dataSource.objects = @[
        genTestObject(@1, @2),
        genTestObject(@2, @2),
    ];

    XCTestExpectation *expectation = genExpectation;
    [self.adapter performUpdatesAnimated:YES completion:^(BOOL finished2) {
        XCTAssertEqual([self.collectionView numberOfSections], 2);
        [expectation fulfill];
    }];
    [self waitForExpectationsWithTimeout:30 handler:nil];
}

- (void)test_whenReloadingItems_withNewItemInstances_thatSectionControllersReceiveNewInstances {
    [self setupWithObjects:@[
        genTestObject(@1, @2),
        genTestObject(@2, @2),
        genTestObject(@3, @2),
    ]];

    IGTestDelegateController *sectionController1 = [self.adapter sectionControllerForObject:genTestObject(@1, @2)];
    IGTestDelegateController *sectionController2 = [self.adapter sectionControllerForObject:genTestObject(@2, @2)];

    NSArray *newObjects = @[
        genTestObject(@1, @3),
        genTestObject(@2, @3),
    ];
    [self.adapter reloadObjects:newObjects];

    XCTAssertEqual(sectionController1.item, newObjects[0]);
    XCTAssertEqual(sectionController2.item, newObjects[1]);
    XCTAssertTrue([[self.adapter.sectionMap objects] indexOfObjectIdenticalTo:newObjects[0]] != NSNotFound);
    XCTAssertTrue([[self.adapter.sectionMap objects] indexOfObjectIdenticalTo:newObjects[1]] != NSNotFound);
}

- (void)test_whenReloadingItems_withPerformUpdates_thatReloadIsApplied {
    [self setupWithObjects:@[
        genTestObject(@1, @1),
        genTestObject(@2, @2),
        genTestObject(@3, @3),
    ]];

    IGTestObject *object = self.dataSource.objects[0];
    IGTestDelegateController *sectionController = [self.adapter sectionControllerForObject:object];

    // using performBatchAnimated: to mimic re-entrant item reload
    [sectionController.collectionContext performBatchAnimated:YES updates:^(id<IGListBatchContext> batchContext) {
        object.value = @4; // from @1
        [self.adapter reloadObjects:@[object]];
    } completion:nil];

    // object is moved from position 0 to 1
    // it is also mutated in the previous update block AND queued for a reload
    self.dataSource.objects = @[
        genTestObject(@3, @3),
        object,
        genTestObject(@2, @2),
    ];

    XCTestExpectation *expectation = genExpectation;
    [self.adapter performUpdatesAnimated:YES completion:^(BOOL finished2) {
        XCTAssertEqual([self.collectionView numberOfItemsInSection:0], 3);
        XCTAssertEqual([self.collectionView numberOfItemsInSection:1], 4); // reloaded section
        XCTAssertEqual([self.collectionView numberOfItemsInSection:2], 2);
        [expectation fulfill];
    }];
    [self waitForExpectationsWithTimeout:30 handler:nil];
}

- (void)test_whenReloadingItems_inItemUpdateBlock_thatDoesntCrash {
    [self setupWithObjects:@[
        genTestObject(@1, @1),
        genTestObject(@2, @2),
    ]];

    IGTestObject *object = self.dataSource.objects[1];
    IGTestDelegateController *sectionController = [self.adapter sectionControllerForObject:object];
    sectionController.itemUpdateBlock = ^{
        // We shouldn't trigger updates within -didUpdateToObject, but in case we do,
        // we should at least try to resolve it correctly.
        [self.adapter reloadObjects:@[object]];
    };

    // Move object from index 1 -> 2, so the -reloadObjects will need to use the previous index (1)
    self.dataSource.objects = @[
        genTestObject(@1, @1),
        genTestObject(@3, @3),
        genTestObject(@2, @2), // Create a new object to trigger -didUpdateToObject
    ];

    XCTestExpectation *expectation = genExpectation;
    [self.adapter performUpdatesAnimated:YES completion:^(BOOL finished2) {
        // Most importantly, we don't want to crash, but lets also check the order is correct
        XCTAssertEqual([self.collectionView numberOfItemsInSection:0], 1);
        XCTAssertEqual([self.collectionView numberOfItemsInSection:1], 3);
        XCTAssertEqual([self.collectionView numberOfItemsInSection:2], 2);
        [expectation fulfill];
    }];
    [self waitForExpectationsWithTimeout:30 handler:nil];
}

- (void)test_whenSectionControllerMutates_whenThereIsNoWindow_thatCollectionViewCountsAreUpdated {
    // remove the collection view from self.window so that we use reloadData
    [self.collectionView removeFromSuperview];

    [self setupWithObjects:@[
        genTestObject(@1, @8)
    ]];
    IGTestObject *object = self.dataSource.objects[0];

    IGTestDelegateController *sectionController = [self.adapter sectionControllerForObject:object];

    XCTestExpectation *expectation = genExpectation;
    // using performBatchAnimated: to mimic re-entrant item reload
    [sectionController.collectionContext performBatchAnimated:YES updates:^(id<IGListBatchContext> batchContext) {
        object.value = @6; // from @1

        [batchContext reloadInSectionController:sectionController atIndexes:[NSIndexSet indexSetWithIndex:0]];
        [batchContext deleteInSectionController:sectionController atIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(5, 3)]];
        [batchContext insertInSectionController:sectionController atIndexes:[NSIndexSet indexSetWithIndex:0]];

    } completion:^(BOOL finished2) {
        XCTAssertEqual([self.collectionView numberOfItemsInSection:0], 6);
        [expectation fulfill];
    }];
    [self waitForExpectationsWithTimeout:30 handler:nil];
}

- (void)test_whenPerformingUpdates_withoutSettingDataSource_thatCompletionBlockExecutes {
    UICollectionView *collectionView = [[UICollectionView alloc] initWithFrame:self.window.frame collectionViewLayout:[UICollectionViewFlowLayout new]];
    [self.window addSubview:collectionView];
    IGListAdapter *adapter = [[IGListAdapter alloc] initWithUpdater:[IGListAdapterUpdater new] viewController:nil];
    adapter.collectionView = collectionView;

    self.dataSource.objects = @[
        genTestObject(@1, @1)
    ];

    XCTestExpectation *expectation = genExpectation;

    // call -performUpdatesAnimated: before we have set the data source
    [adapter performUpdatesAnimated:YES completion:^(BOOL finished) {

        // since the data source isnt set, we complete syncronously. dispatch_async simulates setting the data source
        // in a different runloop from the completion block so it should be set by the time we make our subsequent
        // -performUpdatesAnimated: call
        dispatch_async(dispatch_get_main_queue(), ^{
            self.dataSource.objects = @[
                genTestObject(@1, @1),
                genTestObject(@2, @2)
            ];
            [adapter performUpdatesAnimated:YES completion:^(BOOL finished2) {
                XCTAssertEqual([collectionView numberOfSections], 2);
                [expectation fulfill];
            }];
        });
    }];

    // setting the data source immediately queries it, since the collection view is also set
    adapter.dataSource = self.dataSource;
    // simulate display reloading data on the collection view
    [collectionView layoutIfNeeded];

    [self waitForExpectationsWithTimeout:30 handler:nil];
}

- (void)test_whenPerformingUpdates_withItemsMovingInBlocks_thatCollectionViewWorks {
    [self setupWithObjects:@[
        genTestObject(@1, @0),
        genTestObject(@2, @7),
        genTestObject(@3, @8),
        genTestObject(@4, @8),
        genTestObject(@5, @8),
        genTestObject(@6, @5),
        genTestObject(@7, @8),
        genTestObject(@8, @8),
        genTestObject(@9, @8),
    ]];

    UICollectionView *collectionView = [[UICollectionView alloc] initWithFrame:self.window.frame collectionViewLayout:[UICollectionViewFlowLayout new]];
    [self.window addSubview:collectionView];
    IGListAdapterUpdater *updater = [IGListAdapterUpdater new];
    IGListAdapter *adapter = [[IGListAdapter alloc] initWithUpdater:updater viewController:nil];
    adapter.dataSource = self.dataSource;
    adapter.collectionView = collectionView;
    [collectionView layoutSubviews];

    XCTAssertEqual([collectionView numberOfSections], 9);

    self.dataSource.objects = @[
        genTestObject(@1, @0),
        genTestObject(@10, @5),
        genTestObject(@11, @7),
        genTestObject(@2, @7),
        genTestObject(@3, @8),
        genTestObject(@6, @5), // "moves" in front of 4, 5 but doesn't change index in array
        genTestObject(@4, @8),
        genTestObject(@5, @8),
        genTestObject(@7, @8),
        genTestObject(@8, @8),
    ];

    XCTestExpectation *expectation = genExpectation;
    [adapter performUpdatesAnimated:YES completion:^(BOOL finished) {
        XCTAssertEqual([collectionView numberOfSections], 10);
        [expectation fulfill];
    }];
    [self waitForExpectationsWithTimeout:30 handler:nil];
}

- (void)test_whenItemDeleted_withDisplayDelegate_thatDelegateReceivesDeletedItem {
    [self setupWithObjects:@[
        genTestObject(@1, @1),
        genTestObject(@2, @2),
    ]];
    IGTestObject *object = self.dataSource.objects[0];

    self.dataSource.objects = @[
        genTestObject(@2, @2),
    ];

    IGTestCell *const cell = (IGTestCell*)[self.collectionView cellForItemAtIndexPath:genIndexPath(0, 0)];
    id mockDisplayHandler = [OCMockObject mockForProtocol:@protocol(IGListAdapterDelegate)];
    self.adapter.delegate = mockDisplayHandler;

    [[mockDisplayHandler expect] listAdapter:self.adapter didEndDisplayingObject:object atIndex:0];
    [[mockDisplayHandler expect] listAdapter:self.adapter didEndDisplayingObject:object cell: cell atIndexPath: [NSIndexPath indexPathForItem:0 inSection:0]];

    XCTestExpectation *expectation = genExpectation;
    [self.adapter performUpdatesAnimated:YES completion:^(BOOL finished2) {
        [mockDisplayHandler verify];
        XCTAssertTrue(finished2);
        [expectation fulfill];
    }];
    [self waitForExpectationsWithTimeout:30 handler:nil];
}

- (void)test_whenItemReloaded_withDisplacingMutations_thatCollectionViewWorks {
    [self setupWithObjects:@[
        genTestObject(@1, @1),
        genTestObject(@2, @1),
        genTestObject(@3, @1),
        genTestObject(@4, @1),
        genTestObject(@5, @1),
    ]];

    self.dataSource.objects = @[
        genTestObject(@1, @1),
        genTestObject(@2, @2), // reloaded
        genTestObject(@5, @2), // reloaded
        genTestObject(@4, @2), // reloaded
        genTestObject(@3, @1),
    ];

    XCTestExpectation *expectation = genExpectation;
    [self.adapter performUpdatesAnimated:YES completion:^(BOOL finished) {
        XCTAssertTrue(finished);
        [expectation fulfill];
    }];
    [self waitForExpectationsWithTimeout:30 handler:nil];
}

- (void)test_whenCollectionViewAppears_thatWillDisplayEventsAreSent {
    [self setupWithObjects:@[
        genTestObject(@1, @1),
        genTestObject(@2, @2),
    ]];
    IGTestDelegateController *ic1 = [self.adapter sectionControllerForObject:self.dataSource.objects[0]];
    XCTAssertEqual(ic1.willDisplayCount, 1);
    XCTAssertEqual(ic1.didEndDisplayCount, 0);
    XCTAssertEqual([ic1.willDisplayCellIndexes countForObject:@0], 1);
    XCTAssertEqual([ic1.didEndDisplayCellIndexes countForObject:@0], 0);

    IGTestDelegateController *ic2 = [self.adapter sectionControllerForObject:self.dataSource.objects[1]];
    XCTAssertEqual(ic2.willDisplayCount, 1);
    XCTAssertEqual(ic2.didEndDisplayCount, 0);
    XCTAssertEqual([ic2.willDisplayCellIndexes countForObject:@0], 1);
    XCTAssertEqual([ic2.willDisplayCellIndexes countForObject:@1], 1);
    XCTAssertEqual([ic2.didEndDisplayCellIndexes countForObject:@0], 0);
    XCTAssertEqual([ic2.didEndDisplayCellIndexes countForObject:@1], 0);
}

- (void)test_whenAdapterUpdates_withItemUpdated_thatdidEndDisplayEventsAreSent {
    [self setupWithObjects:@[
        genTestObject(@1, @1),
        genTestObject(@2, @2),
    ]];
    IGTestDelegateController *ic1 = [self.adapter sectionControllerForObject:self.dataSource.objects[0]];
    IGTestDelegateController *ic2 = [self.adapter sectionControllerForObject:self.dataSource.objects[1]];

    self.dataSource.objects = @[
        genTestObject(@1, @1),
        genTestObject(@2, @1), // reloaded w/ 1 cell removed
    ];

    XCTestExpectation *expectation = genExpectation;
    [self.adapter performUpdatesAnimated:YES completion:^(BOOL finished) {
        XCTAssertEqual(ic1.willDisplayCount, 1);
        XCTAssertEqual(ic1.didEndDisplayCount, 0);
        XCTAssertEqual([ic1.willDisplayCellIndexes countForObject:@0], 1);
        XCTAssertEqual([ic1.didEndDisplayCellIndexes countForObject:@0], 0);

        XCTAssertEqual(ic2.willDisplayCount, 1);
        XCTAssertEqual(ic2.didEndDisplayCount, 0);
        XCTAssertEqual([ic2.willDisplayCellIndexes countForObject:@1], 1);
        XCTAssertEqual([ic2.didEndDisplayCellIndexes countForObject:@1], 1);
        [expectation fulfill];
    }];
    [self waitForExpectationsWithTimeout:30 handler:nil];
}

- (void)test_whenAdapterUpdates_withItemRemoved_thatdidEndDisplayEventsAreSent {
    [self setupWithObjects:@[
        genTestObject(@1, @1),
        genTestObject(@2, @2),
    ]];
    IGTestDelegateController *ic1 = [self.adapter sectionControllerForObject:self.dataSource.objects[0]];
    IGTestDelegateController *ic2 = [self.adapter sectionControllerForObject:self.dataSource.objects[1]];

    self.dataSource.objects = @[
        genTestObject(@1, @1)
    ];

    XCTestExpectation *expectation = genExpectation;
    [self.adapter performUpdatesAnimated:YES completion:^(BOOL finished) {
        XCTAssertEqual(ic1.willDisplayCount, 1);
        XCTAssertEqual(ic1.didEndDisplayCount, 0);
        XCTAssertEqual([ic1.willDisplayCellIndexes countForObject:@0], 1);
        XCTAssertEqual([ic1.didEndDisplayCellIndexes countForObject:@0], 0);

        XCTAssertEqual(ic2.willDisplayCount, 1);
        XCTAssertEqual(ic2.didEndDisplayCount, 1);
        XCTAssertEqual([ic2.willDisplayCellIndexes countForObject:@0], 1);
        XCTAssertEqual([ic2.willDisplayCellIndexes countForObject:@1], 1);
        XCTAssertEqual([ic2.didEndDisplayCellIndexes countForObject:@0], 1);
        XCTAssertEqual([ic2.didEndDisplayCellIndexes countForObject:@1], 1);
        [expectation fulfill];
    }];
    [self waitForExpectationsWithTimeout:30 handler:nil];
}

- (void)test_whenAdapterUpdates_withEmptyItems_thatdidEndDisplayEventsAreSent {
    [self setupWithObjects:@[
        genTestObject(@1, @1),
        genTestObject(@2, @2),
    ]];
    IGTestDelegateController *ic1 = [self.adapter sectionControllerForObject:self.dataSource.objects[0]];
    IGTestDelegateController *ic2 = [self.adapter sectionControllerForObject:self.dataSource.objects[1]];

    self.dataSource.objects = @[];

    XCTestExpectation *expectation = genExpectation;
    [self.adapter performUpdatesAnimated:YES completion:^(BOOL finished) {
        XCTAssertEqual(ic1.didEndDisplayCount, 1);
        XCTAssertEqual([ic1.didEndDisplayCellIndexes countForObject:@0], 1);

        XCTAssertEqual(ic2.didEndDisplayCount, 1);
        XCTAssertEqual([ic2.didEndDisplayCellIndexes countForObject:@0], 1);
        XCTAssertEqual([ic2.didEndDisplayCellIndexes countForObject:@1], 1);
        [expectation fulfill];
    }];
    [self waitForExpectationsWithTimeout:30 handler:nil];
}

- (void)test_whenBatchUpdating_withCellQuery_thatCellIsNil {
    __block BOOL executed = NO;
    __weak __typeof__(self) weakSelf = self;
    void (^block)(IGTestDelegateController *) = ^(IGTestDelegateController *ic) {
        executed = YES;
        XCTAssertNil([weakSelf.adapter cellForItemAtIndex:0 sectionController:ic]);
    };
    ((IGTestDelegateDataSource *)self.dataSource).cellConfigureBlock = block;

    [self setupWithObjects:@[
        genTestObject(@1, @1),
        genTestObject(@2, @1),
        genTestObject(@3, @1),
    ]];

    // delete the last object from the original array
    self.dataSource.objects = @[
        genTestObject(@1, @1),
        genTestObject(@2, @1),
        genTestObject(@4, @1),
        genTestObject(@5, @1),
        genTestObject(@6, @1),
    ];
    XCTestExpectation *expectation = genExpectation;
    [self.adapter performUpdatesAnimated:YES completion:^(BOOL finished) {
        [expectation fulfill];
    }];
    [self waitForExpectationsWithTimeout:30 handler:nil];
}

- (void)test_whenPerformingUpdates_withWorkingRange_thatAccessingCellDoesntCrash {
    [self setupWithObjects:@[
        genTestObject(@1, @1),
        genTestObject(@2, @1),
        genTestObject(@3, @1),
    ]];

    // section controller try to access a cell in -listAdapter:sectionControllerWillEnterWorkingRange:
    // add items beyond the 100x100 frame so they access unavailable cells
    self.dataSource.objects = @[
        genTestObject(@1, @1),
        genTestObject(@2, @1),
        genTestObject(@3, @1),
        genTestObject(@4, @1),
        genTestObject(@5, @1),
        genTestObject(@6, @1),
        genTestObject(@7, @1),
        genTestObject(@8, @1),
        genTestObject(@9, @1),
        genTestObject(@10, @1),
        genTestObject(@11, @1),
    ];
    XCTestExpectation *expectation = genExpectation;

    // this will call -collectionView:performBatchUpdates:, trigger collectionView:willDisplayCell:forItemAtIndexPath:,
    // which kicks off the working range logic
    [self.adapter performUpdatesAnimated:YES completion:^(BOOL finished) {
        [expectation fulfill];
    }];

    [self waitForExpectationsWithTimeout:30 handler:nil];
}

- (void)test_whenReloadingItems_withDeleteAndInsertCollision_thatUpdateCanBeApplied {
    [self setupWithObjects:@[
        genTestObject(@1, @1),
        genTestObject(@2, @5),
        genTestObject(@3, @1),
    ]];

    IGListSectionController *section = [self.adapter sectionControllerForObject:self.dataSource.objects[1]];

    XCTestExpectation *expectation = genExpectation;
    [section.collectionContext performBatchAnimated:NO updates:^(id<IGListBatchContext> batchContext) {
        [batchContext deleteInSectionController:section atIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(1, 2)]];
        [batchContext insertInSectionController:section atIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(1, 2)]];
        [batchContext reloadInSectionController:section atIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(1, 4)]];
    } completion:^(BOOL finished) {
        [expectation fulfill];
    }];

    [self waitForExpectationsWithTimeout:30 handler:nil];
}

- (void)test_whenReloadingItems_withSectionInsertedInFront_thatUpdateCanBeApplied {
    [self setupWithObjects:@[
        genTestObject(@1, @1),
        genTestObject(@2, @5),
        genTestObject(@3, @1),
    ]];

    IGListSectionController *section = [self.adapter sectionControllerForObject:self.dataSource.objects[1]];

    XCTestExpectation *expectation1 = genExpectation;
    [section.collectionContext performBatchAnimated:NO updates:^(id<IGListBatchContext> batchContext) {
        [batchContext reloadInSectionController:section atIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(1, 4)]];
    } completion:^(BOOL finished) {
        [expectation1 fulfill];
    }];

    self.dataSource.objects = @[
        genTestObject(@1, @1),
        genTestObject(@4, @1), // insert to shift object @2
        genTestObject(@2, @5),
        genTestObject(@3, @1),
    ];

    XCTestExpectation *expectation2 = genExpectation;
    [self.adapter performUpdatesAnimated:YES completion:^(BOOL finished) {
        [expectation2 fulfill];
    }];

    [self waitForExpectationsWithTimeout:30 handler:nil];
}

- (void)test_whenReloadingItems_withSectionDeletedInFront_thatUpdateCanBeApplied {
    [self setupWithObjects:@[
        genTestObject(@1, @1),
        genTestObject(@2, @5),
        genTestObject(@3, @1),
    ]];

    IGListSectionController *section = [self.adapter sectionControllerForObject:self.dataSource.objects[1]];

    XCTestExpectation *expectation1 = genExpectation;
    [section.collectionContext performBatchAnimated:NO updates:^(id<IGListBatchContext> batchContext) {
        [batchContext reloadInSectionController:section atIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(1, 4)]];
    } completion:^(BOOL finished) {
        [expectation1 fulfill];
    }];

    self.dataSource.objects = @[
        genTestObject(@2, @5),
        genTestObject(@3, @1),
    ];

    XCTestExpectation *expectation2 = genExpectation;
    [self.adapter performUpdatesAnimated:YES completion:^(BOOL finished) {
        [expectation2 fulfill];
    }];

    [self waitForExpectationsWithTimeout:30 handler:nil];
}

- (void)test_whenMovingItems_withObjectMoving_thatCollectionViewWorks {
    [self setupWithObjects:@[
        genTestObject(@1, @2),
        genTestObject(@2, @2),
        genTestObject(@3, @2),
    ]];

    __block BOOL executed = NO;
    IGListSectionController *section = [self.adapter sectionControllerForObject:self.dataSource.objects.lastObject];
    [section.collectionContext performBatchAnimated:YES updates:^(id<IGListBatchContext> batchContext) {
        [batchContext moveInSectionController:section fromIndex:0 toIndex:1];
        executed = YES;
    } completion:nil];

    self.dataSource.objects = @[
        genTestObject(@3, @2),
        genTestObject(@1, @2),
        genTestObject(@2, @2),
    ];

    XCTestExpectation *expectation = genExpectation;
    [self.adapter performUpdatesAnimated:YES completion:^(BOOL finished) {
        XCTAssertTrue(executed);
        [expectation fulfill];
    }];

    [self waitForExpectationsWithTimeout:30 handler:nil];
}

- (void)test_whenMovingItems_withObjectReloaded_thatCollectionViewWorks {
    [self setupWithObjects:@[
        genTestObject(@1, @2),
    ]];

    __block BOOL executed = NO;
    IGListSectionController *section = [self.adapter sectionControllerForObject:self.dataSource.objects.lastObject];
    [section.collectionContext performBatchAnimated:YES updates:^(id<IGListBatchContext> batchContext) {
        [batchContext moveInSectionController:section fromIndex:0 toIndex:1];
        executed = YES;
    } completion:nil];

    self.dataSource.objects = @[
        genTestObject(@1, @3),
    ];

    XCTestExpectation *expectation = genExpectation;
    [self.adapter performUpdatesAnimated:YES completion:^(BOOL finished) {
        XCTAssertTrue(executed);
        [expectation fulfill];
    }];

    [self waitForExpectationsWithTimeout:30 handler:nil];
}

- (void)test_whenMovingItems_withObjectDeleted_thatCollectionViewWorks {
    [self setupWithObjects:@[
        genTestObject(@1, @2),
    ]];

    __block BOOL executed = NO;
    IGListSectionController *section = [self.adapter sectionControllerForObject:self.dataSource.objects.lastObject];
    [section.collectionContext performBatchAnimated:YES updates:^(id<IGListBatchContext> batchContext) {
        [batchContext moveInSectionController:section fromIndex:0 toIndex:1];
        executed = YES;
    } completion:nil];

    self.dataSource.objects = @[];

    XCTestExpectation *expectation = genExpectation;
    [self.adapter performUpdatesAnimated:YES completion:^(BOOL finished) {
        XCTAssertTrue(executed);
        [expectation fulfill];
    }];

    [self waitForExpectationsWithTimeout:30 handler:nil];
}

- (void)test_whenMovingItems_withObjectInsertedBefore_thatCollectionViewWorks {
    [self setupWithObjects:@[
        genTestObject(@1, @2),
    ]];

    __block BOOL executed = NO;
    IGListSectionController *section = [self.adapter sectionControllerForObject:self.dataSource.objects.lastObject];
    [section.collectionContext performBatchAnimated:YES updates:^(id<IGListBatchContext> batchContext) {
        [batchContext moveInSectionController:section fromIndex:0 toIndex:1];
        executed = YES;
    } completion:nil];

    [self setupWithObjects:@[
        genTestObject(@2, @2),
        genTestObject(@1, @2),
    ]];

    XCTestExpectation *expectation = genExpectation;
    [self.adapter performUpdatesAnimated:YES completion:^(BOOL finished) {
        XCTAssertTrue(executed);
        [expectation fulfill];
    }];

    [self waitForExpectationsWithTimeout:30 handler:nil];
}

- (void)test_whenMovingItems_thatCollectionViewWorks {
    [self setupWithObjects:@[
        genTestObject(@1, @2),
    ]];

    IGTestCell *cell1 = (IGTestCell*)[self.collectionView cellForItemAtIndexPath:[NSIndexPath indexPathForItem:0 inSection:0]];
    IGTestCell *cell2 = (IGTestCell*)[self.collectionView cellForItemAtIndexPath:[NSIndexPath indexPathForItem:1 inSection:0]];
    cell1.label.text = @"foo";
    cell2.label.text = @"bar";

    XCTestExpectation *expectation = genExpectation;
    IGListSectionController *section = [self.adapter sectionControllerForObject:self.dataSource.objects.lastObject];
    [section.collectionContext performBatchAnimated:YES updates:^(id<IGListBatchContext> batchContext) {
        [batchContext moveInSectionController:section fromIndex:0 toIndex:1];
    } completion:^(BOOL finished) {
        IGTestCell *movedCell1 = (IGTestCell*)[self.collectionView cellForItemAtIndexPath:[NSIndexPath indexPathForItem:0 inSection:0]];
        IGTestCell *movedCell2 = (IGTestCell*)[self.collectionView cellForItemAtIndexPath:[NSIndexPath indexPathForItem:1 inSection:0]];
        XCTAssertEqualObjects(movedCell1.label.text, @"bar");
        XCTAssertEqualObjects(movedCell2.label.text, @"foo");

        [expectation fulfill];
    }];

    [self waitForExpectationsWithTimeout:30 handler:nil];
}

- (void)test_whenInvalidatingSectionController_withSizeChange_thatCellsAreSameInstance_thatCellsFrameChanged {
    [self setupWithObjects:@[
        genTestObject(@1, @2),
    ]];

    NSIndexPath *path1 = [NSIndexPath indexPathForItem:0 inSection:0];
    NSIndexPath *path2 = [NSIndexPath indexPathForItem:1 inSection:0];
    IGTestCell *cell1 = (IGTestCell*)[self.collectionView cellForItemAtIndexPath:path1];
    IGTestCell *cell2 = (IGTestCell*)[self.collectionView cellForItemAtIndexPath:path2];

    XCTAssertEqual(cell1.frame.size.height, 10);
    XCTAssertEqual(cell2.frame.size.height, 10);

    IGTestDelegateController *section = [self.adapter sectionControllerForObject:self.dataSource.objects.lastObject];
    section.height = 20.0;

    XCTestExpectation *expectation = genExpectation;
    [section.collectionContext invalidateLayoutForSectionController:section completion:^(BOOL finished) {
        XCTAssertEqual(cell1, [self.collectionView cellForItemAtIndexPath:path1]);
        XCTAssertEqual(cell2, [self.collectionView cellForItemAtIndexPath:path2]);
        XCTAssertEqual(cell1.frame.size.height, 20);
        XCTAssertEqual(cell2.frame.size.height, 20);
        [expectation fulfill];
    }];

    [self waitForExpectationsWithTimeout:30 handler:nil];
}

- (void)test_whenAdaptersSwapCollectionViews_thatOldAdapterDoesntUpdateOldCollectionView {
    IGListAdapter *adapter1 = [[IGListAdapter alloc] initWithUpdater:[IGListAdapterUpdater new] viewController:nil];
    IGTestDelegateDataSource *dataSource1 = [IGTestDelegateDataSource new];
    dataSource1.objects = @[genTestObject(@1, @2)];
    adapter1.dataSource = dataSource1;
    adapter1.collectionView = self.collectionView;

    [self.collectionView layoutIfNeeded];
    XCTAssertEqual([self.collectionView numberOfSections], 1);
    XCTAssertEqual([self.collectionView numberOfItemsInSection:0], 2);

    IGListAdapter *adapter2 = [[IGListAdapter alloc] initWithUpdater:[IGListAdapterUpdater new] viewController:nil];
    IGTestDelegateDataSource *dataSource2 = [IGTestDelegateDataSource new];
    dataSource2.objects = @[genTestObject(@1, @1), genTestObject(@2, @1)];
    adapter2.dataSource = dataSource2;
    adapter2.collectionView = self.collectionView;

    XCTAssertEqual([self.collectionView numberOfSections], 2);
    XCTAssertEqual([self.collectionView numberOfItemsInSection:0], 1);
    XCTAssertEqual([self.collectionView numberOfItemsInSection:1], 1);

    dataSource1.objects = @[genTestObject(@1, @2), genTestObject(@2, @2), genTestObject(@3, @2), genTestObject(@4, @2)];
    XCTestExpectation *expectation = genExpectation;

    [adapter1 performUpdatesAnimated:YES completion:^(BOOL finished) {
        XCTAssertEqual([self.collectionView numberOfSections], 2);
        XCTAssertEqual([self.collectionView numberOfItemsInSection:0], 1);
        XCTAssertEqual([self.collectionView numberOfItemsInSection:1], 1);
        [expectation fulfill];
    }];

    [self waitForExpectationsWithTimeout:30 handler:nil];
}

- (void)test_whenAdaptersSwapCollectionViews_ {
    IGListAdapter *adapter1 = [[IGListAdapter alloc] initWithUpdater:[IGListAdapterUpdater new] viewController:nil];
    IGTestDelegateDataSource *dataSource1 = [IGTestDelegateDataSource new];
    dataSource1.objects = @[genTestObject(@1, @2)];
    adapter1.dataSource = dataSource1;
    adapter1.collectionView = self.collectionView;

    [self.collectionView layoutIfNeeded];
    XCTAssertEqual([self.collectionView numberOfSections], 1);
    XCTAssertEqual([self.collectionView numberOfItemsInSection:0], 2);

    IGListAdapter *adapter2 = [[IGListAdapter alloc] initWithUpdater:[IGListAdapterUpdater new] viewController:nil];
    IGTestDelegateDataSource *dataSource2 = [IGTestDelegateDataSource new];
    dataSource2.objects = @[genTestObject(@1, @1), genTestObject(@2, @1)];
    adapter2.dataSource = dataSource2;
    adapter2.collectionView = self.collectionView;

    [self.collectionView layoutIfNeeded];
    XCTAssertEqual([self.collectionView numberOfSections], 2);
    XCTAssertEqual([self.collectionView numberOfItemsInSection:0], 1);
    XCTAssertEqual([self.collectionView numberOfItemsInSection:1], 1);

    dataSource2.objects = @[genTestObject(@1, @2), genTestObject(@2, @1), genTestObject(@3, @1), genTestObject(@4, @1)];
    XCTestExpectation *expectation = genExpectation;

    [adapter2 performUpdatesAnimated:YES completion:^(BOOL finished) {
        XCTAssertEqual([self.collectionView numberOfSections], 4);
        XCTAssertEqual([self.collectionView numberOfItemsInSection:0], 2);
        XCTAssertEqual([self.collectionView numberOfItemsInSection:1], 1);
        XCTAssertEqual([self.collectionView numberOfItemsInSection:1], 1);
        XCTAssertEqual([self.collectionView numberOfItemsInSection:1], 1);
        [expectation fulfill];
    }];

    [self waitForExpectationsWithTimeout:30 handler:nil];
}

- (void)test_whenDidUpdateAsyncReloads_withBatchUpdatesInProgress_thatReloadIsExecuted {
    [self setupWithObjects:@[
        genTestObject(@1, @1)
    ]];

    IGTestDelegateController *section = [self.adapter sectionControllerForObject:self.dataSource.objects[0]];

    XCTestExpectation *expectation1 = genExpectation;
    __weak __typeof__(section) weakSection = section;
    section.itemUpdateBlock = ^{
        // currently inside -[IGListSectionController didUpdateToObject:], change the item (note: NEVER do this) manually
        // so that the data powering numberOfItems changes (1 to 2). dispatch_async the update to skip outside of the
        // -[UICollectionView performBatchUpdates:completion:] block execution
        [weakSection.collectionContext performBatchAnimated:NO updates:^(id<IGListBatchContext> batchContext) {
            weakSection.item = genTestObject(@1, @2);
            [batchContext reloadSectionController:weakSection];
        } completion:^(BOOL finished) {
            [expectation1 fulfill];
            XCTAssertEqual([self.collectionView numberOfItemsInSection:0], 2);
        }];
    };

    // add an object so that a batch update is triggered (diff result has changes)
    self.dataSource.objects = @[
        genTestObject(@1, @1),
        genTestObject(@2, @1)
    ];

    XCTestExpectation *expectation2 = genExpectation;
    [self.adapter performUpdatesAnimated:YES completion:^(BOOL finished) {
        // verify that the section still has 2 items since this completion executes AFTER the reload block above
        XCTAssertEqual([self.collectionView numberOfItemsInSection:0], 2);
        [expectation2 fulfill];
    }];

    [self waitForExpectationsWithTimeout:30 handler:nil];
}

- (void)test_whenInsertingItemsTwice_withDataUpdatedTwice_thatAllUpdatesAppliedWithoutException {
    [self setupWithObjects:@[
        genTestObject(@1, @2),
    ]];

    IGTestObject *object = self.dataSource.objects[0];
    IGListSectionController *sectionController = [self.adapter sectionControllerForObject:object];

    XCTestExpectation *expectation = genExpectation;
    [sectionController.collectionContext performBatchAnimated:YES updates:^(id<IGListBatchContext> batchContext) {
        object.value = @4;
        [batchContext insertInSectionController:sectionController atIndexes:[NSIndexSet indexSetWithIndex:0]];
        [batchContext insertInSectionController:sectionController atIndexes:[NSIndexSet indexSetWithIndex:0]];
    } completion:^(BOOL finished2) {
        XCTAssertEqual([self.collectionView numberOfSections], 1);
        XCTAssertEqual([self.collectionView numberOfItemsInSection:0], 4);
        [expectation fulfill];
    }];
    [self waitForExpectationsWithTimeout:30 handler:nil];
}

- (void)test_whenDeletingItemsTwice_withDataUpdatedTwice_thatAllUpdatesAppliedWithoutException {
    [self setupWithObjects:@[
        genTestObject(@1, @4),
    ]];

    IGTestObject *object = self.dataSource.objects[0];
    IGListSectionController *sectionController = [self.adapter sectionControllerForObject:object];

    XCTestExpectation *expectation = genExpectation;
    [sectionController.collectionContext performBatchAnimated:YES updates:^(id<IGListBatchContext> batchContext) {
        object.value = @3;
        [batchContext deleteInSectionController:sectionController atIndexes:[NSIndexSet indexSetWithIndex:0]];
        [batchContext deleteInSectionController:sectionController atIndexes:[NSIndexSet indexSetWithIndex:0]];
    } completion:^(BOOL finished2) {
        XCTAssertEqual([self.collectionView numberOfSections], 1);
        XCTAssertEqual([self.collectionView numberOfItemsInSection:0], 3);
        [expectation fulfill];
    }];
    [self waitForExpectationsWithTimeout:30 handler:nil];
}

- (void)test_whenReloadingSameItemTwice_thatDeletesAndInsertsAreBalanced {
    [self setupWithObjects:@[
        genTestObject(@1, @4),
    ]];

    IGTestObject *object = self.dataSource.objects[0];
    IGListSectionController *sectionController = [self.adapter sectionControllerForObject:object];

    XCTestExpectation *expectation = genExpectation;
    [sectionController.collectionContext performBatchAnimated:YES updates:^(id<IGListBatchContext> batchContext) {
        [batchContext reloadInSectionController:sectionController atIndexes:[NSIndexSet indexSetWithIndex:0]];
        [batchContext reloadInSectionController:sectionController atIndexes:[NSIndexSet indexSetWithIndex:0]];
    } completion:^(BOOL finished2) {
        XCTAssertEqual([self.collectionView numberOfSections], 1);
        XCTAssertEqual([self.collectionView numberOfItemsInSection:0], 4);
        [expectation fulfill];
    }];
    [self waitForExpectationsWithTimeout:30 handler:nil];
}

- (void)test_whenUpdateQueuedDuringBatch_thatUpdateCompletesWithoutCrashing {
    [self setupWithObjects:@[
        genTestObject(@1, @4),
        genTestObject(@2, @4),
        genTestObject(@3, @4),
        genTestObject(@4, @4),
    ]];

    IGTestObject *object = self.dataSource.objects[0];
    IGTestDelegateController *sectionController = [self.adapter sectionControllerForObject:object];

    XCTestExpectation *expect1 = genExpectation;
    XCTestExpectation *expect2 = genExpectation;

    [sectionController.collectionContext performBatchAnimated:YES updates:^(id<IGListBatchContext> batchContext) {
        object.value = @3;
        [batchContext deleteInSectionController:sectionController atIndexes:[NSIndexSet indexSetWithIndex:0]];

        self.dataSource.objects = @[
            genTestObject(@2, @4),
            genTestObject(@4, @4),
            genTestObject(@1, @3),
        ];
        [self.adapter performUpdatesAnimated:YES completion:^(BOOL finished) {
            XCTAssertEqual([self.collectionView numberOfSections], 3);
            XCTAssertEqual([self.collectionView numberOfItemsInSection:0], 4);
            XCTAssertEqual([self.collectionView numberOfItemsInSection:1], 4);
            XCTAssertEqual([self.collectionView numberOfItemsInSection:2], 3);
            [expect1 fulfill];
        }];
    } completion:^(BOOL finished2) {
        XCTAssertEqual([self.collectionView numberOfSections], 4);
        XCTAssertEqual([self.collectionView numberOfItemsInSection:0], 3);
        XCTAssertEqual([self.collectionView numberOfItemsInSection:1], 4);
        XCTAssertEqual([self.collectionView numberOfItemsInSection:2], 4);
        XCTAssertEqual([self.collectionView numberOfItemsInSection:3], 4);
        [expect2 fulfill];
    }];
    [self waitForExpectationsWithTimeout:30 handler:nil];
}

- (void)test_whenMassiveUpdate_thatUpdateApplied {
    // init empty
    [self setupWithObjects:@[]];

    NSMutableArray *objects = [NSMutableArray new];
    for (NSInteger i = 0; i < 3000; i++) {
        [objects addObject:genTestObject(@(i + 1), @4)];
    }
    self.dataSource.objects = objects;

    XCTestExpectation *expectation = genExpectation;
    [self.adapter performUpdatesAnimated:YES completion:^(BOOL finished) {
        XCTAssertEqual([self.collectionView numberOfSections], 3000);
        [expectation fulfill];
    }];

    [self waitForExpectationsWithTimeout:30 handler:nil];
}

- (void)test_whenAddingMultipleUpdateListeners_withPerformUpdatesAnimated_thatEventsReceived {
    [self setupWithObjects:@[
        genTestObject(@1, @1)
    ]];

    IGListAdapterUpdateTester *listener1 = [IGListAdapterUpdateTester new];;
    IGListAdapterUpdateTester *listener2 = [IGListAdapterUpdateTester new];;

    [self.adapter addUpdateListener:listener1];
    [self.adapter addUpdateListener:listener2];

    self.dataSource.objects = @[
        genTestObject(@1, @1),
        genTestObject(@2, @1)
    ];

    XCTestExpectation *expectation = genExpectation;
    [self.adapter performUpdatesAnimated:YES completion:^(BOOL finished) {
        XCTAssertEqual(listener1.hits, 1);
        XCTAssertEqual(listener1.animated, YES);
        XCTAssertEqual(listener1.type, IGListAdapterUpdateTypePerformUpdates);
        XCTAssertEqual(listener2.hits, 1);
        XCTAssertEqual(listener2.animated, YES);
        XCTAssertEqual(listener2.type, IGListAdapterUpdateTypePerformUpdates);
        [expectation fulfill];
    }];

    [self waitForExpectationsWithTimeout:30 handler:nil];
}

- (void)test_whenAddingMultipleUpdateListeners_withPerformUpdatesNotAnimated_thatEventsReceived {
    [self setupWithObjects:@[
        genTestObject(@1, @1)
    ]];

    IGListAdapterUpdateTester *listener1 = [IGListAdapterUpdateTester new];;
    IGListAdapterUpdateTester *listener2 = [IGListAdapterUpdateTester new];;

    [self.adapter addUpdateListener:listener1];
    [self.adapter addUpdateListener:listener2];

    self.dataSource.objects = @[
        genTestObject(@1, @1),
        genTestObject(@2, @1)
    ];

    XCTestExpectation *expectation = genExpectation;
    [self.adapter performUpdatesAnimated:NO completion:^(BOOL finished) {
        XCTAssertEqual(listener1.hits, 1);
        XCTAssertEqual(listener1.animated, NO);
        XCTAssertEqual(listener1.type, IGListAdapterUpdateTypePerformUpdates);
        XCTAssertEqual(listener2.hits, 1);
        XCTAssertEqual(listener2.animated, NO);
        XCTAssertEqual(listener2.type, IGListAdapterUpdateTypePerformUpdates);
        [expectation fulfill];
    }];

    [self waitForExpectationsWithTimeout:30 handler:nil];
}

- (void)test_whenAddingMultipleUpdateListeners_withReloadData_thatEventsReceived {
    [self setupWithObjects:@[
        genTestObject(@1, @1)
    ]];

    IGListAdapterUpdateTester *listener1 = [IGListAdapterUpdateTester new];;
    IGListAdapterUpdateTester *listener2 = [IGListAdapterUpdateTester new];;

    [self.adapter addUpdateListener:listener1];
    [self.adapter addUpdateListener:listener2];

    self.dataSource.objects = @[
        genTestObject(@1, @1),
        genTestObject(@2, @1)
    ];

    XCTestExpectation *expectation = genExpectation;
    [self.adapter reloadDataWithCompletion:^(BOOL finished) {
        XCTAssertEqual(listener1.hits, 1);
        XCTAssertEqual(listener1.animated, NO);
        XCTAssertEqual(listener1.type, IGListAdapterUpdateTypeReloadData);
        XCTAssertEqual(listener2.hits, 1);
        XCTAssertEqual(listener2.animated, NO);
        XCTAssertEqual(listener2.type, IGListAdapterUpdateTypeReloadData);
        [expectation fulfill];
    }];

    [self waitForExpectationsWithTimeout:30 handler:nil];
}

- (void)test_whenAddingMultipleUpdateListeners_withItemUpdatesAnimated_thatEventsReceived {
    [self setupWithObjects:@[
        genTestObject(@1, @1)
    ]];

    IGListAdapterUpdateTester *listener1 = [IGListAdapterUpdateTester new];;
    IGListAdapterUpdateTester *listener2 = [IGListAdapterUpdateTester new];;

    [self.adapter addUpdateListener:listener1];
    [self.adapter addUpdateListener:listener2];

    self.dataSource.objects = @[
        genTestObject(@1, @1),
        genTestObject(@2, @1)
    ];

    IGListSectionController *section = [self.adapter sectionControllerForObject:self.dataSource.objects.firstObject];

    XCTestExpectation *expectation = genExpectation;
    [section.collectionContext performBatchAnimated:YES updates:^(id<IGListBatchContext>  _Nonnull batchContext) {
        [batchContext reloadInSectionController:section atIndexes:[NSIndexSet indexSetWithIndex:0]];
    } completion:^(BOOL finished) {
        XCTAssertEqual(listener1.hits, 1);
        XCTAssertEqual(listener1.animated, YES);
        XCTAssertEqual(listener1.type, IGListAdapterUpdateTypeItemUpdates);
        XCTAssertEqual(listener2.hits, 1);
        XCTAssertEqual(listener2.animated, YES);
        XCTAssertEqual(listener2.type, IGListAdapterUpdateTypeItemUpdates);
        [expectation fulfill];
    }];

    [self waitForExpectationsWithTimeout:30 handler:nil];
}

- (void)test_whenAddingMultipleUpdateListeners_withItemUpdatesNotAnimated_thatEventsReceived {
    [self setupWithObjects:@[
        genTestObject(@1, @1)
    ]];

    IGListAdapterUpdateTester *listener1 = [IGListAdapterUpdateTester new];;
    IGListAdapterUpdateTester *listener2 = [IGListAdapterUpdateTester new];;

    [self.adapter addUpdateListener:listener1];
    [self.adapter addUpdateListener:listener2];

    self.dataSource.objects = @[
        genTestObject(@1, @1),
        genTestObject(@2, @1)
    ];

    IGListSectionController *section = [self.adapter sectionControllerForObject:self.dataSource.objects.firstObject];

    XCTestExpectation *expectation = genExpectation;
    [section.collectionContext performBatchAnimated:NO updates:^(id<IGListBatchContext>  _Nonnull batchContext) {
        [batchContext reloadInSectionController:section atIndexes:[NSIndexSet indexSetWithIndex:0]];
    } completion:^(BOOL finished) {
        XCTAssertEqual(listener1.hits, 1);
        XCTAssertEqual(listener1.animated, NO);
        XCTAssertEqual(listener1.type, IGListAdapterUpdateTypeItemUpdates);
        XCTAssertEqual(listener2.hits, 1);
        XCTAssertEqual(listener2.animated, NO);
        XCTAssertEqual(listener2.type, IGListAdapterUpdateTypeItemUpdates);
        [expectation fulfill];
    }];

    [self waitForExpectationsWithTimeout:30 handler:nil];
}

- (void)test_whenAddingMultipleUpdateListeners_thenRemovingListener_thatRemainingReceives {
    [self setupWithObjects:@[
        genTestObject(@1, @1)
    ]];

    IGListAdapterUpdateTester *listener1 = [IGListAdapterUpdateTester new];;
    IGListAdapterUpdateTester *listener2 = [IGListAdapterUpdateTester new];;

    [self.adapter addUpdateListener:listener1];
    [self.adapter addUpdateListener:listener2];
    [self.adapter removeUpdateListener:listener2];

    self.dataSource.objects = @[
        genTestObject(@1, @1),
        genTestObject(@2, @1)
    ];

    XCTestExpectation *expectation = genExpectation;
    [self.adapter performUpdatesAnimated:YES completion:^(BOOL finished) {
        XCTAssertEqual(listener1.hits, 1);
        XCTAssertEqual(listener1.animated, YES);
        XCTAssertEqual(listener1.type, IGListAdapterUpdateTypePerformUpdates);
        XCTAssertEqual(listener2.hits, 0);
        [expectation fulfill];
    }];

    [self waitForExpectationsWithTimeout:30 handler:nil];
}

- (void)test_whenAddingUpdateListener_thenListenerReferenceHitsZero_thatListenerReleased {
    [self setupWithObjects:@[
        genTestObject(@1, @1)
    ]];

    IGListAdapterUpdateTester *listener = [IGListAdapterUpdateTester new];
    __weak id weakListener = listener;
    [self.adapter addUpdateListener:listener];
    listener = nil;

    self.dataSource.objects = @[
        genTestObject(@1, @1),
        genTestObject(@2, @1)
    ];

    XCTestExpectation *expectation = genExpectation;
    [self.adapter performUpdatesAnimated:YES completion:^(BOOL finished) {
        XCTAssertNil(weakListener);
        [expectation fulfill];
    }];

    [self waitForExpectationsWithTimeout:30 handler:nil];
}

- (void)test_whenModifyingInitialAndFinalAttribute_thatLayoutIsCorrect {
    // set up the custom layout
    IGListCollectionViewLayout *layout = [[IGListCollectionViewLayout alloc] initWithStickyHeaders:NO topContentInset:0 stretchToEdge:YES];
    self.collectionView.collectionViewLayout = layout;

    IGTestObject *object = genTestObject(@1, @2);
    [self setupWithObjects:@ [object]];

    // set up the section controller
    IGTestDelegateController *sectionController = [self.adapter sectionControllerForObject:object];
    sectionController.transitionDelegate = sectionController;

    CGPoint offset = CGPointMake(10, 10);
    NSIndexPath *indexPath = genIndexPath(0, 0);
    UICollectionViewLayoutAttributes *attribute = [layout layoutAttributesForItemAtIndexPath:indexPath];

    // set up the custom initial attribute transformation
    sectionController.initialAttributesOffset = offset;
    UICollectionViewLayoutAttributes *initialAttribute = [layout initialLayoutAttributesForAppearingItemAtIndexPath:indexPath];

    // set up the custom final attribute transformation
    sectionController.finalAttributesOffset = offset;
    UICollectionViewLayoutAttributes *finalAttribute = [layout finalLayoutAttributesForDisappearingItemAtIndexPath:indexPath];

    IGAssertEqualPoint(initialAttribute.center, attribute.center.x + offset.x, attribute.center.y + offset.y);
    IGAssertEqualPoint(finalAttribute.center, attribute.center.x + offset.x ,attribute.center.y + offset.y);
}

- (void)test_whenModifyingInitialAndFinalAttribute_withoutTransitionDelegate_thatLayoutIsCorrect {
    // set up the custom layout
    IGListCollectionViewLayout *layout = [[IGListCollectionViewLayout alloc] initWithStickyHeaders:NO topContentInset:0 stretchToEdge:YES];
    self.collectionView.collectionViewLayout = layout;

    IGTestObject *object = genTestObject(@1, @2);
    [self setupWithObjects:@ [object]];

    // When no transition delegate is set, the initial and final layout methods no-op, so these values should all match
    NSIndexPath *indexPath = genIndexPath(0, 0);
    UICollectionViewLayoutAttributes *attribute = [layout layoutAttributesForItemAtIndexPath:indexPath];
    UICollectionViewLayoutAttributes *initialAttribute = [layout initialLayoutAttributesForAppearingItemAtIndexPath:indexPath];
    UICollectionViewLayoutAttributes *finalAttribute = [layout finalLayoutAttributesForDisappearingItemAtIndexPath:indexPath];

    IGAssertEqualPoint(attribute.center, initialAttribute.center.x, initialAttribute.center.y);
    IGAssertEqualPoint(attribute.center, finalAttribute.center.x, finalAttribute.center.y);
}

- (void)test_whenSwappingCollectionViewsAfterUpdate_thatUpdatePerformedOnTheCorrectCollectionView {
    // BEGIN: setup of FIRST adapter+dataSource+collectionView
    IGListAdapter *adapter1 = [[IGListAdapter alloc] initWithUpdater:[IGListAdapterUpdater new] viewController:nil];

    UICollectionView *collectionView1 = [[UICollectionView alloc] initWithFrame:self.window.frame collectionViewLayout:[UICollectionViewFlowLayout new]];
    [self.window addSubview:collectionView1];
    adapter1.collectionView = collectionView1;

    IGTestDelegateDataSource *dataSource1 = [IGTestDelegateDataSource new];
    dataSource1.objects = @[
        genTestObject(@1, @1),
        genTestObject(@2, @1)
    ];
    adapter1.dataSource = dataSource1;
    // END: setup of FIRST adapter+dataSource+collectionView

    // BEGIN: setup of SECOND adapter+dataSource+collectionView
    IGListAdapter *adapter2 = [[IGListAdapter alloc] initWithUpdater:[IGListAdapterUpdater new] viewController:nil];

    UICollectionView *collectionView2 = [[UICollectionView alloc] initWithFrame:self.window.frame collectionViewLayout:[UICollectionViewFlowLayout new]];
    [self.window addSubview:collectionView2];
    adapter2.collectionView = collectionView2;

    IGTestDelegateDataSource *dataSource2 = [IGTestDelegateDataSource new];
    dataSource2.objects = @[
        genTestObject(@3, @1)
    ];
    adapter2.dataSource = dataSource2;
    // END: setup of SECOND adapter+dataSource+collectionView

    // delete the last-most section from the FIRST dataSource
    dataSource1.objects = @[
        genTestObject(@1, @1)
    ];

    XCTestExpectation *expectation = genExpectation;
    [adapter1 performUpdatesAnimated:YES completion:^(BOOL finished) {
        [expectation fulfill];
    }];

    // simulate a collectionView swap (e.g. cell reuse) immediately after an async update is queued
    adapter1.collectionView = collectionView2;
    adapter2.collectionView = collectionView1;

    [self waitForExpectationsWithTimeout:30 handler:nil];
}

- (void)test_whenCollectionViewBecomesNilDuringPerformUpdates_thatStateCleanedCorrectly {
    [self setupWithObjects:@[
        genTestObject(@1, @1)
    ]];

    // perform update on listAdapter
    XCTestExpectation *expectation1 = genExpectation;
    [self.adapter performUpdatesAnimated:NO completion:^(BOOL finished) {
        [expectation1 fulfill];
    }];
    [self waitForExpectationsWithTimeout:30 handler:nil];

    // update the underlying contents before performing another update
    self.dataSource.objects = @[
        genTestObject(@1, @1),
        genTestObject(@2, @1)
    ];

    // perform update, but set the listAdapter's collectionView to nil during the update
    XCTestExpectation *expectation2 = genExpectation;
    [self.adapter performUpdatesAnimated:NO completion:^(BOOL finished) {
        [expectation2 fulfill];
    }];
    self.adapter.collectionView = nil;
    [self waitForExpectationsWithTimeout:30 handler:nil];

    // add a new collectionView to the listAdapter
    UICollectionView *collectionView2 = [[UICollectionView alloc] initWithFrame:self.window.frame collectionViewLayout:[UICollectionViewFlowLayout new]];
    [self.window addSubview:collectionView2];
    self.adapter.collectionView = collectionView2;

    // update the underlying contents before performing update
    self.dataSource.objects = @[
        genTestObject(@1, @1),
        genTestObject(@2, @1),
        genTestObject(@3, @1)
    ];

    // perform update on listAdapter (now with a non-nil collectionView)
    XCTestExpectation *expectation3 = genExpectation;
    [self.adapter performUpdatesAnimated:NO completion:^(BOOL finished) {
        [expectation3 fulfill];
    }];
    [self waitForExpectationsWithTimeout:30 handler:nil];
}

- (void)test_whenCollectionViewBecomesNilDuringReloadData_thatStateCleanedCorrectly {
    [self setupWithObjects:@[
        genTestObject(@1, @1)
    ]];

    // reload data on listAdapter
    XCTestExpectation *expectation1 = genExpectation;
    [self.adapter reloadDataWithCompletion:^(BOOL finished) {
        [expectation1 fulfill];
    }];
    [self waitForExpectationsWithTimeout:30 handler:nil];

    // update the underlying contents before reloading again
    self.dataSource.objects = @[
        genTestObject(@1, @1),
        genTestObject(@2, @1)
    ];

    // reload data, but set the listAdapter's collectionView to nil during the update
    XCTestExpectation *expectation2 = genExpectation;
    [self.adapter reloadDataWithCompletion:^(BOOL finished) {
        [expectation2 fulfill];
    }];
    self.adapter.collectionView = nil;
    [self waitForExpectationsWithTimeout:30 handler:nil];

    // add a new collectionView to the listAdapter
    UICollectionView *collectionView2 = [[UICollectionView alloc] initWithFrame:self.window.frame collectionViewLayout:[UICollectionViewFlowLayout new]];
    [self.window addSubview:collectionView2];
    self.adapter.collectionView = collectionView2;
    self.dataSource.objects = @[
        genTestObject(@1, @1),
        genTestObject(@2, @1),
        genTestObject(@3, @1)
    ];

    // reload data on listAdapter (now with a non-nil collectionView)
    XCTestExpectation *expectation3 = genExpectation;
    [self.adapter reloadDataWithCompletion:^(BOOL finished) {
        [expectation3 fulfill];
    }];
    [self waitForExpectationsWithTimeout:30 handler:nil];
}

- (void)test_whenUpdating_withMissingSectionController_thatDoesNotCrash {
    [self setupWithObjects:@[
        genTestObject(@0, @"Foo"),
        genTestObject(@1, @"Bar")
    ]];

    // Adding an object that won't have a corresponding section-controller
    self.dataSource.objects = @[
        genTestObject(@0, @"Foo"),
        genTestObject(@1, @"Bar"),
        kIGTestDelegateDataSourceSkipObject
    ];

    // Perform updates on the adapter
    XCTestExpectation *expectation = genExpectation;
    [self.adapter performUpdatesAnimated:NO completion:^(BOOL finished) {
        // Checked that the update worked
        XCTAssertTrue(finished);
        // Check that we skipped the object with a missing section-controller
        XCTAssertEqual([self.collectionView numberOfSections], 2);
        XCTAssertEqual(self.adapter.objects.count, 2);
        [expectation fulfill];
    }];
    [self waitForExpectationsWithTimeout:30 handler:nil];
}

#pragma mark - Dealloc checks

- (void)test_whenReleasingObjects_thatAssertDoesntFire {
    [self setupWithObjects:@[
        genTestObject(@1, @1)
    ]];

    // if the adapter keeps a strong ref to self and uses an async method, this will hit asserts that a list item
    // controller is nil. the adapter should be released and the completion block never called.
    @autoreleasepool {
        IGListAdapterUpdater *updater = [[IGListAdapterUpdater alloc] init];
        IGListAdapter *adapter = [[IGListAdapter alloc] initWithUpdater:updater viewController:nil workingRangeSize:2];
        adapter.collectionView = self.collectionView;
        adapter.dataSource = self.dataSource;
        [adapter performUpdatesAnimated:NO completion:^(BOOL finished) {
            XCTFail(@"Should not reach completion block for adapter");
        }];
    }

    self.collectionView = nil;
    self.dataSource = nil;

    // queued after perform updates
    XCTestExpectation *expectation = genExpectation;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [expectation fulfill];
    });
    [self waitForExpectationsWithTimeout:30 handler:nil];
}

- (void)test_whenDataSourceDeallocatedAfterUpdateQueued_thatUpdateSuccesfullyCompletes {
    IGTestDelegateDataSource *dataSource = [IGTestDelegateDataSource new];
    dataSource.objects = @[genTestObject(@1, @1)];
    self.adapter.collectionView = self.collectionView;
    self.adapter.dataSource = dataSource;
    [self.collectionView layoutIfNeeded];

    dataSource.objects = @[
        genTestObject(@1, @1),
        genTestObject(@2, @2),
    ];

    XCTestExpectation *expectation = genExpectation;
    [self.adapter performUpdatesAnimated:YES completion:^(BOOL finished) {
        XCTAssertEqual([self.collectionView numberOfSections], 2);
        [expectation fulfill];
    }];

    dataSource = nil;

    [self waitForExpectationsWithTimeout:30 handler:nil];
}

- (void)test_whenQueuingUpdate_withSectionControllerBatchUpdate_thatSectionControllerNotRetained {
    __weak id weakSectionController = nil;
    __weak id weakAdapter = nil;
    __weak id weakCollectionView = nil;

    @autoreleasepool {
        IGListAdapter *adapter = [[IGListAdapter alloc] initWithUpdater:[IGListAdapterUpdater new] viewController:nil];
        IGTestDelegateDataSource *dataSource = [IGTestDelegateDataSource new];
        IGTestObject *object = genTestObject(@1, @2);
        dataSource.objects = @[object];
        UICollectionView *collectionView = [[UICollectionView alloc] initWithFrame:CGRectMake(0, 0, 100, 100) collectionViewLayout:[UICollectionViewFlowLayout new]];
        adapter.collectionView = collectionView;
        adapter.dataSource = dataSource;
        [collectionView layoutIfNeeded];
        XCTAssertEqual([collectionView numberOfSections], 1);
        XCTAssertEqual([collectionView numberOfItemsInSection:0], 2);

        IGListSectionController *section = [adapter sectionControllerForObject:object];

        [section.collectionContext performBatchAnimated:YES updates:^(id<IGListBatchContext> batchContext) {
            object.value = @3;
            [batchContext insertInSectionController:section atIndexes:[NSIndexSet indexSetWithIndex:0]];
        } completion:^(BOOL finished) {}];

        dataSource.objects = @[object, genTestObject(@2, @2)];
        [adapter performUpdatesAnimated:YES completion:^(BOOL finished) {}];

        weakAdapter = adapter;
        weakCollectionView = collectionView;
        weakSectionController = section;

        XCTAssertNotNil(weakAdapter);
        XCTAssertNotNil(weakCollectionView);
        XCTAssertNotNil(weakSectionController);
    }
    XCTAssertNil(weakAdapter);
    XCTAssertNil(weakCollectionView);
    XCTAssertNil(weakSectionController);
}

- (void)test_whenInvalidatingInsideBatchUpdate_withSystemReleased_thatSystemNil_andCollectionViewDoesntCrashOnDealloc {
    __weak id weakAdapter = nil;
    __block BOOL executedItemUpdate = NO;
    XCTestExpectation *expectation = genExpectation;

    @autoreleasepool {
        self.dataSource.objects = @[
            genTestObject(@1, @"Bar"),
            genTestObject(@0, @"Foo")
        ];

        UICollectionView *collectionView = [[UICollectionView alloc] initWithFrame:self.window.frame collectionViewLayout:[UICollectionViewFlowLayout new]];
        [self.window addSubview:collectionView];
        IGListAdapterUpdater *updater = [IGListAdapterUpdater new];
        IGListAdapter *adapter = [[IGListAdapter alloc] initWithUpdater:updater viewController:nil];
        adapter.dataSource = self.dataSource;
        adapter.collectionView = collectionView;
        [collectionView layoutIfNeeded];

        IGTestDelegateController *section = [adapter sectionControllerForObject:self.dataSource.objects.firstObject];

        __weak typeof(section) weakSection = section;
        section.itemUpdateBlock = ^{
            executedItemUpdate = YES;
            [weakSection.collectionContext invalidateLayoutForSectionController:weakSection completion:nil];
        };

        self.dataSource.objects = @[
            genTestObject(@1, @"Bar"),
            genTestObject(@0, @"Foo")
        ];

        [adapter performUpdatesAnimated:YES completion:^(BOOL finished) {
            XCTAssertNotNil(collectionView);
            XCTAssertNotNil(adapter);
            [collectionView removeFromSuperview];
            [expectation fulfill];
        }];

        weakAdapter = adapter;
        XCTAssertNotNil(weakAdapter);
    }

    [self waitForExpectationsWithTimeout:30 handler:^(NSError * _Nullable error) {
        XCTAssertTrue(executedItemUpdate);
        XCTAssertNil(weakAdapter);
    }];
}

- (void)test_whenInvalidatingInsideBatchUpdate_andRemoveThatSectionController_thatCollectionViewDoesntCrash {
    IGTestObject *foo = genTestObject(@1, @"Foo");
    IGTestObject *bar = genTestObject(@0, @"Bar");
    self.dataSource.objects = @[foo, bar];

    UICollectionView *collectionView = [[UICollectionView alloc] initWithFrame:self.window.frame collectionViewLayout:[UICollectionViewFlowLayout new]];
    [self.window addSubview:collectionView];
    IGListAdapterUpdater *updater = [IGListAdapterUpdater new];
    IGListAdapter *adapter = [[IGListAdapter alloc] initWithUpdater:updater viewController:nil];
    adapter.dataSource = self.dataSource;
    adapter.collectionView = collectionView;
    [collectionView layoutIfNeeded];

    IGTestDelegateController *sectionToRemove = [adapter sectionControllerForObject:bar];

    self.dataSource.objects = @[foo];

    XCTestExpectation *expectation = genExpectation;
    [adapter performUpdatesAnimated:YES completion:^(BOOL finished) {
        XCTAssertTrue(finished);
        [expectation fulfill];
    }];

    XCTestExpectation *expectation2 = genExpectation;
    [sectionToRemove.collectionContext invalidateLayoutForSectionController:sectionToRemove completion:^(BOOL finished) {
        // That section-controller is about to be removed, so this should not finish.
        XCTAssertFalse(finished);
        [expectation2 fulfill];
    }];

    [self waitForExpectationsWithTimeout:30 handler:nil];
}

- (void)test_whenPerformingBatchSectionUpdate_thatTransactionObjectsGetsDeallocated {
    __weak IGListUpdateTransactionBuilder *transactionBuilder = nil;
    __block __weak IGListUpdateTransactionBuilder *lastTransactionBuilder = nil;
    __block __weak id<IGListUpdateTransactable> transaction = nil;

    IGListAdapterUpdater *updater = (IGListAdapterUpdater *)self.updater;

    @autoreleasepool {
        [self setupWithObjects:@[
            genTestObject(@0, @"Foo")
        ]];

        self.dataSource.objects = @[
            genTestObject(@0, @"Foo"),
            genTestObject(@1, @"Bar")
        ];

        // Grab the current builder
        transactionBuilder = [updater transactionBuilder];

        [self.adapter performBatchAnimated:NO updates:^(id<IGListBatchContext>  _Nonnull batchContext) {
            // Take advantage of `performBatchAnimated` to grab the transaction, but we don't perform any changes.
            lastTransactionBuilder = [updater lastTransactionBuilder];
            XCTAssertNotNil(lastTransactionBuilder);
            transaction = [updater transaction];
            XCTAssertNotNil(transaction);
        } completion:nil];

        XCTestExpectation *expectation = genExpectation;
        [self.adapter performUpdatesAnimated:NO completion:^(BOOL finished) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                XCTAssertNil(transactionBuilder);
                XCTAssertNil(lastTransactionBuilder);
                XCTAssertNil(transaction);
                [expectation fulfill];
            });
        }];

        // Force the update to happen right away
        [updater update];
    }

    [self waitForExpectationsWithTimeout:30 handler:nil];
}

#pragma mark - Changing the collectionView/dataSource

- (void)test_whenChangingDataSourceWithADifferentCount_thenPerformBatchUpdate_thatLastestDataIsApplied {
    [self setupWithObjects:@[
        genTestObject(@0, @"Foo")
    ]];

    // STATE
    // DataSource: 1 section
    // Adapter: 1 section
    // CollectionView: 1 section

    self.dataSource = [IGTestDelegateDataSource new];
    self.dataSource.objects = @[
        genTestObject(@0, @"Foo"),
        genTestObject(@1, @"Bar")
    ];
    self.adapter.dataSource = self.dataSource;

    // STATE
    // DataSource: 2 sections
    // Adapter: 2 sections
    // CollectionView: Invalidated count

    // Schedule update
    XCTestExpectation *expectation2 = genExpectation;
    [self.adapter performUpdatesAnimated:NO completion:^(BOOL finished) {
        XCTAssertTrue(finished);
        XCTAssertEqual([self.collectionView numberOfSections], 2);
        XCTAssertEqual(self.adapter.objects.count, 2);

        // STATE
        // DataSource: 2 sections
        // Adapter: 2 sections
        // CollectionView: 2 sections

        [expectation2 fulfill];
    }];

    [self waitForExpectationsWithTimeout:30 handler:nil];
}

- (void)test_whenChangingCollectionView_thenScheduleSectionUpdate_thatLastestDataIsApplied {
    [self setupWithObjects:@[
        genTestObject(@0, @"Foo")
    ]];

    // STATE
    // DataSource: 1 section
    // Adapter: 1 section
    // CollectionView: 1 section

    // Force dataSource <> adapater sync by changing the collection view
    self.layout = [UICollectionViewFlowLayout new];
    self.collectionView = [[UICollectionView alloc] initWithFrame:self.frame
                                             collectionViewLayout:self.layout];
    self.adapter.collectionView = self.collectionView;

    // STATE
    // DataSource: 1 sections
    // Adapter: 1 sections
    // CollectionView: Invalidated count

    XCTAssertEqual([self.collectionView numberOfSections], 1);
    XCTAssertEqual(self.adapter.objects.count, 1);

    // STATE
    // DataSource: 1 sections
    // Adapter: 1 sections
    // CollectionView: 1 sections
}

- (void)test_settingCollectionViewAndDataSource_thatDontCreateCellsUntilLayout {
    self.dataSource.objects = @[
        genTestObject(@0, @"Foo")
    ];
    self.adapter.collectionView = self.collectionView;
    self.adapter.dataSource = self.dataSource;

    // Make sure we didn't create the cells just yet, since we might want to scroll way without animating.
    XCTAssertNil([self.collectionView cellForItemAtIndexPath:[NSIndexPath indexPathForItem:0 inSection:0]]);

    [self.collectionView layoutIfNeeded];
    XCTAssertNotNil([self.collectionView cellForItemAtIndexPath:[NSIndexPath indexPathForItem:0 inSection:0]]);
}

#pragma mark - Changing the collectionView/dataSource with pending SECTION updates

- (void)test_whenSchedulingSectionUpdate_thenChangeCollectionView_thatLastestDataIsApplied {
    [self setupWithObjects:@[
        genTestObject(@0, @"Foo")
    ]];

    // STATE
    // DataSource: 1 section
    // Adapter: 1 section
    // CollectionView: 1 section

    self.dataSource.objects = @[
        genTestObject(@0, @"Foo"),
        genTestObject(@1, @"Bar")
    ];

    // STATE
    // DataSource: 2 sections
    // Adapter: 1 section
    // CollectionView: 1 section

    // Schedule update
    XCTestExpectation *expectation = genExpectation;
    [self.adapter performUpdatesAnimated:NO completion:^(BOOL finished) {

        // STATE
        // DataSource: 2 sections
        // Adapter: 2 sections
        // CollectionView: Invalidated count

        // Force collectionView <> adapter sync
        XCTAssertEqual([self.collectionView numberOfSections], 2);
        XCTAssertEqual(self.adapter.objects.count, 2);
        XCTAssertTrue(finished);

        // STATE
        // DataSource: 2 sections
        // Adapter: 2 sections
        // CollectionView: 2 sections

        [expectation fulfill];
    }];

    // Force dataSource <> adapater sync by changing the collection view
    self.layout = [UICollectionViewFlowLayout new];
    self.collectionView = [[UICollectionView alloc] initWithFrame:self.frame
                                             collectionViewLayout:self.layout];
    self.adapter.collectionView = self.collectionView;

    // Although all the syncs should have been checked by now, lets still make
    // sure the counts are right.
    XCTAssertEqual([self.collectionView numberOfSections], 2);
    XCTAssertEqual(self.adapter.objects.count, 2);

    [self waitForExpectationsWithTimeout:30 handler:nil];
}

- (void)test_whenSchedulingSectionUpdate_thenChangeTheDataSource_thatLastestDataIsApplied {
    [self setupWithObjects:@[
        genTestObject(@0, @"Foo")
    ]];

    // STATE
    // DataSource: 1 section
    // Adapter: 1 section
    // CollectionView: 1 section

    self.dataSource.objects = @[
        genTestObject(@0, @"Foo"),
        genTestObject(@1, @"Bar")
    ];

    // STATE
    // DataSource: 2 section
    // Adapter: 1 section
    // CollectionView: 1 section

    // Schedule update
    XCTestExpectation *expectation2 = genExpectation;
    [self.adapter performUpdatesAnimated:NO completion:^(BOOL finished) {
        // STATE
        // DataSource: 3 sections
        // Adapter: 3 sections
        // CollectionView: Invalidated count

        XCTAssertTrue(finished);
        XCTAssertEqual([self.collectionView numberOfSections], 3);
        XCTAssertEqual(self.adapter.objects.count, 3);

        // STATE
        // DataSource: 3 sections
        // Adapter: 3 sections
        // CollectionView: 3 sections

        [expectation2 fulfill];
    }];

    // Force dataSource <> adapater sync by changing the dataSource
    self.dataSource = [IGTestDelegateDataSource new];
    self.dataSource.objects = @[
        genTestObject(@0, @"Foo"),
        genTestObject(@1, @"Bar"),
        genTestObject(@2, @"Baz")
    ];
    self.adapter.dataSource = self.dataSource;

    // Although all the syncs should have been checked by now, lets still make
    // sure the counts are right.
    XCTAssertEqual([self.collectionView numberOfSections], 3);
    XCTAssertEqual(self.adapter.objects.count, 3);

    [self waitForExpectationsWithTimeout:30 handler:nil];
}

#pragma mark - Changing the collectionView/dataSource with pending ITEM updates

- (void)test_whenSchedulingItemUpdate_thenChangeCollectionView_thatLastestDataIsApplied {
    [self setupWithObjects:@[
        genTestObject(@0, @1)
    ]];

    // STATE
    // Section Controller: 1 cell
    // CollectionView: 1 cell

    IGTestDelegateController *contoller = (IGTestDelegateController *)[self.adapter sectionControllerForSection:0];
    XCTAssertNotNil(contoller);
    XCTAssertEqual([self.collectionView numberOfItemsInSection:0], 1);

    XCTestExpectation *expectation1 = genExpectation;
    [contoller.collectionContext performBatchAnimated:NO updates:^(id<IGListBatchContext>  _Nonnull batchContext) {
        // Just change the item count for section 0
        contoller.item = genTestObject(@0, @2);
        [batchContext insertInSectionController:contoller atIndexes:[NSIndexSet indexSetWithIndex:0]];
    } completion:^(BOOL finished) {
        XCTAssertTrue(finished);
        XCTAssertEqual([self.collectionView numberOfItemsInSection:0], 2);
        [expectation1 fulfill];
    }];

    // Force dataSource <> adapater sync by changing the collection view
    self.layout = [UICollectionViewFlowLayout new];
    self.collectionView = [[UICollectionView alloc] initWithFrame:self.frame
                                             collectionViewLayout:self.layout];
    self.adapter.collectionView = self.collectionView;

    // STATE
    // Section Controller: 2 cells
    // CollectionView: Invalidated count

    XCTAssertEqual([self.collectionView numberOfItemsInSection:0], 2);

    // STATE
    // Section Controller: 2 cells
    // CollectionView: 2 cells

    [self waitForExpectationsWithTimeout:30 handler:nil];
}

- (void)test_whenSchedulingItemUpdate_thenChangeDataSource_thatLastestDataIsApplied {
    [self setupWithObjects:@[
        genTestObject(@0, @1)
    ]];

    // STATE
    // Section Controller: 1 cell
    // CollectionView: 1 cell

    IGTestDelegateController *contoller = (IGTestDelegateController *)[self.adapter sectionControllerForSection:0];
    XCTAssertNotNil(contoller);
    XCTAssertEqual([self.collectionView numberOfItemsInSection:0], 1);

    XCTestExpectation *expectation1 = genExpectation;
    [contoller.collectionContext performBatchAnimated:NO updates:^(id<IGListBatchContext>  _Nonnull batchContext) {
        // Just change the item count for section 0
        contoller.item = genTestObject(@0, @2);
        [batchContext insertInSectionController:contoller atIndexes:[NSIndexSet indexSetWithIndex:0]];
    } completion:^(BOOL finished) {
        XCTAssertTrue(finished);
        XCTAssertEqual([self.collectionView numberOfItemsInSection:0], 2);
        [expectation1 fulfill];
    }];

    // Force dataSource <> adapater sync by changing the dataSource.
    // Note that we keep the old object here, but that should not matter since
    // it didn't change, it won't call -didUpdateToObject on that section-controller.
    IGTestDelegateDataSource *oldDataSource = self.dataSource;
    self.dataSource = [IGTestDelegateDataSource new];
    self.dataSource.objects = oldDataSource.objects;
    self.adapter.dataSource = self.dataSource;

    // STATE
    // Section Controller: 2 cells
    // CollectionView: Invalidated count

    XCTAssertEqual([self.collectionView numberOfItemsInSection:0], 2);

    // STATE
    // Section Controller: 2 cells
    // CollectionView: 2 cells

    [self waitForExpectationsWithTimeout:30 handler:nil];
}

#pragma mark - Changing the collectionView/dataSource in middle of diffing

- (void)test_whenSchedulingSectionUpdate_thenBeginDiffing_thenChangeCollectionView_thatLastestDataIsApplied {
    IGListAdapterUpdater *updater = (IGListAdapterUpdater *)self.updater;
    updater.allowsBackgroundDiffing = YES;

    [self setupWithObjects:@[
        genTestObject(@0, @"Foo")
    ]];

    // STATE
    // DataSource: 1 section
    // Adapter: 1 section
    // CollectionView: 1 section

    self.dataSource.objects = @[
        genTestObject(@0, @"Foo"),
        genTestObject(@1, @"Bar")
    ];

    // STATE
    // DataSource: 2 sections
    // Adapter: 1 section
    // CollectionView: 1 section

    // Schedule update
    XCTestExpectation *expectation = genExpectation;
    [self.adapter performUpdatesAnimated:NO completion:^(BOOL finished) {
        // STATE
        // DataSource: 2 sections
        // Adapter: 2 sections
        // CollectionView: Invalidated count

        XCTAssertTrue(finished);
        XCTAssertEqual([self.collectionView numberOfSections], 2);
        XCTAssertEqual(self.adapter.objects.count, 2);

        // STATE
        // DataSource: 2 sections
        // Adapter: 2 sections
        // CollectionView: 2 sections

        [expectation fulfill];
    }];

    // Force the update to happen right way, so that the diffing starts
    [updater update];

    // Force dataSource <> adapater sync by changing the collection view
    self.layout = [UICollectionViewFlowLayout new];
    self.collectionView = [[UICollectionView alloc] initWithFrame:self.frame
                                             collectionViewLayout:self.layout];
    self.adapter.collectionView = self.collectionView;

    // Although all the syncs should have been checked by now, lets still make
    // sure the counts are right.
    XCTAssertEqual([self.collectionView numberOfSections], 2);
    XCTAssertEqual(self.adapter.objects.count, 2);

    [self waitForExpectationsWithTimeout:30 handler:nil];
}

- (void)test_whenSchedulingSectionUpdate_thenBeginDiffing_thenChangeTheDataSource_thatLastestDataIsApplied {
    IGListAdapterUpdater *updater = (IGListAdapterUpdater *)self.updater;
    updater.allowsBackgroundDiffing = YES;

    [self setupWithObjects:@[
        genTestObject(@0, @"Foo")
    ]];

    // STATE
    // DataSource: 1 section
    // Adapter: 1 section
    // CollectionView: 1 section

    self.dataSource.objects = @[
        genTestObject(@0, @"Foo"),
        genTestObject(@1, @"Bar")
    ];

    // STATE
    // DataSource: 2 sections
    // Adapter: 1 section
    // CollectionView: 1 section

    // Schedule update
    XCTestExpectation *expectation = genExpectation;
    [self.adapter performUpdatesAnimated:NO completion:^(BOOL finished) {
        // STATE
        // DataSource: 3 sections
        // Adapter: 3 sections
        // CollectionView: Invalidated count

        XCTAssertTrue(finished);
        XCTAssertEqual([self.collectionView numberOfSections], 3);
        XCTAssertEqual(self.adapter.objects.count, 3);

        // STATE
        // DataSource: 3 sections
        // Adapter: 3 sections
        // CollectionView: 3 sections

        [expectation fulfill];
    }];

    // Force the update to happen right way, so that the diffing starts
    [updater update];

    // Force dataSource <> adapater sync by changing the dataSource
    self.dataSource = [IGTestDelegateDataSource new];
    self.dataSource.objects = @[
        genTestObject(@0, @"Foo"),
        genTestObject(@1, @"Bar"),
        genTestObject(@2, @"Baz")
    ];
    self.adapter.dataSource = self.dataSource;

    // Although all the syncs should have been checked by now, lets still make
    // sure the counts are right.
    XCTAssertEqual([self.collectionView numberOfSections], 3);
    XCTAssertEqual(self.adapter.objects.count, 3);

    [self waitForExpectationsWithTimeout:30 handler:nil];
}

#pragma mark - Sync the collectionView before setting a adapter.dataSource

- (void)test_whenCollectionViewSyncsBeforeTheAdapterDataSourceIsSet_thatLastestDataIsApplied {
    self.adapter.collectionView = self.collectionView;

    // Force the adapter <> collectionView to sync
    XCTAssertEqual([self.collectionView numberOfSections], 0);
    XCTAssertEqual([self.adapter objects].count, 0);

    // STATE
    // DataSource: Nil
    // Adapter: 0 sections
    // CollectionView: 0 sections

    // Changing the `adapter.dataSource` will sync the adapter <> dataSource, and
    // invalidate the collectionView's internal section/item counts.
    self.dataSource.objects = @[genTestObject(@1, @"Foo")];
    self.adapter.dataSource = self.dataSource;

    // STATE
    // DataSource: 1 section
    // Adapter: 1 section
    // CollectionView: Invalidated counts (UICollectionView will ask for counts on next layout)

    XCTAssertEqual([self.collectionView numberOfSections], 1);
    XCTAssertEqual([self.adapter objects].count, 1);

    // Test that collectionView syncs with the adapter
    [self.collectionView layoutIfNeeded];
    XCTAssertNotNil([self.collectionView cellForItemAtIndexPath:[NSIndexPath indexPathForItem:0 inSection:0]]);

    // STATE
    // DataSource: 1 section
    // Adapter: 1 section
    // CollectionView: 1 section
}

- (void)test_whenCollectionViewSyncsBeforeTheAdapterDataSourceIsSet_thenSchedulingSectionUpdate_thatLastestDataIsApplied {
    self.adapter.collectionView = self.collectionView;

    // Force the adapter <> collectionView to sync
    XCTAssertEqual([self.collectionView numberOfSections], 0);
    XCTAssertEqual([self.adapter objects].count, 0);

    // STATE
    // DataSource: Nil
    // Adapter: 0 sections
    // CollectionView: 0 sections

    // Changing the `adapter.dataSource` will sync the adapter <> dataSource, and
    // invalidate the collectionView's internal section/item counts.
    self.dataSource.objects = @[genTestObject(@0, @"Foo")];
    self.adapter.dataSource = self.dataSource;

    // STATE
    // DataSource: 1 section
    // Adapter: 1 section
    // CollectionView: Invalidated counts (UICollectionView will ask for counts on next layout)

    XCTAssertEqual([self.adapter objects].count, 1);

    // Adding an object
    self.dataSource.objects = @[
        genTestObject(@0, @"Foo"),
        genTestObject(@1, @"Bar"),
    ];

    // STATE
    // DataSource: 2 sections
    // Adapter: 1 section
    // CollectionView: Invalidated counts (Still)

    // Test that a batchUpdate from 1 -> 2 objects works, even though
    // the collectionView has not synced yet.
    XCTestExpectation *expectation = genExpectation;
    [self.adapter performUpdatesAnimated:NO completion:^(BOOL finished) {
        // Checked that the update worked
        XCTAssertTrue(finished);
        // Check that the we have the correct counts
        XCTAssertEqual([self.collectionView numberOfSections], 2);
        XCTAssertEqual(self.adapter.objects.count, 2);
        [expectation fulfill];

        // STATE
        // DataSource: 2 sections
        // Adapter: 2 section
        // CollectionView: 2 sections
    }];

    [self waitForExpectationsWithTimeout:30 handler:nil];
}

- (void)test_whenSectionControllerNotSubclassed_thatDoesNotCrash {
    // We need a custom layout that creates attributes for all cells, even the ones with size
    // zero, so that the UICollectionView requests all cells. Using `UICollectionViewDelegateFlowLayout`
    // doesn't crash, because it doesn't seem to return attributes where the size is zero.
    self.collectionView.collectionViewLayout = [IGListTestCollectionViewLayout new];

    XCTExpectFailureWithOptions(@"When IGListSectionController isn't subclassed, expect an assertion failure, but avoid a crash.",
                                [XCTExpectedFailureOptions nonStrictOptions]);
    [self setupWithObjects:@[kIGTestDelegateDataSourceNoSectionControllerSubclass]];

    XCTestExpectation *expectation = genExpectation;
    [self.adapter reloadDataWithCompletion:^(BOOL finished) {
        [self.collectionView layoutIfNeeded];
        [expectation fulfill];
    }];
    [self waitForExpectationsWithTimeout:30 handler:nil];
}

- (void)test_whenPerformingUpdates_withAdaptiveDiffing_thatCollectionViewCountsUpdate {
    IGListAdapterUpdater *updater = (IGListAdapterUpdater *)self.updater;
    updater.allowsBackgroundDiffing = YES;
    updater.adaptiveDiffingExperimentConfig = (IGListAdaptiveDiffingExperimentConfig) {
        .enabled = YES,
    };

    [self setupWithObjects:@[
        genTestObject(@1, @1),
        genTestObject(@2, @2),
        genTestObject(@3, @3),
    ]];

    self.dataSource.objects = @[
        genTestObject(@2, @2),
        genTestObject(@1, @1), // moved from index 0 to 1
        genTestObject(@3, @3),
        genTestObject(@4, @4), // new
    ];

    XCTestExpectation *expectation = genExpectation;
    [self.adapter performUpdatesAnimated:YES completion:^(BOOL finished2) {
        XCTAssertEqual([self.collectionView numberOfSections], 4);
        XCTAssertEqual([self.collectionView numberOfItemsInSection:0], 2);
        XCTAssertEqual([self.collectionView numberOfItemsInSection:1], 1);
        XCTAssertEqual([self.collectionView numberOfItemsInSection:2], 3);
        XCTAssertEqual([self.collectionView numberOfItemsInSection:3], 4);
        [expectation fulfill];
    }];
    [self waitForExpectationsWithTimeout:30 handler:nil];
}

- (void)test_whenPerformingUpdates_withAdaptiveCoalescing_thatCollectionViewCountsUpdate {
    IGListAdapterUpdater *updater = (IGListAdapterUpdater *)self.updater;
    updater.adaptiveCoalescingExperimentConfig = (IGListAdaptiveCoalescingExperimentConfig) {
        .enabled = YES,
    };

    [self setupWithObjects:@[
        genTestObject(@1, @1),
        genTestObject(@2, @2),
        genTestObject(@3, @3),
    ]];

    self.dataSource.objects = @[
        genTestObject(@2, @2),
        genTestObject(@1, @1), // moved from index 0 to 1
        genTestObject(@3, @3),
        genTestObject(@4, @4), // new
    ];

    XCTestExpectation *expectation = genExpectation;
    [self.adapter performUpdatesAnimated:YES completion:^(BOOL finished2) {
        XCTAssertEqual([self.collectionView numberOfSections], 4);
        XCTAssertEqual([self.collectionView numberOfItemsInSection:0], 2);
        XCTAssertEqual([self.collectionView numberOfItemsInSection:1], 1);
        XCTAssertEqual([self.collectionView numberOfItemsInSection:2], 3);
        XCTAssertEqual([self.collectionView numberOfItemsInSection:3], 4);
        [expectation fulfill];
    }];
    [self waitForExpectationsWithTimeout:30 handler:nil];
}

@end
