use starknet::{ContractAddress, contract_address_try_from_felt252};
use integer::BoundedInt;
use yas_core::numbers::signed_integer::{i32::i32, i128::i128, integer_trait::IntegerTrait};
use yas_core::utils::math_utils::{pow};
use openzeppelin::token::erc20::{
    ERC20Component, interface::{IERC20Dispatcher, IERC20DispatcherTrait}
};
use jediswap_v2_core::libraries::tick_math::TickMath::{
    MIN_TICK, MAX_TICK, MAX_SQRT_RATIO, MIN_SQRT_RATIO, get_sqrt_ratio_at_tick,
    get_tick_at_sqrt_ratio
};
use jediswap_v2_core::jediswap_v2_factory::{
    IJediSwapV2FactoryDispatcher, IJediSwapV2FactoryDispatcherTrait
};
use jediswap_v2_core::jediswap_v2_pool::{
    IJediSwapV2PoolDispatcher, IJediSwapV2PoolDispatcherTrait, JediSwapV2Pool
};
use jediswap_v2_core::test_contracts::pool_mint_test::{
    IPoolMintTestDispatcher, IPoolMintTestDispatcherTrait
};
use jediswap_v2_core::test_contracts::pool_swap_test::{
    IPoolSwapTestDispatcher, IPoolSwapTestDispatcherTrait
};
use jediswap_v2_core::libraries::position::{PositionKey, PositionInfo};
use snforge_std::{
    PrintTrait, declare, ContractClassTrait, start_prank, stop_prank, CheatTarget, spy_events,
    SpyOn, EventSpy, EventFetcher, Event, EventAssertions
};

use super::utils::{owner, user1, user2, token0_1};

//TODO Use setup when available

fn setup_factory() -> (ContractAddress, ContractAddress) {
    let owner = owner();
    let pool_class = declare('JediSwapV2Pool');

    let factory_class = declare('JediSwapV2Factory');
    let mut factory_constructor_calldata = Default::default();
    Serde::serialize(@owner, ref factory_constructor_calldata);
    Serde::serialize(@pool_class.class_hash, ref factory_constructor_calldata);
    let factory_address = factory_class.deploy(@factory_constructor_calldata).unwrap();
    (owner, factory_address)
}

fn create_pool() -> ContractAddress {
    let (owner, factory_address) = setup_factory();
    let fee = 3000;
    let factory_dispatcher = IJediSwapV2FactoryDispatcher { contract_address: factory_address };
    let (token0, token1) = token0_1();

    factory_dispatcher.create_pool(token0, token1, fee);

    let pool_address = factory_dispatcher.get_pool(token0, token1, fee);

    pool_address
}

fn initialize_pool_1_10() -> ContractAddress {
    let pool_address = create_pool();

    let pool_dispatcher = IJediSwapV2PoolDispatcher { contract_address: pool_address };

    pool_dispatcher.initialize(25054144837504793750611689472); //  encode_price_sqrt(1, 10)

    pool_address
}

fn get_pool_mint_test_dispatcher() -> IPoolMintTestDispatcher {
    let pool_mint_test_class = declare('PoolMintTest');
    let mut pool_mint_test_constructor_calldata = Default::default();

    let pool_mint_test_address = pool_mint_test_class
        .deploy(@pool_mint_test_constructor_calldata)
        .unwrap();

    IPoolMintTestDispatcher { contract_address: pool_mint_test_address }
}

fn get_pool_swap_test_dispatcher() -> IPoolSwapTestDispatcher {
    let pool_swap_test_class = declare('PoolSwapTest');
    let mut pool_swap_test_constructor_calldata = Default::default();

    let pool_swap_test_address = pool_swap_test_class
        .deploy(@pool_swap_test_constructor_calldata)
        .unwrap();

    IPoolSwapTestDispatcher { contract_address: pool_swap_test_address }
}

fn initiate_pool_1_10_with_intial_mint() -> (ContractAddress, IPoolMintTestDispatcher) {
    let pool_address = initialize_pool_1_10();

    let pool_mint_test_dispatcher = get_pool_mint_test_dispatcher();

    let pool_dispatcher = IJediSwapV2PoolDispatcher { contract_address: pool_address };

    let token0_dispatcher = IERC20Dispatcher { contract_address: pool_dispatcher.get_token0() };
    start_prank(CheatTarget::One(pool_dispatcher.get_token0()), user1());
    token0_dispatcher.approve(pool_mint_test_dispatcher.contract_address, 100 * pow(10, 18));
    stop_prank(CheatTarget::One(pool_dispatcher.get_token0()));

    let token1_dispatcher = IERC20Dispatcher { contract_address: pool_dispatcher.get_token1() };
    start_prank(CheatTarget::One(pool_dispatcher.get_token1()), user1());
    token1_dispatcher.approve(pool_mint_test_dispatcher.contract_address, 100 * pow(10, 18));
    stop_prank(CheatTarget::One(pool_dispatcher.get_token1()));

    start_prank(CheatTarget::One(pool_mint_test_dispatcher.contract_address), user1());
    pool_mint_test_dispatcher.mint(pool_address, user1(), get_min_tick(), get_max_tick(), 3161);
    stop_prank(CheatTarget::One(pool_mint_test_dispatcher.contract_address));

    (pool_address, pool_mint_test_dispatcher)
}

fn get_min_tick() -> i32 {
    IntegerTrait::<i32>::new(887220, true) // math.ceil(-887272 / 60) * 60
}

fn get_max_tick() -> i32 {
    IntegerTrait::<i32>::new(887220, false) // math.floor(887272 / 60) * 60
}

#[test]
#[should_panic(expected: ('already initialized',))]
fn test_initialize_fails_if_already_initialized() {
    let pool_address = create_pool();

    let pool_dispatcher = IJediSwapV2PoolDispatcher { contract_address: pool_address };

    pool_dispatcher.initialize(79228162514264337593543950336); //  encode_price_sqrt(1, 1)

    pool_dispatcher.initialize(79228162514264337593543950336); //  encode_price_sqrt(1, 1)
}

#[test]
#[should_panic(expected: ('Invalid sqrt ratio',))]
fn test_initialize_fails_if_starting_price_is_too_low() {
    let pool_address = create_pool();

    let pool_dispatcher = IJediSwapV2PoolDispatcher { contract_address: pool_address };

    pool_dispatcher.initialize(MIN_SQRT_RATIO - 1);
}

#[test]
#[should_panic(expected: ('Invalid sqrt ratio',))]
fn test_initialize_fails_if_starting_price_is_too_high() {
    let pool_address = create_pool();

    let pool_dispatcher = IJediSwapV2PoolDispatcher { contract_address: pool_address };

    pool_dispatcher.initialize(MAX_SQRT_RATIO);
}

#[test]
fn test_initialize_succeeds_and_emits_event() {
    let pool_address = create_pool();

    let pool_dispatcher = IJediSwapV2PoolDispatcher { contract_address: pool_address };

    let mut spy = spy_events(SpyOn::One(pool_address));

    let sqrt_price_X96 = 56022770974786143748341366784; //  encode_price_sqrt(1, 2)

    pool_dispatcher.initialize(sqrt_price_X96);

    assert(pool_dispatcher.get_sqrt_price_X96() == sqrt_price_X96, 'Invalid Sqrt Price');
    assert(pool_dispatcher.get_tick() == IntegerTrait::<i32>::new(6932, true), 'Invalid Tick');

    spy
        .assert_emitted(
            @array![
                (
                    pool_address,
                    JediSwapV2Pool::Event::Initialize(
                        JediSwapV2Pool::Initialize {
                            sqrt_price_X96: sqrt_price_X96,
                            tick: IntegerTrait::<i32>::new(6932, true)
                        }
                    )
                )
            ]
        );
}

#[test]
fn test_initialize_succeeds_at_min_sqrt_ratio() {
    let pool_address = create_pool();

    let pool_dispatcher = IJediSwapV2PoolDispatcher { contract_address: pool_address };

    let sqrt_price_X96 = MIN_SQRT_RATIO;

    pool_dispatcher.initialize(sqrt_price_X96);

    assert(pool_dispatcher.get_sqrt_price_X96() == sqrt_price_X96, 'Invalid Sqrt Price');
    assert(pool_dispatcher.get_tick() == MIN_TICK(), 'Invalid Tick');
}

#[test]
fn test_initialize_succeeds_at_max_sqrt_ratio_minus_1() {
    let pool_address = create_pool();

    let pool_dispatcher = IJediSwapV2PoolDispatcher { contract_address: pool_address };

    let sqrt_price_X96 = MAX_SQRT_RATIO - 1;

    pool_dispatcher.initialize(sqrt_price_X96);

    assert(pool_dispatcher.get_sqrt_price_X96() == sqrt_price_X96, 'Invalid Sqrt Price');
    assert(
        pool_dispatcher.get_tick() == MAX_TICK() - IntegerTrait::<i32>::new(1, false),
        'Invalid Tick'
    );
}

#[test]
#[should_panic(expected: ('LOK',))]
fn test_mint_fails_if_not_initialized() {
    let pool_address = create_pool();

    let pool_mint_test_dispatcher = get_pool_mint_test_dispatcher();

    pool_mint_test_dispatcher
        .mint(
            pool_address,
            user1(),
            IntegerTrait::<i32>::new(60, true),
            IntegerTrait::<i32>::new(60, false),
            1
        );
}

#[test]
#[should_panic(expected: ('TLU',))]
fn test_mint_fails_if_tick_lower_greater_than_tick_upper() {
    let pool_address = initialize_pool_1_10();

    let pool_mint_test_dispatcher = get_pool_mint_test_dispatcher();

    pool_mint_test_dispatcher
        .mint(
            pool_address,
            user1(),
            IntegerTrait::<i32>::new(1, false),
            IntegerTrait::<i32>::new(0, false),
            1
        );
}

#[test]
#[should_panic(expected: ('TLM',))]
fn test_mint_fails_if_tick_lower_less_than_min_tick() {
    let pool_address = initialize_pool_1_10();

    let pool_mint_test_dispatcher = get_pool_mint_test_dispatcher();

    pool_mint_test_dispatcher
        .mint(
            pool_address,
            user1(),
            IntegerTrait::<i32>::new(887273, true),
            IntegerTrait::<i32>::new(0, false),
            1
        );
}

#[test]
#[should_panic(expected: ('TUM',))]
fn test_mint_fails_if_tick_upper_greater_than_max_tick() {
    let pool_address = initialize_pool_1_10();

    let pool_mint_test_dispatcher = get_pool_mint_test_dispatcher();

    pool_mint_test_dispatcher
        .mint(
            pool_address,
            user1(),
            IntegerTrait::<i32>::new(0, false),
            IntegerTrait::<i32>::new(887273, false),
            1
        );
}

#[test]
#[should_panic(expected: ('LO',))]
fn test_mint_fails_if_amount_exceeds_the_max() {
    let pool_address = initialize_pool_1_10();

    let pool_mint_test_dispatcher = get_pool_mint_test_dispatcher();

    let pool_dispatcher = IJediSwapV2PoolDispatcher { contract_address: pool_address };

    let max_liquidity_gross = pool_dispatcher.get_max_liquidity_per_tick();

    pool_mint_test_dispatcher
        .mint(
            pool_address,
            user1(),
            get_min_tick() + IntegerTrait::<i32>::new(60, false),
            get_max_tick() - IntegerTrait::<i32>::new(60, false),
            max_liquidity_gross + 1
        );
}

#[test]
#[should_panic(expected: ('LO',))]
fn test_mint_fails_if_total_amount_at_tick_exceeds_the_max() {
    let pool_address = initialize_pool_1_10();

    let pool_mint_test_dispatcher = get_pool_mint_test_dispatcher();

    let pool_dispatcher = IJediSwapV2PoolDispatcher { contract_address: pool_address };

    let max_liquidity_gross = pool_dispatcher.get_max_liquidity_per_tick();

    let token0_dispatcher = IERC20Dispatcher { contract_address: pool_dispatcher.get_token0() };
    start_prank(CheatTarget::One(pool_dispatcher.get_token0()), user1());
    token0_dispatcher
        .approve(pool_mint_test_dispatcher.contract_address, max_liquidity_gross.into() + 1);
    stop_prank(CheatTarget::One(pool_dispatcher.get_token0()));

    let token1_dispatcher = IERC20Dispatcher { contract_address: pool_dispatcher.get_token1() };
    start_prank(CheatTarget::One(pool_dispatcher.get_token1()), user1());
    token1_dispatcher
        .approve(pool_mint_test_dispatcher.contract_address, max_liquidity_gross.into() + 1);
    stop_prank(CheatTarget::One(pool_dispatcher.get_token1()));

    start_prank(CheatTarget::One(pool_mint_test_dispatcher.contract_address), user1());
    pool_mint_test_dispatcher
        .mint(
            pool_address,
            user1(),
            get_min_tick() + IntegerTrait::<i32>::new(60, false),
            get_max_tick() - IntegerTrait::<i32>::new(60, false),
            1000
        );
    stop_prank(CheatTarget::One(pool_mint_test_dispatcher.contract_address));

    start_prank(CheatTarget::One(pool_mint_test_dispatcher.contract_address), user1());
    pool_mint_test_dispatcher
        .mint(
            pool_address,
            user1(),
            get_min_tick() + IntegerTrait::<i32>::new(60, false),
            get_max_tick() - IntegerTrait::<i32>::new(60, false),
            max_liquidity_gross - 1000 + 1
        );
    stop_prank(CheatTarget::One(pool_mint_test_dispatcher.contract_address));
}

#[test]
#[should_panic(expected: ('LO',))]
fn test_mint_fails_if_total_amount_at_tick_exceeds_the_max_1() {
    let pool_address = initialize_pool_1_10();

    let pool_mint_test_dispatcher = get_pool_mint_test_dispatcher();

    let pool_dispatcher = IJediSwapV2PoolDispatcher { contract_address: pool_address };

    let max_liquidity_gross = pool_dispatcher.get_max_liquidity_per_tick();

    let token0_dispatcher = IERC20Dispatcher { contract_address: pool_dispatcher.get_token0() };
    start_prank(CheatTarget::One(pool_dispatcher.get_token0()), user1());
    token0_dispatcher
        .approve(pool_mint_test_dispatcher.contract_address, max_liquidity_gross.into() + 1);
    stop_prank(CheatTarget::One(pool_dispatcher.get_token0()));

    let token1_dispatcher = IERC20Dispatcher { contract_address: pool_dispatcher.get_token1() };
    start_prank(CheatTarget::One(pool_dispatcher.get_token1()), user1());
    token1_dispatcher
        .approve(pool_mint_test_dispatcher.contract_address, max_liquidity_gross.into() + 1);
    stop_prank(CheatTarget::One(pool_dispatcher.get_token1()));

    start_prank(CheatTarget::One(pool_mint_test_dispatcher.contract_address), user1());
    pool_mint_test_dispatcher
        .mint(
            pool_address,
            user1(),
            get_min_tick() + IntegerTrait::<i32>::new(60, false),
            get_max_tick() - IntegerTrait::<i32>::new(60, false),
            1000
        );
    stop_prank(CheatTarget::One(pool_mint_test_dispatcher.contract_address));

    start_prank(CheatTarget::One(pool_mint_test_dispatcher.contract_address), user1());
    pool_mint_test_dispatcher
        .mint(
            pool_address,
            user1(),
            get_min_tick() + IntegerTrait::<i32>::new(120, false),
            get_max_tick() - IntegerTrait::<i32>::new(60, false),
            max_liquidity_gross - 1000 + 1
        );
    stop_prank(CheatTarget::One(pool_mint_test_dispatcher.contract_address));
}

#[test]
#[should_panic(expected: ('LO',))]
fn test_mint_fails_if_total_amount_at_tick_exceeds_the_max_2() {
    let pool_address = initialize_pool_1_10();

    let pool_mint_test_dispatcher = get_pool_mint_test_dispatcher();

    let pool_dispatcher = IJediSwapV2PoolDispatcher { contract_address: pool_address };

    let max_liquidity_gross = pool_dispatcher.get_max_liquidity_per_tick();

    let token0_dispatcher = IERC20Dispatcher { contract_address: pool_dispatcher.get_token0() };
    start_prank(CheatTarget::One(pool_dispatcher.get_token0()), user1());
    token0_dispatcher
        .approve(pool_mint_test_dispatcher.contract_address, max_liquidity_gross.into() + 1);
    stop_prank(CheatTarget::One(pool_dispatcher.get_token0()));

    let token1_dispatcher = IERC20Dispatcher { contract_address: pool_dispatcher.get_token1() };
    start_prank(CheatTarget::One(pool_dispatcher.get_token1()), user1());
    token1_dispatcher
        .approve(pool_mint_test_dispatcher.contract_address, max_liquidity_gross.into() + 1);
    stop_prank(CheatTarget::One(pool_dispatcher.get_token1()));

    start_prank(CheatTarget::One(pool_mint_test_dispatcher.contract_address), user1());
    pool_mint_test_dispatcher
        .mint(
            pool_address,
            user1(),
            get_min_tick() + IntegerTrait::<i32>::new(60, false),
            get_max_tick() - IntegerTrait::<i32>::new(60, false),
            1000
        );
    stop_prank(CheatTarget::One(pool_mint_test_dispatcher.contract_address));

    start_prank(CheatTarget::One(pool_mint_test_dispatcher.contract_address), user1());
    pool_mint_test_dispatcher
        .mint(
            pool_address,
            user1(),
            get_min_tick() + IntegerTrait::<i32>::new(60, false),
            get_max_tick() - IntegerTrait::<i32>::new(120, false),
            max_liquidity_gross - 1000 + 1
        );
    stop_prank(CheatTarget::One(pool_mint_test_dispatcher.contract_address));
}

#[test]
#[should_panic(expected: ('amount must be greater than 0',))]
fn test_mint_fails_if_amount_is_0() {
    let pool_address = initialize_pool_1_10();

    let pool_mint_test_dispatcher = get_pool_mint_test_dispatcher();

    let pool_dispatcher = IJediSwapV2PoolDispatcher { contract_address: pool_address };

    let max_liquidity_gross = pool_dispatcher.get_max_liquidity_per_tick();

    pool_mint_test_dispatcher
        .mint(
            pool_address,
            user1(),
            get_min_tick() + IntegerTrait::<i32>::new(60, false),
            get_max_tick() - IntegerTrait::<i32>::new(60, false),
            0
        );
}

#[test]
fn test_mint_succeeds_initial_balances() {
    let (pool_address, pool_mint_test_dispatcher) = initiate_pool_1_10_with_intial_mint();

    let pool_dispatcher = IJediSwapV2PoolDispatcher { contract_address: pool_address };

    let token0_dispatcher = IERC20Dispatcher { contract_address: pool_dispatcher.get_token0() };
    assert(token0_dispatcher.balance_of(pool_address) == 9996, 'Incorrect token0 balance');

    let token1_dispatcher = IERC20Dispatcher { contract_address: pool_dispatcher.get_token1() };
    assert(token1_dispatcher.balance_of(pool_address) == 1000, 'Incorrect token1 balance');
}

#[test]
fn test_mint_succeeds_initial_tick() {
    let (pool_address, pool_mint_test_dispatcher) = initiate_pool_1_10_with_intial_mint();

    let pool_dispatcher = IJediSwapV2PoolDispatcher { contract_address: pool_address };

    assert(pool_dispatcher.get_tick() == IntegerTrait::<i32>::new(23028, true), 'Incorrect tick');
}

#[test]
fn test_mint_succeeds_above_current_price_transfers_token0_only() {
    let (pool_address, pool_mint_test_dispatcher) = initiate_pool_1_10_with_intial_mint();

    let pool_dispatcher = IJediSwapV2PoolDispatcher { contract_address: pool_address };

    start_prank(CheatTarget::One(pool_mint_test_dispatcher.contract_address), user1());
    pool_mint_test_dispatcher
        .mint(
            pool_address,
            user1(),
            IntegerTrait::<i32>::new(22980, true),
            IntegerTrait::<i32>::new(0, false),
            10000
        );
    stop_prank(CheatTarget::One(pool_mint_test_dispatcher.contract_address));

    let token0_dispatcher = IERC20Dispatcher { contract_address: pool_dispatcher.get_token0() };
    assert(token0_dispatcher.balance_of(pool_address) == 9996 + 21549, 'Incorrect token0 balance');

    let token1_dispatcher = IERC20Dispatcher { contract_address: pool_dispatcher.get_token1() };
    assert(token1_dispatcher.balance_of(pool_address) == 1000, 'Incorrect token1 balance');
}

#[test]
fn test_mint_succeeds_above_current_price_max_tick_with_max_leverage() {
    let (pool_address, pool_mint_test_dispatcher) = initiate_pool_1_10_with_intial_mint();

    let pool_dispatcher = IJediSwapV2PoolDispatcher { contract_address: pool_address };

    start_prank(CheatTarget::One(pool_mint_test_dispatcher.contract_address), user1());
    pool_mint_test_dispatcher
        .mint(
            pool_address,
            user1(),
            get_max_tick() - IntegerTrait::<i32>::new(60, false),
            get_max_tick(),
            pow(2, 102).try_into().unwrap()
        );
    stop_prank(CheatTarget::One(pool_mint_test_dispatcher.contract_address));

    let token0_dispatcher = IERC20Dispatcher { contract_address: pool_dispatcher.get_token0() };
    assert(
        token0_dispatcher.balance_of(pool_address) == 9996 + 828011525, 'Incorrect token0 balance'
    );

    let token1_dispatcher = IERC20Dispatcher { contract_address: pool_dispatcher.get_token1() };
    assert(token1_dispatcher.balance_of(pool_address) == 1000, 'Incorrect token1 balance');
}

#[test]
fn test_mint_succeeds_above_current_price_works_for_max_tick() {
    let (pool_address, pool_mint_test_dispatcher) = initiate_pool_1_10_with_intial_mint();

    let pool_dispatcher = IJediSwapV2PoolDispatcher { contract_address: pool_address };

    start_prank(CheatTarget::One(pool_mint_test_dispatcher.contract_address), user1());
    pool_mint_test_dispatcher
        .mint(pool_address, user1(), IntegerTrait::<i32>::new(22980, true), get_max_tick(), 10000);
    stop_prank(CheatTarget::One(pool_mint_test_dispatcher.contract_address));

    let token0_dispatcher = IERC20Dispatcher { contract_address: pool_dispatcher.get_token0() };
    assert(token0_dispatcher.balance_of(pool_address) == 9996 + 31549, 'Incorrect token0 balance');

    let token1_dispatcher = IERC20Dispatcher { contract_address: pool_dispatcher.get_token1() };
    assert(token1_dispatcher.balance_of(pool_address) == 1000, 'Incorrect token1 balance');
}

#[test]
fn test_mint_succeeds_above_current_price_removing_works() {
    let (pool_address, pool_mint_test_dispatcher) = initiate_pool_1_10_with_intial_mint();

    let pool_dispatcher = IJediSwapV2PoolDispatcher { contract_address: pool_address };

    start_prank(CheatTarget::One(pool_mint_test_dispatcher.contract_address), user1());
    pool_mint_test_dispatcher
        .mint(
            pool_address,
            user1(),
            IntegerTrait::<i32>::new(240, true),
            IntegerTrait::<i32>::new(0, false),
            10000
        );
    stop_prank(CheatTarget::One(pool_mint_test_dispatcher.contract_address));

    start_prank(CheatTarget::One(pool_address), user1());
    pool_dispatcher
        .burn(IntegerTrait::<i32>::new(240, true), IntegerTrait::<i32>::new(0, false), 10000);
    let (amount0, amount1) = pool_dispatcher
        .static_collect(
            user1(),
            IntegerTrait::<i32>::new(240, true),
            IntegerTrait::<i32>::new(0, false),
            BoundedInt::<u128>::max(),
            BoundedInt::<u128>::max()
        );
    stop_prank(CheatTarget::One(pool_address));

    assert(amount0 == 120, 'Incorrect amount0');
    assert(amount1 == 0, 'Incorrect amount1');
}

#[test]
fn test_mint_succeeds_above_current_price_adds_liquidity_to_liquidity_gross() {
    let (pool_address, pool_mint_test_dispatcher) = initiate_pool_1_10_with_intial_mint();

    let pool_dispatcher = IJediSwapV2PoolDispatcher { contract_address: pool_address };

    start_prank(CheatTarget::One(pool_mint_test_dispatcher.contract_address), user1());
    pool_mint_test_dispatcher
        .mint(
            pool_address,
            user1(),
            IntegerTrait::<i32>::new(240, true),
            IntegerTrait::<i32>::new(0, false),
            100
        );
    stop_prank(CheatTarget::One(pool_mint_test_dispatcher.contract_address));

    assert(
        pool_dispatcher.get_tick_info(IntegerTrait::<i32>::new(240, true)).liquidity_gross == 100,
        'Incorrect liquidity_gross 0'
    );
    assert(
        pool_dispatcher.get_tick_info(IntegerTrait::<i32>::new(0, false)).liquidity_gross == 100,
        'Incorrect liquidity_gross 1'
    );
    assert(
        pool_dispatcher.get_tick_info(IntegerTrait::<i32>::new(60, false)).liquidity_gross == 0,
        'Incorrect liquidity_gross 2'
    );
    assert(
        pool_dispatcher.get_tick_info(IntegerTrait::<i32>::new(120, false)).liquidity_gross == 0,
        'Incorrect liquidity_gross 3'
    );

    start_prank(CheatTarget::One(pool_mint_test_dispatcher.contract_address), user1());
    pool_mint_test_dispatcher
        .mint(
            pool_address,
            user1(),
            IntegerTrait::<i32>::new(240, true),
            IntegerTrait::<i32>::new(60, false),
            150
        );
    stop_prank(CheatTarget::One(pool_mint_test_dispatcher.contract_address));

    assert(
        pool_dispatcher.get_tick_info(IntegerTrait::<i32>::new(240, true)).liquidity_gross == 250,
        'Incorrect liquidity_gross 4'
    );
    assert(
        pool_dispatcher.get_tick_info(IntegerTrait::<i32>::new(0, false)).liquidity_gross == 100,
        'Incorrect liquidity_gross 5'
    );
    assert(
        pool_dispatcher.get_tick_info(IntegerTrait::<i32>::new(60, false)).liquidity_gross == 150,
        'Incorrect liquidity_gross 6'
    );
    assert(
        pool_dispatcher.get_tick_info(IntegerTrait::<i32>::new(120, false)).liquidity_gross == 0,
        'Incorrect liquidity_gross 7'
    );

    start_prank(CheatTarget::One(pool_mint_test_dispatcher.contract_address), user1());
    pool_mint_test_dispatcher
        .mint(
            pool_address,
            user1(),
            IntegerTrait::<i32>::new(0, false),
            IntegerTrait::<i32>::new(120, false),
            60
        );
    stop_prank(CheatTarget::One(pool_mint_test_dispatcher.contract_address));

    assert(
        pool_dispatcher.get_tick_info(IntegerTrait::<i32>::new(240, true)).liquidity_gross == 250,
        'Incorrect liquidity_gross 8'
    );
    assert(
        pool_dispatcher.get_tick_info(IntegerTrait::<i32>::new(0, false)).liquidity_gross == 160,
        'Incorrect liquidity_gross 9'
    );
    assert(
        pool_dispatcher.get_tick_info(IntegerTrait::<i32>::new(60, false)).liquidity_gross == 150,
        'Incorrect liquidity_gross 10'
    );
    assert(
        pool_dispatcher.get_tick_info(IntegerTrait::<i32>::new(120, false)).liquidity_gross == 60,
        'Incorrect liquidity_gross 11'
    );
}

#[test]
fn test_mint_succeeds_above_current_price_removes_liquidity_from_liquidity_gross() {
    let (pool_address, pool_mint_test_dispatcher) = initiate_pool_1_10_with_intial_mint();

    let pool_dispatcher = IJediSwapV2PoolDispatcher { contract_address: pool_address };

    start_prank(CheatTarget::One(pool_mint_test_dispatcher.contract_address), user1());
    pool_mint_test_dispatcher
        .mint(
            pool_address,
            user1(),
            IntegerTrait::<i32>::new(240, true),
            IntegerTrait::<i32>::new(0, false),
            100
        );
    pool_mint_test_dispatcher
        .mint(
            pool_address,
            user1(),
            IntegerTrait::<i32>::new(240, true),
            IntegerTrait::<i32>::new(0, false),
            40
        );
    stop_prank(CheatTarget::One(pool_mint_test_dispatcher.contract_address));

    start_prank(CheatTarget::One(pool_address), user1());
    pool_dispatcher
        .burn(IntegerTrait::<i32>::new(240, true), IntegerTrait::<i32>::new(0, false), 90);
    stop_prank(CheatTarget::One(pool_address));

    assert(
        pool_dispatcher.get_tick_info(IntegerTrait::<i32>::new(240, true)).liquidity_gross == 50,
        'Incorrect liquidity_gross 0'
    );
    assert(
        pool_dispatcher.get_tick_info(IntegerTrait::<i32>::new(0, false)).liquidity_gross == 50,
        'Incorrect liquidity_gross 1'
    );
}

#[test]
fn test_mint_succeeds_above_current_price_clears_lower_and_upper_tick_if_last_position_is_removed() {
    let (pool_address, pool_mint_test_dispatcher) = initiate_pool_1_10_with_intial_mint();

    let pool_dispatcher = IJediSwapV2PoolDispatcher { contract_address: pool_address };

    start_prank(CheatTarget::One(pool_mint_test_dispatcher.contract_address), user1());
    pool_mint_test_dispatcher
        .mint(
            pool_address,
            user1(),
            IntegerTrait::<i32>::new(240, true),
            IntegerTrait::<i32>::new(0, false),
            100
        );
    stop_prank(CheatTarget::One(pool_mint_test_dispatcher.contract_address));

    start_prank(CheatTarget::One(pool_address), user1());
    pool_dispatcher
        .burn(IntegerTrait::<i32>::new(240, true), IntegerTrait::<i32>::new(0, false), 100);
    stop_prank(CheatTarget::One(pool_address));

    assert(
        pool_dispatcher.get_tick_info(IntegerTrait::<i32>::new(240, true)).liquidity_gross == 0,
        'Incorrect liquidity_gross lower'
    );
    assert(
        pool_dispatcher
            .get_tick_info(IntegerTrait::<i32>::new(240, true))
            .fee_growth_outside_0_X128 == 0,
        'Incorrect fee_growth_0 lower'
    );
    assert(
        pool_dispatcher
            .get_tick_info(IntegerTrait::<i32>::new(240, true))
            .fee_growth_outside_1_X128 == 0,
        'Incorrect fee_growth_1 lower'
    );
    assert(
        pool_dispatcher.get_tick_info(IntegerTrait::<i32>::new(0, false)).liquidity_gross == 0,
        'Incorrect liquidity_gross upper'
    );
    assert(
        pool_dispatcher
            .get_tick_info(IntegerTrait::<i32>::new(0, false))
            .fee_growth_outside_0_X128 == 0,
        'Incorrect fee_growth_0 upper'
    );
    assert(
        pool_dispatcher
            .get_tick_info(IntegerTrait::<i32>::new(0, false))
            .fee_growth_outside_1_X128 == 0,
        'Incorrect fee_growth_1 upper'
    );
}

#[test]
fn test_mint_succeeds_above_current_price_only_clears_tick_that_is_not_used_at_all() {
    let (pool_address, pool_mint_test_dispatcher) = initiate_pool_1_10_with_intial_mint();

    let pool_dispatcher = IJediSwapV2PoolDispatcher { contract_address: pool_address };

    start_prank(CheatTarget::One(pool_mint_test_dispatcher.contract_address), user1());
    pool_mint_test_dispatcher
        .mint(
            pool_address,
            user1(),
            IntegerTrait::<i32>::new(240, true),
            IntegerTrait::<i32>::new(0, false),
            100
        );
    pool_mint_test_dispatcher
        .mint(
            pool_address,
            user1(),
            IntegerTrait::<i32>::new(60, true),
            IntegerTrait::<i32>::new(0, false),
            250
        );
    stop_prank(CheatTarget::One(pool_mint_test_dispatcher.contract_address));

    start_prank(CheatTarget::One(pool_address), user1());
    pool_dispatcher
        .burn(IntegerTrait::<i32>::new(240, true), IntegerTrait::<i32>::new(0, false), 100);
    stop_prank(CheatTarget::One(pool_address));

    assert(
        pool_dispatcher.get_tick_info(IntegerTrait::<i32>::new(240, true)).liquidity_gross == 0,
        'Incorrect liquidity_gross -240'
    );
    assert(
        pool_dispatcher
            .get_tick_info(IntegerTrait::<i32>::new(240, true))
            .fee_growth_outside_0_X128 == 0,
        'Incorrect fee_growth_0 -240'
    );
    assert(
        pool_dispatcher
            .get_tick_info(IntegerTrait::<i32>::new(240, true))
            .fee_growth_outside_1_X128 == 0,
        'Incorrect fee_growth_1 -240'
    );
    assert(
        pool_dispatcher.get_tick_info(IntegerTrait::<i32>::new(60, true)).liquidity_gross == 250,
        'Incorrect liquidity_gross -60'
    );
    assert(
        pool_dispatcher
            .get_tick_info(IntegerTrait::<i32>::new(60, true))
            .fee_growth_outside_0_X128 == 0,
        'Incorrect fee_growth_0 -60'
    );
    assert(
        pool_dispatcher
            .get_tick_info(IntegerTrait::<i32>::new(60, true))
            .fee_growth_outside_1_X128 == 0,
        'Incorrect fee_growth_1 -60'
    );
}

#[test]
fn test_mint_succeeds_including_current_price_transfers_both_tokens() {
    let (pool_address, pool_mint_test_dispatcher) = initiate_pool_1_10_with_intial_mint();

    let pool_dispatcher = IJediSwapV2PoolDispatcher { contract_address: pool_address };

    start_prank(CheatTarget::One(pool_mint_test_dispatcher.contract_address), user1());
    pool_mint_test_dispatcher
        .mint(
            pool_address,
            user1(),
            get_min_tick() + IntegerTrait::<i32>::new(60, false),
            get_max_tick() - IntegerTrait::<i32>::new(60, false),
            100
        );
    stop_prank(CheatTarget::One(pool_mint_test_dispatcher.contract_address));

    let token0_dispatcher = IERC20Dispatcher { contract_address: pool_dispatcher.get_token0() };
    assert(token0_dispatcher.balance_of(pool_address) == 9996 + 317, 'Incorrect token0 balance');

    let token1_dispatcher = IERC20Dispatcher { contract_address: pool_dispatcher.get_token1() };
    assert(token1_dispatcher.balance_of(pool_address) == 1000 + 32, 'Incorrect token1 balance');
}

#[test]
fn test_mint_succeeds_including_current_price_initializes_lower_tick() {
    let (pool_address, pool_mint_test_dispatcher) = initiate_pool_1_10_with_intial_mint();

    let pool_dispatcher = IJediSwapV2PoolDispatcher { contract_address: pool_address };

    start_prank(CheatTarget::One(pool_mint_test_dispatcher.contract_address), user1());
    pool_mint_test_dispatcher
        .mint(
            pool_address,
            user1(),
            get_min_tick() + IntegerTrait::<i32>::new(60, false),
            get_max_tick() - IntegerTrait::<i32>::new(60, false),
            100
        );
    stop_prank(CheatTarget::One(pool_mint_test_dispatcher.contract_address));

    assert(
        pool_dispatcher
            .get_tick_info(get_min_tick() + IntegerTrait::<i32>::new(60, false))
            .liquidity_gross == 100,
        'Incorrect liquidity_gross'
    );
}

#[test]
fn test_mint_succeeds_including_current_price_initializes_upper_tick() {
    let (pool_address, pool_mint_test_dispatcher) = initiate_pool_1_10_with_intial_mint();

    let pool_dispatcher = IJediSwapV2PoolDispatcher { contract_address: pool_address };

    start_prank(CheatTarget::One(pool_mint_test_dispatcher.contract_address), user1());
    pool_mint_test_dispatcher
        .mint(
            pool_address,
            user1(),
            get_min_tick() + IntegerTrait::<i32>::new(60, false),
            get_max_tick() - IntegerTrait::<i32>::new(60, false),
            100
        );
    stop_prank(CheatTarget::One(pool_mint_test_dispatcher.contract_address));

    assert(
        pool_dispatcher
            .get_tick_info(get_max_tick() - IntegerTrait::<i32>::new(60, false))
            .liquidity_gross == 100,
        'Incorrect liquidity_gross'
    );
}

#[test]
fn test_mint_succeeds_including_current_price_works_for_min_max_tick() {
    let (pool_address, pool_mint_test_dispatcher) = initiate_pool_1_10_with_intial_mint();

    let pool_dispatcher = IJediSwapV2PoolDispatcher { contract_address: pool_address };

    start_prank(CheatTarget::One(pool_mint_test_dispatcher.contract_address), user1());
    pool_mint_test_dispatcher.mint(pool_address, user1(), get_min_tick(), get_max_tick(), 10000);
    stop_prank(CheatTarget::One(pool_mint_test_dispatcher.contract_address));

    let token0_dispatcher = IERC20Dispatcher { contract_address: pool_dispatcher.get_token0() };
    assert(token0_dispatcher.balance_of(pool_address) == 9996 + 31623, 'Incorrect token0 balance');

    let token1_dispatcher = IERC20Dispatcher { contract_address: pool_dispatcher.get_token1() };
    assert(token1_dispatcher.balance_of(pool_address) == 1000 + 3163, 'Incorrect token1 balance');
}

#[test]
fn test_mint_succeeds_including_current_price_removing_works() {
    let (pool_address, pool_mint_test_dispatcher) = initiate_pool_1_10_with_intial_mint();

    let pool_dispatcher = IJediSwapV2PoolDispatcher { contract_address: pool_address };

    start_prank(CheatTarget::One(pool_mint_test_dispatcher.contract_address), user1());
    pool_mint_test_dispatcher
        .mint(
            pool_address,
            user1(),
            get_min_tick() + IntegerTrait::<i32>::new(60, false),
            get_max_tick() - IntegerTrait::<i32>::new(60, false),
            100
        );
    stop_prank(CheatTarget::One(pool_mint_test_dispatcher.contract_address));

    start_prank(CheatTarget::One(pool_address), user1());
    pool_dispatcher
        .burn(
            get_min_tick() + IntegerTrait::<i32>::new(60, false),
            get_max_tick() - IntegerTrait::<i32>::new(60, false),
            100
        );
    let (amount0, amount1) = pool_dispatcher
        .static_collect(
            user1(),
            get_min_tick() + IntegerTrait::<i32>::new(60, false),
            get_max_tick() - IntegerTrait::<i32>::new(60, false),
            BoundedInt::<u128>::max(),
            BoundedInt::<u128>::max()
        );
    stop_prank(CheatTarget::One(pool_address));

    assert(amount0 == 316, 'Incorrect amount0');
    assert(amount1 == 31, 'Incorrect amount1');
}

#[test]
fn test_mint_succeeds_below_current_price_transfers_token1_only() {
    let (pool_address, pool_mint_test_dispatcher) = initiate_pool_1_10_with_intial_mint();

    let pool_dispatcher = IJediSwapV2PoolDispatcher { contract_address: pool_address };

    start_prank(CheatTarget::One(pool_mint_test_dispatcher.contract_address), user1());
    pool_mint_test_dispatcher
        .mint(
            pool_address,
            user1(),
            IntegerTrait::<i32>::new(46080, true),
            IntegerTrait::<i32>::new(23040, true),
            10000
        );
    stop_prank(CheatTarget::One(pool_mint_test_dispatcher.contract_address));

    let token0_dispatcher = IERC20Dispatcher { contract_address: pool_dispatcher.get_token0() };
    assert(token0_dispatcher.balance_of(pool_address) == 9996, 'Incorrect token0 balance');

    let token1_dispatcher = IERC20Dispatcher { contract_address: pool_dispatcher.get_token1() };
    assert(token1_dispatcher.balance_of(pool_address) == 1000 + 2162, 'Incorrect token1 balance');
}

#[test]
fn test_mint_succeeds_below_current_price_min_tick_with_max_leverage() {
    let (pool_address, pool_mint_test_dispatcher) = initiate_pool_1_10_with_intial_mint();

    let pool_dispatcher = IJediSwapV2PoolDispatcher { contract_address: pool_address };

    start_prank(CheatTarget::One(pool_mint_test_dispatcher.contract_address), user1());
    pool_mint_test_dispatcher
        .mint(
            pool_address,
            user1(),
            get_min_tick(),
            get_min_tick() + IntegerTrait::<i32>::new(60, false),
            pow(2, 102).try_into().unwrap()
        );
    stop_prank(CheatTarget::One(pool_mint_test_dispatcher.contract_address));

    let token0_dispatcher = IERC20Dispatcher { contract_address: pool_dispatcher.get_token0() };
    assert(token0_dispatcher.balance_of(pool_address) == 9996, 'Incorrect token0 balance');

    let token1_dispatcher = IERC20Dispatcher { contract_address: pool_dispatcher.get_token1() };
    assert(
        token1_dispatcher.balance_of(pool_address) == 1000 + 828011520, 'Incorrect token1 balance'
    );
}

#[test]
fn test_mint_succeeds_below_current_price_works_for_min_tick() {
    let (pool_address, pool_mint_test_dispatcher) = initiate_pool_1_10_with_intial_mint();

    let pool_dispatcher = IJediSwapV2PoolDispatcher { contract_address: pool_address };

    start_prank(CheatTarget::One(pool_mint_test_dispatcher.contract_address), user1());
    pool_mint_test_dispatcher
        .mint(pool_address, user1(), get_min_tick(), IntegerTrait::<i32>::new(23040, true), 10000);
    stop_prank(CheatTarget::One(pool_mint_test_dispatcher.contract_address));

    let token0_dispatcher = IERC20Dispatcher { contract_address: pool_dispatcher.get_token0() };
    assert(token0_dispatcher.balance_of(pool_address) == 9996, 'Incorrect token0 balance');

    let token1_dispatcher = IERC20Dispatcher { contract_address: pool_dispatcher.get_token1() };
    assert(token1_dispatcher.balance_of(pool_address) == 1000 + 3161, 'Incorrect token1 balance');
}

#[test]
fn test_mint_succeeds_below_current_price_removing_works() {
    let (pool_address, pool_mint_test_dispatcher) = initiate_pool_1_10_with_intial_mint();

    let pool_dispatcher = IJediSwapV2PoolDispatcher { contract_address: pool_address };

    start_prank(CheatTarget::One(pool_mint_test_dispatcher.contract_address), user1());
    pool_mint_test_dispatcher
        .mint(
            pool_address,
            user1(),
            IntegerTrait::<i32>::new(46080, true),
            IntegerTrait::<i32>::new(46020, true),
            10000
        );
    stop_prank(CheatTarget::One(pool_mint_test_dispatcher.contract_address));

    start_prank(CheatTarget::One(pool_address), user1());
    pool_dispatcher
        .burn(IntegerTrait::<i32>::new(46080, true), IntegerTrait::<i32>::new(46020, true), 10000);
    let (amount0, amount1) = pool_dispatcher
        .static_collect(
            user1(),
            IntegerTrait::<i32>::new(46080, true),
            IntegerTrait::<i32>::new(46020, true),
            BoundedInt::<u128>::max(),
            BoundedInt::<u128>::max()
        );
    stop_prank(CheatTarget::One(pool_address));

    assert(amount0 == 0, 'Incorrect amount0');
    assert(amount1 == 3, 'Incorrect amount1');
}

#[test]
fn test_mint_succeeds_protocol_fees_accumulate_as_expected_during_swap() {
    let (pool_address, pool_mint_test_dispatcher) = initiate_pool_1_10_with_intial_mint();

    let pool_dispatcher = IJediSwapV2PoolDispatcher { contract_address: pool_address };

    let factory_address = pool_dispatcher.get_factory();

    let factory_dispatcher = IJediSwapV2FactoryDispatcher { contract_address: factory_address };

    start_prank(CheatTarget::One(factory_address), owner());
    factory_dispatcher.set_fee_protocol(6);
    stop_prank(CheatTarget::One(factory_address));

    start_prank(CheatTarget::One(pool_mint_test_dispatcher.contract_address), user1());
    pool_mint_test_dispatcher
        .mint(
            pool_address,
            user1(),
            get_min_tick() + IntegerTrait::<i32>::new(60, false),
            get_max_tick() - IntegerTrait::<i32>::new(60, false),
            pow(10, 18).try_into().unwrap()
        );
    stop_prank(CheatTarget::One(pool_mint_test_dispatcher.contract_address));

    let pool_swap_test_dispatcher = get_pool_swap_test_dispatcher();

    let token0_dispatcher = IERC20Dispatcher { contract_address: pool_dispatcher.get_token0() };
    start_prank(CheatTarget::One(pool_dispatcher.get_token0()), user1());
    token0_dispatcher.approve(pool_swap_test_dispatcher.contract_address, 100 * pow(10, 18));
    stop_prank(CheatTarget::One(pool_dispatcher.get_token0()));

    let token1_dispatcher = IERC20Dispatcher { contract_address: pool_dispatcher.get_token1() };
    start_prank(CheatTarget::One(pool_dispatcher.get_token1()), user1());
    token1_dispatcher.approve(pool_swap_test_dispatcher.contract_address, 100 * pow(10, 18));
    stop_prank(CheatTarget::One(pool_dispatcher.get_token1()));

    start_prank(CheatTarget::One(pool_swap_test_dispatcher.contract_address), user1());
    pool_swap_test_dispatcher
        .swap_exact_0_for_1(pool_address, pow(10, 17), user1(), MIN_SQRT_RATIO + 1);
    pool_swap_test_dispatcher
        .swap_exact_1_for_0(pool_address, pow(10, 16), user1(), MAX_SQRT_RATIO - 1);
    stop_prank(CheatTarget::One(pool_swap_test_dispatcher.contract_address));

    assert(
        pool_dispatcher.get_protocol_fees().token0 == 50000000000000, 'Incorrect protocol fees 0'
    );
    assert(
        pool_dispatcher.get_protocol_fees().token1 == 5000000000000, 'Incorrect protocol fees 1'
    );
}

#[test]
fn test_mint_succeeds_positions_are_protected_before_protocol_fee_is_turned_on() {
    let (pool_address, pool_mint_test_dispatcher) = initiate_pool_1_10_with_intial_mint();

    let pool_dispatcher = IJediSwapV2PoolDispatcher { contract_address: pool_address };

    start_prank(CheatTarget::One(pool_mint_test_dispatcher.contract_address), user1());
    pool_mint_test_dispatcher
        .mint(
            pool_address,
            user1(),
            get_min_tick() + IntegerTrait::<i32>::new(60, false),
            get_max_tick() - IntegerTrait::<i32>::new(60, false),
            pow(10, 18).try_into().unwrap()
        );
    stop_prank(CheatTarget::One(pool_mint_test_dispatcher.contract_address));

    let pool_swap_test_dispatcher = get_pool_swap_test_dispatcher();

    let token0_dispatcher = IERC20Dispatcher { contract_address: pool_dispatcher.get_token0() };
    start_prank(CheatTarget::One(pool_dispatcher.get_token0()), user1());
    token0_dispatcher.approve(pool_swap_test_dispatcher.contract_address, 100 * pow(10, 18));
    stop_prank(CheatTarget::One(pool_dispatcher.get_token0()));

    let token1_dispatcher = IERC20Dispatcher { contract_address: pool_dispatcher.get_token1() };
    start_prank(CheatTarget::One(pool_dispatcher.get_token1()), user1());
    token1_dispatcher.approve(pool_swap_test_dispatcher.contract_address, 100 * pow(10, 18));
    stop_prank(CheatTarget::One(pool_dispatcher.get_token1()));

    start_prank(CheatTarget::One(pool_swap_test_dispatcher.contract_address), user1());
    pool_swap_test_dispatcher
        .swap_exact_0_for_1(pool_address, pow(10, 17), user1(), MIN_SQRT_RATIO + 1);
    pool_swap_test_dispatcher
        .swap_exact_1_for_0(pool_address, pow(10, 16), user1(), MAX_SQRT_RATIO - 1);
    stop_prank(CheatTarget::One(pool_swap_test_dispatcher.contract_address));

    assert(pool_dispatcher.get_protocol_fees().token0 == 0, 'Incorrect protocol fees 0');
    assert(pool_dispatcher.get_protocol_fees().token1 == 0, 'Incorrect protocol fees 1');

    let factory_address = pool_dispatcher.get_factory();

    let factory_dispatcher = IJediSwapV2FactoryDispatcher { contract_address: factory_address };

    start_prank(CheatTarget::One(factory_address), owner());
    factory_dispatcher.set_fee_protocol(6);
    stop_prank(CheatTarget::One(factory_address));

    assert(pool_dispatcher.get_protocol_fees().token0 == 0, 'Incorrect protocol fees 0 0');
    assert(pool_dispatcher.get_protocol_fees().token1 == 0, 'Incorrect protocol fees 1 0');
}

#[test]
#[should_panic(expected: ('NP',))]
fn test_mint_succeeds_poke_not_allowed_on_uninitialized_position() {
    let (pool_address, pool_mint_test_dispatcher) = initiate_pool_1_10_with_intial_mint();

    let pool_dispatcher = IJediSwapV2PoolDispatcher { contract_address: pool_address };

    start_prank(CheatTarget::One(pool_mint_test_dispatcher.contract_address), user1());
    pool_mint_test_dispatcher
        .mint(
            pool_address,
            user1(),
            get_min_tick() + IntegerTrait::<i32>::new(60, false),
            get_max_tick() - IntegerTrait::<i32>::new(60, false),
            pow(10, 18).try_into().unwrap()
        );
    stop_prank(CheatTarget::One(pool_mint_test_dispatcher.contract_address));

    let pool_swap_test_dispatcher = get_pool_swap_test_dispatcher();

    let token0_dispatcher = IERC20Dispatcher { contract_address: pool_dispatcher.get_token0() };
    start_prank(CheatTarget::One(pool_dispatcher.get_token0()), user1());
    token0_dispatcher.approve(pool_swap_test_dispatcher.contract_address, 100 * pow(10, 18));
    stop_prank(CheatTarget::One(pool_dispatcher.get_token0()));

    let token1_dispatcher = IERC20Dispatcher { contract_address: pool_dispatcher.get_token1() };
    start_prank(CheatTarget::One(pool_dispatcher.get_token1()), user1());
    token1_dispatcher.approve(pool_swap_test_dispatcher.contract_address, 100 * pow(10, 18));
    stop_prank(CheatTarget::One(pool_dispatcher.get_token1()));

    start_prank(CheatTarget::One(pool_swap_test_dispatcher.contract_address), user1());
    pool_swap_test_dispatcher
        .swap_exact_0_for_1(pool_address, pow(10, 17), user1(), MIN_SQRT_RATIO + 1);
    pool_swap_test_dispatcher
        .swap_exact_1_for_0(pool_address, pow(10, 16), user1(), MAX_SQRT_RATIO - 1);
    stop_prank(CheatTarget::One(pool_swap_test_dispatcher.contract_address));

    start_prank(CheatTarget::One(pool_address), user2());
    pool_dispatcher
        .burn(
            get_min_tick() + IntegerTrait::<i32>::new(60, false),
            get_max_tick() - IntegerTrait::<i32>::new(60, false),
            0
        );
    stop_prank(CheatTarget::One(pool_address));
}

fn initiate_pool_1_1_with_intial_mint() -> (ContractAddress, IPoolMintTestDispatcher) {
    let pool_address = create_pool();

    let pool_dispatcher = IJediSwapV2PoolDispatcher { contract_address: pool_address };

    pool_dispatcher.initialize(79228162514264337593543950336); //  encode_price_sqrt(1, 1)

    let pool_mint_test_dispatcher = get_pool_mint_test_dispatcher();

    let pool_dispatcher = IJediSwapV2PoolDispatcher { contract_address: pool_address };

    let token0_dispatcher = IERC20Dispatcher { contract_address: pool_dispatcher.get_token0() };
    start_prank(CheatTarget::One(pool_dispatcher.get_token0()), user1());
    token0_dispatcher.approve(pool_mint_test_dispatcher.contract_address, 100 * pow(10, 18));
    stop_prank(CheatTarget::One(pool_dispatcher.get_token0()));

    let token1_dispatcher = IERC20Dispatcher { contract_address: pool_dispatcher.get_token1() };
    start_prank(CheatTarget::One(pool_dispatcher.get_token1()), user1());
    token1_dispatcher.approve(pool_mint_test_dispatcher.contract_address, 100 * pow(10, 18));
    stop_prank(CheatTarget::One(pool_dispatcher.get_token1()));

    start_prank(CheatTarget::One(pool_mint_test_dispatcher.contract_address), user1());
    pool_mint_test_dispatcher
        .mint(
            pool_address,
            user1(),
            get_min_tick(),
            get_max_tick(),
            2 * pow(10, 18).try_into().unwrap()
        );
    stop_prank(CheatTarget::One(pool_mint_test_dispatcher.contract_address));

    (pool_address, pool_mint_test_dispatcher)
}

#[test]
fn test_burn_does_not_clear_the_position_fee_growth_snapshot_if_no_more_liquidity() {
    let (pool_address, pool_mint_test_dispatcher) = initiate_pool_1_1_with_intial_mint();

    let pool_dispatcher = IJediSwapV2PoolDispatcher { contract_address: pool_address };

    let token0_dispatcher = IERC20Dispatcher { contract_address: pool_dispatcher.get_token0() };
    start_prank(CheatTarget::One(pool_dispatcher.get_token0()), user2());
    token0_dispatcher.approve(pool_mint_test_dispatcher.contract_address, 100 * pow(10, 18));
    stop_prank(CheatTarget::One(pool_dispatcher.get_token0()));

    let token1_dispatcher = IERC20Dispatcher { contract_address: pool_dispatcher.get_token1() };
    start_prank(CheatTarget::One(pool_dispatcher.get_token1()), user2());
    token1_dispatcher.approve(pool_mint_test_dispatcher.contract_address, 100 * pow(10, 18));
    stop_prank(CheatTarget::One(pool_dispatcher.get_token1()));

    start_prank(CheatTarget::One(pool_mint_test_dispatcher.contract_address), user2());
    pool_mint_test_dispatcher
        .mint(
            pool_address, user2(), get_min_tick(), get_max_tick(), pow(10, 18).try_into().unwrap()
        );
    stop_prank(CheatTarget::One(pool_mint_test_dispatcher.contract_address));

    let pool_swap_test_dispatcher = get_pool_swap_test_dispatcher();

    let token0_dispatcher = IERC20Dispatcher { contract_address: pool_dispatcher.get_token0() };
    start_prank(CheatTarget::One(pool_dispatcher.get_token0()), user1());
    token0_dispatcher.approve(pool_swap_test_dispatcher.contract_address, 100 * pow(10, 18));
    stop_prank(CheatTarget::One(pool_dispatcher.get_token0()));

    let token1_dispatcher = IERC20Dispatcher { contract_address: pool_dispatcher.get_token1() };
    start_prank(CheatTarget::One(pool_dispatcher.get_token1()), user1());
    token1_dispatcher.approve(pool_swap_test_dispatcher.contract_address, 100 * pow(10, 18));
    stop_prank(CheatTarget::One(pool_dispatcher.get_token1()));

    start_prank(CheatTarget::One(pool_swap_test_dispatcher.contract_address), user1());
    pool_swap_test_dispatcher
        .swap_exact_0_for_1(pool_address, pow(10, 18), user1(), MIN_SQRT_RATIO + 1);
    pool_swap_test_dispatcher
        .swap_exact_1_for_0(pool_address, pow(10, 18), user1(), MAX_SQRT_RATIO - 1);
    stop_prank(CheatTarget::One(pool_swap_test_dispatcher.contract_address));

    start_prank(CheatTarget::One(pool_address), user2());
    pool_dispatcher.burn(get_min_tick(), get_max_tick(), pow(10, 18).try_into().unwrap());
    stop_prank(CheatTarget::One(pool_address));

    let position_info = pool_dispatcher
        .get_position_info(
            PositionKey { owner: user2(), tick_lower: get_min_tick(), tick_upper: get_max_tick() }
        );
    assert(position_info.liquidity == 0, 'Incorrect liquidity');
    assert(position_info.tokens_owed_0 != 0, 'Incorrect tokens_owed_0');
    assert(position_info.tokens_owed_1 != 0, 'Incorrect tokens_owed_1');
    assert(
        position_info.fee_growth_inside_0_last_X128 == 340282366920938463463374607431768211,
        'Incorrect fee_growth_0'
    );
    assert(
        position_info.fee_growth_inside_1_last_X128 == 340282366920938576890830247744589365,
        'Incorrect fee_growth_1'
    );
}

#[test]
fn test_burn_clears_the_tick_if_its_the_last_position_using_it() {
    let (pool_address, pool_mint_test_dispatcher) = initiate_pool_1_1_with_intial_mint();

    let tick_lower = get_min_tick() + IntegerTrait::<i32>::new(60, false);
    let tick_upper = get_max_tick() - IntegerTrait::<i32>::new(60, false);

    let pool_dispatcher = IJediSwapV2PoolDispatcher { contract_address: pool_address };

    start_prank(CheatTarget::One(pool_mint_test_dispatcher.contract_address), user1());
    pool_mint_test_dispatcher.mint(pool_address, user1(), tick_lower, tick_upper, 1);
    stop_prank(CheatTarget::One(pool_mint_test_dispatcher.contract_address));

    let pool_swap_test_dispatcher = get_pool_swap_test_dispatcher();

    let token0_dispatcher = IERC20Dispatcher { contract_address: pool_dispatcher.get_token0() };
    start_prank(CheatTarget::One(pool_dispatcher.get_token0()), user1());
    token0_dispatcher.approve(pool_swap_test_dispatcher.contract_address, 100 * pow(10, 18));
    stop_prank(CheatTarget::One(pool_dispatcher.get_token0()));

    start_prank(CheatTarget::One(pool_swap_test_dispatcher.contract_address), user1());
    pool_swap_test_dispatcher
        .swap_exact_0_for_1(pool_address, pow(10, 18), user1(), MIN_SQRT_RATIO + 1);
    stop_prank(CheatTarget::One(pool_swap_test_dispatcher.contract_address));

    start_prank(CheatTarget::One(pool_address), user1());
    pool_dispatcher.burn(tick_lower, tick_upper, 1);
    stop_prank(CheatTarget::One(pool_address));

    assert(
        pool_dispatcher.get_tick_info(tick_lower).liquidity_gross == 0,
        'Incorrect liquidity_gross lower'
    );
    assert(
        pool_dispatcher.get_tick_info(tick_lower).fee_growth_outside_0_X128 == 0,
        'Incorrect fee_growth_0 lower'
    );
    assert(
        pool_dispatcher.get_tick_info(tick_lower).fee_growth_outside_1_X128 == 0,
        'Incorrect fee_growth_1 lower'
    );
    assert(
        pool_dispatcher
            .get_tick_info(tick_lower)
            .liquidity_net == IntegerTrait::<i128>::new(0, false),
        'Incorrect liquidity_net lower'
    );

    assert(
        pool_dispatcher.get_tick_info(tick_upper).liquidity_gross == 0,
        'Incorrect liquidity_gross upper'
    );
    assert(
        pool_dispatcher.get_tick_info(tick_upper).fee_growth_outside_0_X128 == 0,
        'Incorrect fee_growth_0 upper'
    );
    assert(
        pool_dispatcher.get_tick_info(tick_upper).fee_growth_outside_1_X128 == 0,
        'Incorrect fee_growth_1 upper'
    );
    assert(
        pool_dispatcher
            .get_tick_info(tick_upper)
            .liquidity_net == IntegerTrait::<i128>::new(0, false),
        'Incorrect liquidity_net upper'
    );
}

#[test]
fn test_burn_clears_only_the_lower_tick_if_upper_is_still_used() {
    let (pool_address, pool_mint_test_dispatcher) = initiate_pool_1_1_with_intial_mint();

    let tick_lower = get_min_tick() + IntegerTrait::<i32>::new(60, false);
    let tick_upper = get_max_tick() - IntegerTrait::<i32>::new(60, false);

    let pool_dispatcher = IJediSwapV2PoolDispatcher { contract_address: pool_address };

    start_prank(CheatTarget::One(pool_mint_test_dispatcher.contract_address), user1());
    pool_mint_test_dispatcher.mint(pool_address, user1(), tick_lower, tick_upper, 1);
    pool_mint_test_dispatcher
        .mint(
            pool_address, user1(), tick_lower + IntegerTrait::<i32>::new(60, false), tick_upper, 1
        );
    stop_prank(CheatTarget::One(pool_mint_test_dispatcher.contract_address));

    let pool_swap_test_dispatcher = get_pool_swap_test_dispatcher();

    let token0_dispatcher = IERC20Dispatcher { contract_address: pool_dispatcher.get_token0() };
    start_prank(CheatTarget::One(pool_dispatcher.get_token0()), user1());
    token0_dispatcher.approve(pool_swap_test_dispatcher.contract_address, 100 * pow(10, 18));
    stop_prank(CheatTarget::One(pool_dispatcher.get_token0()));

    start_prank(CheatTarget::One(pool_swap_test_dispatcher.contract_address), user1());
    pool_swap_test_dispatcher
        .swap_exact_0_for_1(pool_address, pow(10, 18), user1(), MIN_SQRT_RATIO + 1);
    stop_prank(CheatTarget::One(pool_swap_test_dispatcher.contract_address));

    start_prank(CheatTarget::One(pool_address), user1());
    pool_dispatcher.burn(tick_lower, tick_upper, 1);
    stop_prank(CheatTarget::One(pool_address));

    assert(
        pool_dispatcher.get_tick_info(tick_lower).liquidity_gross == 0,
        'Incorrect liquidity_gross lower'
    );
    assert(
        pool_dispatcher.get_tick_info(tick_lower).fee_growth_outside_0_X128 == 0,
        'Incorrect fee_growth_0 lower'
    );
    assert(
        pool_dispatcher.get_tick_info(tick_lower).fee_growth_outside_1_X128 == 0,
        'Incorrect fee_growth_1 lower'
    );
    assert(
        pool_dispatcher
            .get_tick_info(tick_lower)
            .liquidity_net == IntegerTrait::<i128>::new(0, false),
        'Incorrect liquidity_net lower'
    );

    assert(
        pool_dispatcher.get_tick_info(tick_upper).liquidity_gross != 0,
        'Incorrect liquidity_gross upper'
    );
}

#[test]
fn test_burn_clears_only_the_upper_tick_if_lower_is_still_used() {
    let (pool_address, pool_mint_test_dispatcher) = initiate_pool_1_1_with_intial_mint();

    let tick_lower = get_min_tick() + IntegerTrait::<i32>::new(60, false);
    let tick_upper = get_max_tick() - IntegerTrait::<i32>::new(60, false);

    let pool_dispatcher = IJediSwapV2PoolDispatcher { contract_address: pool_address };

    start_prank(CheatTarget::One(pool_mint_test_dispatcher.contract_address), user1());
    pool_mint_test_dispatcher.mint(pool_address, user1(), tick_lower, tick_upper, 1);
    pool_mint_test_dispatcher
        .mint(
            pool_address, user1(), tick_lower, tick_upper - IntegerTrait::<i32>::new(60, false), 1
        );
    stop_prank(CheatTarget::One(pool_mint_test_dispatcher.contract_address));

    let pool_swap_test_dispatcher = get_pool_swap_test_dispatcher();

    let token0_dispatcher = IERC20Dispatcher { contract_address: pool_dispatcher.get_token0() };
    start_prank(CheatTarget::One(pool_dispatcher.get_token0()), user1());
    token0_dispatcher.approve(pool_swap_test_dispatcher.contract_address, 100 * pow(10, 18));
    stop_prank(CheatTarget::One(pool_dispatcher.get_token0()));

    start_prank(CheatTarget::One(pool_swap_test_dispatcher.contract_address), user1());
    pool_swap_test_dispatcher
        .swap_exact_0_for_1(pool_address, pow(10, 18), user1(), MIN_SQRT_RATIO + 1);
    stop_prank(CheatTarget::One(pool_swap_test_dispatcher.contract_address));

    start_prank(CheatTarget::One(pool_address), user1());
    pool_dispatcher.burn(tick_lower, tick_upper, 1);
    stop_prank(CheatTarget::One(pool_address));

    assert(
        pool_dispatcher.get_tick_info(tick_lower).liquidity_gross != 0,
        'Incorrect liquidity_gross lower'
    );

    assert(
        pool_dispatcher.get_tick_info(tick_upper).liquidity_gross == 0,
        'Incorrect liquidity_gross upper'
    );
    assert(
        pool_dispatcher.get_tick_info(tick_upper).fee_growth_outside_0_X128 == 0,
        'Incorrect fee_growth_0 upper'
    );
    assert(
        pool_dispatcher.get_tick_info(tick_upper).fee_growth_outside_1_X128 == 0,
        'Incorrect fee_growth_1 upper'
    );
    assert(
        pool_dispatcher
            .get_tick_info(tick_upper)
            .liquidity_net == IntegerTrait::<i128>::new(0, false),
        'Incorrect liquidity_net upper'
    );
}

#[test]
fn test_liquidity_returns_0_before_initialization() {
    let pool_address = create_pool();

    let pool_dispatcher = IJediSwapV2PoolDispatcher { contract_address: pool_address };

    assert(pool_dispatcher.get_liquidity() == 0, 'Incorrect liquidity');
}

#[test]
fn test_liquidity_post_initialized_returns_initial_liquidity() {
    let (pool_address, pool_mint_test_dispatcher) = initiate_pool_1_1_with_intial_mint();

    let pool_dispatcher = IJediSwapV2PoolDispatcher { contract_address: pool_address };

    assert(
        pool_dispatcher.get_liquidity() == 2 * pow(10, 18).try_into().unwrap(),
        'Incorrect liquidity'
    );
}

#[test]
fn test_liquidity_post_initialized_returns_in_supply_in_range() {
    let (pool_address, pool_mint_test_dispatcher) = initiate_pool_1_1_with_intial_mint();

    let pool_dispatcher = IJediSwapV2PoolDispatcher { contract_address: pool_address };

    start_prank(CheatTarget::One(pool_mint_test_dispatcher.contract_address), user1());
    pool_mint_test_dispatcher
        .mint(
            pool_address,
            user1(),
            IntegerTrait::<i32>::new(60, true),
            IntegerTrait::<i32>::new(60, false),
            3 * pow(10, 18).try_into().unwrap()
        );
    stop_prank(CheatTarget::One(pool_mint_test_dispatcher.contract_address));

    assert(
        pool_dispatcher.get_liquidity() == 5 * pow(10, 18).try_into().unwrap(),
        'Incorrect liquidity'
    );
}

#[test]
fn test_liquidity_post_initialized_excludes_supply_at_tick_above_current_tick() {
    let (pool_address, pool_mint_test_dispatcher) = initiate_pool_1_1_with_intial_mint();

    let pool_dispatcher = IJediSwapV2PoolDispatcher { contract_address: pool_address };

    start_prank(CheatTarget::One(pool_mint_test_dispatcher.contract_address), user1());
    pool_mint_test_dispatcher
        .mint(
            pool_address,
            user1(),
            IntegerTrait::<i32>::new(60, false),
            IntegerTrait::<i32>::new(120, false),
            3 * pow(10, 18).try_into().unwrap()
        );
    stop_prank(CheatTarget::One(pool_mint_test_dispatcher.contract_address));

    assert(
        pool_dispatcher.get_liquidity() == 2 * pow(10, 18).try_into().unwrap(),
        'Incorrect liquidity'
    );
}

#[test]
fn test_liquidity_post_initialized_excludes_supply_at_tick_below_current_tick() {
    let (pool_address, pool_mint_test_dispatcher) = initiate_pool_1_1_with_intial_mint();

    let pool_dispatcher = IJediSwapV2PoolDispatcher { contract_address: pool_address };

    start_prank(CheatTarget::One(pool_mint_test_dispatcher.contract_address), user1());
    pool_mint_test_dispatcher
        .mint(
            pool_address,
            user1(),
            IntegerTrait::<i32>::new(120, true),
            IntegerTrait::<i32>::new(60, true),
            3 * pow(10, 18).try_into().unwrap()
        );
    stop_prank(CheatTarget::One(pool_mint_test_dispatcher.contract_address));

    assert(
        pool_dispatcher.get_liquidity() == 2 * pow(10, 18).try_into().unwrap(),
        'Incorrect liquidity'
    );
}

#[test]
fn test_liquidity_post_initialized_updates_correctly_when_exiting_range() {
    let (pool_address, pool_mint_test_dispatcher) = initiate_pool_1_1_with_intial_mint();

    let pool_dispatcher = IJediSwapV2PoolDispatcher { contract_address: pool_address };

    let k_before = pool_dispatcher.get_liquidity();

    assert(k_before == 2 * pow(10, 18).try_into().unwrap(), 'Incorrect liquidity');

    // add liquidity at and above current tick
    start_prank(CheatTarget::One(pool_mint_test_dispatcher.contract_address), user1());
    pool_mint_test_dispatcher
        .mint(
            pool_address,
            user1(),
            IntegerTrait::<i32>::new(0, false),
            IntegerTrait::<i32>::new(60, false),
            pow(10, 18).try_into().unwrap()
        );
    stop_prank(CheatTarget::One(pool_mint_test_dispatcher.contract_address));

    let k_after = pool_dispatcher.get_liquidity();

    assert(k_after == 3 * pow(10, 18).try_into().unwrap(), 'Incorrect liquidity');

    let pool_swap_test_dispatcher = get_pool_swap_test_dispatcher();

    let token0_dispatcher = IERC20Dispatcher { contract_address: pool_dispatcher.get_token0() };
    start_prank(CheatTarget::One(pool_dispatcher.get_token0()), user1());
    token0_dispatcher.approve(pool_swap_test_dispatcher.contract_address, 100 * pow(10, 18));
    stop_prank(CheatTarget::One(pool_dispatcher.get_token0()));

    // swap toward the left (just enough for the tick transition function to trigger)
    start_prank(CheatTarget::One(pool_swap_test_dispatcher.contract_address), user1());
    pool_swap_test_dispatcher.swap_exact_0_for_1(pool_address, 1, user1(), MIN_SQRT_RATIO + 1);
    stop_prank(CheatTarget::One(pool_swap_test_dispatcher.contract_address));

    assert(pool_dispatcher.get_tick() == IntegerTrait::<i32>::new(1, true), 'Invalid Tick');

    assert(
        pool_dispatcher.get_liquidity() == 2 * pow(10, 18).try_into().unwrap(),
        'Incorrect liquidity'
    );
}

#[test]
fn test_liquidity_post_initialized_updates_correctly_when_entering_range() {
    let (pool_address, pool_mint_test_dispatcher) = initiate_pool_1_1_with_intial_mint();

    let pool_dispatcher = IJediSwapV2PoolDispatcher { contract_address: pool_address };

    let k_before = pool_dispatcher.get_liquidity();

    assert(k_before == 2 * pow(10, 18).try_into().unwrap(), 'Incorrect liquidity');

    // add liquidity below current tick
    start_prank(CheatTarget::One(pool_mint_test_dispatcher.contract_address), user1());
    pool_mint_test_dispatcher
        .mint(
            pool_address,
            user1(),
            IntegerTrait::<i32>::new(60, true),
            IntegerTrait::<i32>::new(0, false),
            pow(10, 18).try_into().unwrap()
        );
    stop_prank(CheatTarget::One(pool_mint_test_dispatcher.contract_address));

    // ensure virtual supply hasn't changed
    let k_after = pool_dispatcher.get_liquidity();

    assert(k_after == k_before, 'Incorrect liquidity');

    let pool_swap_test_dispatcher = get_pool_swap_test_dispatcher();

    let token0_dispatcher = IERC20Dispatcher { contract_address: pool_dispatcher.get_token0() };
    start_prank(CheatTarget::One(pool_dispatcher.get_token0()), user1());
    token0_dispatcher.approve(pool_swap_test_dispatcher.contract_address, 100 * pow(10, 18));
    stop_prank(CheatTarget::One(pool_dispatcher.get_token0()));

    // swap toward the left (just enough for the tick transition function to trigger)
    start_prank(CheatTarget::One(pool_swap_test_dispatcher.contract_address), user1());
    pool_swap_test_dispatcher.swap_exact_0_for_1(pool_address, 1, user1(), MIN_SQRT_RATIO + 1);
    stop_prank(CheatTarget::One(pool_swap_test_dispatcher.contract_address));

    assert(pool_dispatcher.get_tick() == IntegerTrait::<i32>::new(1, true), 'Invalid Tick');

    assert(
        pool_dispatcher.get_liquidity() == 3 * pow(10, 18).try_into().unwrap(),
        'Incorrect liquidity'
    );
}

#[test]
fn test_limit_selling_0_for_1_at_tick_0_thru_1() {
    let (pool_address, pool_mint_test_dispatcher) = initiate_pool_1_1_with_intial_mint();

    let pool_dispatcher = IJediSwapV2PoolDispatcher { contract_address: pool_address };

    let mut spy = spy_events(SpyOn::One(pool_dispatcher.get_token0()));

    start_prank(CheatTarget::One(pool_mint_test_dispatcher.contract_address), user1());
    pool_mint_test_dispatcher
        .mint(
            pool_address,
            user1(),
            IntegerTrait::<i32>::new(0, false),
            IntegerTrait::<i32>::new(120, false),
            pow(10, 18).try_into().unwrap()
        );
    stop_prank(CheatTarget::One(pool_mint_test_dispatcher.contract_address));

    spy
        .assert_emitted(
            @array![
                (
                    pool_dispatcher.get_token0(),
                    ERC20Component::Event::Transfer(
                        ERC20Component::Transfer {
                            from: user1(), to: pool_address, value: 5981737760509663
                        }
                    )
                )
            ]
        );

    let pool_swap_test_dispatcher = get_pool_swap_test_dispatcher();

    let token1_dispatcher = IERC20Dispatcher { contract_address: pool_dispatcher.get_token1() };
    start_prank(CheatTarget::One(pool_dispatcher.get_token1()), user2());
    token1_dispatcher.approve(pool_swap_test_dispatcher.contract_address, 100 * pow(10, 18));
    stop_prank(CheatTarget::One(pool_dispatcher.get_token1()));

    // somebody takes the limit order
    start_prank(CheatTarget::One(pool_swap_test_dispatcher.contract_address), user2());
    pool_swap_test_dispatcher
        .swap_exact_1_for_0(pool_address, 2 * pow(10, 18), user2(), MAX_SQRT_RATIO - 1);
    stop_prank(CheatTarget::One(pool_swap_test_dispatcher.contract_address));

    let mut spy = spy_events(SpyOn::One(pool_address));

    start_prank(CheatTarget::One(pool_address), user1());
    pool_dispatcher
        .burn(
            IntegerTrait::<i32>::new(0, false),
            IntegerTrait::<i32>::new(120, false),
            pow(10, 18).try_into().unwrap()
        );
    stop_prank(CheatTarget::One(pool_address));

    spy
        .assert_emitted(
            @array![
                (
                    pool_address,
                    JediSwapV2Pool::Event::Burn(
                        JediSwapV2Pool::Burn {
                            owner: user1(),
                            tick_lower: IntegerTrait::<i32>::new(0, false),
                            tick_upper: IntegerTrait::<i32>::new(120, false),
                            amount: pow(10, 18).try_into().unwrap(),
                            amount0: 0,
                            amount1: 6017734268818165
                        }
                    )
                )
            ]
        );

    let mut spy = spy_events(SpyOn::One(pool_dispatcher.get_token1()));

    start_prank(CheatTarget::One(pool_address), user1());
    let (amount0, amount1) = pool_dispatcher
        .collect(
            user1(),
            IntegerTrait::<i32>::new(0, false),
            IntegerTrait::<i32>::new(120, false),
            BoundedInt::<u128>::max(),
            BoundedInt::<u128>::max()
        );
    stop_prank(CheatTarget::One(pool_address));

    spy
        .assert_emitted(
            @array![
                (
                    pool_dispatcher.get_token1(),
                    ERC20Component::Event::Transfer(
                        ERC20Component::Transfer {
                            from: pool_address,
                            to: user1(),
                            value: 6017734268818165 + 18107525382602
                        }
                    ) // roughly 0.3%
                )
            ]
        );

    assert(pool_dispatcher.get_tick() > IntegerTrait::<i32>::new(120, false), 'Invalid Tick');
}

#[test]
fn test_limit_selling_1_for_0_at_tick_0_thru_minus_1() {
    let (pool_address, pool_mint_test_dispatcher) = initiate_pool_1_1_with_intial_mint();

    let pool_dispatcher = IJediSwapV2PoolDispatcher { contract_address: pool_address };

    let mut spy = spy_events(SpyOn::One(pool_dispatcher.get_token1()));

    start_prank(CheatTarget::One(pool_mint_test_dispatcher.contract_address), user1());
    pool_mint_test_dispatcher
        .mint(
            pool_address,
            user1(),
            IntegerTrait::<i32>::new(120, true),
            IntegerTrait::<i32>::new(0, false),
            pow(10, 18).try_into().unwrap()
        );
    stop_prank(CheatTarget::One(pool_mint_test_dispatcher.contract_address));

    spy
        .assert_emitted(
            @array![
                (
                    pool_dispatcher.get_token1(),
                    ERC20Component::Event::Transfer(
                        ERC20Component::Transfer {
                            from: user1(), to: pool_address, value: 5981737760509663
                        }
                    )
                )
            ]
        );

    let pool_swap_test_dispatcher = get_pool_swap_test_dispatcher();

    let token0_dispatcher = IERC20Dispatcher { contract_address: pool_dispatcher.get_token0() };
    start_prank(CheatTarget::One(pool_dispatcher.get_token0()), user2());
    token0_dispatcher.approve(pool_swap_test_dispatcher.contract_address, 100 * pow(10, 18));
    stop_prank(CheatTarget::One(pool_dispatcher.get_token0()));

    // somebody takes the limit order
    start_prank(CheatTarget::One(pool_swap_test_dispatcher.contract_address), user2());
    pool_swap_test_dispatcher
        .swap_exact_0_for_1(pool_address, 2 * pow(10, 18), user2(), MIN_SQRT_RATIO + 1);
    stop_prank(CheatTarget::One(pool_swap_test_dispatcher.contract_address));

    let mut spy = spy_events(SpyOn::One(pool_address));

    start_prank(CheatTarget::One(pool_address), user1());
    pool_dispatcher
        .burn(
            IntegerTrait::<i32>::new(120, true),
            IntegerTrait::<i32>::new(0, false),
            pow(10, 18).try_into().unwrap()
        );
    stop_prank(CheatTarget::One(pool_address));

    spy
        .assert_emitted(
            @array![
                (
                    pool_address,
                    JediSwapV2Pool::Event::Burn(
                        JediSwapV2Pool::Burn {
                            owner: user1(),
                            tick_lower: IntegerTrait::<i32>::new(120, true),
                            tick_upper: IntegerTrait::<i32>::new(0, false),
                            amount: pow(10, 18).try_into().unwrap(),
                            amount0: 6017734268818165,
                            amount1: 0
                        }
                    )
                )
            ]
        );

    let mut spy = spy_events(SpyOn::One(pool_dispatcher.get_token0()));

    start_prank(CheatTarget::One(pool_address), user1());
    let (amount0, amount1) = pool_dispatcher
        .collect(
            user1(),
            IntegerTrait::<i32>::new(120, true),
            IntegerTrait::<i32>::new(0, false),
            BoundedInt::<u128>::max(),
            BoundedInt::<u128>::max()
        );
    stop_prank(CheatTarget::One(pool_address));

    spy
        .assert_emitted(
            @array![
                (
                    pool_dispatcher.get_token0(),
                    ERC20Component::Event::Transfer(
                        ERC20Component::Transfer {
                            from: pool_address,
                            to: user1(),
                            value: 6017734268818165 + 18107525382602
                        }
                    ) // roughly 0.3%
                )
            ]
        );

    assert(pool_dispatcher.get_tick() < IntegerTrait::<i32>::new(120, true), 'Invalid Tick');
}

#[test]
fn test_limit_selling_0_for_1_at_tick_0_thru_1_fee_is_on() {
    let (pool_address, pool_mint_test_dispatcher) = initiate_pool_1_1_with_intial_mint();

    let pool_dispatcher = IJediSwapV2PoolDispatcher { contract_address: pool_address };

    let factory_address = pool_dispatcher.get_factory();

    let factory_dispatcher = IJediSwapV2FactoryDispatcher { contract_address: factory_address };

    start_prank(CheatTarget::One(factory_address), owner());
    factory_dispatcher.set_fee_protocol(6);
    stop_prank(CheatTarget::One(factory_address));

    let mut spy = spy_events(SpyOn::One(pool_dispatcher.get_token0()));

    start_prank(CheatTarget::One(pool_mint_test_dispatcher.contract_address), user1());
    pool_mint_test_dispatcher
        .mint(
            pool_address,
            user1(),
            IntegerTrait::<i32>::new(0, false),
            IntegerTrait::<i32>::new(120, false),
            pow(10, 18).try_into().unwrap()
        );
    stop_prank(CheatTarget::One(pool_mint_test_dispatcher.contract_address));

    spy
        .assert_emitted(
            @array![
                (
                    pool_dispatcher.get_token0(),
                    ERC20Component::Event::Transfer(
                        ERC20Component::Transfer {
                            from: user1(), to: pool_address, value: 5981737760509663
                        }
                    )
                )
            ]
        );

    let pool_swap_test_dispatcher = get_pool_swap_test_dispatcher();

    let token1_dispatcher = IERC20Dispatcher { contract_address: pool_dispatcher.get_token1() };
    start_prank(CheatTarget::One(pool_dispatcher.get_token1()), user2());
    token1_dispatcher.approve(pool_swap_test_dispatcher.contract_address, 100 * pow(10, 18));
    stop_prank(CheatTarget::One(pool_dispatcher.get_token1()));

    // somebody takes the limit order
    start_prank(CheatTarget::One(pool_swap_test_dispatcher.contract_address), user2());
    pool_swap_test_dispatcher
        .swap_exact_1_for_0(pool_address, 2 * pow(10, 18), user2(), MAX_SQRT_RATIO - 1);
    stop_prank(CheatTarget::One(pool_swap_test_dispatcher.contract_address));

    let mut spy = spy_events(SpyOn::One(pool_address));

    start_prank(CheatTarget::One(pool_address), user1());
    pool_dispatcher
        .burn(
            IntegerTrait::<i32>::new(0, false),
            IntegerTrait::<i32>::new(120, false),
            pow(10, 18).try_into().unwrap()
        );
    stop_prank(CheatTarget::One(pool_address));

    spy
        .assert_emitted(
            @array![
                (
                    pool_address,
                    JediSwapV2Pool::Event::Burn(
                        JediSwapV2Pool::Burn {
                            owner: user1(),
                            tick_lower: IntegerTrait::<i32>::new(0, false),
                            tick_upper: IntegerTrait::<i32>::new(120, false),
                            amount: pow(10, 18).try_into().unwrap(),
                            amount0: 0,
                            amount1: 6017734268818165
                        }
                    )
                )
            ]
        );

    let mut spy = spy_events(SpyOn::One(pool_dispatcher.get_token1()));

    start_prank(CheatTarget::One(pool_address), user1());
    let (amount0, amount1) = pool_dispatcher
        .collect(
            user1(),
            IntegerTrait::<i32>::new(0, false),
            IntegerTrait::<i32>::new(120, false),
            BoundedInt::<u128>::max(),
            BoundedInt::<u128>::max()
        );
    stop_prank(CheatTarget::One(pool_address));

    spy
        .assert_emitted(
            @array![
                (
                    pool_dispatcher.get_token1(),
                    ERC20Component::Event::Transfer(
                        ERC20Component::Transfer {
                            from: pool_address,
                            to: user1(),
                            value: 6017734268818165 + 15089604485501
                        }
                    ) // roughly 0.25%
                )
            ]
        );

    assert(pool_dispatcher.get_tick() > IntegerTrait::<i32>::new(120, false), 'Invalid Tick');
}

#[test]
fn test_limit_selling_1_for_0_at_tick_0_thru_minus_1_fee_is_on() {
    let (pool_address, pool_mint_test_dispatcher) = initiate_pool_1_1_with_intial_mint();

    let pool_dispatcher = IJediSwapV2PoolDispatcher { contract_address: pool_address };

    let factory_address = pool_dispatcher.get_factory();

    let factory_dispatcher = IJediSwapV2FactoryDispatcher { contract_address: factory_address };

    start_prank(CheatTarget::One(factory_address), owner());
    factory_dispatcher.set_fee_protocol(6);
    stop_prank(CheatTarget::One(factory_address));

    let mut spy = spy_events(SpyOn::One(pool_dispatcher.get_token1()));

    start_prank(CheatTarget::One(pool_mint_test_dispatcher.contract_address), user1());
    pool_mint_test_dispatcher
        .mint(
            pool_address,
            user1(),
            IntegerTrait::<i32>::new(120, true),
            IntegerTrait::<i32>::new(0, false),
            pow(10, 18).try_into().unwrap()
        );
    stop_prank(CheatTarget::One(pool_mint_test_dispatcher.contract_address));

    spy
        .assert_emitted(
            @array![
                (
                    pool_dispatcher.get_token1(),
                    ERC20Component::Event::Transfer(
                        ERC20Component::Transfer {
                            from: user1(), to: pool_address, value: 5981737760509663
                        }
                    )
                )
            ]
        );

    let pool_swap_test_dispatcher = get_pool_swap_test_dispatcher();

    let token0_dispatcher = IERC20Dispatcher { contract_address: pool_dispatcher.get_token0() };
    start_prank(CheatTarget::One(pool_dispatcher.get_token0()), user2());
    token0_dispatcher.approve(pool_swap_test_dispatcher.contract_address, 100 * pow(10, 18));
    stop_prank(CheatTarget::One(pool_dispatcher.get_token0()));

    // somebody takes the limit order
    start_prank(CheatTarget::One(pool_swap_test_dispatcher.contract_address), user2());
    pool_swap_test_dispatcher
        .swap_exact_0_for_1(pool_address, 2 * pow(10, 18), user2(), MIN_SQRT_RATIO + 1);
    stop_prank(CheatTarget::One(pool_swap_test_dispatcher.contract_address));

    let mut spy = spy_events(SpyOn::One(pool_address));

    start_prank(CheatTarget::One(pool_address), user1());
    pool_dispatcher
        .burn(
            IntegerTrait::<i32>::new(120, true),
            IntegerTrait::<i32>::new(0, false),
            pow(10, 18).try_into().unwrap()
        );
    stop_prank(CheatTarget::One(pool_address));

    spy
        .assert_emitted(
            @array![
                (
                    pool_address,
                    JediSwapV2Pool::Event::Burn(
                        JediSwapV2Pool::Burn {
                            owner: user1(),
                            tick_lower: IntegerTrait::<i32>::new(120, true),
                            tick_upper: IntegerTrait::<i32>::new(0, false),
                            amount: pow(10, 18).try_into().unwrap(),
                            amount0: 6017734268818165,
                            amount1: 0
                        }
                    )
                )
            ]
        );

    let mut spy = spy_events(SpyOn::One(pool_dispatcher.get_token0()));

    start_prank(CheatTarget::One(pool_address), user1());
    let (amount0, amount1) = pool_dispatcher
        .collect(
            user1(),
            IntegerTrait::<i32>::new(120, true),
            IntegerTrait::<i32>::new(0, false),
            BoundedInt::<u128>::max(),
            BoundedInt::<u128>::max()
        );
    stop_prank(CheatTarget::One(pool_address));

    spy
        .assert_emitted(
            @array![
                (
                    pool_dispatcher.get_token0(),
                    ERC20Component::Event::Transfer(
                        ERC20Component::Transfer {
                            from: pool_address,
                            to: user1(),
                            value: 6017734268818165 + 15089604485501
                        }
                    ) // roughly 0.25%
                )
            ]
        );

    assert(pool_dispatcher.get_tick() < IntegerTrait::<i32>::new(120, true), 'Invalid Tick');
}

fn initiate_pool_1_1_with_intial_mint_1000() -> (ContractAddress, IPoolMintTestDispatcher) {
    let pool_address = create_pool();

    let pool_dispatcher = IJediSwapV2PoolDispatcher { contract_address: pool_address };

    pool_dispatcher.initialize(79228162514264337593543950336); //  encode_price_sqrt(1, 1)

    let pool_mint_test_dispatcher = get_pool_mint_test_dispatcher();

    let pool_dispatcher = IJediSwapV2PoolDispatcher { contract_address: pool_address };

    let token0_dispatcher = IERC20Dispatcher { contract_address: pool_dispatcher.get_token0() };
    start_prank(CheatTarget::One(pool_dispatcher.get_token0()), user1());
    token0_dispatcher.approve(pool_mint_test_dispatcher.contract_address, 1000 * pow(10, 18));
    stop_prank(CheatTarget::One(pool_dispatcher.get_token0()));

    let token1_dispatcher = IERC20Dispatcher { contract_address: pool_dispatcher.get_token1() };
    start_prank(CheatTarget::One(pool_dispatcher.get_token1()), user1());
    token1_dispatcher.approve(pool_mint_test_dispatcher.contract_address, 1000 * pow(10, 18));
    stop_prank(CheatTarget::One(pool_dispatcher.get_token1()));

    start_prank(CheatTarget::One(pool_mint_test_dispatcher.contract_address), user1());
    pool_mint_test_dispatcher
        .mint(
            pool_address,
            user1(),
            get_min_tick(),
            get_max_tick(),
            1000 * pow(10, 18).try_into().unwrap()
        );
    stop_prank(CheatTarget::One(pool_mint_test_dispatcher.contract_address));

    (pool_address, pool_mint_test_dispatcher)
}

fn swap_and_get_fees_owed(
    pool_address: ContractAddress,
    pool_swap_test_dispatcher: IPoolSwapTestDispatcher,
    amount: u256,
    zero_for_one: bool,
    poke: bool
) -> (u128, u128) {
    let pool_dispatcher = IJediSwapV2PoolDispatcher { contract_address: pool_address };

    if (zero_for_one) {
        let token0_dispatcher = IERC20Dispatcher { contract_address: pool_dispatcher.get_token0() };
        start_prank(CheatTarget::One(pool_dispatcher.get_token0()), user1());
        token0_dispatcher.approve(pool_swap_test_dispatcher.contract_address, 100 * pow(10, 18));
        stop_prank(CheatTarget::One(pool_dispatcher.get_token0()));

        start_prank(CheatTarget::One(pool_swap_test_dispatcher.contract_address), user1());
        pool_swap_test_dispatcher
            .swap_exact_0_for_1(pool_address, amount, user1(), MIN_SQRT_RATIO + 1);
        stop_prank(CheatTarget::One(pool_swap_test_dispatcher.contract_address));
    } else {
        let token1_dispatcher = IERC20Dispatcher { contract_address: pool_dispatcher.get_token1() };
        start_prank(CheatTarget::One(pool_dispatcher.get_token1()), user1());
        token1_dispatcher.approve(pool_swap_test_dispatcher.contract_address, 100 * pow(10, 18));
        stop_prank(CheatTarget::One(pool_dispatcher.get_token1()));

        start_prank(CheatTarget::One(pool_swap_test_dispatcher.contract_address), user1());
        pool_swap_test_dispatcher
            .swap_exact_1_for_0(pool_address, amount, user1(), MAX_SQRT_RATIO - 1);
        stop_prank(CheatTarget::One(pool_swap_test_dispatcher.contract_address));
    }

    if (poke) {
        start_prank(CheatTarget::One(pool_address), user1());
        pool_dispatcher.burn(get_min_tick(), get_max_tick(), 0);
        stop_prank(CheatTarget::One(pool_address));
    }

    let (amount0, amount1) = pool_dispatcher
        .static_collect(
            user1(),
            get_min_tick(),
            get_max_tick(),
            BoundedInt::<u128>::max(),
            BoundedInt::<u128>::max()
        );

    (amount0, amount1)
}

#[test]
fn test_fee_protocol_position_owner_gets_full_fees_when_protocol_fee_is_off() {
    let (pool_address, pool_mint_test_dispatcher) = initiate_pool_1_1_with_intial_mint_1000();
    let pool_swap_test_dispatcher = get_pool_swap_test_dispatcher();
    let (token0_fees, token1_fees) = swap_and_get_fees_owed(
        pool_address, pool_swap_test_dispatcher, pow(10, 18), true, true
    );

    assert(token0_fees == 2999999999999999, 'Incorrect token0_fees');
    assert(token1_fees == 0, 'Incorrect token1_fees');
}

#[test]
fn test_fee_protocol_swap_fees_accumulate_as_expected_0_for_1() {
    let (pool_address, pool_mint_test_dispatcher) = initiate_pool_1_1_with_intial_mint_1000();
    let pool_swap_test_dispatcher = get_pool_swap_test_dispatcher();
    let (token0_fees, token1_fees) = swap_and_get_fees_owed(
        pool_address, pool_swap_test_dispatcher, pow(10, 18), true, true
    );

    assert(token0_fees == 2999999999999999, 'Incorrect token0_fees 0');
    assert(token1_fees == 0, 'Incorrect token1_fees');

    let (token0_fees, token1_fees) = swap_and_get_fees_owed(
        pool_address, pool_swap_test_dispatcher, pow(10, 18), true, true
    );

    assert(token0_fees == 2999999999999999 * 2, 'Incorrect token0_fees 1');
    assert(token1_fees == 0, 'Incorrect token1_fees');

    let (token0_fees, token1_fees) = swap_and_get_fees_owed(
        pool_address, pool_swap_test_dispatcher, pow(10, 18), true, true
    );

    assert(token0_fees == 2999999999999999 * 3, 'Incorrect token0_fees 2');
    assert(token1_fees == 0, 'Incorrect token1_fees');
}

#[test]
fn test_fee_protocol_swap_fees_accumulate_as_expected_1_for_0() {
    let (pool_address, pool_mint_test_dispatcher) = initiate_pool_1_1_with_intial_mint_1000();
    let pool_swap_test_dispatcher = get_pool_swap_test_dispatcher();
    let (token0_fees, token1_fees) = swap_and_get_fees_owed(
        pool_address, pool_swap_test_dispatcher, pow(10, 18), false, true
    );

    assert(token0_fees == 0, 'Incorrect token0_fees 0');
    assert(token1_fees == 2999999999999999, 'Incorrect token1_fees');

    let (token0_fees, token1_fees) = swap_and_get_fees_owed(
        pool_address, pool_swap_test_dispatcher, pow(10, 18), false, true
    );

    assert(token0_fees == 0, 'Incorrect token0_fees 1');
    assert(token1_fees == 2999999999999999 * 2, 'Incorrect token1_fees');

    let (token0_fees, token1_fees) = swap_and_get_fees_owed(
        pool_address, pool_swap_test_dispatcher, pow(10, 18), false, true
    );

    assert(token0_fees == 0, 'Incorrect token0_fees 2');
    assert(token1_fees == 2999999999999999 * 3, 'Incorrect token1_fees');
}

#[test]
fn test_fee_protocol_position_owner_gets_partial_fees_when_protocol_fee_is_on() {
    let (pool_address, pool_mint_test_dispatcher) = initiate_pool_1_1_with_intial_mint_1000();

    let pool_dispatcher = IJediSwapV2PoolDispatcher { contract_address: pool_address };

    let factory_address = pool_dispatcher.get_factory();

    let factory_dispatcher = IJediSwapV2FactoryDispatcher { contract_address: factory_address };

    start_prank(CheatTarget::One(factory_address), owner());
    factory_dispatcher.set_fee_protocol(6);
    stop_prank(CheatTarget::One(factory_address));

    let pool_swap_test_dispatcher = get_pool_swap_test_dispatcher();
    let (token0_fees, token1_fees) = swap_and_get_fees_owed(
        pool_address, pool_swap_test_dispatcher, pow(10, 18), true, true
    );

    assert(token0_fees == 2499999999999999, 'Incorrect token0_fees');
    assert(token1_fees == 0, 'Incorrect token1_fees');
}

#[test]
fn test_fee_protocol_collect_protocol_returns_0_if_no_fee() {
    let (pool_address, pool_mint_test_dispatcher) = initiate_pool_1_1_with_intial_mint_1000();

    let pool_dispatcher = IJediSwapV2PoolDispatcher { contract_address: pool_address };

    let factory_address = pool_dispatcher.get_factory();

    let factory_dispatcher = IJediSwapV2FactoryDispatcher { contract_address: factory_address };

    start_prank(CheatTarget::One(factory_address), owner());
    factory_dispatcher.set_fee_protocol(6);
    stop_prank(CheatTarget::One(factory_address));

    start_prank(CheatTarget::One(pool_address), owner());
    let (amount0, amount1) = pool_dispatcher
        .collect_protocol(
            owner(), BoundedInt::<u128>::max(), BoundedInt::<u128>::max()
        ); // TODO static collect_protocol
    stop_prank(CheatTarget::One(pool_address));

    assert(amount0 == 0, 'Incorrect token0_fees');
    assert(amount1 == 0, 'Incorrect token1_fees');
}

#[test]
fn test_fee_protocol_collect_protocol_can_collect_fee() {
    let (pool_address, pool_mint_test_dispatcher) = initiate_pool_1_1_with_intial_mint_1000();

    let pool_dispatcher = IJediSwapV2PoolDispatcher { contract_address: pool_address };

    let factory_address = pool_dispatcher.get_factory();

    let factory_dispatcher = IJediSwapV2FactoryDispatcher { contract_address: factory_address };

    start_prank(CheatTarget::One(factory_address), owner());
    factory_dispatcher.set_fee_protocol(6);
    stop_prank(CheatTarget::One(factory_address));

    let pool_swap_test_dispatcher = get_pool_swap_test_dispatcher();
    let (token0_fees, token1_fees) = swap_and_get_fees_owed(
        pool_address, pool_swap_test_dispatcher, pow(10, 18), true, true
    );

    start_prank(CheatTarget::One(pool_address), owner());
    let (amount0, amount1) = pool_dispatcher
        .collect_protocol(owner(), BoundedInt::<u128>::max(), BoundedInt::<u128>::max());
    stop_prank(CheatTarget::One(pool_address));

    assert(amount0 == 500000000000000, 'Incorrect token0_fees');
    assert(amount1 == 0, 'Incorrect token1_fees');
}

#[test]
fn test_fee_protocol_swap_fees_collected_by_lp_after_two_swaps_should_be_double_one_swap() {
    let (pool_address, pool_mint_test_dispatcher) = initiate_pool_1_1_with_intial_mint_1000();
    let pool_swap_test_dispatcher = get_pool_swap_test_dispatcher();
    let (token0_fees, token1_fees) = swap_and_get_fees_owed(
        pool_address, pool_swap_test_dispatcher, pow(10, 18), true, true
    );

    let (token0_fees, token1_fees) = swap_and_get_fees_owed(
        pool_address, pool_swap_test_dispatcher, pow(10, 18), true, true
    );

    assert(token0_fees == 2999999999999999 * 2, 'Incorrect token0_fees 1');
    assert(token1_fees == 0, 'Incorrect token1_fees');
}

#[test]
fn test_fee_protocol_swap_fees_collected_after_two_swaps_with_fee_turned_on_in_the_middle() {
    let (pool_address, pool_mint_test_dispatcher) = initiate_pool_1_1_with_intial_mint_1000();
    let pool_swap_test_dispatcher = get_pool_swap_test_dispatcher();
    let (token0_fees, token1_fees) = swap_and_get_fees_owed(
        pool_address, pool_swap_test_dispatcher, pow(10, 18), true, true
    );

    let pool_dispatcher = IJediSwapV2PoolDispatcher { contract_address: pool_address };

    let factory_address = pool_dispatcher.get_factory();

    let factory_dispatcher = IJediSwapV2FactoryDispatcher { contract_address: factory_address };

    start_prank(CheatTarget::One(factory_address), owner());
    factory_dispatcher.set_fee_protocol(6);
    stop_prank(CheatTarget::One(factory_address));

    let (token0_fees, token1_fees) = swap_and_get_fees_owed(
        pool_address, pool_swap_test_dispatcher, pow(10, 18), true, true
    );

    assert(token0_fees == 2999999999999999 + 2499999999999999, 'Incorrect token0_fees 1');
    assert(token1_fees == 0, 'Incorrect token1_fees');
}

#[test]
fn test_fee_protocol_swap_fees_collected_by_lp_after_two_swaps_with_intermediate_withdrawal() {
    let (pool_address, pool_mint_test_dispatcher) = initiate_pool_1_1_with_intial_mint_1000();

    let pool_dispatcher = IJediSwapV2PoolDispatcher { contract_address: pool_address };

    let factory_address = pool_dispatcher.get_factory();

    let factory_dispatcher = IJediSwapV2FactoryDispatcher { contract_address: factory_address };

    start_prank(CheatTarget::One(factory_address), owner());
    factory_dispatcher.set_fee_protocol(6);
    stop_prank(CheatTarget::One(factory_address));

    let pool_swap_test_dispatcher = get_pool_swap_test_dispatcher();
    let (token0_fees, token1_fees) = swap_and_get_fees_owed(
        pool_address, pool_swap_test_dispatcher, pow(10, 18), true, true
    );

    assert(token0_fees == 2499999999999999, 'Incorrect token0_fees');
    assert(token1_fees == 0, 'Incorrect token1_fees');

    start_prank(CheatTarget::One(pool_address), user1());
    let (amount0, amount1) = pool_dispatcher
        .collect(
            user1(),
            get_min_tick(),
            get_max_tick(),
            BoundedInt::<u128>::max(),
            BoundedInt::<u128>::max()
        );
    stop_prank(CheatTarget::One(pool_address));

    let (token0_fees_next, token1_fees_next) = swap_and_get_fees_owed(
        pool_address, pool_swap_test_dispatcher, pow(10, 18), true, false
    );

    assert(token0_fees_next == 0, 'Incorrect token0_fees_next');
    assert(token1_fees_next == 0, 'Incorrect token1_fees_next');

    assert(
        pool_dispatcher.get_protocol_fees().token0 == 1000000000000000, 'Incorrect protocol fees 0'
    );
    assert(pool_dispatcher.get_protocol_fees().token1 == 0, 'Incorrect protocol fees 1');

    start_prank(CheatTarget::One(pool_address), user1());
    pool_dispatcher.burn(get_min_tick(), get_max_tick(), 0);
    stop_prank(CheatTarget::One(pool_address));

    start_prank(CheatTarget::One(pool_address), user1());
    let (amount0, amount1) = pool_dispatcher
        .collect(
            user1(),
            get_min_tick(),
            get_max_tick(),
            BoundedInt::<u128>::max(),
            BoundedInt::<u128>::max()
        );
    stop_prank(CheatTarget::One(pool_address));
    assert(amount0 == 2499999999999999, 'Incorrect amount0');
    assert(amount1 == 0, 'Incorrect amount1');

    assert(
        pool_dispatcher.get_protocol_fees().token0 == 1000000000000000, 'Incorrect protocol fees 0'
    );
    assert(pool_dispatcher.get_protocol_fees().token1 == 0, 'Incorrect protocol fees 1');
}
