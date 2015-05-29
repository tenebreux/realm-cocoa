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

#import "RLMObjectStore.h"

#import "RLMAccessor.h"
#import "RLMArray_Private.hpp"
#import "RLMListBase.h"
#import "RLMObject_Private.hpp"
#import "RLMObjectSchema_Private.hpp"
#import "RLMProperty_Private.h"
#import "RLMQueryUtil.hpp"
#import "RLMRealm_Private.hpp"
#import "RLMSchema_Private.h"
#import "RLMSwiftSupport.h"
#import "RLMUtil.hpp"

#import <objc/message.h>

static void RLMVerifyAndAlignColumns(RLMObjectSchema *tableSchema, RLMObjectSchema *objectSchema) {
    NSMutableArray *properties = [NSMutableArray arrayWithCapacity:objectSchema.properties.count];
    NSMutableArray *exceptionMessages = [NSMutableArray array];

    // check to see if properties are the same
    for (RLMProperty *tableProp in tableSchema.properties) {
        RLMProperty *schemaProp = objectSchema[tableProp.name];
        if (!schemaProp) {
            [exceptionMessages addObject:[NSString stringWithFormat:@"Property '%@' is missing from latest object model.", tableProp.name]];
            continue;
        }
        if (tableProp.type != schemaProp.type) {
            [exceptionMessages addObject:[NSString stringWithFormat:@"Property types for '%@' property do not match. Old type '%@', new type '%@'.",
                                          tableProp.name, RLMTypeToString(tableProp.type), RLMTypeToString(schemaProp.type)]];
            continue;
        }
        if (tableProp.type == RLMPropertyTypeObject || tableProp.type == RLMPropertyTypeArray) {
            if (![tableProp.objectClassName isEqualToString:schemaProp.objectClassName]) {
                [exceptionMessages addObject:[NSString stringWithFormat:@"Target object type for property '%@' does not match. Old type '%@', new type '%@'.",
                                              tableProp.name, tableProp.objectClassName, schemaProp.objectClassName]];
            }
        }
        if (tableProp.isPrimary != schemaProp.isPrimary) {
            if (tableProp.isPrimary) {
                [exceptionMessages addObject:[NSString stringWithFormat:@"Property '%@' is no longer a primary key.", tableProp.name]];
            }
            else {
                [exceptionMessages addObject:[NSString stringWithFormat:@"Property '%@' has been made a primary key.", tableProp.name]];
            }
        }
        if (tableProp.optional != schemaProp.optional) {
            if (tableProp.optional) {
                [exceptionMessages addObject:[NSString stringWithFormat:@"Property '%@' is no longer optional.", tableProp.name]];
            }
            else {
                [exceptionMessages addObject:[NSString stringWithFormat:@"Property '%@' has been made optional.", tableProp.name]];
            }
        }

        // create new property with aligned column
        schemaProp.column = tableProp.column;
        [properties addObject:schemaProp];
    }

    // check for new missing properties
    for (RLMProperty *schemaProp in objectSchema.properties) {
        if (!tableSchema[schemaProp.name]) {
            [exceptionMessages addObject:[NSString stringWithFormat:@"Property '%@' has been added to latest object model.", schemaProp.name]];
        }
    }

    // throw if errors
    if (exceptionMessages.count) {
        @throw RLMException([NSString stringWithFormat:@"Migration is required for object type '%@' due to the following errors:\n- %@",
                             objectSchema.className, [exceptionMessages componentsJoinedByString:@"\n- "]]);
    }

    // set new properties array with correct column alignment
    objectSchema.properties = properties;
}

// ensure all search indexes for all tables are up-to-date
// does not need to be called from a write transaction
static void RLMRealmUpdateIndexes(RLMRealm *realm) {
    bool commitWriteTransaction = false;
    for (RLMObjectSchema *objectSchema in realm.schema.objectSchema) {
        realm::Table *table = objectSchema.table;
        for (RLMProperty *prop in objectSchema.properties) {
            if (prop.indexed == table->has_search_index(prop.column)) {
                continue;
            }

            if (!realm.inWriteTransaction) {
                [realm beginWriteTransaction];
                commitWriteTransaction = true;
            }
            if (prop.indexed) {
                try {
                    table->add_search_index(prop.column);
                }
                catch (realm::LogicError const&) {
                    if (commitWriteTransaction) {
                        [realm cancelWriteTransaction];
                    }

                    NSString *err = [NSString stringWithFormat:@"Cannot index property '%@.%@': indexing properties of type '%@' is currently not supported",
                                     objectSchema.className, prop.name, RLMTypeToString(prop.type)];
                    @throw RLMException(err);
                }
            }
            else {
                table->remove_search_index(prop.column);
            }
        }
    }

    if (commitWriteTransaction) {
        [realm commitWriteTransaction];
    }
}

// create a column for a property in a table
// NOTE: must be called from within write transaction
static void RLMCreateColumn(RLMRealm *realm, realm::Table &table, RLMProperty *prop) {
    switch (prop.type) {
            // for objects and arrays, we have to specify target table
        case RLMPropertyTypeObject:
        case RLMPropertyTypeArray: {
            realm::TableRef linkTable = RLMTableForObjectClass(realm, prop.objectClassName);
            prop.column = table.add_column_link(realm::DataType(prop.type), prop.name.UTF8String, *linkTable);
            break;
        }
        default:
            prop.column = table.add_column(realm::DataType(prop.type), prop.name.UTF8String, prop.optional);
            break;
    }
}

// Schema used to created generated accessors
static NSMutableArray * const s_accessorSchema = [NSMutableArray new];

void RLMRealmCreateAccessors(RLMSchema *schema) {
    // create accessors for non-dynamic realms
    RLMSchema *matchingSchema = nil;
    for (RLMSchema *accessorSchema in s_accessorSchema) {
        if ([schema isEqualToSchema:accessorSchema]) {
            matchingSchema = accessorSchema;
            break;
        }
    }

    if (matchingSchema) {
        // reuse accessors
        for (RLMObjectSchema *objectSchema in schema.objectSchema) {
            objectSchema.accessorClass = matchingSchema[objectSchema.className].accessorClass;
        }
    }
    else {
        // create accessors and cache in s_accessorSchema
        for (RLMObjectSchema *objectSchema in schema.objectSchema) {
            if (objectSchema.table) {
                NSString *prefix = [NSString stringWithFormat:@"RLMAccessor_v%lu_",
                                    (unsigned long)s_accessorSchema.count];
                objectSchema.accessorClass = RLMAccessorClassForObjectClass(objectSchema.objectClass, objectSchema, prefix);
            }
        }
        [s_accessorSchema addObject:schema];
    }
}

void RLMClearAccessorCache() {
    [s_accessorSchema removeAllObjects];
}

void RLMRealmSetSchema(RLMRealm *realm, RLMSchema *targetSchema, bool verify) {
    realm.schema = targetSchema;

    for (RLMObjectSchema *objectSchema in realm.schema.objectSchema) {
        objectSchema.realm = realm;

        // read-only realms may be missing tables entirely
        if (verify && objectSchema.table) {
            RLMObjectSchema *tableSchema = [RLMObjectSchema schemaFromTableForClassName:objectSchema.className realm:realm];
            RLMVerifyAndAlignColumns(tableSchema, objectSchema);
        }
    }
}

// try to set table references on targetSchema and return true if all tables exist
static bool RLMRealmGetTables(RLMRealm *realm, RLMSchema *targetSchema) {
    if (!RLMRealmHasMetadataTables(realm)) {
        return false;
    }

    for (RLMObjectSchema *objectSchema in targetSchema.objectSchema) {
        NSString *tableName = RLMTableNameForClass(objectSchema.className);
        TableRef table = realm.group->get_table(tableName.UTF8String);
        if (!table) {
            return false;
        }
        objectSchema.table = table.get();
    }

    return true;
}

static bool RLMPropertyHasChanged(RLMProperty *p1, RLMProperty *p2) {
    return p2 == nil
        || p1.type != p2.type
        || p1.optional != p2.optional
        || ![p1.name isEqualToString:p2.name]
        || (p1.objectClassName != p2.objectClassName && ![p1.objectClassName isEqualToString:p2.objectClassName]);
}

static bool RLMPropertyCanBeMigrated(RLMProperty *oldProperty, RLMProperty *newProperty) {
    if (!oldProperty || !newProperty) {
        return false;
    }
    if (oldProperty.type == newProperty.type && !oldProperty.optional && newProperty.optional && [oldProperty.name isEqualToString:newProperty.name]) {
        return true;
    }
    return false;
}


static void RLMCopyPropertyToProperty(RLMProperty *oldProperty, RLMProperty *newProperty, Table *table) {
    size_t oldColumn = oldProperty.column;
    size_t newColumn = newProperty.column;
    if (oldProperty.type == newProperty.type && newProperty.type == RLMPropertyTypeString) {
        size_t count = table->size();
        for (size_t i = 0; i < count; i++) {
            table->set_string(newColumn, i, table->get_string(oldColumn, i));
        }
    }
    else {
        @throw RLMException([NSString stringWithFormat:@"Unable to automatically copy a property of type '%@' to type '%@'", RLMTypeToString(oldProperty.type), RLMTypeToString(newProperty.type)]);
    }
}

// set references to tables on targetSchema and create/update any missing or out-of-date tables
// if update existing is true, updates existing tables, otherwise validates existing tables
// NOTE: must be called from within write transaction
static bool RLMRealmCreateTables(RLMRealm *realm, RLMSchema *targetSchema, bool updateExisting) {
    // create metadata tables if neded
    bool changed = RLMRealmCreateMetadataTables(realm);

    // first pass to create missing tables
    NSMutableArray *objectSchemaToUpdate = [NSMutableArray array];
    for (RLMObjectSchema *objectSchema in targetSchema.objectSchema) {
        bool created = false;
        objectSchema.table = RLMTableForObjectClass(realm, objectSchema.className, created).get();

        // we will modify tables for any new objectSchema (table was created) or for all if updateExisting is true
        if (updateExisting || created) {
            [objectSchemaToUpdate addObject:objectSchema];
            changed = true;
        }
    }

    // second pass adds/removes columns for objectSchemaToUpdate
    for (RLMObjectSchema *objectSchema in objectSchemaToUpdate) {
        RLMObjectSchema *tableSchema = [RLMObjectSchema schemaFromTableForClassName:objectSchema.className realm:realm];

        // add missing columns
        for (RLMProperty *prop in objectSchema.properties) {
            RLMProperty *tableProp = tableSchema[prop.name];

            // add any new properties (new name or different type)
            if (RLMPropertyHasChanged(prop, tableProp)) {
                RLMCreateColumn(realm, *objectSchema.table, prop);
                if (RLMPropertyCanBeMigrated(tableProp, prop)) {
                    RLMCopyPropertyToProperty(tableProp, prop, objectSchema.table);
                }
                changed = true;
            }
        }

        // remove extra columns
        for (int i = (int)tableSchema.properties.count - 1; i >= 0; i--) {
            RLMProperty *prop = tableSchema.properties[i];
            RLMProperty *newProp = objectSchema[prop.name];
            if (RLMPropertyHasChanged(prop, newProp)) {
                objectSchema.table->remove_column(prop.column);
                changed = true;
            }
        }

        // update table metadata
        NSString *oldPrimary = tableSchema.primaryKeyProperty.name;
        NSString *newPrimary = objectSchema.primaryKeyProperty.name;
        if (newPrimary) {
            // if there is a primary key set, check if it is the same as the old key
            if (!oldPrimary || ![oldPrimary isEqualToString:newPrimary]) {
                RLMRealmSetPrimaryKeyForObjectClass(realm, objectSchema.className, newPrimary);
                changed = true;
            }
        }
        else if (oldPrimary) {
            // there is no primary key, so if there was one nil out
            RLMRealmSetPrimaryKeyForObjectClass(realm, objectSchema.className, nil);
            changed = true;
        }
    }

    return changed;
}

static bool RLMMigrationRequired(RLMRealm *realm, uint64_t newVersion, uint64_t oldVersion) {
    // validate versions
    if (oldVersion > newVersion && oldVersion != RLMNotVersioned) {
        NSString *reason = [NSString stringWithFormat:@"Realm at path '%@' has version number %lu which is greater than the current schema version %lu. "
                                                      @"You must call setSchemaVersion: or setDefaultRealmSchemaVersion: before accessing an upgraded Realm.",
                            realm.path, (unsigned long)oldVersion, (unsigned long)newVersion];
        @throw RLMException(reason, @{@"path" : realm.path});
    }

    return oldVersion != newVersion;
}

NSError *RLMUpdateRealmToSchemaVersion(RLMRealm *realm, NSUInteger newVersion, RLMSchema *targetSchema, NSError *(^migrationBlock)()) {
    // if the schema version matches, try to get all the tables without entering
    // a write transaction
    if (!RLMMigrationRequired(realm, newVersion, RLMRealmSchemaVersion(realm)) && RLMRealmGetTables(realm, targetSchema)) {
        RLMRealmSetSchema(realm, targetSchema, true);
        RLMRealmUpdateIndexes(realm);
        return nil;
    }

    // either a migration is needed or there's missing tables, so we do need a
    // write transaction
    [realm beginWriteTransaction];

    // Recheck the schema version after beginning the write transaction as
    // another process may have done the migration after we opened the read
    // transaction
    uint64_t oldVersion = RLMRealmSchemaVersion(realm);
    bool migrating = RLMMigrationRequired(realm, newVersion, oldVersion);

    @try {
        // create tables
        bool changed = RLMRealmCreateTables(realm, targetSchema, migrating);
        RLMRealmSetSchema(realm, targetSchema, true);

        if (migrating) {
            // apply the migration block if provided and there's any old data
            // to be migrated
            if (oldVersion != RLMNotVersioned && migrationBlock) {
                NSError *error = migrationBlock();
                if (error) {
                    [realm cancelWriteTransaction];
                    return error;
                }
            }

            RLMRealmSetSchemaVersion(realm, newVersion);
            RLMRealmUpdateIndexes(realm);
            changed = true;
        }

        if (changed) {
            [realm commitWriteTransaction];
        }
        else {
            [realm cancelWriteTransaction];
        }
    }
    @catch (NSException *) {
        [realm cancelWriteTransaction];
        @throw;
    }

    return nil;
}

static inline void RLMVerifyInWriteTransaction(__unsafe_unretained RLMRealm *const realm) {
    // if realm is not writable throw
    if (!realm.inWriteTransaction) {
        @throw RLMException(@"Can only add, remove, or create objects in a Realm in a write transaction - call beginWriteTransaction on an RLMRealm instance first.");
    }
    RLMCheckThread(realm);
}

void RLMInitializeSwiftListAccessor(__unsafe_unretained RLMObjectBase *const object) {
    if (!object || !object->_row || !object->_objectSchema.isSwiftClass) {
        return;
    }

    static Class s_swiftObjectClass = NSClassFromString(@"RealmSwift.Object");
    if (![object isKindOfClass:s_swiftObjectClass]) {
        return; // Is a Swift class using the obj-c API
    }

    for (RLMProperty *prop in object->_objectSchema.properties) {
        if (prop.type == RLMPropertyTypeArray) {
            RLMArray *array = [RLMArrayLinkView arrayWithObjectClassName:prop.objectClassName
                                                                    view:object->_row.get_linklist(prop.column)
                                                                   realm:object->_realm];
            [RLMObjectUtilClass(YES) initializeListProperty:object property:prop array:array];
        }
    }
}

template<typename F>
static inline NSUInteger RLMCreateOrGetRowForObject(__unsafe_unretained RLMObjectSchema *const schema, F primaryValueGetter, bool createOrUpdate, bool &created) {
    // try to get existing row if updating
    size_t rowIndex = realm::not_found;
    realm::Table &table = *schema.table;
    RLMProperty *primaryProperty = schema.primaryKeyProperty;
    if (createOrUpdate && primaryProperty) {
        // get primary value
        id primaryValue = RLMNSNullToNil(primaryValueGetter(primaryProperty));
        
        // search for existing object based on primary key type
        if (primaryProperty.type == RLMPropertyTypeString) {
            rowIndex = table.find_first_string(primaryProperty.column, RLMStringDataWithNSString(primaryValue));
        }
        else {
            rowIndex = table.find_first_int(primaryProperty.column, [primaryValue longLongValue]);
        }
    }

    // if no existing, create row
    created = NO;
    if (rowIndex == realm::not_found) {
        rowIndex = table.add_empty_row();
        created = YES;
    }

    // get accessor
    return rowIndex;
}

void RLMAddObjectToRealm(__unsafe_unretained RLMObjectBase *const object,
                         __unsafe_unretained RLMRealm *const realm, 
                         bool createOrUpdate) {
    RLMVerifyInWriteTransaction(realm);

    // verify that object is standalone
    if (object.invalidated) {
        @throw RLMException(@"Adding a deleted or invalidated object to a Realm is not permitted");
    }
    if (object->_realm) {
        if (object->_realm == realm) {
            // no-op
            return;
        }
        // for differing realms users must explicitly create the object in the second realm
        @throw RLMException(@"Object is already persisted in a Realm");
    }

    // set the realm and schema
    NSString *objectClassName = object->_objectSchema.className;
    RLMObjectSchema *schema = realm.schema[objectClassName];
    object->_objectSchema = schema;
    object->_realm = realm;

    // get or create row
    bool created;
    auto primaryGetter = [=](__unsafe_unretained RLMProperty *const p) { return [object valueForKey:p.getterName]; };
    object->_row = (*schema.table)[RLMCreateOrGetRowForObject(schema, primaryGetter, createOrUpdate, created)];

    RLMCreationOptions creationOptions = RLMCreationOptionsPromoteStandalone;
    if (createOrUpdate) {
        creationOptions |= RLMCreationOptionsCreateOrUpdate;
    }

    // populate all properties
    for (RLMProperty *prop in schema.properties) {
        // get object from ivar using key value coding
        id value = nil;
        if (prop.swiftListIvar) {
            value = static_cast<RLMListBase *>(object_getIvar(object, prop.swiftListIvar))._rlmArray;
        }
        else if ([object respondsToSelector:prop.getterSel]) {
            value = [object valueForKey:prop.getterName];
        }

        // FIXME: Add condition to check for Mixed once it can support a nil value.
        if (!value && !prop.optional) {
            @throw RLMException([NSString stringWithFormat:@"No value or default value specified for property '%@' in '%@'",
                                 prop.name, schema.className]);
        }

        // set in table with out validation
        // skip primary key when updating since it doesn't change
        if (created || !prop.isPrimary) {
            RLMDynamicSet(object, prop, RLMNSNullToNil(value), creationOptions);
        }

        // set the ivars for object and array properties to nil as otherwise the
        // accessors retain objects that are no longer accessible via the properties
        // this is mainly an issue when the object graph being added has cycles,
        // as it's not obvious that the user has to set the *ivars* to nil to
        // avoid leaking memory
        if (prop.type == RLMPropertyTypeObject || prop.type == RLMPropertyTypeArray) {
            if (!prop.swiftListIvar) {
                ((void(*)(id, SEL, id))objc_msgSend)(object, prop.setterSel, nil);
            }
        }
    }

    // set to proper accessor class
    object_setClass(object, schema.accessorClass);

    RLMInitializeSwiftListAccessor(object);
}

static void RLMValidateValueForProperty(__unsafe_unretained id const obj,
                                        __unsafe_unretained RLMProperty *const prop,
                                        __unsafe_unretained RLMSchema *const schema,
                                        bool validateNested,
                                        bool allowMissing);

static void RLMValidateValueForObjectSchema(__unsafe_unretained id const value,
                                            __unsafe_unretained RLMObjectSchema *const objectSchema,
                                            __unsafe_unretained RLMSchema *const schema,
                                            bool validateNested,
                                            bool allowMissing);

static void RLMValidateNestedObject(__unsafe_unretained id const obj,
                                    __unsafe_unretained NSString *const className,
                                    __unsafe_unretained RLMSchema *const schema,
                                    bool validateNested,
                                    bool allowMissing) {
    if (obj != nil && obj != NSNull.null) {
        if (RLMObjectBase *objBase = RLMDynamicCast<RLMObjectBase>(obj)) {
            RLMObjectSchema *objectSchema = objBase->_objectSchema;
            if (![className isEqualToString:objectSchema.className]) {
                // if not the right object class treat as literal
                RLMValidateValueForObjectSchema(objBase, schema[className], schema, validateNested, allowMissing);
            }
            if (objBase.isInvalidated) {
                @throw RLMException(@"Adding a deleted or invalidated object to a Realm is not permitted");
            }
        }
        else {
            RLMValidateValueForObjectSchema(obj, schema[className], schema, validateNested, allowMissing);
        }
    }
}

static void RLMValidateValueForProperty(__unsafe_unretained id const obj,
                                        __unsafe_unretained RLMProperty *const prop,
                                        __unsafe_unretained RLMSchema *const schema,
                                        bool validateNested,
                                        bool allowMissing) {
    switch (prop.type) {
        case RLMPropertyTypeString:
        case RLMPropertyTypeBool:
        case RLMPropertyTypeDate:
        case RLMPropertyTypeInt:
        case RLMPropertyTypeFloat:
        case RLMPropertyTypeDouble:
        case RLMPropertyTypeData:
        case RLMPropertyTypeAny:
            if (!RLMIsObjectValidForProperty(obj, prop)) {
                @throw RLMException(@"Invalid property",
                                    @{@"Property name:" : prop.name ?: @"nil",
                                      @"Value": obj ? [obj description] : @"nil"});
            }
            break;
        case RLMPropertyTypeObject:
            if (validateNested) {
                RLMValidateNestedObject(obj, prop.objectClassName, schema, validateNested, allowMissing);
            }
            break;
        case RLMPropertyTypeArray: {
            if (validateNested) {
                if (obj != nil && obj != NSNull.null) {
                    if (![obj conformsToProtocol:@protocol(NSFastEnumeration)]) {
                        @throw  RLMException(@"Array property value is not enumerable.");
                    }
                    id<NSFastEnumeration> array = obj;
                    for (id el in array) {
                        RLMValidateNestedObject(el, prop.objectClassName, schema, validateNested, allowMissing);
                    }
                }
            }
            break;
        }
    }
}

static void RLMValidateValueForObjectSchema(__unsafe_unretained id const value,
                                            __unsafe_unretained RLMObjectSchema *const objectSchema,
                                            __unsafe_unretained RLMSchema *const schema,
                                            bool validateNested,
                                            bool allowMissing) {
    NSArray *props = objectSchema.properties;
    if (NSArray *array = RLMDynamicCast<NSArray>(value)) {
        if (array.count != props.count) {
            @throw RLMException(@"Invalid array input. Number of array elements does not match number of properties.");
        }
        for (NSUInteger i = 0; i < array.count; i++) {
            RLMProperty *prop = props[i];
            RLMValidateValueForProperty(array[i], prop, schema, validateNested, allowMissing);
        }
    }
    else {
        NSDictionary *defaults;
        for (RLMProperty *prop in props) {
            id obj = [value valueForKey:prop.name];

            // get default for nil object
            if (!obj) {
                if (!defaults) {
                    defaults = RLMDefaultValuesForObjectSchema(objectSchema);
                }
                obj = defaults[prop.name];
            }
            if (obj || prop.isPrimary || !allowMissing) {
                RLMValidateValueForProperty(obj, prop, schema, true, allowMissing);
            }
        }
    }
}

RLMObjectBase *RLMCreateObjectInRealmWithValue(RLMRealm *realm, NSString *className, id value, bool createOrUpdate = false) {
    if (createOrUpdate && RLMIsObjectSubclass([value class])) {
        RLMObjectBase *obj = value;
        if ([obj->_objectSchema.className isEqualToString:className] && obj->_realm == realm) {
            // This is a no-op if value is an RLMObject of the same type already backed by the target realm.
            return value;
        }
    }

    // verify writable
    RLMVerifyInWriteTransaction(realm);

    // create the object
    RLMSchema *schema = realm.schema;
    RLMObjectSchema *objectSchema = schema[className];
    RLMObjectBase *object = [[objectSchema.accessorClass alloc] initWithRealm:realm schema:objectSchema];

    RLMCreationOptions creationOptions = createOrUpdate ? RLMCreationOptionsCreateOrUpdate : RLMCreationOptionsNone;

    // create row, and populate
    if (NSArray *array = RLMDynamicCast<NSArray>(value)) {
        // get or create our accessor
        bool created;
        auto primaryGetter = [=](__unsafe_unretained RLMProperty *const p) { return array[p.column]; };
        object->_row = (*objectSchema.table)[RLMCreateOrGetRowForObject(objectSchema, primaryGetter, createOrUpdate, created)];

        // populate
        NSArray *props = objectSchema.properties;
        for (NSUInteger i = 0; i < array.count; i++) {
            RLMProperty *prop = props[i];
            // skip primary key when updating since it doesn't change
            if (created || !prop.isPrimary) {
                id val = array[i];
                RLMValidateValueForProperty(val, prop, schema, false, false);
                RLMDynamicSet(object, prop, RLMNSNullToNil(val), creationOptions);
            }
        }
    }
    else {
        // get or create our accessor
        bool created;
        auto primaryGetter = [=](RLMProperty *p) { return [value valueForKey:p.name]; };
        object->_row = (*objectSchema.table)[RLMCreateOrGetRowForObject(objectSchema, primaryGetter, createOrUpdate, created)];

        // populate
        NSDictionary *defaultValues = nil;
        for (RLMProperty *prop in objectSchema.properties) {
            id propValue = [value valueForKey:prop.name];
            if (!propValue && created) {
                if (!defaultValues) {
                    defaultValues = RLMDefaultValuesForObjectSchema(objectSchema);
                }
                propValue = defaultValues[prop.name];
                if (!propValue && (prop.type == RLMPropertyTypeObject || prop.type == RLMPropertyTypeArray)) {
                    propValue = NSNull.null;
                }
            }

            if (propValue) {
                if (created || !prop.isPrimary) {
                    // skip missing properties and primary key when updating since it doesn't change
                    RLMValidateValueForProperty(propValue, prop, schema, false, false);
                    RLMDynamicSet(object, prop, RLMNSNullToNil(propValue), creationOptions);
                }
            }
            else if (created && !prop.optional) {
                @throw RLMException(@"Missing property value",
                                    @{@"Property name:" : prop.name ?: @"nil",
                                      @"Value": propValue ? [propValue description] : @"nil"});
            }
        }
    }

    RLMInitializeSwiftListAccessor(object);
    return object;
}

void RLMDeleteObjectFromRealm(__unsafe_unretained RLMObjectBase *const object,
                              __unsafe_unretained RLMRealm *const realm) {
    if (realm != object->_realm) {
        @throw RLMException(@"Can only delete an object from the Realm it belongs to.");
    }

    RLMVerifyInWriteTransaction(object->_realm);

    // move last row to row we are deleting
    if (object->_row.is_attached()) {
        object->_row.get_table()->move_last_over(object->_row.get_index());
    }

    // set realm to nil
    object->_realm = nil;
}

void RLMDeleteAllObjectsFromRealm(RLMRealm *realm) {
    RLMVerifyInWriteTransaction(realm);

    // clear table for each object schema
    for (RLMObjectSchema *objectSchema in realm.schema.objectSchema) {
        objectSchema.table->clear();
    }
}

RLMResults *RLMGetObjects(RLMRealm *realm, NSString *objectClassName, NSPredicate *predicate) {
    RLMCheckThread(realm);

    // create view from table and predicate
    RLMObjectSchema *objectSchema = realm.schema[objectClassName];
    if (!objectSchema.table) {
        // read-only realms may be missing tables since we can't add any
        // missing ones on init
        return [RLMEmptyResults emptyResultsWithObjectClassName:objectClassName realm:realm];
    }

    if (predicate) {
        realm::Query query = objectSchema.table->where();
        RLMUpdateQueryWithPredicate(&query, predicate, realm.schema, objectSchema);

        // create and populate array
        return [RLMResults resultsWithObjectClassName:objectClassName
                                                query:std::make_unique<Query>(query)
                                                realm:realm];
    }

    return [RLMTableResults tableResultsWithObjectSchema:objectSchema realm:realm];
}

id RLMGetObject(RLMRealm *realm, NSString *objectClassName, id key) {
    RLMCheckThread(realm);

    RLMObjectSchema *objectSchema = realm.schema[objectClassName];

    RLMProperty *primaryProperty = objectSchema.primaryKeyProperty;
    if (!primaryProperty) {
        NSString *msg = [NSString stringWithFormat:@"%@ does not have a primary key", objectClassName];
        @throw RLMException(msg);
    }

    if (!objectSchema.table) {
        // read-only realms may be missing tables since we can't add any
        // missing ones on init
        return nil;
    }

    key = RLMNSNullToNil(key);

    size_t row = realm::not_found;
    if (primaryProperty.type == RLMPropertyTypeString) {
        NSString *str = RLMDynamicCast<NSString>(key);
        if (str || !key) {
            row = objectSchema.table->find_first_string(primaryProperty.column, RLMStringDataWithNSString(str));
        }
        else {
            @throw RLMException([NSString stringWithFormat:@"Invalid value '%@' for primary key", key]);
        }
    }
    else {
        if (NSNumber *number = RLMDynamicCast<NSNumber>(key)) {
            row = objectSchema.table->find_first_int(primaryProperty.column, number.longLongValue);
        }
        else {
            @throw RLMException([NSString stringWithFormat:@"Invalid value '%@' for primary key", key]);
        }
    }

    if (row == realm::not_found) {
        return nil;
    }

    return RLMCreateObjectAccessor(realm, objectSchema, row);
}

// Create accessor and register with realm
RLMObjectBase *RLMCreateObjectAccessor(__unsafe_unretained RLMRealm *const realm,
                                       __unsafe_unretained RLMObjectSchema *const objectSchema,
                                       NSUInteger index) {
    RLMObjectBase *accessor = [[objectSchema.accessorClass alloc] initWithRealm:realm schema:objectSchema];
    accessor->_row = (*objectSchema.table)[index];
    RLMInitializeSwiftListAccessor(accessor);
    return accessor;
}
