// Sui's On-Chain Metadata Program
// On-chain metadata is stored in its deserialized state inside of dynamic fields attached to objects.
// Schemas are root-level objects used to map field-names to types, which is necessary in the deserialization process.
//
// Future to do:
// - have a dedicated URL type rather than using just a string

module metadata::metadata {
    use std::ascii;
    use std::string::String;
    use std::option;
    use std::vector;
    use sui::bcs::{Self};
    use sui::dynamic_field;
    use sui::object::{UID, ID};
    use sui::vec_map::VecMap;
    use metadata::schema::{Self, Schema};
    use sui_utils::encode;
    use sui_utils::deserialize;
    use sui_utils::dynamic_field2;
    use ownership::ownership;
    use ownership::tx_authority::TxAuthority;

    // Error enums
    const EINCORRECT_DATA_LENGTH: u64 = 0;
    const EUNRECOGNIZED_TYPE: u64 = 1;
    const EINCORRECT_SCHEMA_SUPPLIED: u64 = 2;
    const EINCOMPATIBLE_READER_SCHEMA: u64 = 3;
    const EINCOMPATIBLE_FALLBACK: u64 = 4;
    const ENO_MODULE_AUTHORITY: u64 = 5;
    const ENO_OWNER_AUTHORITY: u64 = 6;
    const EKEY_DOES_NOT_EXIST_ON_SCHEMA: u64 = 7;
    const EMISSING_VALUES_NEEDED_FOR_MIGRATION: u64 = 8;
    const EKEY_IS_NOT_OPTIONAL: u64 = 9;
    const EVALUE_UNDEFINED: u64 = 10;

    struct SchemaID has store, copy, drop { } // vector<u8>
    struct Key has store, copy, drop { slot: ascii::String }

    // `data` is an array of BCS-serialized values. Such as [ [3, 0, 0, 0], [2, 99, 100] ]
    // All variable-length types are prepended with a ULEB18 length. The Schema object is needed to deserialize the data.
    public fun attach(uid: &mut UID, data: vector<vector<u8>>, schema: &Schema, auth: &TxAuthority) {
        assert!(ownership::is_authorized_by_module(uid, auth), ENO_MODULE_AUTHORITY);
        assert!(ownership::is_authorized_by_owner(uid, auth), ENO_OWNER_AUTHORITY);

        let items = schema::into_items(schema);

        let i = 0;
        while (i < vector::length(&items)) {
            let item = vector::borrow(&items, i);
            let (key, type, optional) = schema::item(item);
            let value = *vector::borrow(&data, i);

            set_field(uid, Key { slot: key }, type, optional, value, true);
            i = i + 1;
        };

        dynamic_field::add(uid, SchemaID { }, schema::into_schema_id(schema));
    }

    // If `overwrite_existing` == true, then values are overwritten. Otherwise they are filled-in, in the sense that
    // data will only be written if (1) it is missing, or (2) if the existing data is of the wrong type.
    // This is strict on keys, in the sense that if you specify keys that do not exist on the schema, this
    // will abort rather than silently ignoring them or allowing you to write to keys outside of the schema.
    public fun update(
        uid: &mut UID,
        keys: vector<ascii::String>,
        data: vector<vector<u8>>,
        schema: &Schema,
        overwrite_existing: bool,
        auth: &TxAuthority
    ) {
        assert!(vector::length(&keys) == vector::length(&data), EINCORRECT_DATA_LENGTH);
        assert_valid_ownership_and_schema(uid, schema, auth);

        let i = 0;
        while (i < vector::length(&keys)) {
            let key = *vector::borrow(&keys, i);
            let (type_maybe, optional_maybe) = schema::find_type_for_key(schema, key);
            if (option::is_none(&type_maybe)) abort EKEY_DOES_NOT_EXIST_ON_SCHEMA;
            let value = *vector::borrow(&data, i);

            set_field(
                uid,
                Key { slot: key },
                option::destroy_some(type_maybe),
                option::destroy_some(optional_maybe),
                value,
                overwrite_existing);
            i = i + 1;
        };
    }

    // Useful if you want to borrow / borrow_mut but want to avoid an abort in case the value doesn't exist
    public fun exists_(uid: &UID, key: ascii::String): bool {
        dynamic_field::exists_(uid, Key { slot: key } )
    }

    // We allow any metadata field to be read without any permission. T must be correct, otherwise this will abort
    public fun borrow<T: store>(uid: &UID, key: ascii::String): &T {
        dynamic_field::borrow<Key, T>(uid, Key { slot: key } )
    }

    // For atomic updates (like incrementing a counter) use this rather than an `overwrite` to ensure no
    // writes are lost. `T` must be the type corresponding to the schema, and the value must be defined, or
    // this will abort
    public fun borrow_mut<T: store>(uid: &mut UID, key: ascii::String, auth: &TxAuthority): &mut T {
        assert!(ownership::is_authorized_by_module(uid, auth), ENO_MODULE_AUTHORITY);
        assert!(ownership::is_authorized_by_owner(uid, auth), ENO_OWNER_AUTHORITY);

        dynamic_field::borrow_mut<Key, T>(uid, Key { slot: key } )
    }

    // You can accomplish this by using `overwrite` with option bytes set to 0 (none) for all keys you
    // want to remove, but this function exists for convenience
    public fun delete_optional(uid: &mut UID, keys: vector<ascii::String>, schema: &Schema, auth: &TxAuthority) {
        assert_valid_ownership_and_schema(uid, schema, auth);

        let i = 0;
        while (i < vector::length(&keys)) {
            let key = *vector::borrow(&keys, i);
            let (type_maybe, optional_maybe) = schema::find_type_for_key(schema, key);
            if (option::is_none(&type_maybe)) abort EKEY_DOES_NOT_EXIST_ON_SCHEMA;
            if (!option::destroy_some(optional_maybe)) abort EKEY_IS_NOT_OPTIONAL;

            drop_field(uid, Key { slot: key }, option::destroy_some(type_maybe));
            i = i + 1;
        };
    }
    
    // Wipes all metadata, including the schema. This allows you to start from scratch again using a new
    // schema and new data using attach().
    public fun delete_all(uid: &mut UID, schema: &Schema, auth: &TxAuthority) {
        assert_valid_ownership_and_schema(uid, schema, auth);

        let (i, items) = (0, schema::into_items(schema));
        while (i < vector::length(&items)) {
            let item = vector::borrow(&items, i);
            let (key, type, _) = schema::item(item);

            drop_field(uid, Key { slot: key }, type);
            i = i + 1;
        };

        dynamic_field2::drop<SchemaID, vector<u8>>(uid, SchemaID { });
    }

    // Moves from old-schema -> new-schema.
    // Keys and data act as fill-ins; i.e., if there is already a value at 'name' of the type specified in
    // new_schema, then the old view will be left in place. However, if the value is missing, or if the type
    // is different from the one specified in new_schema, the data will be used to fill it in.
    // You must supply [keys, data] for (1) any new fields, (2) any fields that were optional but are now
    // mandatory and are missing on this object, and (3) any fields whose types are changing in the new
    // schema
    public fun migrate(
        uid: &mut UID,
        old_schema: &Schema,
        new_schema: &Schema,
        keys: vector<ascii::String>,
        data: vector<vector<u8>>,
        auth: &TxAuthority
    ) {
        assert_valid_ownership_and_schema(uid, old_schema, auth);

        // Drop all of the old_schema's fields which no longer exist in the new schema
        let items = schema::difference(old_schema, new_schema);
        let i = 0;
        while (i < vector::length(&items)) {
            let (key, type, _) = schema::item(vector::borrow(&items, i));
            drop_field(uid, Key { slot: key }, type);
        };

        // Drop any of the fields whose types are changing
        let new = schema::into_items(new_schema);
        let i = 0;
        while (i < vector::length(&new)) {
            let (key, type, _) = schema::item(vector::borrow(&new, i));
            let (old_type_maybe, _) = schema::find_type_for_key(old_schema, key);
            if (option::is_some(&old_type_maybe)) {
                let old_type = option::destroy_some(old_type_maybe);
                if (old_type != type) drop_field(uid, Key { slot: key }, old_type);
            };
            i = i + 1;
        };

        dynamic_field2::set(uid, SchemaID { }, schema::into_schema_id(new_schema));

        // Fill-in all the newly supplied values
        update(uid, keys, data, new_schema, false, auth);

        // Check to make sure that all required fields are defined
        let i = 0;
        while (i < vector::length(&new)) {
            let (key, _, optional) = schema::item(vector::borrow(&new, i));
            if (!optional) {
                assert!(dynamic_field::exists_(uid, Key { slot: key }), EMISSING_VALUES_NEEDED_FOR_MIGRATION);
            };
            i = i + 1;
        };
    }

    // ============= devInspect Functions ============= 

    // This is the same as calling `view` with all the keys in its schema
    public fun view_all(uid: &UID, schema: &Schema): vector<u8> {
        view(uid, schema::into_keys(schema), schema)
    }

    // The response is raw BCS bytes; the client app will need to consult this object's cannonical schema for the
    // corresponding keys that were queried in order to deserialize the results.
    public fun view(uid: &UID, keys: vector<ascii::String>, schema: &Schema): vector<u8> {
        assert!(schema::equals_(schema, schema_id(uid)), EINCORRECT_SCHEMA_SUPPLIED);

        let (i, response, len) = (0, vector::empty<u8>(), vector::length(&keys));

        while (i < len) {
            let slot = *vector::borrow(&keys, i);
            vector::append(&mut response, view_field(uid, slot, schema));
            i = i + 1;
        };

        response
    }

    // Note that this doesn't validate that the schema you supplied is the cannonical schema for this object, or that the keys
    // you've specified exist on your suppplied schema. Deserialize these results with the schema you supplied, not with the
    // object's cannonical schema
    public fun view_field(uid: &UID, slot: ascii::String, schema: &Schema): vector<u8> {
        let (type_maybe, optional_maybe) = schema::find_type_for_key(schema, slot);

        if (dynamic_field::exists_(uid, Key { slot }) && option::is_some(&type_maybe)) {
            let type = option::destroy_some(type_maybe);

            // We only prepend option-bytes if the key is optional
            let bytes = if (option::destroy_some(optional_maybe)) { 
                vector[1u8] // option::is_some
            } else {
                vector::empty<u8>()
            };

            vector::append(&mut bytes, get_bcs_bytes(uid, slot, type));

            bytes
        } else if (option::is_some(&type_maybe)) {
            vector[0u8] // option::is_none
        } else {
            abort EKEY_DOES_NOT_EXIST_ON_SCHEMA
        }
    }

    // Query all keys specified inside of `reader_schema`
    // Note that the reader_schema and the object's own schema must be compatible, in the sense that any key
    // overlaps are the same type.
    // Maybe we could take into account optionality or do some sort of type coercian to relax this compatability
    // requirement? I.e., turn a u8 into a u64
    public fun view_with_reader_schema(
        uid: &UID,
        reader_schema: &Schema,
        object_schema: &Schema
    ): vector<u8> {
        assert!(schema::is_compatible(reader_schema, object_schema), EINCOMPATIBLE_READER_SCHEMA);
        assert!(schema::equals_(object_schema, schema_id(uid)), EINCORRECT_SCHEMA_SUPPLIED);

        let (reader_items, i, keys) = (schema::into_items(reader_schema), 0, vector::empty<ascii::String>());

        while (i < vector::length(&reader_items)) {
            let (key, _, _) = schema::item(vector::borrow(&reader_items, i));
            vector::push_back(&mut keys, key);
            i = i + 1;
        };

        view(uid, keys, object_schema)
    }

    public fun view_all_with_default(
        uid: &UID,
        fallback: &UID,
        schema: &Schema,
        fallback_schema: &Schema,
    ): vector<u8> {
        view_with_default(uid, fallback, schema::into_keys(schema), schema, fallback_schema)
    }

    // Asserting that both the object and the fallback object have compatible schemas is a bit extreme; they
    // really only need to have the same types for the keys being used here
    public fun view_with_default(
        uid: &UID,
        fallback: &UID,
        keys: vector<ascii::String>,
        schema: &Schema,
        fallback_schema: &Schema,
    ): vector<u8> {
        assert!(schema::is_compatible(schema, fallback_schema), EINCOMPATIBLE_FALLBACK);
        assert!(schema::equals_(schema, schema_id(uid)), EINCORRECT_SCHEMA_SUPPLIED);
        assert!(schema::equals_(fallback_schema, schema_id(fallback)), EINCORRECT_SCHEMA_SUPPLIED);

        let (i, response, len) = (0, vector::empty<u8>(), vector::length(&keys));

        while (i < len) {
            let slot = *vector::borrow(&keys, i);
            let res = view_field(uid, slot, schema);
            if (res != vector[0u8]) {
                vector::append(&mut response, view_field(uid, slot, schema));
            } else {
                vector::append(&mut response, view_field(fallback, slot, fallback_schema));
            };
            i = i + 1;
        };

        response
    }

    public fun schema_id(uid: &UID): vector<u8> {
        *dynamic_field::borrow<SchemaID, vector<u8>>(uid, SchemaID { } )
    }

    // ============ (de)serializes objects ============ 

    // Private function so that the schema cannot be bypassed
    // Aborts if the type is incorrect because the bcs deserialization will fail
    // Supported: address, bool, objectID, u8, u64, u128, String (utf8), + vectors of these types
    // + VecMap, vector<vector<u8>>
    // Not yet supported: u16, u32, u256 <--not included in sui::bcs
    fun set_field(
        uid: &mut UID,
        key: Key,
        type_string: ascii::String,
        optional: bool,
        value: vector<u8>,
        overwrite: bool
    ) {
        let type = ascii::into_bytes(type_string);

        // Empty byte-arrays are treated as undefined
        if (vector::length(&value) == 0) {
            if (optional) {
                drop_field(uid, key, type_string);
                return
            // These types are allowed to be empty arrays and still count as being "defined"
            } else if ( type == b"String" || type == b"VecMap" || encode::is_vector(type_string) ) {
                value = if (optional) { vector[1u8, 0u8] } else { vector[0u8] };
            } else { abort EKEY_IS_NOT_OPTIONAL };
        };

        // Field is optional and undefined
        if (optional && *vector::borrow(&value, 0) == 0u8) {
            drop_field(uid, key, type_string);
            return
        };

        // Index to start deserializing
        let i = if (optional) { 1 } else { 0 };

        if (type == b"address") {
            let (addr, _) = deserialize::address_(&value, i);
            if (overwrite || !dynamic_field::exists_(uid, key))
                dynamic_field2::set(uid, key, addr);
        } 
        else if (type == b"bool") {
            let (boolean, _) = deserialize::bool_(&value, i);
            if (overwrite || !dynamic_field::exists_(uid, key))
                dynamic_field2::set(uid, key, boolean);
        } 
        else if (type == b"id") {
            let (object_id, _) = deserialize::id_(&value, i);
            if (overwrite || !dynamic_field::exists_(uid, key))
                dynamic_field2::set(uid, key, object_id);
        } 
        else if (type == b"u8") {
            let integer = vector::borrow(&value, i);
            if (overwrite || !dynamic_field::exists_(uid, key))
                dynamic_field2::set(uid, key, *integer);
        }
        else if (type == b"u16") {
            let (integer, _) = deserialize::u16_(&value, i);
            if (overwrite || !dynamic_field::exists_(uid, key))
                dynamic_field2::set(uid, key, integer);
        } 
        else if (type == b"u32") {
            let (integer, _) = deserialize::u32_(&value, i);
            if (overwrite || !dynamic_field::exists_(uid, key))
                dynamic_field2::set(uid, key, integer);
        } 
        else if (type == b"u64") {
            let (integer, _) = deserialize::u64_(&value, i);
            if (overwrite || !dynamic_field::exists_(uid, key))
                dynamic_field2::set(uid, key, integer);
        } 
        else if (type == b"u128") {
            let (integer, _) = deserialize::u128_(&value, i);
            if (overwrite || !dynamic_field::exists_(uid, key))
                dynamic_field2::set(uid, key, integer);
        } 
        else if (type == b"u256") {
            let (integer, _) = deserialize::u256_(&value, i);
            if (overwrite || !dynamic_field::exists_(uid, key))
                dynamic_field2::set(uid, key, integer);
        } 
        else if (type == b"String") {
            let (string, _) = deserialize::string_(&value, i);
            if (overwrite || !dynamic_field::exists_(uid, key))
                dynamic_field2::set(uid, key, string);
        } 
        else if (type == b"vector<address>") {
            let (vec, _) = deserialize::vec_address(&value, i);
            if (overwrite || !dynamic_field::exists_(uid, key))
                dynamic_field2::set(uid, key, vec);
        }
        else if (type == b"vector<bool>") {
            let (vec, _) = deserialize::vec_bool(&value, i);
            if (overwrite || !dynamic_field::exists_(uid, key))
                dynamic_field2::set(uid, key, vec);
        }
        else if (type == b"vector<id>") {
            let (vec, _) = deserialize::vec_id(&value, i);
            if (overwrite || !dynamic_field::exists_(uid, key))
                dynamic_field2::set(uid, key, vec);
        }
        else if (type == b"vector<u8>") {
            let (vec, _) = deserialize::vec_u8(&value, i);
            if (overwrite || !dynamic_field::exists_(uid, key))
                dynamic_field2::set(uid, key, vec);
        }
        else if (type == b"vector<u16>") {
            let (vec, _) = deserialize::vec_u16(&value, i);
            if (overwrite || !dynamic_field::exists_(uid, key))
                dynamic_field2::set(uid, key, vec);
        }
        else if (type == b"vector<u32>") {
            let (vec, _) = deserialize::vec_u32(&value, i);
            if (overwrite || !dynamic_field::exists_(uid, key))
                dynamic_field2::set(uid, key, vec);
        }
        else if (type == b"vector<u64>") {
            let (vec, _) = deserialize::vec_u64(&value, i);
            if (overwrite || !dynamic_field::exists_(uid, key))
                dynamic_field2::set(uid, key, vec);
        }
        else if (type == b"vector<u128>") {
            let (vec, _) = deserialize::vec_u128(&value, i);
            if (overwrite || !dynamic_field::exists_(uid, key))
                dynamic_field2::set(uid, key, vec);
        }
        else if (type == b"vector<u256>") {
            let (vec, _) = deserialize::vec_u256(&value, i);
            if (overwrite || !dynamic_field::exists_(uid, key))
                dynamic_field2::set(uid, key, vec);
        }
        else if (type == b"vector<vector<u8>>") {
            let (vec, _) = deserialize::vec_vec_u8(&value, i);
            if (overwrite || !dynamic_field::exists_(uid, key))
                dynamic_field2::set(uid, key, vec);
        }
        else if (type == b"vector<String>") {
            let (strings, _) = deserialize::vec_string(&value, i);
            if (overwrite || !dynamic_field::exists_(uid, key))
                dynamic_field2::set(uid, key, strings);
        }
        else if (type == b"VecMap") {
            let (vec_map, _) = deserialize::vec_map_string_string(&value, i);
            if (overwrite || !dynamic_field::exists_(uid, key))
                dynamic_field2::set(uid, key, vec_map);
        }
        else {
            abort EUNRECOGNIZED_TYPE
        }
    }

    // Private function so that the schema cannot be bypassed
    // Unfortunately sui::dynamic_field does not have a general 'drop' function; the value of the type
    // being dropped MUST be known. This makes dropping droppable assets unecessarily complex, hence
    // this lengthy function in place of what should be one line of code. I know... believe me I've asked.
    fun drop_field(uid: &mut UID, key: Key, type_string: ascii::String) {
        let type = ascii::into_bytes(type_string);

        if (type == b"address") {
            dynamic_field2::drop<Key, address>(uid, key);
        } 
        else if (type == b"bool") {
            dynamic_field2::drop<Key, bool>(uid, key);
        } 
        else if (type == b"id") {
            dynamic_field2::drop<Key, ID>(uid, key);
        } 
        else if (type == b"u8") {
            dynamic_field2::drop<Key, u8>(uid, key);
        } 
        else if (type == b"u64") {
            dynamic_field2::drop<Key, u64>(uid, key);
        } 
        else if (type == b"u128") {
            dynamic_field2::drop<Key, u128>(uid, key);
        } 
        else if (type == b"String") {
            dynamic_field2::drop<Key, String>(uid, key);
        } 
        else if (type == b"vector<address>") {
            dynamic_field2::drop<Key, vector<address>>(uid, key);
        }
        else if (type == b"vector<bool>") {
            dynamic_field2::drop<Key, vector<bool>>(uid, key);
        }
        else if (type == b"vector<id>") {
            dynamic_field2::drop<Key, vector<ID>>(uid, key);
        }
        else if (type == b"vector<u8>") {
            dynamic_field2::drop<Key, vector<u8>>(uid, key);
        }
        else if (type == b"vector<u64>") {
            dynamic_field2::drop<Key, vector<u64>>(uid, key);
        }
        else if (type == b"vector<u128>") {
            dynamic_field2::drop<Key, vector<u128>>(uid, key);
        }
        else if (type == b"vector<String>") {
            dynamic_field2::drop<Key, vector<String>>(uid, key);
        }
        else if (type == b"VecMap") {
            dynamic_field2::drop<Key, VecMap<String, String>>(uid, key);
        }
        else {
            abort EUNRECOGNIZED_TYPE
        }
    }

    // If we get dynamic_field::get_bcs_bytes we can simplify this down into 2 or 3 lines
    public fun get_bcs_bytes(uid: &UID, slot: ascii::String, type_string: ascii::String): vector<u8> {
        let key = Key { slot };
        assert!(dynamic_field::exists_(uid, key), EVALUE_UNDEFINED);

        let type = ascii::into_bytes(type_string);

        if (type == b"address") {
            let addr = dynamic_field::borrow<Key, address>(uid, key);
            bcs::to_bytes(addr)
        } 
        else if (type == b"bool") {
            let boolean = dynamic_field::borrow<Key, bool>(uid, key);
            bcs::to_bytes(boolean)
        } 
        else if (type == b"id") {
            let object_id = dynamic_field::borrow<Key, ID>(uid, key);
            bcs::to_bytes(object_id)
        } 
        else if (type == b"u8") {
            let int = dynamic_field::borrow<Key, u8>(uid, key);
            bcs::to_bytes(int)
        } 
        else if (type == b"u64") {
            let int = dynamic_field::borrow<Key, u64>(uid, key);
            bcs::to_bytes(int)
        } 
        else if (type == b"u128") {
            let int = dynamic_field::borrow<Key, u128>(uid, key);
            bcs::to_bytes(int)
        } 
        else if (type == b"String") {
            let string = dynamic_field::borrow<Key, String>(uid, key);
            bcs::to_bytes(string)
        } 
        else if (type == b"vector<address>") {
            let vec = dynamic_field::borrow<Key, vector<address>>(uid, key);
            bcs::to_bytes(vec)
        }
        else if (type == b"vector<bool>") {
            let vec = dynamic_field::borrow<Key, vector<bool>>(uid, key);
            bcs::to_bytes(vec)
        }
        else if (type == b"vector<id>") {
            let vec = dynamic_field::borrow<Key, vector<ID>>(uid, key);
            bcs::to_bytes(vec)
        }
        else if (type == b"vector<u8>") {
            let vec = dynamic_field::borrow<Key, vector<u8>>(uid, key);
            bcs::to_bytes(vec)
        }
        else if (type == b"vector<u64>") {
            let vec = dynamic_field::borrow<Key, vector<u64>>(uid, key);
            bcs::to_bytes(vec)
        }
        else if (type == b"vector<u128>") {
            let vec = dynamic_field::borrow<Key, vector<u128>>(uid, key);
            bcs::to_bytes(vec)
        }
        else if (type == b"vector<String>") {
            let vec = dynamic_field::borrow<Key, vector<String>>(uid, key);
            bcs::to_bytes(vec)
        }
        else if (type == b"VecMap") {
            let vec_map = dynamic_field::borrow<Key, VecMap<String, String>>(uid, key);
            bcs::to_bytes(vec_map)
        }
        else {
            abort EUNRECOGNIZED_TYPE
        }
    }

    // ========= Helper Functions ========= 

    public fun assert_valid_ownership_and_schema(uid: &UID, schema: &Schema, auth: &TxAuthority) {
        assert!(ownership::is_authorized_by_module(uid, auth), ENO_MODULE_AUTHORITY);
        assert!(ownership::is_authorized_by_owner(uid, auth), ENO_OWNER_AUTHORITY);
        assert!(schema::equals_(schema, schema_id(uid)), EINCORRECT_SCHEMA_SUPPLIED);
    }
}

#[test_only]
module metadata::metadata_tests {
    use std::ascii::{String, string};
    use std::vector;
    use std::option;
    use sui::bcs;
    use sui::object::{Self, UID};
    use sui::test_scenario;
    use metadata::metadata;
    use metadata::schema;
    use ownership::tx_authority;
    use ownership::ownership;
    use sui::transfer;

    struct Witness has drop {}

    struct TestObject has key {
        id: UID
    }

    // Error constant
    const EINVALID_METADATA: u64 = 0;

    const SENDER: address = @0x99;

    public entry fun extend(test_object: &mut TestObject): &mut UID {
        &mut test_object.id
    }

    public fun assert_correct_serialization(data: vector<vector<u8>>, schema_data: vector<vector<String>>) {
        // Tx1: Create a schema
        let scenario_val = test_scenario::begin(SENDER);
        let scenario = &mut scenario_val;
        {
            let ctx = test_scenario::ctx(scenario);
            schema::create(schema_data, ctx);
        };

        // Tx2: Create an object and attach metadata
        test_scenario::next_tx(scenario, SENDER);
        let schema = test_scenario::take_immutable<schema::Schema>(scenario);
        {
            let ctx = test_scenario::ctx(scenario);

            let object = TestObject { id: object::new(ctx) };
            let auth = tx_authority::add_type_capability(&Witness {}, &tx_authority::begin(ctx));

            let proof = ownership::setup(&object);
            ownership::initialize(&mut object.id, proof, &auth);

            metadata::attach(&mut object.id, data, &schema, &auth);

            transfer::share_object(object);
        };

        // Tx3: view metadata and assert that it was deserialized correctly
        test_scenario::next_tx(scenario, SENDER);
        let test_object = test_scenario::take_shared<TestObject>(scenario);
        {
            let uid = extend(&mut test_object);
            metadata::view_field(uid, string(b"name"), &schema);

            let keys = schema::into_keys(&schema);
            let i = 0;

            while (i < vector::length(&keys)) {
                let key = *vector::borrow(&keys, i);
                let bcs_bytes = metadata::view_field(uid, key, &schema);
                assert!(&bcs_bytes == vector::borrow(&data, i), EINVALID_METADATA);
                i = i + 1;
            };
        };
        test_scenario::return_immutable(schema);
        test_scenario::return_shared(test_object);

        test_scenario::end(scenario_val);
    }

    #[test]
    public fun nft1() {
        let schema_data = vector<vector<String>>[ 
            vector[string(b"name"), string(b"String")],
            vector[string(b"description"), string(b"Option<String>")],
            vector[string(b"image"), string(b"String")], 
            vector[string(b"power_level"), string(b"u64")] 
        ];
        let data = vector<vector<u8>>[ 
            bcs::to_bytes(&b"Kyrie"), 
            bcs::to_bytes(&option::some(vector<u8>[])), 
            bcs::to_bytes(&b"https://wikipedia.org/"), 
            bcs::to_bytes(&19999u64) 
        ];

        assert_correct_serialization(data, schema_data);
    }

    #[test]
    public fun nft2() {
        let schema_data = vector[ 
            vector[string(b"name"), string(b"String")], 
            vector[string(b"description"), string(b"Option<String>")], 
            vector[string(b"image"), string(b"String")], 
            vector[string(b"power_level"), string(b"u64")], 
            vector[string(b"attributes"), string(b"VecMap")] 
        ];

        let data = vector[ 
            vector[6, 79, 117, 116, 108, 97, 119], 
            vector[1, 65, 84, 104, 101, 115, 101, 32, 97, 114, 101, 32, 100, 101, 109, 111, 32, 79, 117, 116, 108, 97, 119, 115, 32, 99, 114, 101, 97, 116, 101, 100, 32, 98, 121, 32, 67, 97, 112, 115, 117, 108, 101, 67, 114, 101, 97, 116, 111, 114, 32, 102, 111, 114, 32, 111, 117, 114, 32, 116, 117, 116, 111, 114, 105, 97, 108], 
            vector[77, 104, 116, 116, 112, 115, 58, 47, 47, 112, 98, 115, 46, 116, 119, 105, 109, 103, 46, 99, 111, 109, 47, 112, 114, 111, 102, 105, 108, 101, 95, 105, 109, 97, 103, 101, 115, 47, 49, 53, 54, 57, 55, 50, 55, 51, 50, 52, 48, 56, 49, 51, 50, 56, 49, 50, 56, 47, 55, 115, 85, 110, 74, 118, 82, 103, 95, 52, 48, 48, 120, 52, 48, 48, 46, 106, 112, 103], 
            vector[199, 0, 0, 0, 0, 0, 0, 0], 
            vector[ 0 ]
        ];

        assert_correct_serialization(data, schema_data);
    }

    #[test]
    public fun nft3() {
        let schema_data = vector[ 
            vector[string(b"name"), string(b"String")], 
            vector[string(b"description"), string(b"Option<String>")], 
            vector[string(b"image"), string(b"String")], 
            vector[string(b"attributes"), string(b"VecMap")] 
        ];

        let data = vector[ 
            vector[10, 121, 48, 48, 116, 32,  35, 56, 49,  55, 51], 
            vector[ 0 ], 
            vector[37, 104, 116, 116, 112, 115,  58,  47, 47, 109, 101, 116,  97, 100,  97, 116,  97,  46, 121,  48,  48, 116, 115,  46,  99, 111, 109, 47, 121,  47,  56,  49,  55,  50,  46, 112, 110, 103], 
            vector[7, 10, 66, 97, 99, 107, 103, 114, 111, 117, 110, 100, 5,  87, 104, 105, 116, 101,   3,  70, 117, 114,  14,  80, 97, 114,  97, 100, 105, 115, 101, 32, 71, 114, 101, 101, 110,  4,  70,  97,  99, 101, 9,  87, 104, 111, 108, 101, 115, 111, 109, 101,   8,  67, 108, 111, 116, 116, 104, 101, 115,  12,  83, 117, 109, 109, 101, 114,  32, 83, 104, 105, 114, 116,   4,  72, 101,  97, 100,  17,  66, 101,  97, 110, 105, 101,  32,  40,  98, 108,  97,  99, 107, 111, 117, 116, 41, 7,  69, 121, 101, 119, 101,  97, 114,  14,  77, 101, 108, 114, 111, 115, 101,  32,  66, 114, 105,  99, 107, 115, 3, 49, 47, 49, 4, 78, 111, 110, 101] ];

        assert_correct_serialization(data, schema_data);
    }
}