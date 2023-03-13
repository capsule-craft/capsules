module metadata::package {
    use std::ascii;
    use sui::tx_context::TxContext;
    use sui::object::{Self, UID, ID};
    use sui::transfer;
    use sui::typed_id;

    use metadata::metadata;
    use metadata::schema::Schema;
    
    use ownership::ownership;
    use ownership::tx_authority;

    friend metadata::creator;

    // Error enums
    const EBAD_WITNESS: u64 = 0;
    const ESENDER_UNAUTHORIZED: u64 = 1;

    struct Witness has drop {}

    // Owned, root-level object. Cannot be destroyed. Unique by package ID.
    struct Package has key {
        id: UID,
        package: ID,
        creator: ID // this is denormalized data; makes it more convenient to find creators
    }

    // Only metadata::creator can create Package Metadata
    public(friend) fun define(package: ID, creator: ID, ctx: &mut TxContext): Package {
        let package = Package { id: object::new(ctx), package, creator };

        // Renounce control of this asset so that the owner can attach metadata independently of us
        let auth = tx_authority::begin_with_type(&Witness { });
        let typed_id = typed_id::new(&package);
        ownership::initialize_without_module_authority(&mut package.id, typed_id, &auth);
        ownership::as_owned_object(&mut package.id, &auth);

        package
    }

    // ======== Metadata Module API =====
    // For convenience, we replicate the Metadata Module API here to make it easier to access Package's UID.

    public entry fun attach(package: &mut Package, data: vector<vector<u8>>, schema: &Schema) {
        metadata::attach(&mut package.id, data, schema, &tx_authority::empty());
    }

    public entry fun update(
        package: &mut Package,
        keys: vector<ascii::String>,
        data: vector<vector<u8>>,
        schema: &Schema,
        overwrite_existing: bool
    ) {
        metadata::update(&mut package.id, keys, data, schema, overwrite_existing, &tx_authority::empty());
    }

    public entry fun delete_optional(package: &mut Package, keys: vector<ascii::String>, schema: &Schema) {
        metadata::delete_optional(&mut package.id, keys, schema, &tx_authority::empty());
    }

    public entry fun delete_all(package: &mut Package, schema: &Schema) {
        metadata::delete_all(&mut package.id, schema, &tx_authority::empty());
    }

    public entry fun migrate(
        package: &mut Package,
        old_schema: &Schema,
        new_schema: &Schema,
        keys: vector<ascii::String>,
        data: vector<vector<u8>>
    ) {
        metadata::migrate(&mut package.id, old_schema, new_schema, keys, data, &tx_authority::empty());
    }

    // ======== For Owners =====

    // Makes the metadata immutable. This cannot be undone
    public entry fun freeze_(package: Package) {
        transfer::freeze_object(package);
    }

    // Because Package lacks `store`, polymorphic transfer does not work outside of this module
    public entry fun transfer(package: Package, new_owner: address) {
        transfer::transfer(package, new_owner);
    }

    // Owned object; no need for an ownership check
    public fun extend(package: &mut Package): &mut UID {
        &mut package.id
    }
}