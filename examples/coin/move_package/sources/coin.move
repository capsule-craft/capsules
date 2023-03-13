// This demonstrates how the Capsules Metadata program can replace CoinMetadata. It provides a more
// general and powerful metadata system.
//
// This also generalizes the creation of new currencies; you can now create new Coin<T>'s arbitrarily
// per type `T`, not just once per package and only at deploy-time.

module sui_examples::coin {
    use std::ascii;
    use std::option;
    use sui::balance::{Self, Balance, Supply};
    use sui::tx_context::TxContext;
    use sui::object::{Self, UID};
    use sui::tx_context;
    use sui::typed_id;
    use sui::transfer;
    use std::vector;
    use sui::event;
    use ownership::ownership;
    use ownership::tx_authority;
    use metadata::abstract_type::{Self, AbstractType};
    use metadata::metadata;
    use metadata::type::{Self, Type};
    use metadata::schema::{Self, Schema};
    use metadata::publish_receipt;
    use sui_utils::ascii2;

    /// For when invalid arguments are passed to a function.
    const EInvalidArg: u64 = 1;

    /// For when trying to split a coin more times than its balance allows.
    const ENotEnough: u64 = 2;

    /// Owned object. A coin of type `T` worth `balance`.
    struct Coin<phantom T> has key, store {
        id: UID,
        balance: Balance<T>
    }

    // Owned capability object. Allows the bearer to mint and burn Coin<T>
    struct TreasuryCap<phantom T> has key, store {
        id: UID,
        total_supply: Supply<T>
    }

    struct Witness has drop { }
    struct COIN has drop { }

    const METADATA_SCHEMA: vector<vector<vector<u8>>> = vector[ 
        vector[b"decimals", b"u8"], 
        vector[b"name", b"String"], 
        vector[b"symbol", b"String"], 
        vector[b"description", b"String"], 
        vector[b"icon_url", b"Option<String>"]
    ];

    // === Events ===

    /// Emitted when new currency is created through the `create_currency` call.
    /// Contains currency metadata for off-chain discovery. Type parameter `T`
    /// matches the one in `Coin<T>`
    struct CurrencyCreated<phantom T> has copy, drop {
        /// Number of decimal places the coin uses.
        /// A coin with `value ` N and `decimals` D should be shown as N / 10^D
        /// E.g., a coin with `value` 7002 and decimals 3 should be displayed as 7.002
        /// This is metadata for display usage only.
        decimals: u8
    }

    /// Create a new currency type `T` as and return `TreasuryCap<T>` and `Type<T>` metadata
    /// object to the caller.
    /// Note that the default sui::coin module uses one-time-witnesses to guarantee that these are
    /// singleton objects, whereas we use abstract types to ensure that Coin<T> is unique per type `T`.
    public fun create_currency<T: drop>(
        witness: T,
        abstract_type: &mut AbstractType,
        data: vector<vector<u8>>,
        schema: &Schema,
        ctx: &mut TxContext
    ): (TreasuryCap<T>, Type<Coin<T>>) {
        let treasury_cap = TreasuryCap {
            id: object::new(ctx),
            total_supply: balance::create_supply(witness)
        };
        let auth = tx_authority::begin_with_type(&Witness { });
        let type = abstract_type::define_from_abstract_<Coin<T>>(abstract_type, data, schema, &auth, ctx);

        // Emit Currency metadata as an event.
        let uid = type::extend(&mut type);
        let decimals = *metadata::borrow(uid, ascii::string(b"decimals"));
        event::emit(CurrencyCreated<T> { decimals });

        (treasury_cap, type)
    }

    // As an alternative approach, we can skip creating the schema object and just compute
    // the schema id directly, like this:
    // let schema_id = schema::compute_schema_id_(schema_fields);
    fun init(genesis: COIN, ctx: &mut TxContext) {
        let receipt = publish_receipt::claim(&genesis, ctx);

        let schema_fields = ascii2::vec_bytes_to_vec_strings(METADATA_SCHEMA);
        let schema = schema::create_(schema_fields, ctx);

        let witness = tx_authority::type_into_address<Witness>();
        let sender = tx_context::sender(ctx);

        abstract_type::create<Coin<Witness>>(&mut receipt, vector[witness, sender], schema, ctx);
        transfer::transfer(receipt, sender);
    }

    // The schema is statically embedded into this package here
    const INDIVIDUAL_METADATA_SCHEMA: vector<vector<vector<u8>>> = vector[ 
        vector[b"icon_url", b"Option<String>"],
        vector[b"memo", b"String"]
    ];

    // This shows how metadata can be attached to individual coins, in addition to the Type generally.
    // In this case, our schema is statically embedded into this package
    public entry fun attach_metadata<T>(coin: &mut Coin<T>, data: vector<vector<u8>>, ctx: &mut TxContext) {
        let auth = tx_authority::begin_with_type(&Witness {});
        let typed_id = typed_id::new(coin);
        let schema_fields = ascii2::vec_bytes_to_vec_strings(INDIVIDUAL_METADATA_SCHEMA);
        let schema = schema::create_(schema_fields, ctx);

        ownership::initialize_with_module_authority(&mut coin.id, typed_id, &auth);
        ownership::as_owned_object(&mut coin.id, &auth);
        metadata::attach(&mut coin.id, data, &schema, &auth);

        schema::return_and_destroy(schema);
    }

    // This shows how we can view coins. This is not really needed; we can just call metadata::view(uid)
    // directly
    public fun view<T>(coin: &Coin<T>, schema: &Schema): vector<u8> {
        metadata::view_all(&coin.id, schema)
    }

    public fun extend<T>(coin: &mut Coin<T>): &mut UID {
        &mut coin.id
    }

    // === Supply <-> TreasuryCap morphing and accessors  ===

    /// Return the total number of `T`'s in circulation.
    public fun total_supply<T>(cap: &TreasuryCap<T>): u64 {
        balance::supply_value(&cap.total_supply)
    }

    /// Unwrap `TreasuryCap` getting the `Supply`.
    ///
    /// Operation is irreversible. Supply cannot be converted into a `TreasuryCap` due
    /// to different security guarantees (TreasuryCap can be created only once for a type)
    public fun treasury_into_supply<T>(treasury: TreasuryCap<T>): Supply<T> {
        let TreasuryCap { id, total_supply } = treasury;
        object::delete(id);
        total_supply
    }

    /// Get immutable reference to the treasury's `Supply`.
    public fun supply<T>(treasury: &mut TreasuryCap<T>): &Supply<T> {
        &treasury.total_supply
    }

    /// Get mutable reference to the treasury's `Supply`.
    public fun supply_mut<T>(treasury: &mut TreasuryCap<T>): &mut Supply<T> {
        &mut treasury.total_supply
    }

    // === Balance <-> Coin accessors and type morphing ===

    /// Public getter for the coin's value
    public fun value<T>(self: &Coin<T>): u64 {
        balance::value(&self.balance)
    }

    /// Get immutable reference to the balance of a coin.
    public fun balance<T>(coin: &Coin<T>): &Balance<T> {
        &coin.balance
    }

    /// Get a mutable reference to the balance of a coin.
    public fun balance_mut<T>(coin: &mut Coin<T>): &mut Balance<T> {
        &mut coin.balance
    }

    /// Wrap a balance into a Coin to make it transferable.
    public fun from_balance<T>(balance: Balance<T>, ctx: &mut TxContext): Coin<T> {
        Coin { id: object::new(ctx), balance }
    }

    /// Destruct a Coin wrapper and keep the balance.
    public fun into_balance<T>(coin: Coin<T>): Balance<T> {
        let Coin { id, balance } = coin;
        object::delete(id);
        balance
    }

    /// Take a `Coin` worth of `value` from `Balance`.
    /// Aborts if `value > balance.value`
    public fun take<T>(
        balance: &mut Balance<T>, value: u64, ctx: &mut TxContext,
    ): Coin<T> {
        Coin {
            id: object::new(ctx),
            balance: balance::split(balance, value)
        }
    }

    spec take {
        let before_val = balance.value;
        let post after_val = balance.value;
        ensures after_val == before_val - value;

        aborts_if value > before_val;
        aborts_if ctx.ids_created + 1 > MAX_U64;
    }

    /// Put a `Coin<T>` to the `Balance<T>`.
    public fun put<T>(balance: &mut Balance<T>, coin: Coin<T>) {
        balance::join(balance, into_balance(coin));
    }

    spec put {
        let before_val = balance.value;
        let post after_val = balance.value;
        ensures after_val == before_val + coin.balance.value;

        aborts_if before_val + coin.balance.value > MAX_U64;
    }

    // === Base Coin functionality ===

    /// Consume the coin `c` and add its value to `self`.
    /// Aborts if `c.value + self.value > U64_MAX`
    public entry fun join<T>(self: &mut Coin<T>, c: Coin<T>) {
        let Coin { id, balance } = c;
        object::delete(id);
        balance::join(&mut self.balance, balance);
    }

    spec join {
        let before_val = self.balance.value;
        let post after_val = self.balance.value;
        ensures after_val == before_val + c.balance.value;

        aborts_if before_val + c.balance.value > MAX_U64;
    }

    /// Split coin `self` to two coins, one with balance `split_amount`,
    /// and the remaining balance is left is `self`.
    public fun split<T>(
        self: &mut Coin<T>, split_amount: u64, ctx: &mut TxContext
    ): Coin<T> {
        take(&mut self.balance, split_amount, ctx)
    }

    spec split {
        let before_val = self.balance.value;
        let post after_val = self.balance.value;
        ensures after_val == before_val - split_amount;

        aborts_if split_amount > before_val;
        aborts_if ctx.ids_created + 1 > MAX_U64;
    }

    /// Split coin `self` into `n - 1` coins with equal balances. The remainder is left in
    /// `self`. Return newly created coins.
    public fun divide_into_n<T>(
        self: &mut Coin<T>, n: u64, ctx: &mut TxContext
    ): vector<Coin<T>> {
        assert!(n > 0, EInvalidArg);
        assert!(n <= value(self), ENotEnough);

        let vec = vector::empty<Coin<T>>();
        let i = 0;
        let split_amount = value(self) / n;
        while ({
            spec {
                invariant i <= n-1;
                invariant self.balance.value == old(self).balance.value - (i * split_amount);
                invariant ctx.ids_created == old(ctx).ids_created + i;
            };
            i < n - 1
        }) {
            vector::push_back(&mut vec, split(self, split_amount, ctx));
            i = i + 1;
        };
        vec
    }

    spec divide_into_n {
        let before_val = self.balance.value;
        let post after_val = self.balance.value;
        let split_amount = before_val / n;
        ensures after_val == before_val - ((n - 1) * split_amount);

        aborts_if n == 0;
        aborts_if self.balance.value < n;
        aborts_if ctx.ids_created + n - 1 > MAX_U64;
    }

    /// Make any Coin with a zero value. Useful for placeholding
    /// bids/payments or preemptively making empty balances.
    public fun zero<T>(ctx: &mut TxContext): Coin<T> {
        Coin { id: object::new(ctx), balance: balance::zero() }
    }

    /// Destroy a coin with value zero
    public fun destroy_zero<T>(c: Coin<T>) {
        let Coin { id, balance } = c;
        object::delete(id);
        balance::destroy_zero(balance)
    }

    // === Managing the coin supply ===

    /// Create a coin worth `value`. and increase the total supply
    /// in `cap` accordingly.
    public fun mint<T>(
        cap: &mut TreasuryCap<T>, value: u64, ctx: &mut TxContext,
    ): Coin<T> {
        Coin {
            id: object::new(ctx),
            balance: balance::increase_supply(&mut cap.total_supply, value)
        }
    }

    spec schema MintBalance<T> {
        cap: TreasuryCap<T>;
        value: u64;

        let before_supply = cap.total_supply.value;
        let post after_supply = cap.total_supply.value;
        ensures after_supply == before_supply + value;

        aborts_if before_supply + value >= MAX_U64;
    }

    spec mint {
        include MintBalance<T>;
        aborts_if ctx.ids_created + 1 > MAX_U64;
    }

    /// Mint some amount of T as a `Balance` and increase the total
    /// supply in `cap` accordingly.
    /// Aborts if `value` + `cap.total_supply` >= U64_MAX
    public fun mint_balance<T>(
        cap: &mut TreasuryCap<T>, value: u64
    ): Balance<T> {
        balance::increase_supply(&mut cap.total_supply, value)
    }

    spec mint_balance {
        include MintBalance<T>;
    }

    /// Destroy the coin `c` and decrease the total supply in `cap`
    /// accordingly.
    public fun burn<T>(cap: &mut TreasuryCap<T>, c: Coin<T>): u64 {
        let Coin { id, balance } = c;
        object::delete(id);
        balance::decrease_supply(&mut cap.total_supply, balance)
    }

    spec schema Burn<T> {
        cap: TreasuryCap<T>;
        c: Coin<T>;

        let before_supply = cap.total_supply.value;
        let post after_supply = cap.total_supply.value;
        ensures after_supply == before_supply - c.balance.value;

        aborts_if before_supply < c.balance.value;
    }

    spec burn {
        include Burn<T>;
    }

    // === Entrypoints ===

    /// Mint `amount` of `Coin` and send it to `recipient`. Invokes `mint()`.
    public entry fun mint_and_transfer<T>(
        c: &mut TreasuryCap<T>, amount: u64, recipient: address, ctx: &mut TxContext
    ) {
        transfer::transfer(mint(c, amount, ctx), recipient)
    }

    /// Burn a Coin and reduce the total_supply. Invokes `burn()`.
    public entry fun burn_<T>(cap: &mut TreasuryCap<T>, c: Coin<T>) {
        burn(cap, c);
    }

    spec burn_ {
        include Burn<T>;
    }

    // === Test-only code ===

    #[test_only]
    /// Mint coins of any type for (obviously!) testing purposes only
    public fun mint_for_testing<T>(value: u64, ctx: &mut TxContext): Coin<T> {
        Coin { id: object::new(ctx), balance: balance::create_for_testing(value) }
    }

    #[test_only]
    /// Destroy a `Coin` with any value in it for testing purposes.
    public fun destroy_for_testing<T>(self: Coin<T>): u64 {
        let Coin { id, balance } = self;
        object::delete(id);
        balance::destroy_for_testing(balance)
    }
}