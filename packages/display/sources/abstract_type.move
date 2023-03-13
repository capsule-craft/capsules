// Abstract types are display objects used to produce display objects for concrete types
// For example, `Coin<T>` is a single abstract type; `T` can be filled in to produce a boundless number
// of concrete types, such as: Coin<0x2::sui::SUI> and Coin<0xc0ffee::diem::DIEM>

module display::abstract_type {
    use std::string::{Self, String};
    use std::option::{Self, Option};
    use std::vector;

    use sui::object::{Self, UID};
    use sui::tx_context::{Self, TxContext};
    use sui::dynamic_field;
    use sui::transfer;
    use sui::typed_id;

    use sui_utils::encode;
    use sui_utils::struct_tag::{Self, StructTag};

    use ownership::ownership;
    use ownership::tx_authority::{Self, TxAuthority};

    use display::display;
    use display::publish_receipt::{Self, PublishReceipt};
    use display::schema::{Self, Schema};
    use display::type::{Self, Type};

    use transfer_system::simple_transfer::Witness as SimpleTransfer;

    // Error constants
    const ENO_OWNER_AUTHORITY: u64 = 0;
    const EINVALID_PUBLISH_RECEIPT: u64 = 1;
    const ETYPE_IS_NOT_ABSTRACT: u64 = 2;
    const ETYPE_ALREADY_DEFINED: u64 = 3;
    const EINCORRECT_SCHEMA_SUPPLIED: u64 = 4;
    const EINVALID_SCHEMA_ID: u64 = 5;
    const EABSTRACT_DOES_NOT_MATCH_CONCRETE: u64 = 6;

    // Singleton, shared root-level object. Cannot be destroyed. Unique on its `type` field.
    struct AbstractType has key {
        id: UID,
        type: StructTag,
        // These will be used as the default schema and display template when defining a concrete type based on
        // this abstract type
        schema: Schema,
        template: VecMap<String, String>,

    }

    // Added to publish receipt to ensure an abstract type is only defined once
    struct Key has store, copy, drop { slot: String }

    // Added to abstract-type to ensure that a concrete type is only defined once
    struct KeyGenerics has store, copy, drop { slot: vector<String> }

    // Module authority
    struct Witness has drop { }

    // When create an abstract type like `Coin<E>`, the `E` can be filled in as anything for the
    // type argument. Note that we are merely creating the abstract type here, not defining it, which would
    // involve attaching display metadata as well.
    public entry fun create<T>(
        publisher: &mut PublishReceipt,
        owner: Option<address>,
        schema: &Schema,
        ctx: &mut TxContext
    ) {
        let abstract_type = create_<T>(publisher, schema, ctx);
        return_and_share(abstract_type, owner, ctx);
    }

    public fun create_<T>(
        publisher: &mut PublishReceipt,
        schema: &Schema,
        ctx: &mut TxContext
    ): AbstractType {
        assert!(encode::package_id<T>() == publish_receipt::into_package_id(publisher), EINVALID_PUBLISH_RECEIPT);
        assert!(encode::has_generics<T>(), ETYPE_IS_NOT_ABSTRACT);

        let key = Key { slot: encode::module_and_struct_name<T>() };
        let uid = publish_receipt::extend(publisher);
        assert!(!dynamic_field::exists_(uid, key), ETYPE_ALREADY_DEFINED);

        dynamic_field::add(uid, key, true);

        let abstract_type = AbstractType { 
            id: object::new(ctx),
            type: struct_tag::get_abstract<T>(),
            schema: schema::dupliate(schema),
            template: vec_map::empty(),
        };
        let auth = tx_authority::begin_with_type(&Witness { });
        let typed_id = typed_id::new(&abstract_type);

        ownership::initialize_without_module_authority(&mut abstract_type.id, typed_id, &auth);

        abstract_type
    }

    public fun return_and_share(abstract_type: AbstractType, owner: Option<address>, ctx: &TxContext) {
        let owner = if (option::is_some(&owner)) { option::destroy_some(owner) }
            else { tx_context::sender(ctx) };

        ownership::as_shared_object<SimpleTransfer>(&mut abstract_type.id, vector[owner], &tx_authority::empty());

        transfer::share_object(abstract_type);
    }

    // `define` combines both `create` and `attach` into a single entry function for convenience
    public entry fun define<T>(
        publisher: &mut PublishReceipt,
        owner: Option<address>,
        data: vector<vector<u8>>,
        schema: &Schema,
        ctx: &mut TxContext
    ) {
        let abstract_type = create_<T>(publisher, schema, ctx);
        display::attach(&mut abstract_type.id, data, schema, &tx_authority::begin(ctx));
        return_and_share(abstract_type, owner, ctx);
    }

    // Convenience entry function
    public entry fun define_from_abstract<T>(
        abstract_type: &mut AbstractType,
        data: vector<vector<u8>>,
        schema: &Schema,
        ctx: &mut TxContext
    ) {
        let type = define_from_abstract_<T>(abstract_type, data, schema, &tx_authority::begin(ctx), ctx);
        type::transfer(type, tx_context::sender(ctx));
    }

    // Returns a concrete type based on an abstract type, like Type<Coin<0x2::sui::SUI>> from
    // AbstractType Coin<T>
    // The schema supplied will be used to define the concrete type's display, and must be the same 
    // schema specified in the abstract type's `schema_id` field
    public fun define_from_abstract_<T>(
        abstract: &mut AbstractType,
        data: vector<vector<u8>>,
        schema: &Schema,
        auth: &TxAuthority,
        ctx: &mut TxContext
    ): Type<T> {
        let struct_tag = struct_tag::get<T>();
        assert!(struct_tag::is_same_abstract_type(&abstract.type, &struct_tag), EABSTRACT_DOES_NOT_MATCH_CONCRETE);
        assert!(ownership::is_authorized_by_owner(&abstract.id, auth), ENO_OWNER_AUTHORITY);
        assert!(schema::equals_(schema, abstract.schema_id), EINCORRECT_SCHEMA_SUPPLIED);

        // Ensures that this concrete type can only ever be created once
        let generics = struct_tag::generics(&struct_tag);
        let key = KeyGenerics { slot: generics };
        assert!(!dynamic_field::exists_(&abstract.id, key), ETYPE_ALREADY_DEFINED);

        dynamic_field::add(&mut abstract.id, key, true);

        type::define_internal<T>(data, schema, ctx)
    }

    // ======== Metadata Module's API =====
    // These can be removed once Sui supports programmable transactions that support mutable references

    public entry fun attach(abstract_type: &mut AbstractType, data: vector<vector<u8>>, schema: &Schema, ctx: &mut TxContext) {
        display::attach(&mut abstract_type.id, data, schema, &tx_authority::begin(ctx));
    }

    public entry fun update<T>(abstract_type: &mut AbstractType, keys: vector<String>, data: vector<vector<u8>>, schema: &Schema, overwrite_existing: bool, ctx: &mut TxContext) {
        display::update(&mut abstract_type.id, keys, data, schema, overwrite_existing, &tx_authority::begin(ctx));
    }

    public entry fun delete_optional<T>(abstract_type: &mut AbstractType, keys: vector<String>, schema: &Schema, ctx: &mut TxContext) {
        display::delete_optional(&mut abstract_type.id, keys, schema, &tx_authority::begin(ctx));
    }

    public entry fun delete_all<T>(abstract_type: &mut AbstractType, schema: &Schema, ctx: &mut TxContext) {
        display::delete_all(&mut abstract_type.id, schema, &tx_authority::begin(ctx));
    }

    public entry fun migrate<T>(
        abstract_type: &mut AbstractType,
        old_schema: &Schema,
        new_schema: &Schema,
        keys: vector<:String>,
        data: vector<vector<u8>>,
        ctx: &mut TxContext
    ) {
        display::migrate(&mut abstract_type.id, old_schema, new_schema, keys, data, &tx_authority::begin(ctx));
    }

    // ======== View Functions =====

    // AbstractType serves as a convenient display fallback
    public fun view_with_default<T>(
        uid: &UID,
        fallback_type: &AbstractType,
        keys: vector<String>,
        schema: &Schema,
        fallback_schema: &Schema,
    ): vector<u8> {
        let struct_tag = option::destroy_some(ownership::get_type(uid));
        assert!(
            struct_tag::is_same_abstract_type(&fallback_type.type, &struct_tag),
            EABSTRACT_DOES_NOT_MATCH_CONCRETE);

        display::view_with_default(uid, &fallback_type.id, keys, schema, fallback_schema)
    }

    // ======== For Owners ========

    public fun extend<T: store>(abstract: &mut AbstractType, auth: &TxAuthority): &mut UID {
        assert!(ownership::is_authorized_by_owner(&abstract.id, auth), ENO_OWNER_AUTHORITY);

        &mut abstract.id
    }

    public fun update_schema_id(abstract: &mut AbstractType, new_schema_id: vector<u8>, auth: &TxAuthority) {
        assert!(ownership::is_authorized_by_owner(&abstract.id, auth), ENO_OWNER_AUTHORITY);
        assert!(vector::length(&new_schema_id) == 32, EINVALID_SCHEMA_ID);

        abstract.schema_id = new_schema_id;
    }
}