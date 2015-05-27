////////////////////////////////////////////////////////////////////////////
//
// Copyright 2015 Realm Inc.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
////////////////////////////////////////////////////////////////////////////

#import "RLMTestCase.h"

#import "RLMObjectSchema_Private.hpp"
#import "RLMObjectStore.h"
#import "RLMObject_Private.hpp"
#import "RLMPredicateUtil.h"
#import "RLMRealm_Private.hpp"
#import "RLMSchema_Private.h"

#import <atomic>
#import <memory>
#import <vector>

RLM_ARRAY_TYPE(KVOObject)
RLM_ARRAY_TYPE(KVOLinkObject1)

@interface KVOObject : RLMObject
@property int pk; // Primary key for isEqual:
@property int ignored;

@property BOOL                 boolCol;
@property int16_t              int16Col;
@property int32_t              int32Col;
@property int64_t              int64Col;
@property float                floatCol;
@property double               doubleCol;
@property bool                 cBoolCol;
@property NSString            *stringCol;
@property NSData              *binaryCol;
@property NSDate              *dateCol;
@property KVOObject           *objectCol;
@property RLMArray<KVOObject> *arrayCol;
@end
@implementation KVOObject
+ (NSString *)primaryKey {
    return @"pk";
}
+ (NSArray *)ignoredProperties {
    return @[@"ignored"];
}
@end

@interface KVOLinkObject1 : RLMObject
@property int pk; // Primary key for isEqual:
@property KVOObject *obj;
@property RLMArray<KVOObject> *array;
@end
@implementation KVOLinkObject1
+ (NSString *)primaryKey {
    return @"pk";
}
@end

@interface KVOLinkObject2 : RLMObject
@property int pk; // Primary key for isEqual:
@property KVOLinkObject1 *obj;
@property RLMArray<KVOLinkObject1> *array;
@end
@implementation KVOLinkObject2
+ (NSString *)primaryKey {
    return @"pk";
}
@end

@interface PlainKVOObject : NSObject
@property int ignored;

@property BOOL            boolCol;
@property int16_t         int16Col;
@property int32_t         int32Col;
@property int64_t         int64Col;
@property float           floatCol;
@property double          doubleCol;
@property bool            cBoolCol;
@property NSString       *stringCol;
@property NSData         *binaryCol;
@property NSDate         *dateCol;
@property PlainKVOObject *objectCol;
@property NSMutableArray *arrayCol;
@end
@implementation PlainKVOObject
@end

@interface PlainLinkObject1 : NSObject
@property PlainKVOObject *obj;
@property NSMutableArray *array;
@end
@implementation PlainLinkObject1
@end

@interface PlainLinkObject2 : NSObject
@property PlainLinkObject1 *obj;
@property NSMutableArray *array;
@end
@implementation PlainLinkObject2
@end

@interface KVOTests : RLMTestCase
// get an object that should be observed for the given object being mutated
// used by some of the subclasses to observe a different accessor for the same row
- (id)observableForObject:(id)obj;
@end

struct KVONotification {
    NSString *keyPath;
    id object;
    NSDictionary *change;
};

// subscribes to kvo notifications on the passed object on creation, records
// all change notifications sent and makes them available in `notifications`,
// and automatically unsubscribes on destruction
class KVORecorder {
    id _observer;
    id _obj;
    NSString *_keyPath;
    RLMRealm *_mutationRealm;
    RLMRealm *_observationRealm;

public:
    std::vector<KVONotification> notifications;

    // construct a new recorder for the given `keyPath` on `obj`, using `observer`
    // as the NSObject helper to actually add as an observer
    KVORecorder(id observer, id obj, NSString *keyPath,
                int options = NSKeyValueObservingOptionOld|NSKeyValueObservingOptionNew)
    : _observer(observer)
    , _obj([observer observableForObject:obj])
    , _keyPath(keyPath)
    , _mutationRealm([obj respondsToSelector:@selector(realm)] ? (RLMRealm *)[obj realm] : nil)
    , _observationRealm([_obj respondsToSelector:@selector(realm)] ? (RLMRealm *)[_obj realm] : nil)
    {
        [_obj addObserver:observer forKeyPath:keyPath options:options context:this];
    }

    ~KVORecorder() {
        @try {
            [_obj removeObserver:_observer forKeyPath:_keyPath context:this];
        }
        @catch (NSException *e) {
            id self = _observer;
            XCTFail(@"%@", e.description);
        }
    }

    // record a single notification
    void operator()(NSString *key, id obj, NSDictionary *changeDictionary) {
        notifications.push_back({key, obj, changeDictionary.copy});
    }

    // ensure that the observed object is updated for any changes made to the
    // object being mutated if they are different
    void refresh() {
        if (_mutationRealm != _observationRealm) {
            [_mutationRealm commitWriteTransaction];
            [_observationRealm refresh];
            [_mutationRealm beginWriteTransaction];
        }
    }
};

// Assert that `recorder` has a notification at `index` and return it if so
#define AssertNotification(recorder, index) ([&]{ \
    (recorder).refresh(); \
    XCTAssertGreaterThan((recorder).notifications.size(), index); \
    return (recorder).notifications.size() > index ? &(recorder).notifications[index] : nullptr; \
})()

// Validate that `recorder` has enough notifications for `index` to be valid,
// and if it does validate that the notification is correct
#define AssertChanged(recorder, index, from, to) do { \
    if (KVONotification *note = AssertNotification((recorder), (index))) { \
        XCTAssertEqualObjects(@(NSKeyValueChangeSetting), note->change[NSKeyValueChangeKindKey]); \
        XCTAssertEqualObjects((from), note->change[NSKeyValueChangeOldKey]); \
        XCTAssertEqualObjects((to), note->change[NSKeyValueChangeNewKey]); \
    } \
} while (false)

@implementation KVOTests
// forward a KVO notification to the KVORecorder stored in the context
- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary *)change
                       context:(void *)context
{
    (*static_cast<KVORecorder *>(context))(keyPath, object, change);
}

// overridden in the multiple accessors, one realm and multiple realms cases
- (id)observableForObject:(id)obj {
    return obj;
}

// overridden in the multiple realms case because `-refresh` does not send
// notifications for intermediate states
- (bool)collapsesNotifications {
    return false;
}

// overridden in all subclases to return the appropriate object
// base class runs the tests on a plain NSObject using stock KVO to ensure that
// the tests are actually covering the correct behavior, since there's a great
// deal that the documentation doesn't specify
- (id)createObject {
    PlainKVOObject *obj = [PlainKVOObject new];
    obj.int16Col = 1;
    obj.int32Col = 2;
    obj.int64Col = 3;
    obj.binaryCol = NSData.data;
    obj.stringCol = @"";
    obj.dateCol = [NSDate dateWithTimeIntervalSinceReferenceDate:0];
    obj.arrayCol = [NSMutableArray array];
    return obj;
}

- (id)createLinkObject {
    PlainLinkObject1 *obj1 = [PlainLinkObject1 new];
    obj1.obj = [self createObject];
    obj1.array = [NSMutableArray new];

    PlainLinkObject2 *obj2 = [PlainLinkObject2 new];
    obj2.obj = obj1;
    obj2.array = [NSMutableArray new];

    return obj2;
}

// actual tests follow

- (void)testRegisterForUnknownProperty {
    KVOObject *obj = [self createObject];

    XCTAssertNoThrow([obj addObserver:self forKeyPath:@"non-existent" options:0 context:nullptr]);
    XCTAssertNoThrow([obj removeObserver:self forKeyPath:@"non-existent"]);

    XCTAssertNoThrow([obj addObserver:self forKeyPath:@"non-existent" options:NSKeyValueObservingOptionOld context:nullptr]);
    XCTAssertNoThrow([obj removeObserver:self forKeyPath:@"non-existent"]);

    XCTAssertNoThrow([obj addObserver:self forKeyPath:@"non-existent" options:NSKeyValueObservingOptionPrior context:nullptr]);
    XCTAssertNoThrow([obj removeObserver:self forKeyPath:@"non-existent"]);
}

- (void)testRemoveObserver {
    KVOObject *obj = [self createObject];
    XCTAssertThrowsSpecificNamed([obj removeObserver:self forKeyPath:@"int32Col"], NSException, NSRangeException);
    XCTAssertThrowsSpecificNamed([obj removeObserver:self forKeyPath:@"int32Col" context:nullptr], NSException, NSRangeException);
    XCTAssertNoThrow([obj addObserver:self forKeyPath:@"int32Col" options:0 context:nullptr]);
    XCTAssertNoThrow([obj removeObserver:self forKeyPath:@"int32Col"]);
    XCTAssertThrowsSpecificNamed([obj removeObserver:self forKeyPath:@"int32Col"], NSException, NSRangeException);

    // `context` parameter must match if it's passed, but the overload that doesn't
    // take one will unregister any context
    void *context = (__bridge void *)obj;
    XCTAssertNoThrow([obj addObserver:self forKeyPath:@"int32Col" options:0 context:nullptr]);
    XCTAssertThrows([obj removeObserver:self forKeyPath:@"int32Col" context:context]);
    XCTAssertNoThrow([obj removeObserver:self forKeyPath:@"int32Col" context:nullptr]);

    XCTAssertNoThrow([obj addObserver:self forKeyPath:@"int32Col" options:0 context:context]);
    XCTAssertNoThrow([obj removeObserver:self forKeyPath:@"int32Col" context:context]);

    XCTAssertNoThrow([obj addObserver:self forKeyPath:@"int32Col" options:0 context:context]);
    XCTAssertNoThrow([obj removeObserver:self forKeyPath:@"int32Col"]);

    // no context version should only unregister one (unspecified) observer
    XCTAssertNoThrow([obj addObserver:self forKeyPath:@"int32Col" options:0 context:context]);
    XCTAssertNoThrow([obj addObserver:self forKeyPath:@"int32Col" options:0 context:nullptr]);
    XCTAssertNoThrow([obj removeObserver:self forKeyPath:@"int32Col"]);
    XCTAssertNoThrow([obj removeObserver:self forKeyPath:@"int32Col"]);
}

- (void)testSimple {
    KVOObject *obj = [self createObject];
    {
        KVORecorder r(self, obj, @"int32Col");
        obj.int32Col = 10;
        AssertChanged(r, 0U, @2, @10);
    }
    {
        KVORecorder r(self, obj, @"int32Col");
        obj.int32Col = 1;
        AssertChanged(r, 0U, @10, @1);
    }
}

- (void)testSelfAssignmentNotifies {
    KVOObject *obj = [self createObject];
    {
        KVORecorder r(self, obj, @"int32Col");
        obj.int32Col = obj.int32Col;
        AssertChanged(r, 0U, @2, @2);
    }
}

- (void)testMultipleObserversAreNotified {
    KVOObject *obj = [self createObject];
    {
        KVORecorder r1(self, obj, @"int32Col");
        KVORecorder r2(self, obj, @"int32Col");
        KVORecorder r3(self, obj, @"int32Col");
        obj.int32Col = 10;
        AssertChanged(r1, 0U, @2, @10);
        AssertChanged(r2, 0U, @2, @10);
        AssertChanged(r3, 0U, @2, @10);
    }
}

- (void)testOnlyObserversForTheCorrectPropertyAreNotified {
    KVOObject *obj = [self createObject];
    {
        KVORecorder r16(self, obj, @"int16Col");
        KVORecorder r32(self, obj, @"int32Col");
        KVORecorder r64(self, obj, @"int64Col");

        obj.int16Col = 2;
        AssertChanged(r16, 0U, @1, @2);
        XCTAssertEqual(1U, r16.notifications.size());
        XCTAssertEqual(0U, r32.notifications.size());
        XCTAssertEqual(0U, r64.notifications.size());

        obj.int32Col = 2;
        AssertChanged(r32, 0U, @2, @2);
        XCTAssertEqual(1U, r16.notifications.size());
        XCTAssertEqual(1U, r32.notifications.size());
        XCTAssertEqual(0U, r64.notifications.size());

        obj.int64Col = 2;
        AssertChanged(r64, 0U, @3, @2);
        XCTAssertEqual(1U, r16.notifications.size());
        XCTAssertEqual(1U, r32.notifications.size());
        XCTAssertEqual(1U, r64.notifications.size());
    }
}

- (void)testMultipleChangesWithSingleObserver {
    KVOObject *obj = [self createObject];
    KVORecorder r(self, obj, @"int32Col");

    obj.int32Col = 1;
    obj.int32Col = 2;
    obj.int32Col = 3;
    obj.int32Col = 3;

    if (self.collapsesNotifications) {
        AssertChanged(r, 0U, @2, @3);
    }
    else {
        AssertChanged(r, 0U, @2, @1);
        AssertChanged(r, 1U, @1, @2);
        AssertChanged(r, 2U, @2, @3);
        AssertChanged(r, 3U, @3, @3);
    }
}

- (void)testOnlyObserversForTheCorrectObjectAreNotified {
    KVOObject *obj1 = [self createObject];
    KVOObject *obj2 = [self createObject];

    KVORecorder r1(self, obj1, @"int32Col");
    KVORecorder r2(self, obj2, @"int32Col");

    obj1.int32Col = 10;
    AssertChanged(r1, 0U, @2, @10);
    XCTAssertEqual(0U, r2.notifications.size());

    obj2.int32Col = 5;
    XCTAssertEqual(1U, r1.notifications.size());
    AssertChanged(r2, 0U, @2, @5);
}

- (void)testOptionsInitial {
    KVOObject *obj = [self createObject];

    {
        KVORecorder r(self, obj, @"int32Col", 0);
        XCTAssertEqual(0U, r.notifications.size());
    }
    {
        KVORecorder r(self, obj, @"int32Col", NSKeyValueObservingOptionInitial);
        XCTAssertEqual(1U, r.notifications.size());
    }
}

- (void)testOptionsOld {
    KVOObject *obj = [self createObject];

    {
        KVORecorder r(self, obj, @"int32Col", 0);
        obj.int32Col = 0;
        if (KVONotification *note = AssertNotification(r, 0U)) {
            XCTAssertNil(note->change[NSKeyValueChangeOldKey]);
        }
    }
    {
        KVORecorder r(self, obj, @"int32Col", NSKeyValueObservingOptionOld);
        obj.int32Col = 0;
        if (KVONotification *note = AssertNotification(r, 0U)) {
            XCTAssertNotNil(note->change[NSKeyValueChangeOldKey]);
        }
    }
}

- (void)testOptionsNew {
    KVOObject *obj = [self createObject];

    {
        KVORecorder r(self, obj, @"int32Col", 0);
        obj.int32Col = 0;
        if (KVONotification *note = AssertNotification(r, 0U)) {
            XCTAssertNil(note->change[NSKeyValueChangeNewKey]);
        }
    }
    {
        KVORecorder r(self, obj, @"int32Col", NSKeyValueObservingOptionNew);
        obj.int32Col = 0;
        if (KVONotification *note = AssertNotification(r, 0U)) {
            XCTAssertNotNil(note->change[NSKeyValueChangeNewKey]);
        }
    }
}

- (void)testOptionsPrior {
    KVOObject *obj = [self createObject];

    KVORecorder r(self, obj, @"int32Col", NSKeyValueObservingOptionNew|NSKeyValueObservingOptionPrior);
    obj.int32Col = 0;
    r.refresh();

    XCTAssertEqual(2U, r.notifications.size());
    if (KVONotification *note = AssertNotification(r, 0U)) {
        XCTAssertNil(note->change[NSKeyValueChangeNewKey]);
        XCTAssertEqualObjects(@YES, note->change[NSKeyValueChangeNotificationIsPriorKey]);
    }
    if (KVONotification *note = AssertNotification(r, 1U)) {
        XCTAssertNotNil(note->change[NSKeyValueChangeNewKey]);
        XCTAssertNil(note->change[NSKeyValueChangeNotificationIsPriorKey]);
    }
}

- (void)testAllPropertyTypes {
    KVOObject *obj = [self createObject];

    {
        KVORecorder r(self, obj, @"boolCol");
        obj.boolCol = YES;
        AssertChanged(r, 0U, @NO, @YES);
    }

    {
        KVORecorder r(self, obj, @"int16Col");
        obj.int16Col = 0;
        AssertChanged(r, 0U, @1, @0);
    }

    {
        KVORecorder r(self, obj, @"int32Col");
        obj.int32Col = 0;
        AssertChanged(r, 0U, @2, @0);
    }

    {
        KVORecorder r(self, obj, @"int64Col");
        obj.int64Col = 0;
        AssertChanged(r, 0U, @3, @0);
    }

    {
        KVORecorder r(self, obj, @"floatCol");
        obj.floatCol = 1.0f;
        AssertChanged(r, 0U, @0, @1);
    }

    {
        KVORecorder r(self, obj, @"doubleCol");
        obj.doubleCol = 1.0;
        AssertChanged(r, 0U, @0, @1);
    }

    {
        KVORecorder r(self, obj, @"cBoolCol");
        obj.cBoolCol = YES;
        AssertChanged(r, 0U, @NO, @YES);
    }

    {
        KVORecorder r(self, obj, @"stringCol");
        obj.stringCol = @"abc";
        AssertChanged(r, 0U, @"", @"abc");
    }

    {
        KVORecorder r(self, obj, @"binaryCol");
        NSData *data = [@"abc" dataUsingEncoding:NSUTF8StringEncoding];
        obj.binaryCol = data;
        AssertChanged(r, 0U, NSData.data, data);
    }

    {
        KVORecorder r(self, obj, @"dateCol");
        NSDate *date = [NSDate dateWithTimeIntervalSinceReferenceDate:1];
        obj.dateCol = date;
        AssertChanged(r, 0U, [NSDate dateWithTimeIntervalSinceReferenceDate:0], date);
    }

    {
        KVORecorder r(self, obj, @"objectCol");
        obj.objectCol = obj;
        AssertChanged(r, 0U, NSNull.null, [self observableForObject:obj]);
    }

    { // should be testing assignment, not mutation
        KVORecorder r(self, obj, @"arrayCol");
        id mutator = [obj mutableArrayValueForKey:@"arrayCol"];
        [mutator addObject:obj];
        r.refresh();
        XCTAssertEqual(1U, r.notifications.size());
    }
}

- (void)testArrayDiffs {
    KVOObject *obj = [self createObject];
    KVORecorder r(self, obj, @"arrayCol");

    id mutator = [obj mutableArrayValueForKey:@"arrayCol"];

#define AssertIndexChange(kind, indexes) \
    if (KVONotification *note = AssertNotification(r, 0U)) { \
        XCTAssertEqual([note->change[NSKeyValueChangeKindKey] intValue], kind); \
        XCTAssertEqualObjects(note->change[NSKeyValueChangeIndexesKey], indexes); \
        r.notifications.pop_back(); \
        XCTAssertTrue(r.notifications.empty()); \
    }

    [mutator addObject:obj];
    AssertIndexChange(NSKeyValueChangeInsertion, [NSIndexSet indexSetWithIndex:0]);

    [mutator addObject:obj];
    AssertIndexChange(NSKeyValueChangeInsertion, [NSIndexSet indexSetWithIndex:1]);

    [mutator removeObjectAtIndex:0];
    AssertIndexChange(NSKeyValueChangeRemoval, [NSIndexSet indexSetWithIndex:0]);

    [mutator replaceObjectAtIndex:0 withObject:obj];
    AssertIndexChange(NSKeyValueChangeReplacement, [NSIndexSet indexSetWithIndex:0]);

    NSMutableIndexSet *indexes = [NSMutableIndexSet new];
    [indexes addIndex:0];
    [indexes addIndex:2];
    [mutator insertObjects:@[obj, obj] atIndexes:indexes];
    AssertIndexChange(NSKeyValueChangeInsertion, indexes);

    [mutator removeObjectsAtIndexes:indexes];
    AssertIndexChange(NSKeyValueChangeRemoval, indexes);

    // We deliberately diverge from NSMutableArray for `removeAllObjects` and
    // `addObjectsFromArray:`, because generating a separate notification for
    // each object added or removed is needlessly pessimal.
    if (![obj.arrayCol isKindOfClass:[NSArray class]]) {
        [mutator addObjectsFromArray:@[obj, obj]];
        AssertIndexChange(NSKeyValueChangeInsertion, [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(1, 2)]);

        [mutator removeLastObject];
        AssertIndexChange(NSKeyValueChangeRemoval, [NSIndexSet indexSetWithIndex:2]);

        [mutator removeAllObjects];
        AssertIndexChange(NSKeyValueChangeRemoval, [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, 2)]);
    }
}

- (void)testIgnoredProperty {
    KVOObject *obj = [self createObject];
    KVORecorder r(self, obj, @"ignored");
    obj.ignored = 10;
    AssertChanged(r, 0U, @0, @10);
}

- (void)testChangeEndOfKeyPath {
    KVOLinkObject2 *obj = [self createLinkObject];
    std::unique_ptr<KVORecorder> r;
    @autoreleasepool {
        r = std::make_unique<KVORecorder>(self, obj, @"obj.obj.boolCol");
    }
    obj.obj.obj.boolCol = YES;
    AssertChanged(*r, 0U, @NO, @YES);
}

- (void)testChangeMiddleOfKeyPath {
    KVOLinkObject2 *obj = [self createLinkObject];
    KVOObject *oldObj = obj.obj.obj;
    KVOObject *newObj = [self createObject];
    newObj.boolCol = YES;

    KVORecorder r(self, obj, @"obj.obj.boolCol");
    obj.obj.obj = newObj;
    AssertChanged(r, 0U, @NO, @YES);
    newObj.boolCol = NO;
    AssertChanged(r, 1U, @YES, @NO);
    oldObj.boolCol = YES;
    XCTAssertEqual(2U, r.notifications.size());
}

- (void)testNullifyMiddleOfKeyPath {
    KVOLinkObject2 *obj = [self createLinkObject];
    KVORecorder r(self, obj, @"obj.obj.boolCol");
    obj.obj = nil;
    AssertChanged(r, 0U, @NO, NSNull.null);
}

- (void)testChangeMiddleOfKeyPathToNonNil {
    KVOLinkObject2 *obj = [self createLinkObject];
    KVOLinkObject1 *obj2 = obj.obj;
    obj.obj = nil;
    obj2.obj.boolCol = YES;

    KVORecorder r(self, obj, @"obj.obj.boolCol");
    obj.obj = obj2;
    AssertChanged(r, 0U, NSNull.null, @YES);
}

//- (void)testObserveArrayCount {
//    KVOObject *obj = [self createObject];
//    KVORecorder r(self, obj, @"arrayCol.@count");
//    id mutator = [obj mutableArrayValueForKey:@"arrayCol"];
//    [mutator addObject:obj];
//    AssertChanged(r, 0U, @0, @1);
//}

// still to test:
//   - Batch array modification
//   - correct object sent in notifications
//   - correct object number of `invalidate` notifications sent
//   - rollback of RLMArray changes
@end

// Run tests on a standalone RLMObject instance
@interface KVOStandaloneObjectTests : KVOTests
@end
@implementation KVOStandaloneObjectTests
- (id)createObject {
    static int pk = 0;
    KVOObject *obj = [KVOObject new];
    obj.pk = pk++;
    obj.int16Col = 1;
    obj.int32Col = 2;
    obj.int64Col = 3;
    obj.binaryCol = NSData.data;
    obj.stringCol = @"";
    obj.dateCol = [NSDate dateWithTimeIntervalSinceReferenceDate:0];
    return obj;
}

- (id)createLinkObject {
    static int pk = 0;
    KVOLinkObject1 *obj1 = [KVOLinkObject1 new];
    obj1.pk = pk++;
    obj1.obj = [self createObject];
    KVOLinkObject2 *obj2 = [KVOLinkObject2 new];
    obj2.pk = pk++;
    obj2.obj = obj1;
    return obj2;
}

- (void)testAddToRealmAfterAddingObservers {
    KVOObject *obj = [self createObject];
    KVORecorder r1(self, obj, @"int32Col");
    KVORecorder r2(self, obj, @"ignored");

    RLMRealm *realm = RLMRealm.defaultRealm;
    [realm beginWriteTransaction];
    [realm addObject:obj];
    obj.int32Col = 10;
    obj.ignored = 15;
    AssertChanged(r1, 0U, @2, @10);
    AssertChanged(r2, 0U, @0, @15);
    [realm commitWriteTransaction];
}

- (void)testInitialIsNotRetriggeredOnAdd {
    KVOObject *obj = [self createObject];
    KVORecorder r1(self, obj, @"int32Col", NSKeyValueObservingOptionInitial);
    KVORecorder r2(self, obj, @"ignored", NSKeyValueObservingOptionInitial);

    XCTAssertEqual(1U, r1.notifications.size());
    XCTAssertEqual(1U, r2.notifications.size());

    RLMRealm *realm = RLMRealm.defaultRealm;
    [realm beginWriteTransaction];
    [realm addObject:obj];
    [realm commitWriteTransaction];

    XCTAssertEqual(1U, r1.notifications.size());
    XCTAssertEqual(1U, r2.notifications.size());
}

- (void)testAddToRealmWithLinkedStandaloneObjects {
    {
        KVOLinkObject2 *obj = [self createLinkObject];
        KVORecorder r(self, obj.obj, @"obj.boolCol");

        RLMRealm *realm = RLMRealm.defaultRealm;
        [realm beginWriteTransaction];
        [realm addObject:obj.obj];
        obj.obj.obj.boolCol = YES;
        AssertChanged(r, 0U, @NO, @YES);
        [realm cancelWriteTransaction];
    }
    @autoreleasepool {
        KVOLinkObject2 *obj = [self createLinkObject];
        KVORecorder r(self, obj.obj, @"obj.boolCol");

        RLMRealm *realm = RLMRealm.defaultRealm;
        [realm beginWriteTransaction];
        [realm addObject:obj.obj];
        obj.obj.obj.boolCol = YES;
        AssertChanged(r, 0U, @NO, @YES);
        [realm cancelWriteTransaction];
    }

    __weak id objleak;
    @autoreleasepool {
        KVOLinkObject2 *obj = [self createLinkObject];
        objleak = obj;
        KVORecorder r(self, obj, @"obj.obj.boolCol");

        RLMRealm *realm = RLMRealm.defaultRealm;
        [realm beginWriteTransaction];
        [realm addObject:obj];
        obj.obj.obj.boolCol = YES;
        AssertChanged(r, 0U, @NO, @YES);
        [realm cancelWriteTransaction];
    }
    @autoreleasepool {
        XCTAssertNil(objleak);
    }

    {
        KVOLinkObject2 *obj = [self createLinkObject];
        KVORecorder r(self, obj, @"obj.obj.boolCol");

        RLMRealm *realm = RLMRealm.defaultRealm;
        [realm beginWriteTransaction];
        [realm addObject:obj.obj];
        obj.obj.obj.boolCol = YES;
        AssertChanged(r, 0U, @NO, @YES);
        [realm cancelWriteTransaction];
    }

    {
        KVOLinkObject2 *obj = [self createLinkObject];
        KVORecorder r(self, obj, @"obj.obj.boolCol");

        RLMRealm *realm = RLMRealm.defaultRealm;
        [realm beginWriteTransaction];
        [realm addObject:obj.obj.obj];
        obj.obj.obj.boolCol = YES;
        AssertChanged(r, 0U, @NO, @YES);
        [realm cancelWriteTransaction];
    }

    {
        KVOLinkObject2 *obj = [self createLinkObject];
        KVORecorder r(self, obj.obj, @"obj.boolCol");

        RLMRealm *realm = RLMRealm.defaultRealm;
        [realm beginWriteTransaction];
        [realm addObject:obj];
        obj.obj.obj.boolCol = YES;
        AssertChanged(r, 0U, @NO, @YES);
        [realm cancelWriteTransaction];
    }
}

@end

// A single persisted object
@interface KVOPersistedObjectTests : KVOTests
@property (nonatomic, strong) RLMRealm *realm;
@end

@implementation KVOPersistedObjectTests
- (void)setUp {
    [super setUp];
    _realm = RLMRealm.defaultRealm;
    [_realm beginWriteTransaction];
}

- (void)tearDown {
    [self.realm cancelWriteTransaction];
    self.realm = nil;
    [super tearDown];
}

- (id)createObject {
    static std::atomic<int> pk{0};
    return [KVOObject createInDefaultRealmWithValue:@[@(++pk),
                                                       @NO, @1, @2, @3, @0, @0, @NO, @"",
                                                       NSData.data, [NSDate dateWithTimeIntervalSinceReferenceDate:0],
                                                       NSNull.null, NSNull.null]];
}

- (id)createLinkObject {
    static std::atomic<int> pk{0};
    return [KVOLinkObject2 createInDefaultRealmWithValue:@[@(++pk), @[@(++pk), [self createObject], @[]], @[]]];
}

- (void)testDeleteObservedObject {
    KVOObject *obj = [self createObject];
    KVORecorder r1(self, obj, @"boolCol");
    KVORecorder r2(self, obj, @"invalidated");
    [self.realm deleteObject:obj];
    AssertChanged(r2, 0U, @NO, @YES);
    // should not crash
}

- (void)testDeleteMiddleOfKeyPath {
    KVOLinkObject2 *obj = [self createLinkObject];
    KVORecorder r(self, obj, @"obj.obj.boolCol");
    [self.realm deleteObject:obj.obj];
    AssertChanged(r, 0U, @NO, NSNull.null);
}

- (void)testDeleteParentOfObservedRLMArray {
    KVOObject *obj = [self createObject];
    KVORecorder r1(self, obj, @"arrayCol");
    KVORecorder r2(self, obj, @"arrayCol.invalidated");
    [self.realm deleteObject:obj];
    AssertChanged(r2, 0U, @NO, @YES);
}

- (void)testDeleteAllObjects {
    KVOObject *obj = [self createObject];
    KVORecorder r1(self, obj, @"boolCol");
    KVORecorder r2(self, obj, @"invalidated");
    [self.realm deleteAllObjects];
    AssertChanged(r2, 0U, @NO, @YES);
    // should not crash
}

- (void)testClearTable {
    KVOObject *obj = [self createObject];
    KVORecorder r1(self, obj, @"boolCol");
    KVORecorder r2(self, obj, @"invalidated");
    [self.realm deleteObjects:[KVOObject allObjectsInRealm:self.realm]];
    AssertChanged(r2, 0U, @NO, @YES);
    // should not crash
}

- (void)testClearQuery {
    KVOObject *obj = [self createObject];
    KVORecorder r1(self, obj, @"boolCol");
    KVORecorder r2(self, obj, @"invalidated");
    [self.realm deleteObjects:[KVOObject objectsInRealm:self.realm where:@"TRUEPREDICATE"]];
    AssertChanged(r2, 0U, @NO, @YES);
    // should not crash
}


- (void)testClearLinkView {
    // TODO
}

- (void)testCreateObserverAfterDealloc {
    @autoreleasepool {
        KVOObject *obj = [self createObject];
        KVORecorder r(self, obj, @"boolCol");
        obj.boolCol = YES;
        AssertChanged(r, 0U, @NO, @YES);
    }
    @autoreleasepool {
        KVOObject *obj = [self createObject];
        KVORecorder r(self, obj, @"boolCol");
        obj.boolCol = YES;
        AssertChanged(r, 0U, @NO, @YES);
    }
}

- (void)testDirectlyDeleteLinkedToObject {
    KVOLinkObject2 *obj = [self createLinkObject];
    KVOLinkObject1 *linked = obj.obj;
    KVORecorder r(self, obj, @"obj");
    [self.realm deleteObject:linked];

    if (KVONotification *note = AssertNotification(r, 0U)) {
        XCTAssertTrue([note->change[NSKeyValueChangeOldKey] isKindOfClass:[RLMObjectBase class]]);
        XCTAssertEqualObjects(note->change[NSKeyValueChangeNewKey], NSNull.null);
    }
}

- (void)testDeleteLinkedToObjectViaTableClear {
    KVOLinkObject2 *obj = [self createLinkObject];
    KVORecorder r(self, obj, @"obj");
    [self.realm deleteObjects:[KVOLinkObject1 allObjectsInRealm:self.realm]];

    if (KVONotification *note = AssertNotification(r, 0U)) {
        XCTAssertTrue([note->change[NSKeyValueChangeOldKey] isKindOfClass:[RLMObjectBase class]]);
        XCTAssertEqualObjects(note->change[NSKeyValueChangeNewKey], NSNull.null);
    }
}

- (void)testDeleteLinkedToObjectViaQueryClear {
    KVOLinkObject2 *obj = [self createLinkObject];
    KVORecorder r(self, obj, @"obj");
    [self.realm deleteObjects:[KVOLinkObject1 objectsInRealm:self.realm where:@"TRUEPREDICATE"]];

    if (KVONotification *note = AssertNotification(r, 0U)) {
        XCTAssertTrue([note->change[NSKeyValueChangeOldKey] isKindOfClass:[RLMObjectBase class]]);
        XCTAssertEqualObjects(note->change[NSKeyValueChangeNewKey], NSNull.null);
    }
}

- (void)testDeleteObjectInArray {
    KVOLinkObject2 *obj = [self createLinkObject];
    KVOLinkObject1 *linked = obj.obj;
    [obj.array addObject:linked];
    KVORecorder r(self, obj, @"array");
    [self.realm deleteObject:linked];
    AssertIndexChange(NSKeyValueChangeRemoval, [NSIndexSet indexSetWithIndex:0]);
}

- (void)testDeleteObjectsInArrayViaTableClear {
    KVOLinkObject2 *obj = [self createLinkObject];
    KVOLinkObject2 *obj2 = [self createLinkObject];
    [obj.array addObject:obj.obj];
    [obj.array addObject:obj.obj];
    [obj.array addObject:obj2.obj];

    KVORecorder r(self, obj, @"array");
    [self.realm deleteObjects:[KVOLinkObject1 allObjectsInRealm:self.realm]];
    AssertIndexChange(NSKeyValueChangeRemoval, ([NSIndexSet indexSetWithIndexesInRange:{0, 3}]));
}

- (void)testDeleteObjectsInArrayViaQueryClear {
    KVOLinkObject2 *obj = [self createLinkObject];
    KVOLinkObject2 *obj2 = [self createLinkObject];
    [obj.array addObject:obj.obj];
    [obj.array addObject:obj.obj];
    [obj.array addObject:obj2.obj];

    KVORecorder r(self, obj, @"array");
    [self.realm deleteObjects:[KVOLinkObject1 objectsInRealm:self.realm where:@"TRUEPREDICATE"]];
    AssertIndexChange(NSKeyValueChangeRemoval, ([NSIndexSet indexSetWithIndexesInRange:{0, 3}]));
}

@end

// Observing an object backed by the same row as the persisted object being mutated
@interface KVOMultipleAccessorsTests : KVOPersistedObjectTests
@end
@implementation KVOMultipleAccessorsTests
- (id)observableForObject:(RLMObject *)obj {
    RLMObject *copy = [[obj.objectSchema.accessorClass alloc] initWithRealm:obj.realm schema:obj.objectSchema];
    copy->_row = obj->_row;
    return copy;
}

- (void)testIgnoredProperty {
    // ignored properties do not notify other accessors for the same row
}

- (void)testCancelWriteTransactionWhileObservingNewObject {
    KVOObject *obj = [self createObject];
    KVORecorder r(self, obj, @"invalidated");
    KVORecorder r2(self, obj, @"boolCol");
    [self.realm cancelWriteTransaction];
    AssertChanged(r, 0U, @NO, @YES);
    [self.realm beginWriteTransaction];
}

- (void)testCancelWriteTransactionWhileObservingChangedProperty {
    KVOObject *obj = [self createObject];
    [self.realm commitWriteTransaction];
    [self.realm beginWriteTransaction];

    obj.boolCol = YES;

    KVORecorder r(self, obj, @"boolCol");
    [self.realm cancelWriteTransaction];
    AssertChanged(r, 0U, @YES, @NO);

    [self.realm beginWriteTransaction];
}

- (void)testCancelWriteTransactionWhileObservingLinkToExistingObject {
    KVOObject *obj = [self createObject];
    KVOObject *obj2 = [self createObject];
    [self.realm commitWriteTransaction];
    [self.realm beginWriteTransaction];

    obj.objectCol = obj2;

    KVORecorder r(self, obj, @"objectCol");
    [self.realm cancelWriteTransaction];
    AssertChanged(r, 0U, obj2, NSNull.null);

    [self.realm beginWriteTransaction];
}

- (void)testCancelWriteTransactionWhileObservingLinkToNewObject {
    KVOObject *obj = [self createObject];
    [self.realm commitWriteTransaction];
    [self.realm beginWriteTransaction];

    obj.objectCol = [self createObject];

    KVORecorder r(self, obj, @"objectCol");
    [self.realm cancelWriteTransaction];
    if (KVONotification *note = AssertNotification(r, 0U)) {
        XCTAssertTrue([note->change[NSKeyValueChangeOldKey] isKindOfClass:[RLMObjectBase class]]);
        XCTAssertEqualObjects(note->change[NSKeyValueChangeNewKey], NSNull.null);
    }

    [self.realm beginWriteTransaction];
}

- (void)testCancelWriteTransactionWhileObservingNewObjectLinkingToNewObject {
    KVOObject *obj = [self createObject];
    obj.objectCol = [self createObject];
    KVORecorder r(self, obj, @"invalidated");
    KVORecorder r2(self, obj, @"objectCol");
    KVORecorder r3(self, obj, @"objectCol.boolCol");
    [self.realm cancelWriteTransaction];
    AssertChanged(r, 0U, @NO, @YES);
    if (KVONotification *note = AssertNotification(r2, 0U)) {
        XCTAssertTrue([note->change[NSKeyValueChangeOldKey] isKindOfClass:[RLMObjectBase class]]);
        XCTAssertEqualObjects(note->change[NSKeyValueChangeNewKey], NSNull.null);
    }
    AssertChanged(r3, 0U, @NO, NSNull.null);
    // FIXME: too many invalidateds being sent
    [self.realm beginWriteTransaction];
}

- (void)testCancelWriteWithArrayChanges {
    KVOObject *obj = [self createObject];
    [obj.arrayCol addObject:obj];
    [self.realm commitWriteTransaction];
    [self.realm beginWriteTransaction];

    {
        [obj.arrayCol addObject:obj];
        KVORecorder r(self, obj, @"arrayCol");
        [self.realm cancelWriteTransaction];
        [self.realm beginWriteTransaction];
        AssertIndexChange(NSKeyValueChangeRemoval, [NSIndexSet indexSetWithIndex:1]);
    }
    {
        [obj.arrayCol removeLastObject];
        KVORecorder r(self, obj, @"arrayCol");
        [self.realm cancelWriteTransaction];
        [self.realm beginWriteTransaction];
        AssertIndexChange(NSKeyValueChangeInsertion, [NSIndexSet indexSetWithIndex:0]);
    }
    {
        obj.arrayCol[0] = obj;
        KVORecorder r(self, obj, @"arrayCol");
        [self.realm cancelWriteTransaction];
        [self.realm beginWriteTransaction];
        AssertIndexChange(NSKeyValueChangeReplacement, [NSIndexSet indexSetWithIndex:0]);
    }

    // test batching with multiple items changed
    [obj.arrayCol addObject:obj];
    [self.realm commitWriteTransaction];
    [self.realm beginWriteTransaction];
    {
        [obj.arrayCol removeAllObjects];
        KVORecorder r(self, obj, @"arrayCol");
        [self.realm cancelWriteTransaction];
        [self.realm beginWriteTransaction];
        AssertIndexChange(NSKeyValueChangeInsertion, ([NSIndexSet indexSetWithIndexesInRange:{0, 2}]));
    }
    {
        [obj.arrayCol removeLastObject];
        [obj.arrayCol removeLastObject];
        KVORecorder r(self, obj, @"arrayCol");
        [self.realm cancelWriteTransaction];
        [self.realm beginWriteTransaction];
        AssertIndexChange(NSKeyValueChangeInsertion, ([NSIndexSet indexSetWithIndexesInRange:{0, 2}]));
    }
    {
        [obj.arrayCol insertObject:obj atIndex:1];
        [obj.arrayCol insertObject:obj atIndex:0];
        KVORecorder r(self, obj, @"arrayCol");
        [self.realm cancelWriteTransaction];
        [self.realm beginWriteTransaction];
        NSMutableIndexSet *expected = [NSMutableIndexSet new];
        [expected addIndex:0];
        [expected addIndex:2]; // shifted due to inserting at 0 after 1
        AssertIndexChange(NSKeyValueChangeRemoval, expected);
    }
}

- (void)testCancelWriteWithLinkedObjectedRemoved {
    KVOLinkObject2 *obj = [self createLinkObject];
    [obj.array addObject:obj.obj];
    [self.realm commitWriteTransaction];
    [self.realm beginWriteTransaction];

    {
        [self.realm deleteObject:obj.obj];

        KVORecorder r(self, obj, @"array");
        KVORecorder r2(self, obj, @"obj");
        [self.realm cancelWriteTransaction];
        [self.realm beginWriteTransaction];
        AssertIndexChange(NSKeyValueChangeInsertion, [NSIndexSet indexSetWithIndex:0]);
        AssertChanged(r2, 0U, NSNull.null, [KVOLinkObject1 allObjectsInRealm:self.realm].firstObject);
    }
    {
        [self.realm deleteObjects:[KVOLinkObject1 allObjectsInRealm:self.realm]];

        KVORecorder r(self, obj, @"array");
        KVORecorder r2(self, obj, @"obj");
        [self.realm cancelWriteTransaction];
        [self.realm beginWriteTransaction];
        AssertIndexChange(NSKeyValueChangeInsertion, [NSIndexSet indexSetWithIndex:0]);
        AssertChanged(r2, 0U, NSNull.null, [KVOLinkObject1 allObjectsInRealm:self.realm].firstObject);
    }
    {
        [self.realm deleteObjects:obj.array];

        KVORecorder r(self, obj, @"array");
        KVORecorder r2(self, obj, @"obj");
        [self.realm cancelWriteTransaction];
        [self.realm beginWriteTransaction];
        AssertIndexChange(NSKeyValueChangeInsertion, [NSIndexSet indexSetWithIndex:0]);
        AssertChanged(r2, 0U, NSNull.null, [KVOLinkObject1 allObjectsInRealm:self.realm].firstObject);
    }
}

// linkview and table selection ordering
@end

// Observing an object from a different RLMRealm instance backed by the same
// row as the persisted object being mutated
@interface KVOMultipleRealmsTests : KVOPersistedObjectTests
@property RLMRealm *secondaryRealm;
@end

@implementation KVOMultipleRealmsTests
- (void)setUp {
    [super setUp];
    // use private constructor to bypass cache and get a second instance on the
    // same thread
    self.secondaryRealm = [[RLMRealm alloc] initWithPath:self.realm.path
                                                     key:nil readOnly:NO
                                                inMemory:NO dynamic:NO error:nil];
    RLMRealmSetSchema(self.secondaryRealm, [self.realm.schema shallowCopy], false);
}

- (void)tearDown {
    self.secondaryRealm = nil;
    [super tearDown];
}

- (id)observableForObject:(RLMObject *)obj {
    [self.realm commitWriteTransaction];
    [self.realm beginWriteTransaction];
    [self.secondaryRealm refresh];

    RLMObject *copy = [[obj.objectSchema.accessorClass alloc] initWithRealm:self.secondaryRealm
                                                                     schema:self.secondaryRealm.schema[obj.objectSchema.className]];
    copy->_row = (*copy.objectSchema.table)[obj->_row.get_index()];
    return copy;
}

- (bool)collapsesNotifications {
    return true;
}

- (void)testIgnoredProperty {
    // ignored properties do not notify other accessors for the same row
}
@end

