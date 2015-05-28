////////////////////////////////////////////////////////////////////////////
//
// Copyright 2014 Realm Inc.
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

#import "RLMObject_Private.hpp"

#import "RLMAccessor.h"
#import "RLMArray.h"
#import "RLMObjectSchema_Private.hpp"
#import "RLMObjectStore.h"
#import "RLMProperty_Private.h"
#import "RLMRealm_Private.hpp"
#import "RLMSchema_Private.h"
#import "RLMSwiftSupport.h"
#import "RLMUtil.hpp"

@interface RLMObjectBase () {
    @public
    RLMObservable *_observable;
}
@end

@implementation RLMObservable {
    RLMRealm *_realm;
    RLMObjectSchema *_objectSchema;
}
- (instancetype)initWithRow:(realm::Row const&)row realm:(RLMRealm *)realm schema:(RLMObjectSchema *)objectSchema {
    self = [super init];
    if (self) {
        NSAssert(row, @"row should be attached");
        NSAssert(row.get_table(), @"row should be attached");
        _row = row;
        _realm = realm;
        _objectSchema = objectSchema;
    }
    return self;
}

- (id)valueForKey:(NSString *)key {
    if ([key isEqualToString:@"invalidated"]) {
        return @(!_row.is_attached());
    }
    else if (!_row.is_attached() || _returnNil) {
        return nil;
    }

    id value = RLMDynamicGet(_realm, _row, _objectSchema[key]);
    // get the observable preemptively for the case of the middle of an observed
    // keypath being deleted, as we won't be able to get it after the change
    // is made (there may be multiple detached Rows and we don't know which one
    // to pick).
    // FIXME: probably also for RLMArrayLinkView
    if (auto obj = RLMDynamicCast<RLMObjectBase>(value)) {
        for (__unsafe_unretained RLMObservable *o : obj->_objectSchema->_observers) {
            if (o->_row && o->_row.get_index() == obj->_row.get_index()) {
                obj->_observable = o;
                break;
            }
        }
    }
    return value;
}

- (void)dealloc {
    auto &observers = _objectSchema->_observers;
    for (auto it = observers.begin(), end = observers.end(); it != end; ++it) {
        if (*it == self) {
            iter_swap(it, prev(end));
            observers.pop_back();
            return;
        }
    }
}
@end

const NSUInteger RLMDescriptionMaxDepth = 5;

@implementation RLMObjectBase
// standalone init
- (instancetype)init {
    if (RLMSchema.sharedSchema) {
        __unsafe_unretained RLMObjectSchema *const objectSchema = [self.class sharedSchema];
        self = [self initWithRealm:nil schema:objectSchema];

        // set default values
        if (!objectSchema.isSwiftClass) {
            NSDictionary *dict = RLMDefaultValuesForObjectSchema(objectSchema);
            for (NSString *key in dict) {
                [self setValue:dict[key] forKey:key];
            }
        }

        // set standalone accessor class
        object_setClass(self, objectSchema.standaloneClass);
    }
    else {
        // if schema not initialized
        // this is only used for introspection
        self = [super init];
    }

    return self;
}

- (instancetype)initWithValue:(id)value schema:(RLMSchema *)schema {
    self = [self init];
    if (NSArray *array = RLMDynamicCast<NSArray>(value)) {
        // validate and populate
        array = RLMValidatedArrayForObjectSchema(array, _objectSchema, schema);
        NSArray *properties = _objectSchema.properties;
        for (NSUInteger i = 0; i < array.count; i++) {
            [self setValue:array[i] forKeyPath:[properties[i] name]];
        }
    }
    else {
        // assume our object is an NSDictionary or a an object with kvc properties
        NSDictionary *dict = RLMValidatedDictionaryForObjectSchema(value, _objectSchema, schema);
        for (NSString *name in dict) {
            id val = dict[name];
            // strip out NSNull before passing values to standalone setters
            if (val == NSNull.null) {
                val = nil;
            }
            [self setValue:val forKeyPath:name];
        }
    }

    return self;
}

- (instancetype)initWithRealm:(__unsafe_unretained RLMRealm *const)realm
                       schema:(__unsafe_unretained RLMObjectSchema *const)schema {
    self = [super init];
    if (self) {
        _realm = realm;
        _objectSchema = schema;
    }
    return self;
}

// overridden at runtime per-class for performance
+ (NSString *)className {
    NSString *className = NSStringFromClass(self);
    if ([RLMSwiftSupport isSwiftClassName:className]) {
        className = [RLMSwiftSupport demangleClassName:className];
    }
    return className;
}

// overridden at runtime per-class for performance
+ (RLMObjectSchema *)sharedSchema {
    return RLMSchema.sharedSchema[self.className];
}

- (NSString *)description
{
    if (self.isInvalidated) {
        return @"[invalid object]";
    }

    return [self descriptionWithMaxDepth:RLMDescriptionMaxDepth];
}

- (NSString *)descriptionWithMaxDepth:(NSUInteger)depth {
    if (depth == 0) {
        return @"<Maximum depth exceeded>";
    }

    NSString *baseClassName = _objectSchema.className;
    NSMutableString *mString = [NSMutableString stringWithFormat:@"%@ {\n", baseClassName];

    for (RLMProperty *property in _objectSchema.properties) {
        id object = RLMObjectBaseObjectForKeyedSubscript(self, property.name);
        NSString *sub;
        if ([object respondsToSelector:@selector(descriptionWithMaxDepth:)]) {
            sub = [object descriptionWithMaxDepth:depth - 1];
        }
        else if (property.type == RLMPropertyTypeData) {
            static NSUInteger maxPrintedDataLength = 24;
            NSData *data = object;
            NSUInteger length = data.length;
            if (length > maxPrintedDataLength) {
                data = [NSData dataWithBytes:data.bytes length:maxPrintedDataLength];
            }
            NSString *dataDescription = [data description];
            sub = [NSString stringWithFormat:@"<%@ — %lu total bytes>", [dataDescription substringWithRange:NSMakeRange(1, dataDescription.length - 2)], (unsigned long)length];
        }
        else {
            sub = [object description];
        }
        [mString appendFormat:@"\t%@ = %@;\n", property.name, [sub stringByReplacingOccurrencesOfString:@"\n" withString:@"\n\t"]];
    }
    [mString appendString:@"}"];

    return [NSString stringWithString:mString];
}

- (BOOL)isInvalidated {
    // if not standalone and our accessor has been detached, we have been deleted
    return self.class == _objectSchema.accessorClass && !_row.is_attached();
}

- (BOOL)isDeletedFromRealm {
    return self.isInvalidated;
}

- (BOOL)isEqual:(id)object {
    if (RLMObjectBase *other = RLMDynamicCast<RLMObjectBase>(object)) {
        if (_objectSchema.primaryKeyProperty) {
            return RLMObjectBaseAreEqual(self, other);
        }
    }
    return [super isEqual:object];
}

- (NSUInteger)hash {
    if (_objectSchema.primaryKeyProperty) {
        id primaryProperty = [self valueForKey:_objectSchema.primaryKeyProperty.name];

        // modify the hash of our primary key value to avoid potential (although unlikely) collisions
        return [primaryProperty hash] ^ 1;
    }
    else {
        return [super hash];
    }
}

+ (BOOL)shouldPersistToRealm {
    return RLMIsObjectSubclass(self);
}

- (id)mutableArrayValueForKey:(NSString *)key {
    id obj = [self valueForKey:key];
    if ([obj isKindOfClass:[RLMArray class]]) {
        return obj;
    }
    return [super mutableArrayValueForKey:key];
}

static NSString *propertyKeyPath(NSString *keyPath, RLMObjectSchema *objectSchema) {
    if ([keyPath isEqualToString:@"invalidated"])
        return keyPath;

    NSUInteger sep = [keyPath rangeOfString:@"."].location;
    NSString *key = sep == NSNotFound ? keyPath : [keyPath substringToIndex:sep];
    RLMProperty *prop = objectSchema[key];
    return prop ? keyPath : nil;
}

static RLMObservable *getObservable(RLMObjectBase *obj) {
    if (obj->_observable) {
        return obj->_observable;
    }

    for (__unsafe_unretained RLMObservable *o : obj->_objectSchema->_observers) {
        if (o->_row && o->_row.get_index() == obj->_row.get_index()) {
            obj->_observable = o;
            return o;
        }
    }

    RLMObservable *observable = [[RLMObservable alloc] initWithRow:obj->_row realm:obj->_realm schema:obj->_objectSchema];
    obj->_objectSchema->_observers.push_back(observable);
    obj->_observable = observable;
    return observable;
}

- (void)addObserver:(id)observer
         forKeyPath:(NSString *)keyPath
            options:(NSKeyValueObservingOptions)options
            context:(void *)context {
    NSString *key = propertyKeyPath(keyPath, _objectSchema);
    if (!key) {
        [super addObserver:observer forKeyPath:keyPath options:options context:context];
        return;
    }

    RLMObservable *observable = getObservable(self);
    [observable addObserver:observer forKeyPath:key options:options context:context];
    // "Using a __bridge_retained or __bridge_transfer cast purely to convince ARC to emit an unbalanced retain or release, respectively, is poor form."
    (void)(__bridge_retained CFDataRef)observable;
}

- (void)removeObserver:(NSObject *)observer forKeyPath:(NSString *)keyPath {
    NSString *key = propertyKeyPath(keyPath, _objectSchema);
    if (key) {
        RLMObservable *observable = getObservable(self);
        [observable removeObserver:observer forKeyPath:key];
        (void)(__bridge_transfer id)(__bridge void *)observable;
    }
    else {
        [super removeObserver:observer forKeyPath:keyPath];
    }
}

- (void)removeObserver:(NSObject *)observer forKeyPath:(NSString *)keyPath context:(void *)context {
    NSString *key = propertyKeyPath(keyPath, _objectSchema);
    if (key) {
        RLMObservable *observable = getObservable(self);
        [observable removeObserver:observer forKeyPath:key context:context];
        (void)(__bridge_transfer id)(__bridge void *)observable;
    }
    else {
        [super removeObserver:observer forKeyPath:keyPath context:context];
    }
}

@end

void RLMWillChange(RLMObjectBase *obj, NSString *key) {
    [getObservable(obj) willChangeValueForKey:key];
}

void RLMDidChange(RLMObjectBase *obj, NSString *key) {
    [getObservable(obj) didChangeValueForKey:key];
}

@implementation RLMObservationInfo
@end

void RLMObjectBaseSetRealm(__unsafe_unretained RLMObjectBase *object, __unsafe_unretained RLMRealm *realm) {
    if (object) {
        object->_realm = realm;
    }
}

RLMRealm *RLMObjectBaseRealm(__unsafe_unretained RLMObjectBase *object) {
    return object ? object->_realm : nil;
}

void RLMObjectBaseSetObjectSchema(__unsafe_unretained RLMObjectBase *object, __unsafe_unretained RLMObjectSchema *objectSchema) {
    if (object) {
        object->_objectSchema = objectSchema;
    }
}

RLMObjectSchema *RLMObjectBaseObjectSchema(__unsafe_unretained RLMObjectBase *object) {
    return object ? object->_objectSchema : nil;
}

NSArray *RLMObjectBaseLinkingObjectsOfClass(RLMObjectBase *object, NSString *className, NSString *property) {
    if (!object) {
        return nil;
    }

    if (!object->_realm) {
        @throw RLMException(@"Linking object only available for objects in a Realm.");
    }
    RLMCheckThread(object->_realm);

    if (!object->_row.is_attached()) {
        @throw RLMException(@"Object has been deleted or invalidated and is no longer valid.");
    }

    RLMObjectSchema *schema = object->_realm.schema[className];
    RLMProperty *prop = schema[property];
    if (!prop) {
        @throw RLMException([NSString stringWithFormat:@"Invalid property '%@'", property]);
    }

    if (![prop.objectClassName isEqualToString:object->_objectSchema.className]) {
        @throw RLMException([NSString stringWithFormat:@"Property '%@' of '%@' expected to be an RLMObject or RLMArray property pointing to type '%@'", property, className, object->_objectSchema.className]);
    }

    Table *table = schema.table;
    if (!table) {
        return @[];
    }

    size_t col = prop.column;
    NSUInteger count = object->_row.get_backlink_count(*table, col);
    NSMutableArray *links = [NSMutableArray arrayWithCapacity:count];
    for (NSUInteger i = 0; i < count; i++) {
        [links addObject:RLMCreateObjectAccessor(object->_realm, schema, object->_row.get_backlink(*table, col, i))];
    }
    return [links copy];
}

id RLMObjectBaseObjectForKeyedSubscript(RLMObjectBase *object, NSString *key) {
    if (!object) {
        return nil;
    }

    if (object->_realm) {
        return RLMDynamicGet(object, key);
    }
    else {
        return [object valueForKey:key];
    }
}

void RLMObjectBaseSetObjectForKeyedSubscript(RLMObjectBase *object, NSString *key, id obj) {
    if (!object) {
        return;
    }

    if (object->_realm) {
        RLMDynamicValidatedSet(object, key, obj);
    }
    else {
        [object setValue:obj forKey:key];
    }
}


BOOL RLMObjectBaseAreEqual(RLMObjectBase *o1, RLMObjectBase *o2) {
    // if not the correct types throw
    if ((o1 && ![o1 isKindOfClass:RLMObjectBase.class]) || (o2 && ![o2 isKindOfClass:RLMObjectBase.class])) {
        @throw RLMException(@"Can only compare objects of class RLMObjectBase");
    }
    // if identical object (or both are nil)
    if (o1 == o2) {
        return YES;
    }
    // if one is nil
    if (o1 == nil || o2 == nil) {
        return NO;
    }
    // if not in realm or differing realms
    if (o1->_realm == nil || o1->_realm != o2->_realm) {
        return NO;
    }
    // if either are detached
    if (!o1->_row.is_attached() || !o2->_row.is_attached()) {
        return NO;
    }
    // if table and index are the same
    return o1->_row.get_table() == o2->_row.get_table()
        && o1->_row.get_index() == o2->_row.get_index();
}


Class RLMObjectUtilClass(BOOL isSwift) {
    static Class objectUtilObjc = [RLMObjectUtil class];
    static Class objectUtilSwift = NSClassFromString(@"RealmSwift.ObjectUtil");
    return isSwift && objectUtilSwift ? objectUtilSwift : objectUtilObjc;
}

@implementation RLMObjectUtil

+ (NSString *)primaryKeyForClass:(Class)cls {
    return [cls primaryKey];
}

+ (NSArray *)ignoredPropertiesForClass:(Class)cls {
    return [cls ignoredProperties];
}

+ (NSArray *)indexedPropertiesForClass:(Class)cls {
    return [cls indexedProperties];
}

+ (NSArray *)getGenericListPropertyNames:(__unused id)obj {
    return nil;
}

+ (void)initializeListProperty:(__unused RLMObjectBase *)object property:(__unused RLMProperty *)property array:(__unused RLMArray *)array {
}

@end

void RLMOverrideStandaloneMethods(Class cls) {
    struct methodInfo {
        SEL sel;
        IMP imp;
        const char *type;
    };

    auto make = [](SEL sel, auto&& func) {
        Method m = class_getInstanceMethod(NSObject.class, sel);
        IMP superImp = method_getImplementation(m);
        const char *type = method_getTypeEncoding(m);
        IMP imp = imp_implementationWithBlock(func(sel, superImp));
        return methodInfo{sel, imp, type};
    };

    static const methodInfo methods[] = {
        make(@selector(addObserver:forKeyPath:options:context:), [](SEL sel, IMP superImp) {
            auto superFn = (void (*)(id, SEL, id, NSString *, NSKeyValueObservingOptions, void *))superImp;
            return ^(RLMObjectBase *self, id observer, NSString *keyPath, NSKeyValueObservingOptions options, void *context) {
                if (!self->_standaloneObservers)
                    self->_standaloneObservers = [NSMutableArray new];

                RLMObservationInfo *info = [RLMObservationInfo new];
                info.observer = observer;
                info.options = options;
                info.context = context;
                info.key = keyPath;
                [self->_standaloneObservers addObject:info];
                superFn(self, sel, observer, keyPath, options, context);
            };
        }),

        make(@selector(removeObserver:forKeyPath:), [](SEL sel, IMP superImp) {
            auto superFn = (void (*)(id, SEL, id, NSString *))superImp;
            return ^(RLMObjectBase *self, id observer, NSString *keyPath) {
                for (RLMObservationInfo *info in self->_standaloneObservers) {
                    if (info.observer == observer && [info.key isEqualToString:keyPath]) {
                        [self->_standaloneObservers removeObject:info];
                        break;
                    }
                }
                superFn(self, sel, observer, keyPath);
            };
        }),

        make(@selector(removeObserver:forKeyPath:context:), [](SEL sel, IMP superImp) {
            auto superFn = (void (*)(id, SEL, id, NSString *, void *))superImp;
            return ^(RLMObjectBase *self, id observer, NSString *keyPath, void *context) {
                for (RLMObservationInfo *info in self->_standaloneObservers) {
                    if (info.observer == observer && info.context == context && [info.key isEqualToString:keyPath]) {
                        [self->_standaloneObservers removeObject:info];
                        break;
                    }
                }
                superFn(self, sel, observer, keyPath, context);
            };
        })
    };

    for (auto const& m : methods)
        class_addMethod(cls, m.sel, m.imp, m.type);
}

void RLMTrackDeletions(__unsafe_unretained RLMRealm *const realm, dispatch_block_t block) {
    struct change {
        __unsafe_unretained RLMObservable *observable;
        __unsafe_unretained NSString *property;
    };
    std::vector<change> changes;
    struct arrayChange {
        __unsafe_unretained RLMObservable *observable;
        __unsafe_unretained NSString *property;
        NSMutableIndexSet *indexes;
    };
    std::vector<arrayChange> arrayChanges;

    realm.group->notify_thing = [&](realm::ColumnBase::CascadeState const& cs) {
        for (auto const& row : cs.rows) {
            for (RLMObjectSchema *objectSchema in realm.schema.objectSchema) {
                if (objectSchema.table->get_index_in_group() != row.table_ndx)
                    continue;
                for (auto observer : objectSchema->_observers) {
                    if (observer->_row && observer->_row.get_index() == row.row_ndx) {
                        changes.push_back({observer, @"invalidated"});
                        break;
                    }
                }
                break;
            }
        }
        for (auto const& link : cs.links) {
            for (RLMObjectSchema *objectSchema in realm.schema.objectSchema) {
                if (objectSchema.table->get_index_in_group() != link.origin_table->get_index_in_group())
                    continue;
                for (auto observer : objectSchema->_observers) {
                    if (observer->_row.get_index() != link.origin_row_ndx)
                        continue;
                    RLMProperty *prop = objectSchema.properties[link.origin_col_ndx];
                    NSString *name = prop.name;
                    if (prop.type != RLMPropertyTypeArray)
                        changes.push_back({observer, name});
                    else {
                        auto linkview = observer->_row.get_linklist(prop.column);
                        arrayChange *c = nullptr;
                        for (auto& ac : arrayChanges) {
                            if (ac.observable == observer && ac.property == name) {
                                c = &ac;
                                break;
                            }
                        }
                        if (!c) {
                            arrayChanges.push_back({observer, name, [NSMutableIndexSet new]});
                            c = &arrayChanges.back();
                        }

                        size_t start = 0, index;
                        while ((index = linkview->find(link.old_target_row_ndx, start)) != realm::not_found) {
                            [c->indexes addIndex:index];
                            start = index + 1;
                        }
                    }
                    break;
               }
                break;
            }
        }

        for (auto const& change : changes)
            [change.observable willChangeValueForKey:change.property];
        for (auto const& change : arrayChanges)
            [change.observable willChange:NSKeyValueChangeRemoval valuesAtIndexes:change.indexes forKey:change.property];
    };

    block();

    for (auto const& change : changes)
        [change.observable didChangeValueForKey:change.property];
    for (auto const& change : arrayChanges)
        [change.observable didChange:NSKeyValueChangeRemoval valuesAtIndexes:change.indexes forKey:change.property];

    realm.group->notify_thing = nullptr;
}
