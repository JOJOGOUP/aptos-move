module Aptoswap::pool {
    use std::string;
    use std::signer;
    use std::option;
    use aptos_std::event::{ Self, EventHandle };
    use aptos_framework::managed_coin;
    use aptos_framework::coin;
    use aptos_framework::account;
    use aptos_framework::timestamp;
    const NUMBER_1E8: u128 = 100000000;

    const ERouteSwapDirectionForward: u8 = 0;
    const ERouteSwapDirectionReverse: u8 = 1;

    const EPoolTypeV2: u8 = 100;
    const EPoolTypeStableSwap: u8 = 101;

    const EFeeDirectionX: u8 = 200;
    const EFeeDirectionY: u8 = 201;

    /// For when supplied Coin is zero.
    const EInvalidParameter: u64 = 13400;
    /// For when pool fee is set incorrectly.  Allowed values are: [0-10000)
    const EWrongFee: u64 = 134001;
    /// For when someone tries to swap in an empty pool.
    const EReservesEmpty: u64 = 134002;
    /// For when initial LP amount is zero.02
    const EShareEmpty: u64 = 134003;
    /// For when someone attemps to add more liquidity than u128 Math allows.3
    const EPoolFull: u64 = 134004;
    /// For when the internal operation overflow.
    const EOperationOverflow: u64 = 134005;
    /// For when some intrinsic computation error detects
    const EComputationError: u64 = 134006;
    /// Can not operate this operation
    const EPermissionDenied: u64 = 134007;
    /// Not enough balance for operation
    const ENotEnoughBalance: u64 = 134008;
    /// Not coin registed
    const ECoinNotRegister: u64 = 134009;
    /// Pool freezes for operation
    const EPoolFreeze: u64 = 134010;
    /// Slippage limit error
    const ESlippageLimit: u64 = 134011;
    /// Pool not found
    const EPoolNotFound: u64 = 134012;
    /// Create duplicate pool
    const EPoolDuplicate: u64 = 134013;
    /// Stable coin decimal too large
    const ECreatePoolStableCoinDecimalTooLarge: u64 = 134014;
    /// No implementeed error code
    const ENoImplement: u64 = 134015;
    /// Deprecated
    const EDeprecated: u64 = 134016;

    /// The integer scaling setting for fees calculation.
    const BPS_SCALING: u128 = 10000;
    /// The maximum number of u64
    const U64_MAX: u128 = 18446744073709551615;
    /// The max decimal of stable swap coin
    const STABLESWAP_COIN_MAX_DECIMAL: u8 = 18;

    /// The interval between the snapshot in seconds
    const SNAPSHOT_INTERVAL_SEC: u64 = 900;
    /// The interval between the refreshing the total trade 24h
    const TOTAL_TRADE_24H_INTERVAL_SEC: u64 = 86400;
    /// The interval between captuing the bank amount
    const BANK_AMOUNT_SNAPSHOT_INTERVAL_SEC: u64 = 3600 * 6;

    struct PoolCreateEvent has drop, store {
        index: u64
    }

    struct SwapTokenEvent has drop, store {
        // When the direction is x to y or y to x
        x_to_y: bool,
        // The in token amount
        in_amount: u64,
        // The out token amount
        out_amount: u64,
    }

    struct LiquidityEvent has drop, store {
        // Whether it is a added/removed liqulity event or remove liquidity event
        is_added: bool,
        // The x amount to added/removed
        x_amount: u64,
        // The y amount to added/removed
        y_amount: u64,
        // The lp amount to added/removed
        lp_amount: u64
    }

    struct SnapshotEvent has drop, store {
        x: u64,
        y: u64
    }

    struct CoinAmountEvent has drop, store {
        amount: u64
    }

    struct SwapCap has key {
        /// Points to the next pool id that should be used
        pool_create_counter: u64,
        pool_create_event: EventHandle<PoolCreateEvent>,
    }

    struct Token { }
    struct TestToken { }

    struct TestTokenCapabilities has key {
        mint: coin::MintCapability<TestToken>,
        freeze: coin::FreezeCapability<TestToken>,
        burn: coin::BurnCapability<TestToken>,
    }

    struct LP<phantom X, phantom Y> {}

    struct LPCapabilities<phantom X, phantom Y> has key {
        mint: coin::MintCapability<LP<X, Y>>,
        freeze: coin::FreezeCapability<LP<X, Y>>,
        burn: coin::BurnCapability<LP<X, Y>>,
    }

    struct Bank<phantom X> has key {
        coin: coin::Coin<X>,
        coin_amount_event: EventHandle<CoinAmountEvent>,
        coin_amount_event_last_time: u64
    }

    struct Pool<phantom X, phantom Y> has key {
        /// The index of the pool
        index: u64,
        /// The pool type
        pool_type: u8,
        /// The balance of X token in the pool
        x: coin::Coin<X>,
        /// The balance of token in the pool
        y: coin::Coin<Y>,
        /// The current lp supply value as u64
        lp_supply: u64,

        /// Affects how the admin fee and connect fee are extracted.
        /// For a pool with quote coin X and base coin Y. 
        /// - When `fee_direction` is EFeeDirectionX, we always
        /// collect quote coin X for admin_fee & conY. 
        /// - When `fee_direction` is EFeeDirectionY, we always 
        /// collect base coin Y for admin_fee & connect_fee.
        fee_direction: u8,

        /// Admin fee is denominated in basis points, in bps
        admin_fee: u64,
        /// Liqudity fee is denominated in basis points, in bps
        lp_fee: u64,
        /// Fee for incentive
        incentive_fee: u64,
        /// Fee when connect to a token reward pool
        connect_fee: u64,
        /// Fee when user withdraw lp token
        withdraw_fee: u64,

        /// Stable pool amplifier
        stable_amp: u64, 
        /// The scaling factor that aligns x's decimal to 18
        stable_x_scale: u64,
        /// The scaling factor that aligns y's decimal to 18
        stable_y_scale: u64,
        
        /// Whether the pool is freezed for swapping and adding liquidity
        freeze: bool,

        /// Last trade time
        last_trade_time: u64,

        /// Number of x has been traded
        total_trade_x: u128,
        /// Number of y has been traded
        total_trade_y: u128,

        /// Total trade 24h last capture time
        total_trade_24h_last_capture_time: u64,
        /// Number of x has been traded (in one day)
        total_trade_x_24h: u128,
        /// Number of y has been traded (in one day)
        total_trade_y_24h: u128,

        /// The term "ksp_e7" means (K / lp * 10^8), record in u128 format
        // ksp_e8_sma: WeeklySmaU128,

        /// Swap token events
        swap_token_event: EventHandle<SwapTokenEvent>,
        /// Add liquidity events
        liquidity_event: EventHandle<LiquidityEvent>,
        /// Snapshot events
        snapshot_event: EventHandle<SnapshotEvent>,
        /// Snapshot last capture time (in sec)
        snapshot_last_capture_time: u64
    }

    // ============================================= Entry points =============================================
    public entry fun initialize(owner: &signer) {
        initialize_impl(owner);
    }

    public entry fun create_pool<X, Y>(owner: &signer, fee_direction: u8, admin_fee: u64, lp_fee: u64, incentive_fee: u64, connect_fee: u64, withdraw_fee: u64) acquires SwapCap, Pool {
        let _ = create_pool_impl<X, Y>(owner, EPoolTypeV2, fee_direction, admin_fee, lp_fee, incentive_fee, connect_fee, withdraw_fee, 0);
    }

    public entry fun create_stable_pool<X, Y>(owner: &signer, fee_direction: u8, admin_fee: u64, lp_fee: u64, incentive_fee: u64, connect_fee: u64, withdraw_fee: u64, amp: u64) acquires SwapCap, Pool {
        let _ = create_pool_impl<X, Y>(owner, EPoolTypeStableSwap, fee_direction, admin_fee, lp_fee, incentive_fee, connect_fee, withdraw_fee, amp);
    }

    public entry fun add_liquidity<X, Y>(user: &signer, x_added: u64, y_added: u64) acquires Pool, LPCapabilities {
        add_liquidity_impl<X, Y>(user, x_added, y_added);
    }

    public entry fun remove_liquidity<X, Y>(user: &signer, lsp_amount: u64) acquires Pool, LPCapabilities, Bank {
        remove_liquidity_impl<X, Y>(user, lsp_amount, timestamp::now_seconds());
    }

    public entry fun swap_x_to_y<X, Y>(user: &signer, in_amount: u64, min_out_amount: u64) acquires Pool, Bank {
        swap_x_to_y_impl<X, Y>(user, in_amount, min_out_amount, timestamp::now_seconds());
    }

    public entry fun swap_y_to_x<X, Y>(user: &signer, in_amount: u64, min_out_amount: u64) acquires Pool, Bank {
        swap_y_to_x_impl<X, Y>(user, in_amount, min_out_amount, timestamp::now_seconds());
    }

    // ============================================= Implementations =============================================
    public(friend) fun initialize_impl(admin: &signer) {
        assert!(signer::address_of(admin) == @Aptoswap, EPermissionDenied);

        let aptos_cap = SwapCap {
            pool_create_counter: 0,
            pool_create_event: account::new_event_handle<PoolCreateEvent>(admin),
        };

        move_to(admin, aptos_cap);
    }


    public(friend) fun create_pool_impl<X, Y>(owner: &signer, pool_type: u8, fee_direction: u8, admin_fee: u64, lp_fee: u64, incentive_fee: u64, connect_fee: u64, withdraw_fee: u64, amp: u64): address acquires SwapCap, Pool {
        validate_admin(owner);

        let owner_addr = signer::address_of(owner);

        assert!(fee_direction == EFeeDirectionX || fee_direction == EFeeDirectionY, EInvalidParameter);
        assert!(pool_type == EPoolTypeV2 || pool_type == EPoolTypeStableSwap, EInvalidParameter);
        
        assert!(lp_fee >= 0 && admin_fee >= 0 && incentive_fee >= 0 && connect_fee >= 0, EWrongFee);
        assert!(lp_fee + admin_fee + incentive_fee + connect_fee < (BPS_SCALING as u64), EWrongFee);
        assert!(withdraw_fee < (BPS_SCALING as u64), EWrongFee);

        // Note: we restrict the owner to the admin, which is @Aptoswap in create_pool 
        let pool_account = owner;
        let pool_account_addr = owner_addr;
        assert!(pool_account_addr == @Aptoswap, EPermissionDenied); // We can delete it, leave it here

        let aptos_cap = borrow_global_mut<SwapCap>(owner_addr);
        let pool_index = aptos_cap.pool_create_counter;
        aptos_cap.pool_create_counter = aptos_cap.pool_create_counter + 1;

        // Check whether the pool we've created
        assert!(!exists<Pool<X, Y>>(pool_account_addr), EPoolDuplicate);

        // Get the coin scale for x and y, used for stable
        let stable_x_scale: u64 = 0;
        let stable_y_scale: u64 = 0;
        if (pool_type == EPoolTypeStableSwap) {
            
            let x_decimal = coin::decimals<X>();
            let y_decimal = coin::decimals<Y>();

            assert!(x_decimal <= STABLESWAP_COIN_MAX_DECIMAL && y_decimal <= STABLESWAP_COIN_MAX_DECIMAL, ECreatePoolStableCoinDecimalTooLarge);
            assert!(amp > 0, EInvalidParameter);

            stable_x_scale = pow10(STABLESWAP_COIN_MAX_DECIMAL - x_decimal);
            stable_y_scale = pow10(STABLESWAP_COIN_MAX_DECIMAL - x_decimal);
        };

        // Create pool and move
        let pool = Pool<X, Y> {
            index: pool_index,
            pool_type: pool_type,

            x: coin::zero<X>(),
            y: coin::zero<Y>(),
            lp_supply: 0,

            fee_direction: fee_direction,

            admin_fee: admin_fee,
            lp_fee: lp_fee,
            incentive_fee: incentive_fee,
            connect_fee: connect_fee,
            withdraw_fee: withdraw_fee,

            stable_amp: amp,
            stable_x_scale: stable_x_scale,
            stable_y_scale: stable_y_scale,

            freeze: false,

            last_trade_time: 0,

            total_trade_x: 0,
            total_trade_y: 0,

            total_trade_24h_last_capture_time: 0,
            total_trade_x_24h: 0,
            total_trade_y_24h: 0,

            // ksp_e8_sma: create_sma128(),

            swap_token_event: account::new_event_handle<SwapTokenEvent>(pool_account),
            liquidity_event: account::new_event_handle<LiquidityEvent>(pool_account),
            snapshot_event: account::new_event_handle<SnapshotEvent>(pool_account),

            snapshot_last_capture_time: 0
        };
        move_to(pool_account, pool);

        // Register coin if needed for pool account
        register_coin_if_needed<X>(pool_account);
        register_coin_if_needed<Y>(pool_account);
        if (!exists<Bank<X>>(pool_account_addr)) {
            move_to(pool_account, empty_bank<X>(pool_account));
        };
        if (!exists<Bank<Y>>(pool_account_addr)) {
            move_to(pool_account, empty_bank<Y>(pool_account));
        };


        // Initialize the LP<X, Y> token and transfer the ownership to pool account 
        let (burn_cap, freeze_cap, mint_cap) = coin::initialize<LP<X, Y>>(
            owner, 
            string::utf8(b"PNG Pool Token"),
            string::utf8(b"PNG_LP"),
            0, 
            true
        );
        let lp_cap = LPCapabilities<X, Y> {
            mint: mint_cap,
            freeze: freeze_cap,
            burn: burn_cap
        };
        move_to(pool_account, lp_cap);

        // Register the lp token for the pool account 
        managed_coin::register<LP<X, Y>>(pool_account);

        let pool = borrow_global<Pool<X, Y>>(pool_account_addr);
        validate_lp(pool);

        // Emit event
        event::emit_event(
            &mut aptos_cap.pool_create_event,
            PoolCreateEvent {
                index: pool_index
            }
        );

        pool_account_addr
    }
    
    public(friend) fun add_liquidity_impl<X, Y>(user: &signer, x_added: u64, y_added: u64) acquires Pool, LPCapabilities {

        let pool_account_addr = @Aptoswap;

        let user_addr = signer::address_of(user);

        assert!(x_added > 0 && y_added > 0, EInvalidParameter);
        assert!(exists<Pool<X, Y>>(pool_account_addr), EPoolNotFound);
        assert!(coin::is_account_registered<X>(user_addr), ECoinNotRegister);
        assert!(coin::is_account_registered<Y>(user_addr), ECoinNotRegister);
        assert!(x_added <= coin::balance<X>(user_addr), ENotEnoughBalance);
        assert!(y_added <= coin::balance<Y>(user_addr), ENotEnoughBalance);

        let pool = borrow_global_mut<Pool<X, Y>>(pool_account_addr);
        assert!(pool.freeze == false, EPoolFreeze);

        let (x_amt, y_amt, lsp_supply) = get_amounts(pool);
        let share_minted = if (lsp_supply > 0) {
            // When it is not a intialized the deposit, we compute the amount of minted lsp by
            // not reducing the "token / lsp" value.

            // We should make the value "token / lsp" larger than the previous value before adding liqudity
            // Thus 
            // (token + dtoken) / (lsp + dlsp) >= token / lsp
            //  ==> (token + dtoken) * lsp >= token * (lsp + dlsp)
            //  ==> dtoken * lsdp >= token * dlsp
            //  ==> dlsp <= dtoken * lsdp / token
            //  ==> dslp = floor[dtoken * lsdp / token] <= dtoken * lsdp / token
            // We use the floor operation
            let x_shared_minted: u128 = ((x_added as u128) * (lsp_supply as u128)) / (x_amt as u128);
            let y_shared_minted: u128 = ((y_added as u128) * (lsp_supply as u128)) / (y_amt as u128);
            let share_minted: u128 = if (x_shared_minted < y_shared_minted) { x_shared_minted } else { y_shared_minted };
            let share_minted: u64 = (share_minted as u64);
            share_minted
        } else {
            // When it is a initialzed deposit, we compute using sqrt(x_added) * sqrt(y_added)
            let share_minted: u64 = 1000;
            share_minted
        };


        // Transfer the X, Y to the pool and transfer 
        let mint_cap = &borrow_global<LPCapabilities<X, Y>>(pool_account_addr).mint;

        // Depsoit the coin to user
        register_coin_if_needed<LP<X, Y>>(user);
        coin::deposit<LP<X, Y>>(
            user_addr,
            coin::mint<LP<X, Y>>(
                share_minted,
                mint_cap
            )
        );
        // 1. pool.x = pool.x + x_added;
        coin::merge(&mut pool.x, coin::withdraw(user, x_added));
        // 2. pool.y = pool.y + y_added;
        coin::merge(&mut pool.y, coin::withdraw(user, y_added));
        pool.lp_supply = pool.lp_supply + share_minted;

        // Check:
        // x_amt / lsp_supply <= x_amt_after / lsp_supply_after
        //    ==> x_amt * lsp_supply_after <= x_amt_after * lsp_supply
        let (x_amt_after, y_amt_after, lsp_supply_after) = get_amounts(pool); {
            let x_amt_ = (x_amt as u128);
            let y_amt_ = (y_amt as u128);
            let lsp_supply_ = (lsp_supply as u128);
            let x_amt_after_ = (x_amt_after as u128);
            let y_amt_after_ = (y_amt_after as u128);
            let lsp_supply_after_ = (lsp_supply_after as u128);
            assert!(x_amt_ * lsp_supply_after_ <= x_amt_after_ * lsp_supply_, EComputationError);
            assert!(y_amt_ * lsp_supply_after_ <= y_amt_after_ * lsp_supply_, EComputationError);
        };

        validate_lp(pool);

        event::emit_event(
            &mut pool.liquidity_event,
            LiquidityEvent {
                is_added: true,
                x_amount: x_added,
                y_amount: y_added,
                lp_amount: share_minted
            }
        );
    }

    public(friend) fun remove_liquidity_impl<X, Y>(user: &signer, lsp_amount: u64, current_time: u64) acquires Pool, LPCapabilities, Bank {

        let pool_account_addr = @Aptoswap;

        let user_addr = signer::address_of(user);

        assert!(lsp_amount > 0, EInvalidParameter);
        assert!(coin::is_account_registered<LP<X, Y>>(user_addr), ECoinNotRegister);
        assert!(lsp_amount <= coin::balance<LP<X, Y>>(user_addr), ENotEnoughBalance);

        // Note: We don't need freeze check, user can still burn lsp token and get original token when pool
        // is freeze
        let pool = borrow_global_mut<Pool<X, Y>>(pool_account_addr);

        // We should make the value "token / lsp" larger than the previous value before removing liqudity
        // Thus 
        // (token - dtoken) / (lsp - dlsp) >= token / lsp
        //  ==> (token - dtoken) * lsp >= token * (lsp - dlsp)
        //  ==> -dtoken * lsp >= -token * dlsp
        //  ==> dtoken * lsp <= token * dlsp
        //  ==> dtoken <= token * dlsp / lsp
        //  ==> dtoken = floor[token * dlsp / lsp] <= token * dlsp / lsp
        // We use the floor operation
        let (x_amt, y_amt, lsp_supply) = get_amounts(pool);
        let x_removed = ((x_amt as u128) * (lsp_amount as u128)) / (lsp_supply as u128);
        let y_removed = ((y_amt as u128) * (lsp_amount as u128)) / (lsp_supply as u128);

        let x_removed = (x_removed as u64);
        let y_removed = (y_removed as u64);

        let burn_cap = &borrow_global<LPCapabilities<X, Y>>(pool_account_addr).burn;

        // 1. pool.x = pool.x - x_removed;
        let coin_x_removed = coin::extract(&mut pool.x, x_removed);
        // 2. pool.y = pool.y - y_removed;
        let coin_y_removed = coin::extract(&mut pool.y, y_removed);

        // Deposit the withdraw fee to the admin
        collect_admin_fee(&mut coin_x_removed, pool.withdraw_fee, current_time);
        collect_admin_fee(&mut coin_y_removed, pool.withdraw_fee, current_time);

        pool.lp_supply = pool.lp_supply - lsp_amount;
        register_coin_if_needed<X>(user);
        register_coin_if_needed<Y>(user);

        coin::deposit(user_addr, coin_x_removed);
        coin::deposit(user_addr, coin_y_removed);

        coin::burn_from<LP<X, Y>>(user_addr, lsp_amount, burn_cap);

        // Check:
        // x_amt / lsp_supply <= x_amt_after / lsp_supply_after
        //    ==> x_amt * lsp_supply_after <= x_amt_after * lsp_supply
        let (x_amt_after, y_amt_after, lsp_supply_after) = get_amounts(pool); {
            let x_amt_ = (x_amt as u128);
            let y_amt_ = (y_amt as u128);
            let lsp_supply_ = (lsp_supply as u128);
            let x_amt_after_ = (x_amt_after as u128);
            let y_amt_after_ = (y_amt_after as u128);
            let lsp_supply_after_ = (lsp_supply_after as u128);
            assert!(x_amt_ * lsp_supply_after_ <= x_amt_after_ * lsp_supply_, EComputationError);
            assert!(y_amt_ * lsp_supply_after_ <= y_amt_after_ * lsp_supply_, EComputationError);
        };

        validate_lp(pool);

        event::emit_event(
            &mut pool.liquidity_event,
            LiquidityEvent {
                is_added: false,
                x_amount: x_removed,
                y_amount: y_removed,
                lp_amount: lsp_amount
            }
        );
    }

    public(friend) fun swap_x_to_y_impl<X, Y>(user: &signer, in_amount: u64, min_out_amount: u64, current_time: u64): u64 acquires Pool, Bank {
        let user_addr = signer::address_of(user);

        assert!(in_amount > 0, EInvalidParameter);
        register_coin_if_needed<X>(user);
        register_coin_if_needed<Y>(user);
        assert!(in_amount <= coin::balance<X>(user_addr), ENotEnoughBalance);

        let in_coin = coin::withdraw<X>(user, in_amount);
        let out_coin = swap_x_to_y_direct_impl<X, Y>(in_coin, current_time);
        let out_coin_value = coin::value(&out_coin);
        assert!(out_coin_value >= min_out_amount, ESlippageLimit);

        coin::deposit(user_addr, out_coin);

        out_coin_value
    }

    public(friend) fun swap_y_to_x_impl<X, Y>(user: &signer, in_amount: u64, min_out_amount: u64, current_time: u64): u64 acquires Pool, Bank {
        let user_addr = signer::address_of(user);

        assert!(in_amount > 0, EInvalidParameter);
        register_coin_if_needed<X>(user);
        register_coin_if_needed<Y>(user);
        assert!(in_amount <= coin::balance<Y>(user_addr), ENotEnoughBalance);

        let in_coin = coin::withdraw<Y>(user, in_amount);
        let out_coin = swap_y_to_x_direct_impl<X, Y>(in_coin, current_time);
        let out_coin_value = coin::value(&out_coin);
        assert!(out_coin_value >= min_out_amount, ESlippageLimit);

        coin::deposit(user_addr, out_coin);

        out_coin_value
    }

    public(friend) fun swap_x_to_y_direct_impl<X, Y>(in_coin: coin::Coin<X>, current_time: u64): coin::Coin<Y> acquires Pool, Bank {
        let pool_account_addr = @Aptoswap;

        let in_amount = coin::value(&in_coin);
        assert!(in_amount > 0, EInvalidParameter);
        
        let pool = borrow_global_mut<Pool<X, Y>>(pool_account_addr);
        assert!(pool.freeze == false, EPoolFreeze);

        let k_before = compute_k(pool);

        let (x_reserve_amt, y_reserve_amt, _) = get_amounts(pool);
        assert!(x_reserve_amt > 0 && y_reserve_amt > 0, EReservesEmpty);

        if (pool.fee_direction == EFeeDirectionX) {
            collect_admin_fee(&mut in_coin, get_total_admin_fee(pool), current_time);
        };

        let fee_coin = collect_fee(&mut in_coin, get_total_lp_fee(pool));

        // Get the output amount
        let output_amount = compute_amount(
            coin::value(&in_coin),
            x_reserve_amt,
            y_reserve_amt,
        );

        // 2. pool.x = pool.x + x_remain_amt + x_lp
        coin::merge(&mut pool.x, in_coin);
        coin::merge(&mut pool.x, fee_coin);

        // 3. pool.y = pool.y - output_amount
        let out_coin = coin::extract(&mut pool.y, output_amount);
        if (pool.fee_direction == EFeeDirectionY) {
            collect_admin_fee(&mut out_coin, get_total_admin_fee(pool), current_time);
        };

        let k_after = compute_k(pool);  
        assert!(k_after >= k_before, EComputationError);

        // Emit swap event
        event::emit_event(
            &mut pool.swap_token_event,
            SwapTokenEvent {
                x_to_y: true,
                in_amount: in_amount,
                out_amount: output_amount
            }
        );

        // Accumulate total_trade
        pool.total_trade_x = pool.total_trade_x + (in_amount as u128);
        pool.total_trade_y = pool.total_trade_y + (output_amount as u128);

        if (current_time > 0) {

            pool.last_trade_time = current_time;

            if (pool.total_trade_24h_last_capture_time + TOTAL_TRADE_24H_INTERVAL_SEC < current_time) {
                pool.total_trade_24h_last_capture_time = current_time;
                pool.total_trade_x_24h = 0;
                pool.total_trade_y_24h = 0;
            };

            pool.total_trade_x_24h = pool.total_trade_x_24h + (in_amount as u128);
            pool.total_trade_y_24h = pool.total_trade_y_24h + (output_amount as u128);

            // Emit snapshot event
            if (pool.snapshot_last_capture_time + SNAPSHOT_INTERVAL_SEC < current_time) {
                pool.snapshot_last_capture_time = current_time;
                event::emit_event(
                    &mut pool.snapshot_event,
                    SnapshotEvent {
                        x: coin::value(&pool.x),
                        y: coin::value(&pool.y)
                    }
                );
            };

            // Add ksp_e8 sma average
            // let ksp_e8: u128 = k_after * NUMBER_1E8 / (pool.lp_supply as u128);
            // add_sma128(&mut pool.ksp_e8_sma, current_time, ksp_e8);
        };

        out_coin
    }

    public(friend) fun swap_y_to_x_direct_impl<X, Y>(in_coin: coin::Coin<Y>, current_time: u64): coin::Coin<X> acquires Pool, Bank {
        let pool_account_addr = @Aptoswap;

        let in_amount = coin::value(&in_coin);
        assert!(in_amount > 0, EInvalidParameter);
        
        let pool = borrow_global_mut<Pool<X, Y>>(pool_account_addr);
        assert!(pool.freeze == false, EPoolFreeze);

        let k_before = compute_k(pool);

        let (x_reserve_amt, y_reserve_amt, _) = get_amounts(pool);
        assert!(x_reserve_amt > 0 && y_reserve_amt > 0, EReservesEmpty);

        if (pool.fee_direction == EFeeDirectionY) {
            collect_admin_fee(&mut in_coin, get_total_admin_fee(pool), current_time);
        };

        let fee_coin = collect_fee(&mut in_coin, get_total_lp_fee(pool));

        // Get the output amount
        let output_amount = compute_amount(
            coin::value(&in_coin),
            y_reserve_amt,
            x_reserve_amt,
        );

        // 2. pool.y = pool.y + y_remain_amt + y_lp;
        coin::merge(&mut pool.y, in_coin);
        coin::merge(&mut pool.y, fee_coin);

        // 3. pool.x = pool.x - output_amount;
        let out_coin = coin::extract(&mut pool.x, output_amount);
        if (pool.fee_direction == EFeeDirectionX) {
            collect_admin_fee(&mut out_coin, get_total_admin_fee(pool), current_time);
        };

        let k_after = compute_k(pool); 
        assert!(k_after >= k_before, EComputationError);

        // Emit swap event
        event::emit_event(
            &mut pool.swap_token_event,
            SwapTokenEvent {
                x_to_y: false,
                in_amount: in_amount,
                out_amount: output_amount
            }
        );

        // Accumulate total_trade
        pool.total_trade_y = pool.total_trade_y + (in_amount as u128);
        pool.total_trade_x = pool.total_trade_x + (output_amount as u128);

        if (current_time > 0) {

            pool.last_trade_time = current_time;

            if (pool.total_trade_24h_last_capture_time + TOTAL_TRADE_24H_INTERVAL_SEC < current_time) {
                pool.total_trade_24h_last_capture_time = current_time;
                pool.total_trade_x_24h = 0;
                pool.total_trade_y_24h = 0;
            };

            pool.total_trade_y_24h = pool.total_trade_y_24h + (in_amount as u128);
            pool.total_trade_x_24h = pool.total_trade_x_24h + (output_amount as u128);

            // Emit snapshot event
            if (pool.snapshot_last_capture_time + SNAPSHOT_INTERVAL_SEC < current_time) {
                pool.snapshot_last_capture_time = current_time;
                event::emit_event(
                    &mut pool.snapshot_event,
                    SnapshotEvent {
                        x: coin::value(&pool.x),
                        y: coin::value(&pool.y)
                    }
                );
            };

            // Add ksp_e8 sma average
            // let ksp_e8: u128 = k_after * NUMBER_1E8 / (pool.lp_supply as u128);
            // add_sma128(&mut pool.ksp_e8_sma, current_time, ksp_e8);
        };

        out_coin
    }

    /// Given dx (dx > 0), x and y. Ensure the constant product 
    /// market making (CPMM) equation fulfills after swapping:
    /// (x + dx) * (y - dy) = x * y
    /// Due to the integter operation, we change the equality into
    /// inequadity operation, i.e:
    /// (x + dx) * (y - dy) >= x * y
    public(friend) fun compute_amount(dx: u64, x: u64, y: u64): u64 {
        // (x + dx) * (y - dy) >= x * y
        //    ==> y - dy >= (x * y) / (x + dx)
        //    ==> dy <= y - (x * y) / (x + dx)
        //    ==> dy <= (y * dx) / (x + dx)
        //    ==> dy = floor[(y * dx) / (x + dx)] <= (y * dx) / (x + dx)
        let (dx, x, y) = ((dx as u128), (x as u128), (y as u128));
        
        let numerator: u128 = y * dx;
        let denominator: u128 = x + dx;
        let dy: u128 = numerator / denominator;
        assert!(dy <= U64_MAX, EOperationOverflow);

        // Addition liqudity check, should not happen
        let k_after: u128 = (x + dx) * (y - dy);
        let k_before: u128 = x * y;
        assert!(k_after >= k_before, EComputationError);

        (dy as u64)
    }

    public(friend) fun compute_k<T1,T2>(pool: &Pool<T1, T2>): u128 {
        let (x_amt, y_amt, _) = get_amounts(pool);
        (x_amt as u128) * (y_amt as u128)
    }

    public(friend) fun get_total_lp_fee<X, Y>(pool: &Pool<X, Y>): u64 {
        pool.lp_fee + pool.incentive_fee
    }

    public(friend) fun get_total_admin_fee<X, Y>(pool: &Pool<X, Y>): u64 {
        pool.admin_fee + pool.connect_fee
    }

    // ============================================= Helper Function =============================================

    fun validate_admin(user: &signer) {
        // assert!(exists<SwapCap>(user_addr), EPermissionDenied);
        assert!(signer::address_of(user) == @Aptoswap, EPermissionDenied);
    }

    fun register_coin_if_needed<X>(user: &signer) {
        if (!coin::is_account_registered<X>(signer::address_of(user))) {
            managed_coin::register<X>(user);
        };
    }

    fun empty_bank<X>(owner: &signer): Bank<X> {
        Bank<X> {
            coin: coin::zero<X>(),
            coin_amount_event: account::new_event_handle<CoinAmountEvent>(owner),
            coin_amount_event_last_time: 0
        }
    }

    

    fun validate_lp<X, Y>(pool: &Pool<X, Y>) {
        let lp_supply_checked = *option::borrow(&coin::supply<LP<X, Y>>());
        assert!(lp_supply_checked == (pool.lp_supply as u128), EComputationError);
    }
    
    fun pow10(num: u8): u64 {
        // Naive implementation, we can refine with quick pow, but currently it is not necessary
        let value: u64 = 1;
        let i: u8 = 0;

        while (i < num) {
            value = value * 10;
            i = i + 1;
        };

        value
    }

    public(friend) fun get_amounts<X, Y>(pool: &Pool<X, Y>): (u64, u64, u64) {
        (
            coin::value(&pool.x),
            coin::value(&pool.y), 
            pool.lp_supply
        )
    }

    public(friend) fun collect_admin_fee<T>(coin: &mut coin::Coin<T>, fee: u64, current_time: u64) acquires Bank {
        deposit_to_bank(
            borrow_global_mut<Bank<T>>(@Aptoswap),
            collect_fee(coin, fee),
            current_time
        );
    }

    public(friend) fun collect_fee<T>(coin: &mut coin::Coin<T>, fee: u64): coin::Coin<T> {
        let x = (coin::value(coin) as u128);
        let fee = (fee as u128);
        
        let x_fee_value = (((x * fee) / BPS_SCALING) as u64);
        let x_fee = coin::extract(coin, x_fee_value);
        x_fee
    }

    fun deposit_to_bank<X>(bank: &mut Bank<X>, c: coin::Coin<X>, current_time: u64) {
        // Merge coin
        coin::merge(&mut bank.coin, c);

        // Capture the event if needed
        if (current_time > 0) {
            if (bank.coin_amount_event_last_time + BANK_AMOUNT_SNAPSHOT_INTERVAL_SEC < current_time) {
                bank.coin_amount_event_last_time = current_time;
                event::emit_event(&mut bank.coin_amount_event, CoinAmountEvent { 
                    amount: coin::value(&bank.coin)
                });
            }
        }
    }

    public(friend) fun sqrt(x: u64): u64 {
        let bit = 1u128 << 64;
        let res = 0u128;
        let x = (x as u128);

        while (bit != 0) {
            if (x >= res + bit) {
                x = x - (res + bit);
                res = (res >> 1) + bit;
            } else {
                res = res >> 1;
            };
            bit = bit >> 2;
        };

        (res as u64)
    }

}
