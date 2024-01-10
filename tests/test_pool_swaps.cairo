use starknet:: { ContractAddress, contract_address_try_from_felt252 };
use integer::BoundedInt;
use yas_core::numbers::signed_integer::{i32::i32, i128::i128, i256::i256, integer_trait::IntegerTrait};
use yas_core::utils::math_utils::{pow};
use openzeppelin::token::erc20::{ ERC20Component, interface::{IERC20Dispatcher, IERC20DispatcherTrait}};
use jediswap_v2_core::libraries::tick_math::TickMath::{MIN_TICK, MAX_TICK, MAX_SQRT_RATIO, MIN_SQRT_RATIO, get_sqrt_ratio_at_tick, get_tick_at_sqrt_ratio};
use jediswap_v2_core::jediswap_v2_factory::{IJediSwapV2FactoryDispatcher, IJediSwapV2FactoryDispatcherTrait};
use jediswap_v2_core::jediswap_v2_pool::{IJediSwapV2PoolDispatcher, IJediSwapV2PoolDispatcherTrait, JediSwapV2Pool};
use jediswap_v2_core::test_contracts::pool_mint_test::{IPoolMintTestDispatcher, IPoolMintTestDispatcherTrait};
use jediswap_v2_core::test_contracts::pool_swap_test::{IPoolSwapTestDispatcher, IPoolSwapTestDispatcherTrait};
use jediswap_v2_core::libraries::position::{PositionKey, PositionInfo};
use snforge_std::{ PrintTrait, declare, ContractClassTrait, start_prank, stop_prank, CheatTarget, spy_events, SpyOn, EventSpy, EventFetcher, Event, EventAssertions };

use super::utils::{owner, user1, user2, token0_1};

//TODO Use setup when available

#[derive(Copy, Drop, Serde)]
struct PoolTestPosition {
    // @notice The lower tick of the position's tick range
    tick_lower: i32,
    // @notice The upper tick of the position's tick range
    tick_upper: i32,
    // @notice The liquidity to mint
    liquidity: u256,
}

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

fn get_min_tick(fee: u32) -> i32 {
    if (fee == 3000) {
        return IntegerTrait::<i32>::new(887220, true); // math.ceil(-887272 / 60) * 60
    } else if (fee == 500) {
        return IntegerTrait::<i32>::new(887270, true); // math.ceil(-887272 / 10) * 10
    } else if (fee == 10000) {
        return IntegerTrait::<i32>::new(887200, true); // math.ceil(-887272 / 200) * 200
    } else {
        return IntegerTrait::<i32>::new(887272, true);  // math.ceil(-887272 / 2) * 2
    }
}

fn get_max_tick(fee: u32) -> i32 {
    if (fee == 3000) {
        return IntegerTrait::<i32>::new(887220, false); // math.floor(887272 / 60) * 60
    } else if (fee == 500) {
        return IntegerTrait::<i32>::new(887270, false); // math.floor(887272 / 10) * 10
    } else if (fee == 10000) {
        return IntegerTrait::<i32>::new(887200, false); // math.floor(887272 / 200) * 200
    } else {
        return IntegerTrait::<i32>::new(887272, false); // math.floor(887272 / 2) * 2
    }
}

fn get_max_liquidity_per_tick(fee: u32) -> u256 {
    if (fee == 3000) {
        return 11505743598341114571880798222544994;     // get_max_liquidity_per_tick(60)
    } else {
        return 0;
    }
}

fn create_pool(fee: u32) -> ContractAddress {
    let (owner, factory_address) = setup_factory();
    let factory_dispatcher = IJediSwapV2FactoryDispatcher { contract_address: factory_address };
    let (token0, token1) = token0_1();


    factory_dispatcher.create_pool(token0, token1, fee);

    let pool_address = factory_dispatcher.get_pool(token0, token1, fee);

    pool_address
}

fn initialize_pool(fee: u32, price0: u256, price1: u256) -> ContractAddress {
    let pool_address = create_pool(fee);

    let pool_dispatcher = IJediSwapV2PoolDispatcher { contract_address: pool_address };

    if (price0 == 1 && price1 == 10) {
        pool_dispatcher.initialize(25054144837504793750611689472);  //  encode_price_sqrt(1, 10)
    } else if (price0 == 10 && price1 == 1) {
        pool_dispatcher.initialize(250541448375047946302209916928);  //  encode_price_sqrt(10, 1)
    } else if (price0 == 1 && price1 == 1) {
        pool_dispatcher.initialize(79228162514264337593543950336);  //  encode_price_sqrt(1, 1)
    } else if (price0 == pow(2, 127) && price1 == 1) {
        pool_dispatcher.initialize(1033437718471923777310199514854514985353235922944);  //  encode_price_sqrt(2 ** 127, 1)
    } else if (price0 == 1 && price1 == pow(2, 127)) {
        pool_dispatcher.initialize(6074000999);  //  encode_price_sqrt(1, 2 ** 127)
    } else if (price0 == 'max' && price1 == 'max') {
        pool_dispatcher.initialize(MAX_SQRT_RATIO - 1);
    } else if (price0 == 'min' && price1 == 'min') {
        pool_dispatcher.initialize(MIN_SQRT_RATIO);
    }

    pool_address
}

fn get_pool_mint_test_dispatcher() -> IPoolMintTestDispatcher {
    let pool_mint_test_class = declare('PoolMintTest');
    let mut pool_mint_test_constructor_calldata = Default::default();

    let pool_mint_test_address = pool_mint_test_class.deploy(@pool_mint_test_constructor_calldata).unwrap();

    IPoolMintTestDispatcher { contract_address: pool_mint_test_address }
}

fn initiate_pool_with_intial_mint(fee: u32, price0: u256, price1: u256, pool_test_positions: Array::<PoolTestPosition>) -> (ContractAddress, IPoolMintTestDispatcher) {
    let pool_address = initialize_pool(fee, price0, price1);

    let pool_mint_test_dispatcher = get_pool_mint_test_dispatcher();

    let pool_dispatcher = IJediSwapV2PoolDispatcher { contract_address: pool_address };

    let token0_dispatcher = IERC20Dispatcher { contract_address: pool_dispatcher.get_token0() };
    start_prank(CheatTarget::One(pool_dispatcher.get_token0()), user1());
    token0_dispatcher.approve(pool_mint_test_dispatcher.contract_address, 100 * pow(10, 18) * pow(10, 18));
    stop_prank(CheatTarget::One(pool_dispatcher.get_token0()));

    let token1_dispatcher = IERC20Dispatcher { contract_address: pool_dispatcher.get_token1() };
    start_prank(CheatTarget::One(pool_dispatcher.get_token1()), user1());
    token1_dispatcher.approve(pool_mint_test_dispatcher.contract_address, 100 * pow(10, 18) * pow(10, 18));
    stop_prank(CheatTarget::One(pool_dispatcher.get_token1()));

    let mut index = 0;
    loop {
        if (index == pool_test_positions.len()) {
            break;
        }
        let pool_test_position = *pool_test_positions[index];
        start_prank(CheatTarget::One(pool_mint_test_dispatcher.contract_address), user1());
        pool_mint_test_dispatcher.mint(pool_address, user1(), pool_test_position.tick_lower, pool_test_position.tick_upper, pool_test_position.liquidity.try_into().unwrap());
        stop_prank(CheatTarget::One(pool_mint_test_dispatcher.contract_address));
        index += 1;
    };

    (pool_address, pool_mint_test_dispatcher)
}

fn get_pool_swap_test_dispatcher(pool_dispatcher: IJediSwapV2PoolDispatcher) -> IPoolSwapTestDispatcher {
    let pool_swap_test_class = declare('PoolSwapTest');
    let mut pool_swap_test_constructor_calldata = Default::default();

    let pool_swap_test_address = pool_swap_test_class.deploy(@pool_swap_test_constructor_calldata).unwrap();

    let pool_swap_test_dispatcher = IPoolSwapTestDispatcher { contract_address: pool_swap_test_address };

    let token0_dispatcher = IERC20Dispatcher { contract_address: pool_dispatcher.get_token0() };
    start_prank(CheatTarget::One(pool_dispatcher.get_token0()), user1());
    token0_dispatcher.approve(pool_swap_test_address, 100 * pow(10, 18) * pow(10, 18));
    stop_prank(CheatTarget::One(pool_dispatcher.get_token0()));

    let token1_dispatcher = IERC20Dispatcher { contract_address: pool_dispatcher.get_token1() };
    start_prank(CheatTarget::One(pool_dispatcher.get_token1()), user1());
    token1_dispatcher.approve(pool_swap_test_address, 100 * pow(10, 18) * pow(10, 18));
    stop_prank(CheatTarget::One(pool_dispatcher.get_token1()));

    pool_swap_test_dispatcher
}

fn execute_and_test_swap(fee: u32, price0: u256, price1: u256, pool_test_positions: Array::<PoolTestPosition>, zero_for_one: bool, exact_out: bool, amount: u256, mut sqrt_price_limit: u256) {
    let (pool_address, pool_mint_test_dispatcher)  = initiate_pool_with_intial_mint(fee, price0, price1, pool_test_positions);

    let pool_dispatcher = IJediSwapV2PoolDispatcher { contract_address: pool_address };
    
    let token0_dispatcher = IERC20Dispatcher { contract_address: pool_dispatcher.get_token0() };
    let pool_balance0 = token0_dispatcher.balance_of(pool_address);
    
    let token1_dispatcher = IERC20Dispatcher { contract_address: pool_dispatcher.get_token1() };
    let pool_balance1 = token1_dispatcher.balance_of(pool_address);

    let pool_swap_test_dispatcher = get_pool_swap_test_dispatcher(pool_dispatcher);

    let mut spy = spy_events(SpyOn::Multiple(array![pool_dispatcher.get_token0(), pool_dispatcher.get_token1(), pool_address]));
    
    start_prank(CheatTarget::One(pool_swap_test_dispatcher.contract_address), user1());
    if (amount != 0) {
        if (exact_out) {
            if (zero_for_one) {
                if (sqrt_price_limit == 0) {
                    sqrt_price_limit = MIN_SQRT_RATIO + 1;
                }
                pool_swap_test_dispatcher.swap_0_for_exact_1(pool_address, amount, user1(), sqrt_price_limit);
            } else {
                if (sqrt_price_limit == 0) {
                    sqrt_price_limit = MAX_SQRT_RATIO - 1;
                }
                pool_swap_test_dispatcher.swap_1_for_exact_0(pool_address, amount, user1(), sqrt_price_limit);
            }
        } else {
            if (zero_for_one) {
                if (sqrt_price_limit == 0) {
                    sqrt_price_limit = MIN_SQRT_RATIO + 1;
                }
                pool_swap_test_dispatcher.swap_exact_0_for_1(pool_address, amount, user1(), sqrt_price_limit);
            } else {
                if (sqrt_price_limit == 0) {
                    sqrt_price_limit = MAX_SQRT_RATIO - 1;
                }
                pool_swap_test_dispatcher.swap_exact_1_for_0(pool_address, amount, user1(), sqrt_price_limit);
            }
        }
    } else {
        if (zero_for_one) {
                pool_swap_test_dispatcher.swap_to_lower_sqrt_price(pool_address, sqrt_price_limit, user1());
            } else {
                pool_swap_test_dispatcher.swap_to_higher_sqrt_price(pool_address, sqrt_price_limit, user1());
            }
    }
    stop_prank(CheatTarget::One(pool_swap_test_dispatcher.contract_address));

    let pool_balance0_after = token0_dispatcher.balance_of(pool_address);
    let pool_balance1_after = token1_dispatcher.balance_of(pool_address);

    let pool_balance0_delta = IntegerTrait::<i256>::new(pool_balance0_after, false) - pool_balance0.into();
    let pool_balance1_delta = IntegerTrait::<i256>::new(pool_balance1_after, false) - pool_balance1.into();

    if (pool_balance0_delta < IntegerTrait::<i256>::new(0, false)) {
        spy.assert_emitted(@array![
            (
                pool_dispatcher.get_token0(), 
                ERC20Component::Event::Transfer(ERC20Component::Transfer{ from: pool_address, to: user1(), value: (-pool_balance0_delta).try_into().unwrap() })
            )
        ]);
    } else if (pool_balance0_delta > IntegerTrait::<i256>::new(0, false)) {
        spy.assert_emitted(@array![
            (
                pool_dispatcher.get_token0(), 
                ERC20Component::Event::Transfer(ERC20Component::Transfer{ from: user1(), to: pool_address, value: pool_balance0_delta.try_into().unwrap() })
            )
        ]);
    }

    if (pool_balance1_delta < IntegerTrait::<i256>::new(0, false)) {
        spy.assert_emitted(@array![
            (
                pool_dispatcher.get_token1(), 
                ERC20Component::Event::Transfer(ERC20Component::Transfer{ from: pool_address, to: user1(), value: (-pool_balance1_delta).try_into().unwrap() })
            )
        ]);
    } else if (pool_balance1_delta > IntegerTrait::<i256>::new(0, false)) {
        spy.assert_emitted(@array![
            (
                pool_dispatcher.get_token1(), 
                ERC20Component::Event::Transfer(ERC20Component::Transfer{ from: user1(), to: pool_address, value: pool_balance1_delta.try_into().unwrap() })
            )
        ]);
    }

    spy.assert_emitted(@array![
            (
                pool_address, 
                JediSwapV2Pool::Event::Swap(JediSwapV2Pool::Swap{sender: pool_swap_test_dispatcher.contract_address, 
                recipient: user1(), 
                amount0: pool_balance0_delta, 
                amount1: pool_balance1_delta, 
                sqrt_price_X96: pool_dispatcher.get_sqrt_price_X96(), 
                liquidity: pool_dispatcher.get_liquidity(),
                tick: pool_dispatcher.get_tick()})
            )
        ]);
}


//////
//////

#[test]
fn test_swap_3000_fee_1_10_price_max_range_liquidity_swap_large_amount_zero_for_one_true_exact_input() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 10;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = true;
    let exact_out = false;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_1_10_price_max_range_liquidity_swap_large_amount_zero_for_one_false_exact_input() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 10;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = false;
    let exact_out = false;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_1_10_price_max_range_liquidity_swap_large_amount_zero_for_one_true_exact_output() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 10;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = true;
    let exact_out = true;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_1_10_price_max_range_liquidity_swap_large_amount_zero_for_one_false_exact_output() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 10;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = false;
    let exact_out = true;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit);
}

#[test]
#[should_panic(expected: ('SPL',))]
fn test_swap_3000_fee_1_10_price_max_range_liquidity_swap_large_amount_with_price_limit_zero_for_one_true_exact_input() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 10;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = true;
    let exact_out = false;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 56022770974786143748341366784;   // encode_price_sqrt(50, 100)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_1_10_price_max_range_liquidity_swap_large_amount_with_price_limit_zero_for_one_false_exact_input() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 10;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = false;
    let exact_out = false;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 112045541949572287496682733568;  // encode_price_sqrt(200, 100)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit);
}

#[test]
#[should_panic(expected: ('SPL',))]
fn test_swap_3000_fee_1_10_price_max_range_liquidity_swap_large_amount_with_price_limit_zero_for_one_true_exact_output() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 10;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = true;
    let exact_out = true;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 56022770974786143748341366784;   // encode_price_sqrt(50, 100)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_1_10_price_max_range_liquidity_swap_large_amount_with_price_limit_zero_for_one_false_exact_output() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 10;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = false;
    let exact_out = true;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 112045541949572287496682733568;  // encode_price_sqrt(200, 100)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_1_10_price_max_range_liquidity_swap_small_amount_zero_for_one_true_exact_input() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 10;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = true;
    let exact_out = false;
    let amount0 = 1000;
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_1_10_price_max_range_liquidity_swap_small_amount_zero_for_one_false_exact_input() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 10;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = false;
    let exact_out = false;
    let amount1 = 1000;
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_1_10_price_max_range_liquidity_swap_small_amount_zero_for_one_true_exact_output() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 10;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = true;
    let exact_out = true;
    let amount1 = 1000;
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_1_10_price_max_range_liquidity_swap_small_amount_zero_for_one_false_exact_output() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 10;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = false;
    let exact_out = true;
    let amount0 = 1000;
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_1_10_price_max_range_liquidity_swap_arbitrary_amount_to_price_zero_for_one_false_price_limit_5_2() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 10;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = false;
    let exact_out = false;
    let sqrt_price_limit = 125270724187523973151104958464;  // encode_price_sqrt(5, 2)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit);
}

#[test]
#[should_panic(expected: ('SPL',))]
fn test_swap_3000_fee_1_10_price_max_range_liquidity_swap_arbitrary_amount_to_price_zero_for_one_true_price_limit_5_2() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 10;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = true;
    let exact_out = false;
    let sqrt_price_limit = 125270724187523973151104958464;  // encode_price_sqrt(5, 2)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_1_10_price_max_range_liquidity_swap_arbitrary_amount_to_price_zero_for_one_false_price_limit_2_5() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 10;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = false;
    let exact_out = false;
    let sqrt_price_limit = 50108289675009587501223378944;  // encode_price_sqrt(2, 5)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit);
}

#[test]
#[should_panic(expected: ('SPL',))]
fn test_swap_3000_fee_1_10_price_max_range_liquidity_swap_arbitrary_amount_to_price_zero_for_one_true_price_limit_2_5() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 10;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = true;
    let exact_out = false;
    let sqrt_price_limit = 50108289675009587501223378944;  // encode_price_sqrt(2, 5)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit);
}

//////
//////

#[test]
fn test_swap_3000_fee_10_1_price_max_range_liquidity_swap_large_amount_zero_for_one_true_exact_input() {
    let fee = 3000;
    let price0 = 10;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = true;
    let exact_out = false;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_10_1_price_max_range_liquidity_swap_large_amount_zero_for_one_false_exact_input() {
    let fee = 3000;
    let price0 = 10;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = false;
    let exact_out = false;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_10_1_price_max_range_liquidity_swap_large_amount_zero_for_one_true_exact_output() {
    let fee = 3000;
    let price0 = 10;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = true;
    let exact_out = true;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_10_1_price_max_range_liquidity_swap_large_amount_zero_for_one_false_exact_output() {
    let fee = 3000;
    let price0 = 10;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = false;
    let exact_out = true;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_10_1_price_max_range_liquidity_swap_large_amount_with_price_limit_zero_for_one_true_exact_input() {
    let fee = 3000;
    let price0 = 10;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = true;
    let exact_out = false;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 56022770974786143748341366784;   // encode_price_sqrt(50, 100)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit);
}

#[test]
#[should_panic(expected: ('SPL',))]
fn test_swap_3000_fee_10_1_price_max_range_liquidity_swap_large_amount_with_price_limit_zero_for_one_false_exact_input() {
    let fee = 3000;
    let price0 = 10;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = false;
    let exact_out = false;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 112045541949572287496682733568;  // encode_price_sqrt(200, 100)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_10_1_price_max_range_liquidity_swap_large_amount_with_price_limit_zero_for_one_true_exact_output() {
    let fee = 3000;
    let price0 = 10;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = true;
    let exact_out = true;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 56022770974786143748341366784;   // encode_price_sqrt(50, 100)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit);
}

#[test]
#[should_panic(expected: ('SPL',))]
fn test_swap_3000_fee_10_1_price_max_range_liquidity_swap_large_amount_with_price_limit_zero_for_one_false_exact_output() {
    let fee = 3000;
    let price0 = 10;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = false;
    let exact_out = true;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 112045541949572287496682733568;  // encode_price_sqrt(200, 100)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_10_1_price_max_range_liquidity_swap_small_amount_zero_for_one_true_exact_input() {
    let fee = 3000;
    let price0 = 10;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = true;
    let exact_out = false;
    let amount0 = 1000;
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_10_1_price_max_range_liquidity_swap_small_amount_zero_for_one_false_exact_input() {
    let fee = 3000;
    let price0 = 10;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = false;
    let exact_out = false;
    let amount1 = 1000;
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_10_1_price_max_range_liquidity_swap_small_amount_zero_for_one_true_exact_output() {
    let fee = 3000;
    let price0 = 10;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = true;
    let exact_out = true;
    let amount1 = 1000;
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_10_1_price_max_range_liquidity_swap_small_amount_zero_for_one_false_exact_output() {
    let fee = 3000;
    let price0 = 10;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = false;
    let exact_out = true;
    let amount0 = 1000;
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit);
}

#[test]
#[should_panic(expected: ('SPL',))]
fn test_swap_3000_fee_10_1_price_max_range_liquidity_swap_arbitrary_amount_to_price_zero_for_one_false_price_limit_5_2() {
    let fee = 3000;
    let price0 = 10;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = false;
    let exact_out = false;
    let sqrt_price_limit = 125270724187523973151104958464;  // encode_price_sqrt(5, 2)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_10_1_price_max_range_liquidity_swap_arbitrary_amount_to_price_zero_for_one_true_price_limit_5_2() {
    let fee = 3000;
    let price0 = 10;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = true;
    let exact_out = false;
    let sqrt_price_limit = 125270724187523973151104958464;  // encode_price_sqrt(5, 2)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit);
}

#[test]
#[should_panic(expected: ('SPL',))]
fn test_swap_3000_fee_10_1_price_max_range_liquidity_swap_arbitrary_amount_to_price_zero_for_one_false_price_limit_2_5() {
    let fee = 3000;
    let price0 = 10;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = false;
    let exact_out = false;
    let sqrt_price_limit = 50108289675009587501223378944;  // encode_price_sqrt(2, 5)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_10_1_price_max_range_liquidity_swap_arbitrary_amount_to_price_zero_for_one_true_price_limit_2_5() {
    let fee = 3000;
    let price0 = 10;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = true;
    let exact_out = false;
    let sqrt_price_limit = 50108289675009587501223378944;  // encode_price_sqrt(2, 5)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit);
}


//////
//////

#[test]
fn test_swap_3000_fee_1_1_price_max_range_liquidity_swap_large_amount_zero_for_one_true_exact_input() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = true;
    let exact_out = false;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_1_1_price_max_range_liquidity_swap_large_amount_zero_for_one_false_exact_input() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = false;
    let exact_out = false;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_1_1_price_max_range_liquidity_swap_large_amount_zero_for_one_true_exact_output() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = true;
    let exact_out = true;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_1_1_price_max_range_liquidity_swap_large_amount_zero_for_one_false_exact_output() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = false;
    let exact_out = true;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_1_1_price_max_range_liquidity_swap_large_amount_with_price_limit_zero_for_one_true_exact_input() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = true;
    let exact_out = false;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 56022770974786143748341366784;   // encode_price_sqrt(50, 100)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_1_1_price_max_range_liquidity_swap_large_amount_with_price_limit_zero_for_one_false_exact_input() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = false;
    let exact_out = false;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 112045541949572287496682733568;  // encode_price_sqrt(200, 100)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_1_1_price_max_range_liquidity_swap_large_amount_with_price_limit_zero_for_one_true_exact_output() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = true;
    let exact_out = true;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 56022770974786143748341366784;   // encode_price_sqrt(50, 100)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_1_1_price_max_range_liquidity_swap_large_amount_with_price_limit_zero_for_one_false_exact_output() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = false;
    let exact_out = true;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 112045541949572287496682733568;  // encode_price_sqrt(200, 100)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_1_1_price_max_range_liquidity_swap_small_amount_zero_for_one_true_exact_input() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = true;
    let exact_out = false;
    let amount0 = 1000;
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_1_1_price_max_range_liquidity_swap_small_amount_zero_for_one_false_exact_input() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = false;
    let exact_out = false;
    let amount1 = 1000;
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_1_1_price_max_range_liquidity_swap_small_amount_zero_for_one_true_exact_output() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = true;
    let exact_out = true;
    let amount1 = 1000;
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_1_1_price_max_range_liquidity_swap_small_amount_zero_for_one_false_exact_output() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = false;
    let exact_out = true;
    let amount0 = 1000;
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_1_1_price_max_range_liquidity_swap_arbitrary_amount_to_price_zero_for_one_false_price_limit_5_2() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = false;
    let exact_out = false;
    let sqrt_price_limit = 125270724187523973151104958464;  // encode_price_sqrt(5, 2)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit);
}

#[test]
#[should_panic(expected: ('SPL',))]
fn test_swap_3000_fee_1_1_price_max_range_liquidity_swap_arbitrary_amount_to_price_zero_for_one_true_price_limit_5_2() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = true;
    let exact_out = false;
    let sqrt_price_limit = 125270724187523973151104958464;  // encode_price_sqrt(5, 2)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit);
}

#[test]
#[should_panic(expected: ('SPL',))]
fn test_swap_3000_fee_1_1_price_max_range_liquidity_swap_arbitrary_amount_to_price_zero_for_one_false_price_limit_2_5() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = false;
    let exact_out = false;
    let sqrt_price_limit = 50108289675009587501223378944;  // encode_price_sqrt(2, 5)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_1_1_price_max_range_liquidity_swap_arbitrary_amount_to_price_zero_for_one_true_price_limit_2_5() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = true;
    let exact_out = false;
    let sqrt_price_limit = 50108289675009587501223378944;  // encode_price_sqrt(2, 5)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit);
}

//////
//////

#[test]
fn test_swap_100_fee_1_1_price_max_range_liquidity_swap_large_amount_zero_for_one_true_exact_input() {
    let fee = 100;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = true;
    let exact_out = false;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit);
}

#[test]
fn test_swap_100_fee_1_1_price_max_range_liquidity_swap_large_amount_zero_for_one_false_exact_input() {
    let fee = 100;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = false;
    let exact_out = false;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit);
}

#[test]
fn test_swap_100_fee_1_1_price_max_range_liquidity_swap_large_amount_zero_for_one_true_exact_output() {
    let fee = 100;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = true;
    let exact_out = true;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit);
}

#[test]
fn test_swap_100_fee_1_1_price_max_range_liquidity_swap_large_amount_zero_for_one_false_exact_output() {
    let fee = 100;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = false;
    let exact_out = true;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit);
}

#[test]
fn test_swap_100_fee_1_1_price_max_range_liquidity_swap_large_amount_with_price_limit_zero_for_one_true_exact_input() {
    let fee = 100;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = true;
    let exact_out = false;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 56022770974786143748341366784;   // encode_price_sqrt(50, 100)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit);
}

#[test]
fn test_swap_100_fee_1_1_price_max_range_liquidity_swap_large_amount_with_price_limit_zero_for_one_false_exact_input() {
    let fee = 100;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = false;
    let exact_out = false;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 112045541949572287496682733568;  // encode_price_sqrt(200, 100)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit);
}

#[test]
fn test_swap_100_fee_1_1_price_max_range_liquidity_swap_large_amount_with_price_limit_zero_for_one_true_exact_output() {
    let fee = 100;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = true;
    let exact_out = true;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 56022770974786143748341366784;   // encode_price_sqrt(50, 100)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit);
}

#[test]
fn test_swap_100_fee_1_1_price_max_range_liquidity_swap_large_amount_with_price_limit_zero_for_one_false_exact_output() {
    let fee = 100;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = false;
    let exact_out = true;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 112045541949572287496682733568;  // encode_price_sqrt(200, 100)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit);
}

#[test]
fn test_swap_100_fee_1_1_price_max_range_liquidity_swap_small_amount_zero_for_one_true_exact_input() {
    let fee = 100;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = true;
    let exact_out = false;
    let amount0 = 1000;
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit);
}

#[test]
fn test_swap_100_fee_1_1_price_max_range_liquidity_swap_small_amount_zero_for_one_false_exact_input() {
    let fee = 100;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = false;
    let exact_out = false;
    let amount1 = 1000;
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit);
}

#[test]
fn test_swap_100_fee_1_1_price_max_range_liquidity_swap_small_amount_zero_for_one_true_exact_output() {
    let fee = 100;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = true;
    let exact_out = true;
    let amount1 = 1000;
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit);
}

#[test]
fn test_swap_100_fee_1_1_price_max_range_liquidity_swap_small_amount_zero_for_one_false_exact_output() {
    let fee = 100;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = false;
    let exact_out = true;
    let amount0 = 1000;
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit);
}

#[test]
fn test_swap_100_fee_1_1_price_max_range_liquidity_swap_arbitrary_amount_to_price_zero_for_one_false_price_limit_5_2() {
    let fee = 100;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = false;
    let exact_out = false;
    let sqrt_price_limit = 125270724187523973151104958464;  // encode_price_sqrt(5, 2)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit);
}

#[test]
#[should_panic(expected: ('SPL',))]
fn test_swap_100_fee_1_1_price_max_range_liquidity_swap_arbitrary_amount_to_price_zero_for_one_true_price_limit_5_2() {
    let fee = 100;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = true;
    let exact_out = false;
    let sqrt_price_limit = 125270724187523973151104958464;  // encode_price_sqrt(5, 2)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit);
}

#[test]
#[should_panic(expected: ('SPL',))]
fn test_swap_100_fee_1_1_price_max_range_liquidity_swap_arbitrary_amount_to_price_zero_for_one_false_price_limit_2_5() {
    let fee = 100;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = false;
    let exact_out = false;
    let sqrt_price_limit = 50108289675009587501223378944;  // encode_price_sqrt(2, 5)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit);
}

#[test]
fn test_swap_100_fee_1_1_price_max_range_liquidity_swap_arbitrary_amount_to_price_zero_for_one_true_price_limit_2_5() {
    let fee = 100;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = true;
    let exact_out = false;
    let sqrt_price_limit = 50108289675009587501223378944;  // encode_price_sqrt(2, 5)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit);
}

//////
//////

#[test]
fn test_swap_500_fee_1_1_price_max_range_liquidity_swap_large_amount_zero_for_one_true_exact_input() {
    let fee = 500;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = true;
    let exact_out = false;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit);
}

#[test]
fn test_swap_500_fee_1_1_price_max_range_liquidity_swap_large_amount_zero_for_one_false_exact_input() {
    let fee = 500;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = false;
    let exact_out = false;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit);
}

#[test]
fn test_swap_500_fee_1_1_price_max_range_liquidity_swap_large_amount_zero_for_one_true_exact_output() {
    let fee = 500;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = true;
    let exact_out = true;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit);
}

#[test]
fn test_swap_500_fee_1_1_price_max_range_liquidity_swap_large_amount_zero_for_one_false_exact_output() {
    let fee = 500;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = false;
    let exact_out = true;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit);
}

#[test]
fn test_swap_500_fee_1_1_price_max_range_liquidity_swap_large_amount_with_price_limit_zero_for_one_true_exact_input() {
    let fee = 500;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = true;
    let exact_out = false;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 56022770974786143748341366784;   // encode_price_sqrt(50, 100)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit);
}

#[test]
fn test_swap_500_fee_1_1_price_max_range_liquidity_swap_large_amount_with_price_limit_zero_for_one_false_exact_input() {
    let fee = 500;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = false;
    let exact_out = false;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 112045541949572287496682733568;  // encode_price_sqrt(200, 100)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit);
}

#[test]
fn test_swap_500_fee_1_1_price_max_range_liquidity_swap_large_amount_with_price_limit_zero_for_one_true_exact_output() {
    let fee = 500;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = true;
    let exact_out = true;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 56022770974786143748341366784;   // encode_price_sqrt(50, 100)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit);
}

#[test]
fn test_swap_500_fee_1_1_price_max_range_liquidity_swap_large_amount_with_price_limit_zero_for_one_false_exact_output() {
    let fee = 500;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = false;
    let exact_out = true;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 112045541949572287496682733568;  // encode_price_sqrt(200, 100)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit);
}

#[test]
fn test_swap_500_fee_1_1_price_max_range_liquidity_swap_small_amount_zero_for_one_true_exact_input() {
    let fee = 500;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = true;
    let exact_out = false;
    let amount0 = 1000;
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit);
}

#[test]
fn test_swap_500_fee_1_1_price_max_range_liquidity_swap_small_amount_zero_for_one_false_exact_input() {
    let fee = 500;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = false;
    let exact_out = false;
    let amount1 = 1000;
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit);
}

#[test]
fn test_swap_500_fee_1_1_price_max_range_liquidity_swap_small_amount_zero_for_one_true_exact_output() {
    let fee = 500;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = true;
    let exact_out = true;
    let amount1 = 1000;
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit);
}

#[test]
fn test_swap_500_fee_1_1_price_max_range_liquidity_swap_small_amount_zero_for_one_false_exact_output() {
    let fee = 500;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = false;
    let exact_out = true;
    let amount0 = 1000;
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit);
}

#[test]
fn test_swap_500_fee_1_1_price_max_range_liquidity_swap_arbitrary_amount_to_price_zero_for_one_false_price_limit_5_2() {
    let fee = 500;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = false;
    let exact_out = false;
    let sqrt_price_limit = 125270724187523973151104958464;  // encode_price_sqrt(5, 2)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit);
}

#[test]
#[should_panic(expected: ('SPL',))]
fn test_swap_500_fee_1_1_price_max_range_liquidity_swap_arbitrary_amount_to_price_zero_for_one_true_price_limit_5_2() {
    let fee = 500;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = true;
    let exact_out = false;
    let sqrt_price_limit = 125270724187523973151104958464;  // encode_price_sqrt(5, 2)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit);
}

#[test]
#[should_panic(expected: ('SPL',))]
fn test_swap_500_fee_1_1_price_max_range_liquidity_swap_arbitrary_amount_to_price_zero_for_one_false_price_limit_2_5() {
    let fee = 500;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = false;
    let exact_out = false;
    let sqrt_price_limit = 50108289675009587501223378944;  // encode_price_sqrt(2, 5)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit);
}

#[test]
fn test_swap_500_fee_1_1_price_max_range_liquidity_swap_arbitrary_amount_to_price_zero_for_one_true_price_limit_2_5() {
    let fee = 500;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = true;
    let exact_out = false;
    let sqrt_price_limit = 50108289675009587501223378944;  // encode_price_sqrt(2, 5)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit);
}

//////
//////

#[test]
fn test_swap_10000_fee_1_1_price_max_range_liquidity_swap_large_amount_zero_for_one_true_exact_input() {
    let fee = 10000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = true;
    let exact_out = false;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit);
}

#[test]
fn test_swap_10000_fee_1_1_price_max_range_liquidity_swap_large_amount_zero_for_one_false_exact_input() {
    let fee = 10000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = false;
    let exact_out = false;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit);
}

#[test]
fn test_swap_10000_fee_1_1_price_max_range_liquidity_swap_large_amount_zero_for_one_true_exact_output() {
    let fee = 10000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = true;
    let exact_out = true;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit);
}

#[test]
fn test_swap_10000_fee_1_1_price_max_range_liquidity_swap_large_amount_zero_for_one_false_exact_output() {
    let fee = 10000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = false;
    let exact_out = true;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit);
}

#[test]
fn test_swap_10000_fee_1_1_price_max_range_liquidity_swap_large_amount_with_price_limit_zero_for_one_true_exact_input() {
    let fee = 10000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = true;
    let exact_out = false;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 56022770974786143748341366784;   // encode_price_sqrt(50, 100)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit);
}

#[test]
fn test_swap_10000_fee_1_1_price_max_range_liquidity_swap_large_amount_with_price_limit_zero_for_one_false_exact_input() {
    let fee = 10000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = false;
    let exact_out = false;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 112045541949572287496682733568;  // encode_price_sqrt(200, 100)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit);
}

#[test]
fn test_swap_10000_fee_1_1_price_max_range_liquidity_swap_large_amount_with_price_limit_zero_for_one_true_exact_output() {
    let fee = 10000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = true;
    let exact_out = true;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 56022770974786143748341366784;   // encode_price_sqrt(50, 100)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit);
}

#[test]
fn test_swap_10000_fee_1_1_price_max_range_liquidity_swap_large_amount_with_price_limit_zero_for_one_false_exact_output() {
    let fee = 10000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = false;
    let exact_out = true;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 112045541949572287496682733568;  // encode_price_sqrt(200, 100)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit);
}

#[test]
fn test_swap_10000_fee_1_1_price_max_range_liquidity_swap_small_amount_zero_for_one_true_exact_input() {
    let fee = 10000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = true;
    let exact_out = false;
    let amount0 = 1000;
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit);
}

#[test]
fn test_swap_10000_fee_1_1_price_max_range_liquidity_swap_small_amount_zero_for_one_false_exact_input() {
    let fee = 10000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = false;
    let exact_out = false;
    let amount1 = 1000;
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit);
}

#[test]
fn test_swap_10000_fee_1_1_price_max_range_liquidity_swap_small_amount_zero_for_one_true_exact_output() {
    let fee = 10000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = true;
    let exact_out = true;
    let amount1 = 1000;
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit);
}

#[test]
fn test_swap_10000_fee_1_1_price_max_range_liquidity_swap_small_amount_zero_for_one_false_exact_output() {
    let fee = 10000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = false;
    let exact_out = true;
    let amount0 = 1000;
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit);
}

#[test]
fn test_swap_10000_fee_1_1_price_max_range_liquidity_swap_arbitrary_amount_to_price_zero_for_one_false_price_limit_5_2() {
    let fee = 10000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = false;
    let exact_out = false;
    let sqrt_price_limit = 125270724187523973151104958464;  // encode_price_sqrt(5, 2)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit);
}

#[test]
#[should_panic(expected: ('SPL',))]
fn test_swap_10000_fee_1_1_price_max_range_liquidity_swap_arbitrary_amount_to_price_zero_for_one_true_price_limit_5_2() {
    let fee = 10000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = true;
    let exact_out = false;
    let sqrt_price_limit = 125270724187523973151104958464;  // encode_price_sqrt(5, 2)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit);
}

#[test]
#[should_panic(expected: ('SPL',))]
fn test_swap_10000_fee_1_1_price_max_range_liquidity_swap_arbitrary_amount_to_price_zero_for_one_false_price_limit_2_5() {
    let fee = 10000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = false;
    let exact_out = false;
    let sqrt_price_limit = 50108289675009587501223378944;  // encode_price_sqrt(2, 5)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit);
}

#[test]
fn test_swap_10000_fee_1_1_price_max_range_liquidity_swap_arbitrary_amount_to_price_zero_for_one_true_price_limit_2_5() {
    let fee = 10000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = true;
    let exact_out = false;
    let sqrt_price_limit = 50108289675009587501223378944;  // encode_price_sqrt(2, 5)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit);
}

//////
//////

#[test]
fn test_swap_3000_fee_1_1_price_0_liquidity_all_liquidity_around_current_price_swap_large_amount_zero_for_one_true_exact_input() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: IntegerTrait::<i32>::new(60, true), liquidity: 2 * pow(10, 18)});
    pool_test_positions.append(PoolTestPosition {tick_lower: IntegerTrait::<i32>::new(60, false), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = true;
    let exact_out = false;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_1_1_price_0_liquidity_all_liquidity_around_current_price_swap_large_amount_zero_for_one_false_exact_input() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: IntegerTrait::<i32>::new(60, true), liquidity: 2 * pow(10, 18)});
    pool_test_positions.append(PoolTestPosition {tick_lower: IntegerTrait::<i32>::new(60, false), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = false;
    let exact_out = false;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_1_1_price_0_liquidity_all_liquidity_around_current_price_swap_large_amount_zero_for_one_true_exact_output() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: IntegerTrait::<i32>::new(60, true), liquidity: 2 * pow(10, 18)});
    pool_test_positions.append(PoolTestPosition {tick_lower: IntegerTrait::<i32>::new(60, false), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = true;
    let exact_out = true;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_1_1_price_0_liquidity_all_liquidity_around_current_price_swap_large_amount_zero_for_one_false_exact_output() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: IntegerTrait::<i32>::new(60, true), liquidity: 2 * pow(10, 18)});
    pool_test_positions.append(PoolTestPosition {tick_lower: IntegerTrait::<i32>::new(60, false), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = false;
    let exact_out = true;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_1_1_price_0_liquidity_all_liquidity_around_current_price_swap_large_amount_with_price_limit_zero_for_one_true_exact_input() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: IntegerTrait::<i32>::new(60, true), liquidity: 2 * pow(10, 18)});
    pool_test_positions.append(PoolTestPosition {tick_lower: IntegerTrait::<i32>::new(60, false), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = true;
    let exact_out = false;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 56022770974786143748341366784;   // encode_price_sqrt(50, 100)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_1_1_price_0_liquidity_all_liquidity_around_current_price_swap_large_amount_with_price_limit_zero_for_one_false_exact_input() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: IntegerTrait::<i32>::new(60, true), liquidity: 2 * pow(10, 18)});
    pool_test_positions.append(PoolTestPosition {tick_lower: IntegerTrait::<i32>::new(60, false), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = false;
    let exact_out = false;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 112045541949572287496682733568;  // encode_price_sqrt(200, 100)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_1_1_price_0_liquidity_all_liquidity_around_current_price_swap_large_amount_with_price_limit_zero_for_one_true_exact_output() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: IntegerTrait::<i32>::new(60, true), liquidity: 2 * pow(10, 18)});
    pool_test_positions.append(PoolTestPosition {tick_lower: IntegerTrait::<i32>::new(60, false), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = true;
    let exact_out = true;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 56022770974786143748341366784;   // encode_price_sqrt(50, 100)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_1_1_price_0_liquidity_all_liquidity_around_current_price_swap_large_amount_with_price_limit_zero_for_one_false_exact_output() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: IntegerTrait::<i32>::new(60, true), liquidity: 2 * pow(10, 18)});
    pool_test_positions.append(PoolTestPosition {tick_lower: IntegerTrait::<i32>::new(60, false), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = false;
    let exact_out = true;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 112045541949572287496682733568;  // encode_price_sqrt(200, 100)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_1_1_price_0_liquidity_all_liquidity_around_current_price_swap_small_amount_zero_for_one_true_exact_input() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: IntegerTrait::<i32>::new(60, true), liquidity: 2 * pow(10, 18)});
    pool_test_positions.append(PoolTestPosition {tick_lower: IntegerTrait::<i32>::new(60, false), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = true;
    let exact_out = false;
    let amount0 = 1000;
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_1_1_price_0_liquidity_all_liquidity_around_current_price_swap_small_amount_zero_for_one_false_exact_input() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: IntegerTrait::<i32>::new(60, true), liquidity: 2 * pow(10, 18)});
    pool_test_positions.append(PoolTestPosition {tick_lower: IntegerTrait::<i32>::new(60, false), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = false;
    let exact_out = false;
    let amount1 = 1000;
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_1_1_price_0_liquidity_all_liquidity_around_current_price_swap_small_amount_zero_for_one_true_exact_output() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: IntegerTrait::<i32>::new(60, true), liquidity: 2 * pow(10, 18)});
    pool_test_positions.append(PoolTestPosition {tick_lower: IntegerTrait::<i32>::new(60, false), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = true;
    let exact_out = true;
    let amount1 = 1000;
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_1_1_price_0_liquidity_all_liquidity_around_current_price_swap_small_amount_zero_for_one_false_exact_output() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: IntegerTrait::<i32>::new(60, true), liquidity: 2 * pow(10, 18)});
    pool_test_positions.append(PoolTestPosition {tick_lower: IntegerTrait::<i32>::new(60, false), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = false;
    let exact_out = true;
    let amount0 = 1000;
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_1_1_price_0_liquidity_all_liquidity_around_current_price_swap_arbitrary_amount_to_price_zero_for_one_false_price_limit_5_2() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: IntegerTrait::<i32>::new(60, true), liquidity: 2 * pow(10, 18)});
    pool_test_positions.append(PoolTestPosition {tick_lower: IntegerTrait::<i32>::new(60, false), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = false;
    let exact_out = false;
    let sqrt_price_limit = 125270724187523973151104958464;  // encode_price_sqrt(5, 2)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit);
}

#[test]
#[should_panic(expected: ('SPL',))]
fn test_swap_3000_fee_1_1_price_0_liquidity_all_liquidity_around_current_price_swap_arbitrary_amount_to_price_zero_for_one_true_price_limit_5_2() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: IntegerTrait::<i32>::new(60, true), liquidity: 2 * pow(10, 18)});
    pool_test_positions.append(PoolTestPosition {tick_lower: IntegerTrait::<i32>::new(60, false), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = true;
    let exact_out = false;
    let sqrt_price_limit = 125270724187523973151104958464;  // encode_price_sqrt(5, 2)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit);
}

#[test]
#[should_panic(expected: ('SPL',))]
fn test_swap_3000_fee_1_1_price_0_liquidity_all_liquidity_around_current_price_swap_arbitrary_amount_to_price_zero_for_one_false_price_limit_2_5() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: IntegerTrait::<i32>::new(60, true), liquidity: 2 * pow(10, 18)});
    pool_test_positions.append(PoolTestPosition {tick_lower: IntegerTrait::<i32>::new(60, false), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = false;
    let exact_out = false;
    let sqrt_price_limit = 50108289675009587501223378944;  // encode_price_sqrt(2, 5)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_1_1_price_0_liquidity_all_liquidity_around_current_price_swap_arbitrary_amount_to_price_zero_for_one_true_price_limit_2_5() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: IntegerTrait::<i32>::new(60, true), liquidity: 2 * pow(10, 18)});
    pool_test_positions.append(PoolTestPosition {tick_lower: IntegerTrait::<i32>::new(60, false), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = true;
    let exact_out = false;
    let sqrt_price_limit = 50108289675009587501223378944;  // encode_price_sqrt(2, 5)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit);
}

//////
//////

#[test]
fn test_swap_3000_fee_1_1_price_additional_liquidity_around_current_price_swap_large_amount_zero_for_one_true_exact_input() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: IntegerTrait::<i32>::new(60, true), liquidity: 2 * pow(10, 18)});
    pool_test_positions.append(PoolTestPosition {tick_lower: IntegerTrait::<i32>::new(60, false), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = true;
    let exact_out = false;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_1_1_price_additional_liquidity_around_current_price_swap_large_amount_zero_for_one_false_exact_input() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: IntegerTrait::<i32>::new(60, true), liquidity: 2 * pow(10, 18)});
    pool_test_positions.append(PoolTestPosition {tick_lower: IntegerTrait::<i32>::new(60, false), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = false;
    let exact_out = false;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_1_1_price_additional_liquidity_around_current_price_swap_large_amount_zero_for_one_true_exact_output() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: IntegerTrait::<i32>::new(60, true), liquidity: 2 * pow(10, 18)});
    pool_test_positions.append(PoolTestPosition {tick_lower: IntegerTrait::<i32>::new(60, false), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = true;
    let exact_out = true;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_1_1_price_additional_liquidity_around_current_price_swap_large_amount_zero_for_one_false_exact_output() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: IntegerTrait::<i32>::new(60, true), liquidity: 2 * pow(10, 18)});
    pool_test_positions.append(PoolTestPosition {tick_lower: IntegerTrait::<i32>::new(60, false), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = false;
    let exact_out = true;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_1_1_price_additional_liquidity_around_current_price_swap_large_amount_with_price_limit_zero_for_one_true_exact_input() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: IntegerTrait::<i32>::new(60, true), liquidity: 2 * pow(10, 18)});
    pool_test_positions.append(PoolTestPosition {tick_lower: IntegerTrait::<i32>::new(60, false), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = true;
    let exact_out = false;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 56022770974786143748341366784;   // encode_price_sqrt(50, 100)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_1_1_price_additional_liquidity_around_current_price_swap_large_amount_with_price_limit_zero_for_one_false_exact_input() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: IntegerTrait::<i32>::new(60, true), liquidity: 2 * pow(10, 18)});
    pool_test_positions.append(PoolTestPosition {tick_lower: IntegerTrait::<i32>::new(60, false), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = false;
    let exact_out = false;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 112045541949572287496682733568;  // encode_price_sqrt(200, 100)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_1_1_price_additional_liquidity_around_current_price_swap_large_amount_with_price_limit_zero_for_one_true_exact_output() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: IntegerTrait::<i32>::new(60, true), liquidity: 2 * pow(10, 18)});
    pool_test_positions.append(PoolTestPosition {tick_lower: IntegerTrait::<i32>::new(60, false), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = true;
    let exact_out = true;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 56022770974786143748341366784;   // encode_price_sqrt(50, 100)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_1_1_price_additional_liquidity_around_current_price_swap_large_amount_with_price_limit_zero_for_one_false_exact_output() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: IntegerTrait::<i32>::new(60, true), liquidity: 2 * pow(10, 18)});
    pool_test_positions.append(PoolTestPosition {tick_lower: IntegerTrait::<i32>::new(60, false), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = false;
    let exact_out = true;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 112045541949572287496682733568;  // encode_price_sqrt(200, 100)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_1_1_price_additional_liquidity_around_current_price_swap_small_amount_zero_for_one_true_exact_input() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: IntegerTrait::<i32>::new(60, true), liquidity: 2 * pow(10, 18)});
    pool_test_positions.append(PoolTestPosition {tick_lower: IntegerTrait::<i32>::new(60, false), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = true;
    let exact_out = false;
    let amount0 = 1000;
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_1_1_price_additional_liquidity_around_current_price_swap_small_amount_zero_for_one_false_exact_input() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: IntegerTrait::<i32>::new(60, true), liquidity: 2 * pow(10, 18)});
    pool_test_positions.append(PoolTestPosition {tick_lower: IntegerTrait::<i32>::new(60, false), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = false;
    let exact_out = false;
    let amount1 = 1000;
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_1_1_price_additional_liquidity_around_current_price_swap_small_amount_zero_for_one_true_exact_output() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: IntegerTrait::<i32>::new(60, true), liquidity: 2 * pow(10, 18)});
    pool_test_positions.append(PoolTestPosition {tick_lower: IntegerTrait::<i32>::new(60, false), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = true;
    let exact_out = true;
    let amount1 = 1000;
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_1_1_price_additional_liquidity_around_current_price_swap_small_amount_zero_for_one_false_exact_output() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: IntegerTrait::<i32>::new(60, true), liquidity: 2 * pow(10, 18)});
    pool_test_positions.append(PoolTestPosition {tick_lower: IntegerTrait::<i32>::new(60, false), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = false;
    let exact_out = true;
    let amount0 = 1000;
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_1_1_price_additional_liquidity_around_current_price_swap_arbitrary_amount_to_price_zero_for_one_false_price_limit_5_2() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: IntegerTrait::<i32>::new(60, true), liquidity: 2 * pow(10, 18)});
    pool_test_positions.append(PoolTestPosition {tick_lower: IntegerTrait::<i32>::new(60, false), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = false;
    let exact_out = false;
    let sqrt_price_limit = 125270724187523973151104958464;  // encode_price_sqrt(5, 2)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit);
}

#[test]
#[should_panic(expected: ('SPL',))]
fn test_swap_3000_fee_1_1_price_additional_liquidity_around_current_price_swap_arbitrary_amount_to_price_zero_for_one_true_price_limit_5_2() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: IntegerTrait::<i32>::new(60, true), liquidity: 2 * pow(10, 18)});
    pool_test_positions.append(PoolTestPosition {tick_lower: IntegerTrait::<i32>::new(60, false), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = true;
    let exact_out = false;
    let sqrt_price_limit = 125270724187523973151104958464;  // encode_price_sqrt(5, 2)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit);
}

#[test]
#[should_panic(expected: ('SPL',))]
fn test_swap_3000_fee_1_1_price_additional_liquidity_around_current_price_swap_arbitrary_amount_to_price_zero_for_one_false_price_limit_2_5() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: IntegerTrait::<i32>::new(60, true), liquidity: 2 * pow(10, 18)});
    pool_test_positions.append(PoolTestPosition {tick_lower: IntegerTrait::<i32>::new(60, false), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = false;
    let exact_out = false;
    let sqrt_price_limit = 50108289675009587501223378944;  // encode_price_sqrt(2, 5)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_1_1_price_additional_liquidity_around_current_price_swap_arbitrary_amount_to_price_zero_for_one_true_price_limit_2_5() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: IntegerTrait::<i32>::new(60, true), liquidity: 2 * pow(10, 18)});
    pool_test_positions.append(PoolTestPosition {tick_lower: IntegerTrait::<i32>::new(60, false), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = true;
    let exact_out = false;
    let sqrt_price_limit = 50108289675009587501223378944;  // encode_price_sqrt(2, 5)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit);
}

//////
//////

#[test]
fn test_swap_500_fee_1_1_price_large_liquidity_around_current_price_stable_swap_large_amount_zero_for_one_true_exact_input() {
    let fee = 500;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: IntegerTrait::<i32>::new(10, true), tick_upper: IntegerTrait::<i32>::new(10, false), liquidity: 2 * pow(10, 18)});

    let zero_for_one = true;
    let exact_out = false;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit);
}

#[test]
fn test_swap_500_fee_1_1_price_large_liquidity_around_current_price_stable_swap_large_amount_zero_for_one_false_exact_input() {
    let fee = 500;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: IntegerTrait::<i32>::new(10, true), tick_upper: IntegerTrait::<i32>::new(10, false), liquidity: 2 * pow(10, 18)});

    let zero_for_one = false;
    let exact_out = false;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit);
}

#[test]
fn test_swap_500_fee_1_1_price_large_liquidity_around_current_price_stable_swap_large_amount_zero_for_one_true_exact_output() {
    let fee = 500;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: IntegerTrait::<i32>::new(10, true), tick_upper: IntegerTrait::<i32>::new(10, false), liquidity: 2 * pow(10, 18)});

    let zero_for_one = true;
    let exact_out = true;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit);
}

#[test]
fn test_swap_500_fee_1_1_price_large_liquidity_around_current_price_stable_swap_large_amount_zero_for_one_false_exact_output() {
    let fee = 500;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: IntegerTrait::<i32>::new(10, true), tick_upper: IntegerTrait::<i32>::new(10, false), liquidity: 2 * pow(10, 18)});

    let zero_for_one = false;
    let exact_out = true;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit);
}

#[test]
fn test_swap_500_fee_1_1_price_large_liquidity_around_current_price_stable_swap_large_amount_with_price_limit_zero_for_one_true_exact_input() {
    let fee = 500;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: IntegerTrait::<i32>::new(10, true), tick_upper: IntegerTrait::<i32>::new(10, false), liquidity: 2 * pow(10, 18)});

    let zero_for_one = true;
    let exact_out = false;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 56022770974786143748341366784;   // encode_price_sqrt(50, 100)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit);
}

#[test]
fn test_swap_500_fee_1_1_price_large_liquidity_around_current_price_stable_swap_large_amount_with_price_limit_zero_for_one_false_exact_input() {
    let fee = 500;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: IntegerTrait::<i32>::new(10, true), tick_upper: IntegerTrait::<i32>::new(10, false), liquidity: 2 * pow(10, 18)});

    let zero_for_one = false;
    let exact_out = false;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 112045541949572287496682733568;  // encode_price_sqrt(200, 100)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit);
}

#[test]
fn test_swap_500_fee_1_1_price_large_liquidity_around_current_price_stable_swap_large_amount_with_price_limit_zero_for_one_true_exact_output() {
    let fee = 500;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: IntegerTrait::<i32>::new(10, true), tick_upper: IntegerTrait::<i32>::new(10, false), liquidity: 2 * pow(10, 18)});

    let zero_for_one = true;
    let exact_out = true;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 56022770974786143748341366784;   // encode_price_sqrt(50, 100)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit);
}

#[test]
fn test_swap_500_fee_1_1_price_large_liquidity_around_current_price_stable_swap_large_amount_with_price_limit_zero_for_one_false_exact_output() {
    let fee = 500;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: IntegerTrait::<i32>::new(10, true), tick_upper: IntegerTrait::<i32>::new(10, false), liquidity: 2 * pow(10, 18)});

    let zero_for_one = false;
    let exact_out = true;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 112045541949572287496682733568;  // encode_price_sqrt(200, 100)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit);
}

#[test]
fn test_swap_500_fee_1_1_price_large_liquidity_around_current_price_stable_swap_small_amount_zero_for_one_true_exact_input() {
    let fee = 500;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: IntegerTrait::<i32>::new(10, true), tick_upper: IntegerTrait::<i32>::new(10, false), liquidity: 2 * pow(10, 18)});

    let zero_for_one = true;
    let exact_out = false;
    let amount0 = 1000;
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit);
}

#[test]
fn test_swap_500_fee_1_1_price_large_liquidity_around_current_price_stable_swap_small_amount_zero_for_one_false_exact_input() {
    let fee = 500;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: IntegerTrait::<i32>::new(10, true), tick_upper: IntegerTrait::<i32>::new(10, false), liquidity: 2 * pow(10, 18)});

    let zero_for_one = false;
    let exact_out = false;
    let amount1 = 1000;
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit);
}

#[test]
fn test_swap_500_fee_1_1_price_large_liquidity_around_current_price_stable_swap_small_amount_zero_for_one_true_exact_output() {
    let fee = 500;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: IntegerTrait::<i32>::new(10, true), tick_upper: IntegerTrait::<i32>::new(10, false), liquidity: 2 * pow(10, 18)});

    let zero_for_one = true;
    let exact_out = true;
    let amount1 = 1000;
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit);
}

#[test]
fn test_swap_500_fee_1_1_price_large_liquidity_around_current_price_stable_swap_small_amount_zero_for_one_false_exact_output() {
    let fee = 500;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: IntegerTrait::<i32>::new(10, true), tick_upper: IntegerTrait::<i32>::new(10, false), liquidity: 2 * pow(10, 18)});

    let zero_for_one = false;
    let exact_out = true;
    let amount0 = 1000;
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit);
}

#[test]
fn test_swap_500_fee_1_1_price_large_liquidity_around_current_price_stable_swap_arbitrary_amount_to_price_zero_for_one_false_price_limit_5_2() {
    let fee = 500;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: IntegerTrait::<i32>::new(10, true), tick_upper: IntegerTrait::<i32>::new(10, false), liquidity: 2 * pow(10, 18)});

    let zero_for_one = false;
    let exact_out = false;
    let sqrt_price_limit = 125270724187523973151104958464;  // encode_price_sqrt(5, 2)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit);
}

#[test]
#[should_panic(expected: ('SPL',))]
fn test_swap_500_fee_1_1_price_large_liquidity_around_current_price_stable_swap_arbitrary_amount_to_price_zero_for_one_true_price_limit_5_2() {
    let fee = 500;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: IntegerTrait::<i32>::new(10, true), tick_upper: IntegerTrait::<i32>::new(10, false), liquidity: 2 * pow(10, 18)});

    let zero_for_one = true;
    let exact_out = false;
    let sqrt_price_limit = 125270724187523973151104958464;  // encode_price_sqrt(5, 2)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit);
}

#[test]
#[should_panic(expected: ('SPL',))]
fn test_swap_500_fee_1_1_price_large_liquidity_around_current_price_stable_swap_arbitrary_amount_to_price_zero_for_one_false_price_limit_2_5() {
    let fee = 500;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: IntegerTrait::<i32>::new(10, true), tick_upper: IntegerTrait::<i32>::new(10, false), liquidity: 2 * pow(10, 18)});

    let zero_for_one = false;
    let exact_out = false;
    let sqrt_price_limit = 50108289675009587501223378944;  // encode_price_sqrt(2, 5)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit);
}

#[test]
fn test_swap_500_fee_1_1_price_large_liquidity_around_current_price_stable_swap_arbitrary_amount_to_price_zero_for_one_true_price_limit_2_5() {
    let fee = 500;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: IntegerTrait::<i32>::new(10, true), tick_upper: IntegerTrait::<i32>::new(10, false), liquidity: 2 * pow(10, 18)});

    let zero_for_one = true;
    let exact_out = false;
    let sqrt_price_limit = 50108289675009587501223378944;  // encode_price_sqrt(2, 5)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit);
}

//////
//////

#[test]
fn test_swap_3000_fee_1_1_price_token0_liquidity_only_swap_large_amount_zero_for_one_true_exact_input() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: IntegerTrait::<i32>::new(0, false), tick_upper: IntegerTrait::<i32>::new(2000 * 60, false), liquidity: 2 * pow(10, 18)});

    let zero_for_one = true;
    let exact_out = false;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_1_1_price_token0_liquidity_only_swap_large_amount_zero_for_one_false_exact_input() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: IntegerTrait::<i32>::new(0, false), tick_upper: IntegerTrait::<i32>::new(2000 * 60, false), liquidity: 2 * pow(10, 18)});

    let zero_for_one = false;
    let exact_out = false;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_1_1_price_token0_liquidity_only_swap_large_amount_zero_for_one_true_exact_output() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: IntegerTrait::<i32>::new(0, false), tick_upper: IntegerTrait::<i32>::new(2000 * 60, false), liquidity: 2 * pow(10, 18)});

    let zero_for_one = true;
    let exact_out = true;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_1_1_price_token0_liquidity_only_swap_large_amount_zero_for_one_false_exact_output() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: IntegerTrait::<i32>::new(0, false), tick_upper: IntegerTrait::<i32>::new(2000 * 60, false), liquidity: 2 * pow(10, 18)});

    let zero_for_one = false;
    let exact_out = true;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_1_1_price_token0_liquidity_only_swap_large_amount_with_price_limit_zero_for_one_true_exact_input() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: IntegerTrait::<i32>::new(0, false), tick_upper: IntegerTrait::<i32>::new(2000 * 60, false), liquidity: 2 * pow(10, 18)});

    let zero_for_one = true;
    let exact_out = false;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 56022770974786143748341366784;   // encode_price_sqrt(50, 100)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_1_1_price_token0_liquidity_only_swap_large_amount_with_price_limit_zero_for_one_false_exact_input() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: IntegerTrait::<i32>::new(0, false), tick_upper: IntegerTrait::<i32>::new(2000 * 60, false), liquidity: 2 * pow(10, 18)});

    let zero_for_one = false;
    let exact_out = false;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 112045541949572287496682733568;  // encode_price_sqrt(200, 100)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_1_1_price_token0_liquidity_only_swap_large_amount_with_price_limit_zero_for_one_true_exact_output() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: IntegerTrait::<i32>::new(0, false), tick_upper: IntegerTrait::<i32>::new(2000 * 60, false), liquidity: 2 * pow(10, 18)});

    let zero_for_one = true;
    let exact_out = true;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 56022770974786143748341366784;   // encode_price_sqrt(50, 100)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_1_1_price_token0_liquidity_only_swap_large_amount_with_price_limit_zero_for_one_false_exact_output() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: IntegerTrait::<i32>::new(0, false), tick_upper: IntegerTrait::<i32>::new(2000 * 60, false), liquidity: 2 * pow(10, 18)});

    let zero_for_one = false;
    let exact_out = true;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 112045541949572287496682733568;  // encode_price_sqrt(200, 100)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_1_1_price_token0_liquidity_only_swap_small_amount_zero_for_one_true_exact_input() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: IntegerTrait::<i32>::new(0, false), tick_upper: IntegerTrait::<i32>::new(2000 * 60, false), liquidity: 2 * pow(10, 18)});

    let zero_for_one = true;
    let exact_out = false;
    let amount0 = 1000;
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_1_1_price_token0_liquidity_only_swap_small_amount_zero_for_one_false_exact_input() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: IntegerTrait::<i32>::new(0, false), tick_upper: IntegerTrait::<i32>::new(2000 * 60, false), liquidity: 2 * pow(10, 18)});

    let zero_for_one = false;
    let exact_out = false;
    let amount1 = 1000;
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_1_1_price_token0_liquidity_only_swap_small_amount_zero_for_one_true_exact_output() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: IntegerTrait::<i32>::new(0, false), tick_upper: IntegerTrait::<i32>::new(2000 * 60, false), liquidity: 2 * pow(10, 18)});

    let zero_for_one = true;
    let exact_out = true;
    let amount1 = 1000;
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_1_1_price_token0_liquidity_only_swap_small_amount_zero_for_one_false_exact_output() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: IntegerTrait::<i32>::new(0, false), tick_upper: IntegerTrait::<i32>::new(2000 * 60, false), liquidity: 2 * pow(10, 18)});

    let zero_for_one = false;
    let exact_out = true;
    let amount0 = 1000;
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_1_1_price_token0_liquidity_only_swap_arbitrary_amount_to_price_zero_for_one_false_price_limit_5_2() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: IntegerTrait::<i32>::new(0, false), tick_upper: IntegerTrait::<i32>::new(2000 * 60, false), liquidity: 2 * pow(10, 18)});

    let zero_for_one = false;
    let exact_out = false;
    let sqrt_price_limit = 125270724187523973151104958464;  // encode_price_sqrt(5, 2)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit);
}

#[test]
#[should_panic(expected: ('SPL',))]
fn test_swap_3000_fee_1_1_price_token0_liquidity_only_swap_arbitrary_amount_to_price_zero_for_one_true_price_limit_5_2() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: IntegerTrait::<i32>::new(0, false), tick_upper: IntegerTrait::<i32>::new(2000 * 60, false), liquidity: 2 * pow(10, 18)});

    let zero_for_one = true;
    let exact_out = false;
    let sqrt_price_limit = 125270724187523973151104958464;  // encode_price_sqrt(5, 2)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit);
}

#[test]
#[should_panic(expected: ('SPL',))]
fn test_swap_3000_fee_1_1_price_token0_liquidity_only_swap_arbitrary_amount_to_price_zero_for_one_false_price_limit_2_5() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: IntegerTrait::<i32>::new(0, false), tick_upper: IntegerTrait::<i32>::new(2000 * 60, false), liquidity: 2 * pow(10, 18)});

    let zero_for_one = false;
    let exact_out = false;
    let sqrt_price_limit = 50108289675009587501223378944;  // encode_price_sqrt(2, 5)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_1_1_price_token0_liquidity_only_swap_arbitrary_amount_to_price_zero_for_one_true_price_limit_2_5() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: IntegerTrait::<i32>::new(0, false), tick_upper: IntegerTrait::<i32>::new(2000 * 60, false), liquidity: 2 * pow(10, 18)});

    let zero_for_one = true;
    let exact_out = false;
    let sqrt_price_limit = 50108289675009587501223378944;  // encode_price_sqrt(2, 5)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit);
}

//////
//////

#[test]
fn test_swap_3000_fee_1_1_price_token1_liquidity_only_swap_large_amount_zero_for_one_true_exact_input() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: IntegerTrait::<i32>::new(2000 * 60, true), tick_upper: IntegerTrait::<i32>::new(0, false), liquidity: 2 * pow(10, 18)});

    let zero_for_one = true;
    let exact_out = false;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_1_1_price_token1_liquidity_only_swap_large_amount_zero_for_one_false_exact_input() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: IntegerTrait::<i32>::new(2000 * 60, true), tick_upper: IntegerTrait::<i32>::new(0, false), liquidity: 2 * pow(10, 18)});

    let zero_for_one = false;
    let exact_out = false;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_1_1_price_token1_liquidity_only_swap_large_amount_zero_for_one_true_exact_output() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: IntegerTrait::<i32>::new(2000 * 60, true), tick_upper: IntegerTrait::<i32>::new(0, false), liquidity: 2 * pow(10, 18)});

    let zero_for_one = true;
    let exact_out = true;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_1_1_price_token1_liquidity_only_swap_large_amount_zero_for_one_false_exact_output() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: IntegerTrait::<i32>::new(2000 * 60, true), tick_upper: IntegerTrait::<i32>::new(0, false), liquidity: 2 * pow(10, 18)});

    let zero_for_one = false;
    let exact_out = true;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_1_1_price_token1_liquidity_only_swap_large_amount_with_price_limit_zero_for_one_true_exact_input() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: IntegerTrait::<i32>::new(2000 * 60, true), tick_upper: IntegerTrait::<i32>::new(0, false), liquidity: 2 * pow(10, 18)});

    let zero_for_one = true;
    let exact_out = false;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 56022770974786143748341366784;   // encode_price_sqrt(50, 100)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_1_1_price_token1_liquidity_only_swap_large_amount_with_price_limit_zero_for_one_false_exact_input() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: IntegerTrait::<i32>::new(2000 * 60, true), tick_upper: IntegerTrait::<i32>::new(0, false), liquidity: 2 * pow(10, 18)});

    let zero_for_one = false;
    let exact_out = false;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 112045541949572287496682733568;  // encode_price_sqrt(200, 100)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_1_1_price_token1_liquidity_only_swap_large_amount_with_price_limit_zero_for_one_true_exact_output() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: IntegerTrait::<i32>::new(2000 * 60, true), tick_upper: IntegerTrait::<i32>::new(0, false), liquidity: 2 * pow(10, 18)});

    let zero_for_one = true;
    let exact_out = true;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 56022770974786143748341366784;   // encode_price_sqrt(50, 100)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_1_1_price_token1_liquidity_only_swap_large_amount_with_price_limit_zero_for_one_false_exact_output() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: IntegerTrait::<i32>::new(2000 * 60, true), tick_upper: IntegerTrait::<i32>::new(0, false), liquidity: 2 * pow(10, 18)});

    let zero_for_one = false;
    let exact_out = true;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 112045541949572287496682733568;  // encode_price_sqrt(200, 100)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_1_1_price_token1_liquidity_only_swap_small_amount_zero_for_one_true_exact_input() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: IntegerTrait::<i32>::new(2000 * 60, true), tick_upper: IntegerTrait::<i32>::new(0, false), liquidity: 2 * pow(10, 18)});

    let zero_for_one = true;
    let exact_out = false;
    let amount0 = 1000;
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_1_1_price_token1_liquidity_only_swap_small_amount_zero_for_one_false_exact_input() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: IntegerTrait::<i32>::new(2000 * 60, true), tick_upper: IntegerTrait::<i32>::new(0, false), liquidity: 2 * pow(10, 18)});

    let zero_for_one = false;
    let exact_out = false;
    let amount1 = 1000;
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_1_1_price_token1_liquidity_only_swap_small_amount_zero_for_one_true_exact_output() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: IntegerTrait::<i32>::new(2000 * 60, true), tick_upper: IntegerTrait::<i32>::new(0, false), liquidity: 2 * pow(10, 18)});

    let zero_for_one = true;
    let exact_out = true;
    let amount1 = 1000;
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_1_1_price_token1_liquidity_only_swap_small_amount_zero_for_one_false_exact_output() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: IntegerTrait::<i32>::new(2000 * 60, true), tick_upper: IntegerTrait::<i32>::new(0, false), liquidity: 2 * pow(10, 18)});

    let zero_for_one = false;
    let exact_out = true;
    let amount0 = 1000;
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_1_1_price_token1_liquidity_only_swap_arbitrary_amount_to_price_zero_for_one_false_price_limit_5_2() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: IntegerTrait::<i32>::new(2000 * 60, true), tick_upper: IntegerTrait::<i32>::new(0, false), liquidity: 2 * pow(10, 18)});

    let zero_for_one = false;
    let exact_out = false;
    let sqrt_price_limit = 125270724187523973151104958464;  // encode_price_sqrt(5, 2)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit);
}

#[test]
#[should_panic(expected: ('SPL',))]
fn test_swap_3000_fee_1_1_price_token1_liquidity_only_swap_arbitrary_amount_to_price_zero_for_one_true_price_limit_5_2() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: IntegerTrait::<i32>::new(2000 * 60, true), tick_upper: IntegerTrait::<i32>::new(0, false), liquidity: 2 * pow(10, 18)});

    let zero_for_one = true;
    let exact_out = false;
    let sqrt_price_limit = 125270724187523973151104958464;  // encode_price_sqrt(5, 2)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit);
}

#[test]
#[should_panic(expected: ('SPL',))]
fn test_swap_3000_fee_1_1_price_token1_liquidity_only_swap_arbitrary_amount_to_price_zero_for_one_false_price_limit_2_5() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: IntegerTrait::<i32>::new(2000 * 60, true), tick_upper: IntegerTrait::<i32>::new(0, false), liquidity: 2 * pow(10, 18)});

    let zero_for_one = false;
    let exact_out = false;
    let sqrt_price_limit = 50108289675009587501223378944;  // encode_price_sqrt(2, 5)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_1_1_price_token1_liquidity_only_swap_arbitrary_amount_to_price_zero_for_one_true_price_limit_2_5() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: IntegerTrait::<i32>::new(2000 * 60, true), tick_upper: IntegerTrait::<i32>::new(0, false), liquidity: 2 * pow(10, 18)});

    let zero_for_one = true;
    let exact_out = false;
    let sqrt_price_limit = 50108289675009587501223378944;  // encode_price_sqrt(2, 5)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit);
}

//////
//////

#[test]
fn test_swap_3000_fee_max_1_price_swap_large_amount_zero_for_one_true_exact_input() {
    let fee = 3000;
    let price0 = pow(2, 127);   
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = true;
    let exact_out = false;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_max_1_price_swap_large_amount_zero_for_one_false_exact_input() {
    let fee = 3000;
    let price0 = pow(2, 127);
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = false;
    let exact_out = false;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_max_1_price_swap_large_amount_zero_for_one_true_exact_output() {
    let fee = 3000;
    let price0 = pow(2, 127);
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = true;
    let exact_out = true;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_max_1_price_swap_large_amount_zero_for_one_false_exact_output() {
    let fee = 3000;
    let price0 = pow(2, 127);
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = false;
    let exact_out = true;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_max_1_price_swap_large_amount_with_price_limit_zero_for_one_true_exact_input() {
    let fee = 3000;
    let price0 = pow(2, 127);
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = true;
    let exact_out = false;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 56022770974786143748341366784;   // encode_price_sqrt(50, 100)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit);
}

#[test]
#[should_panic(expected: ('SPL',))]
fn test_swap_3000_fee_max_1_price_swap_large_amount_with_price_limit_zero_for_one_false_exact_input() {
    let fee = 3000;
    let price0 = pow(2, 127);
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = false;
    let exact_out = false;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 112045541949572287496682733568;  // encode_price_sqrt(200, 100)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_max_1_price_swap_large_amount_with_price_limit_zero_for_one_true_exact_output() {
    let fee = 3000;
    let price0 = pow(2, 127);
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = true;
    let exact_out = true;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 56022770974786143748341366784;   // encode_price_sqrt(50, 100)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit);
}

#[test]
#[should_panic(expected: ('SPL',))]
fn test_swap_3000_fee_max_1_price_swap_large_amount_with_price_limit_zero_for_one_false_exact_output() {
    let fee = 3000;
    let price0 = pow(2, 127);
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = false;
    let exact_out = true;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 112045541949572287496682733568;  // encode_price_sqrt(200, 100)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_max_1_price_swap_small_amount_zero_for_one_true_exact_input() {
    let fee = 3000;
    let price0 = pow(2, 127);
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = true;
    let exact_out = false;
    let amount0 = 1000;
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_max_1_price_swap_small_amount_zero_for_one_false_exact_input() {
    let fee = 3000;
    let price0 = pow(2, 127);
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = false;
    let exact_out = false;
    let amount1 = 1000;
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_max_1_price_swap_small_amount_zero_for_one_true_exact_output() {
    let fee = 3000;
    let price0 = pow(2, 127);
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = true;
    let exact_out = true;
    let amount1 = 1000;
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_max_1_price_swap_small_amount_zero_for_one_false_exact_output() {
    let fee = 3000;
    let price0 = pow(2, 127);
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = false;
    let exact_out = true;
    let amount0 = 1000;
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit);
}

#[test]
#[should_panic(expected: ('SPL',))]
fn test_swap_3000_fee_max_1_price_swap_arbitrary_amount_to_price_zero_for_one_false_price_limit_5_2() {
    let fee = 3000;
    let price0 = pow(2, 127);
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = false;
    let exact_out = false;
    let sqrt_price_limit = 125270724187523973151104958464;  // encode_price_sqrt(5, 2)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_max_1_price_swap_arbitrary_amount_to_price_zero_for_one_true_price_limit_5_2() {
    let fee = 3000;
    let price0 = pow(2, 127);
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = true;
    let exact_out = false;
    let sqrt_price_limit = 125270724187523973151104958464;  // encode_price_sqrt(5, 2)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit);
}

#[test]
#[should_panic(expected: ('SPL',))]
fn test_swap_3000_fee_max_1_price_swap_arbitrary_amount_to_price_zero_for_one_false_price_limit_2_5() {
    let fee = 3000;
    let price0 = pow(2, 127);
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = false;
    let exact_out = false;
    let sqrt_price_limit = 50108289675009587501223378944;  // encode_price_sqrt(2, 5)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_max_1_price_swap_arbitrary_amount_to_price_zero_for_one_true_price_limit_2_5() {
    let fee = 3000;
    let price0 = pow(2, 127);
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = true;
    let exact_out = false;
    let sqrt_price_limit = 50108289675009587501223378944;  // encode_price_sqrt(2, 5)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit);
}

//////
//////

#[test]
fn test_swap_3000_fee_1_max_price_swap_large_amount_zero_for_one_true_exact_input() {
    let fee = 3000;
    let price0 = 1;   
    let price1 = pow(2, 127);

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = true;
    let exact_out = false;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_1_max_price_swap_large_amount_zero_for_one_false_exact_input() {
    let fee = 3000;
    let price0 = 1;
    let price1 = pow(2, 127);

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = false;
    let exact_out = false;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_1_max_price_swap_large_amount_zero_for_one_true_exact_output() {
    let fee = 3000;
    let price0 = 1;
    let price1 = pow(2, 127);

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = true;
    let exact_out = true;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_1_max_price_swap_large_amount_zero_for_one_false_exact_output() {
    let fee = 3000;
    let price0 = 1;
    let price1 = pow(2, 127);

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = false;
    let exact_out = true;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit);
}

#[test]
#[should_panic(expected: ('SPL',))]
fn test_swap_3000_fee_1_max_price_swap_large_amount_with_price_limit_zero_for_one_true_exact_input() {
    let fee = 3000;
    let price0 = 1;
    let price1 = pow(2, 127);

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = true;
    let exact_out = false;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 56022770974786143748341366784;   // encode_price_sqrt(50, 100)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit);
}

#[test]
#[should_panic(expected: ('SPL',))]
fn test_swap_3000_fee_1_max_price_swap_large_amount_with_price_limit_zero_for_one_false_exact_input() {
    let fee = 3000;
    let price0 = 1;
    let price1 = pow(2, 127);

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = false;
    let exact_out = false;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 112045541949572287496682733568;  // encode_price_sqrt(200, 100)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit);
}

#[test]
#[should_panic(expected: ('SPL',))]
fn test_swap_3000_fee_1_max_price_swap_large_amount_with_price_limit_zero_for_one_true_exact_output() {
    let fee = 3000;
    let price0 = 1;
    let price1 = pow(2, 127);

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = true;
    let exact_out = true;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 56022770974786143748341366784;   // encode_price_sqrt(50, 100)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_1_max_price_swap_large_amount_with_price_limit_zero_for_one_false_exact_output() {
    let fee = 3000;
    let price0 = 1;
    let price1 = pow(2, 127);

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = false;
    let exact_out = true;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 112045541949572287496682733568;  // encode_price_sqrt(200, 100)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_1_max_price_swap_small_amount_zero_for_one_true_exact_input() {
    let fee = 3000;
    let price0 = 1;
    let price1 = pow(2, 127);

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = true;
    let exact_out = false;
    let amount0 = 1000;
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_1_max_price_swap_small_amount_zero_for_one_false_exact_input() {
    let fee = 3000;
    let price0 = 1;
    let price1 = pow(2, 127);

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = false;
    let exact_out = false;
    let amount1 = 1000;
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_1_max_price_swap_small_amount_zero_for_one_true_exact_output() {
    let fee = 3000;
    let price0 = 1;
    let price1 = pow(2, 127);

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = true;
    let exact_out = true;
    let amount1 = 1000;
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_1_max_price_swap_small_amount_zero_for_one_false_exact_output() {
    let fee = 3000;
    let price0 = 1;
    let price1 = pow(2, 127);

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = false;
    let exact_out = true;
    let amount0 = 1000;
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit);
}

#[test]
#[should_panic(expected: ('SPL',))]
fn test_swap_3000_fee_1_max_price_swap_arbitrary_amount_to_price_zero_for_one_false_price_limit_5_2() {
    let fee = 3000;
    let price0 = 1;
    let price1 = pow(2, 127);

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = false;
    let exact_out = false;
    let sqrt_price_limit = 125270724187523973151104958464;  // encode_price_sqrt(5, 2)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit);
}

#[test]
#[should_panic(expected: ('SPL',))]
fn test_swap_3000_fee_1_max_price_swap_arbitrary_amount_to_price_zero_for_one_true_price_limit_5_2() {
    let fee = 3000;
    let price0 = 1;
    let price1 = pow(2, 127);

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = true;
    let exact_out = false;
    let sqrt_price_limit = 125270724187523973151104958464;  // encode_price_sqrt(5, 2)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit);
}

#[test]
#[should_panic(expected: ('SPL',))]
fn test_swap_3000_fee_1_max_price_swap_arbitrary_amount_to_price_zero_for_one_false_price_limit_2_5() {
    let fee = 3000;
    let price0 = 1;
    let price1 = pow(2, 127);

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = false;
    let exact_out = false;
    let sqrt_price_limit = 50108289675009587501223378944;  // encode_price_sqrt(2, 5)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit);
}

#[test]
#[should_panic(expected: ('SPL',))]
fn test_swap_3000_fee_1_max_price_swap_arbitrary_amount_to_price_zero_for_one_true_price_limit_2_5() {
    let fee = 3000;
    let price0 = 1;
    let price1 = pow(2, 127);

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = true;
    let exact_out = false;
    let sqrt_price_limit = 50108289675009587501223378944;  // encode_price_sqrt(2, 5)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit);
}

//////
//////

#[test]
fn test_swap_3000_fee_1_1_price_max_full_range_liquidity_swap_large_amount_zero_for_one_true_exact_input() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: get_max_liquidity_per_tick(fee)});

    let zero_for_one = true;
    let exact_out = false;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_1_1_price_max_full_range_liquidity_swap_large_amount_zero_for_one_false_exact_input() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: get_max_liquidity_per_tick(fee)});

    let zero_for_one = false;
    let exact_out = false;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_1_1_price_max_full_range_liquidity_swap_large_amount_zero_for_one_true_exact_output() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: get_max_liquidity_per_tick(fee)});

    let zero_for_one = true;
    let exact_out = true;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_1_1_price_max_full_range_liquidity_swap_large_amount_zero_for_one_false_exact_output() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: get_max_liquidity_per_tick(fee)});

    let zero_for_one = false;
    let exact_out = true;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_1_1_price_max_full_range_liquidity_swap_large_amount_with_price_limit_zero_for_one_true_exact_input() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: get_max_liquidity_per_tick(fee)});

    let zero_for_one = true;
    let exact_out = false;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 56022770974786143748341366784;   // encode_price_sqrt(50, 100)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_1_1_price_max_full_range_liquidity_swap_large_amount_with_price_limit_zero_for_one_false_exact_input() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: get_max_liquidity_per_tick(fee)});

    let zero_for_one = false;
    let exact_out = false;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 112045541949572287496682733568;  // encode_price_sqrt(200, 100)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_1_1_price_max_full_range_liquidity_swap_large_amount_with_price_limit_zero_for_one_true_exact_output() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: get_max_liquidity_per_tick(fee)});

    let zero_for_one = true;
    let exact_out = true;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 56022770974786143748341366784;   // encode_price_sqrt(50, 100)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_1_1_price_max_full_range_liquidity_swap_large_amount_with_price_limit_zero_for_one_false_exact_output() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: get_max_liquidity_per_tick(fee)});

    let zero_for_one = false;
    let exact_out = true;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 112045541949572287496682733568;  // encode_price_sqrt(200, 100)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_1_1_price_max_full_range_liquidity_swap_small_amount_zero_for_one_true_exact_input() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: get_max_liquidity_per_tick(fee)});

    let zero_for_one = true;
    let exact_out = false;
    let amount0 = 1000;
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_1_1_price_max_full_range_liquidity_swap_small_amount_zero_for_one_false_exact_input() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: get_max_liquidity_per_tick(fee)});

    let zero_for_one = false;
    let exact_out = false;
    let amount1 = 1000;
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_1_1_price_max_full_range_liquidity_swap_small_amount_zero_for_one_true_exact_output() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: get_max_liquidity_per_tick(fee)});

    let zero_for_one = true;
    let exact_out = true;
    let amount1 = 1000;
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_1_1_price_max_full_range_liquidity_swap_small_amount_zero_for_one_false_exact_output() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: get_max_liquidity_per_tick(fee)});

    let zero_for_one = false;
    let exact_out = true;
    let amount0 = 1000;
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_1_1_price_max_full_range_liquidity_swap_arbitrary_amount_to_price_zero_for_one_false_price_limit_5_2() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: get_max_liquidity_per_tick(fee)});

    let zero_for_one = false;
    let exact_out = false;
    let sqrt_price_limit = 125270724187523973151104958464;  // encode_price_sqrt(5, 2)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit);
}

#[test]
#[should_panic(expected: ('SPL',))]
fn test_swap_3000_fee_1_1_price_max_full_range_liquidity_swap_arbitrary_amount_to_price_zero_for_one_true_price_limit_5_2() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: get_max_liquidity_per_tick(fee)});

    let zero_for_one = true;
    let exact_out = false;
    let sqrt_price_limit = 125270724187523973151104958464;  // encode_price_sqrt(5, 2)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit);
}

#[test]
#[should_panic(expected: ('SPL',))]
fn test_swap_3000_fee_1_1_price_max_full_range_liquidity_swap_arbitrary_amount_to_price_zero_for_one_false_price_limit_2_5() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: get_max_liquidity_per_tick(fee)});

    let zero_for_one = false;
    let exact_out = false;
    let sqrt_price_limit = 50108289675009587501223378944;  // encode_price_sqrt(2, 5)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_1_1_price_max_full_range_liquidity_swap_arbitrary_amount_to_price_zero_for_one_true_price_limit_2_5() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: get_max_liquidity_per_tick(fee)});

    let zero_for_one = true;
    let exact_out = false;
    let sqrt_price_limit = 50108289675009587501223378944;  // encode_price_sqrt(2, 5)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit);
}

//////
//////

#[test]
fn test_swap_3000_fee_max_max_price_swap_large_amount_zero_for_one_true_exact_input() {
    let fee = 3000;
    let price0 = 'max';
    let price1 = 'max';

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = true;
    let exact_out = false;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit);
}

#[test]
#[should_panic(expected: ('SPL',))]
fn test_swap_3000_fee_max_max_price_swap_large_amount_zero_for_one_false_exact_input() {
    let fee = 3000;
    let price0 = 'max';
    let price1 = 'max';

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = false;
    let exact_out = false;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_max_max_price_swap_large_amount_zero_for_one_true_exact_output() {
    let fee = 3000;
    let price0 = 'max';
    let price1 = 'max';

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = true;
    let exact_out = true;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit);
}

#[test]
#[should_panic(expected: ('SPL',))]
fn test_swap_3000_fee_max_max_price_swap_large_amount_zero_for_one_false_exact_output() {
    let fee = 3000;
    let price0 = 'max';
    let price1 = 'max';

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = false;
    let exact_out = true;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_max_max_price_swap_large_amount_with_price_limit_zero_for_one_true_exact_input() {
    let fee = 3000;
    let price0 = 'max';
    let price1 = 'max';

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = true;
    let exact_out = false;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 56022770974786143748341366784;   // encode_price_sqrt(50, 100)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit);
}

#[test]
#[should_panic(expected: ('SPL',))]
fn test_swap_3000_fee_max_max_price_swap_large_amount_with_price_limit_zero_for_one_false_exact_input() {
    let fee = 3000;
    let price0 = 'max';
    let price1 = 'max';

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = false;
    let exact_out = false;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 112045541949572287496682733568;  // encode_price_sqrt(200, 100)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_max_max_price_swap_large_amount_with_price_limit_zero_for_one_true_exact_output() {
    let fee = 3000;
    let price0 = 'max';
    let price1 = 'max';

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = true;
    let exact_out = true;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 56022770974786143748341366784;   // encode_price_sqrt(50, 100)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit);
}

#[test]
#[should_panic(expected: ('SPL',))]
fn test_swap_3000_fee_max_max_price_swap_large_amount_with_price_limit_zero_for_one_false_exact_output() {
    let fee = 3000;
    let price0 = 'max';
    let price1 = 'max';

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = false;
    let exact_out = true;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 112045541949572287496682733568;  // encode_price_sqrt(200, 100)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_max_max_price_swap_small_amount_zero_for_one_true_exact_input() {
    let fee = 3000;
    let price0 = 'max';
    let price1 = 'max';

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = true;
    let exact_out = false;
    let amount0 = 1000;
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit);
}

#[test]
#[should_panic(expected: ('SPL',))]
fn test_swap_3000_fee_max_max_price_swap_small_amount_zero_for_one_false_exact_input() {
    let fee = 3000;
    let price0 = 'max';
    let price1 = 'max';

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = false;
    let exact_out = false;
    let amount1 = 1000;
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_max_max_price_swap_small_amount_zero_for_one_true_exact_output() {
    let fee = 3000;
    let price0 = 'max';
    let price1 = 'max';

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = true;
    let exact_out = true;
    let amount1 = 1000;
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit);
}

#[test]
#[should_panic(expected: ('SPL',))]
fn test_swap_3000_fee_max_max_price_swap_small_amount_zero_for_one_false_exact_output() {
    let fee = 3000;
    let price0 = 'max';
    let price1 = 'max';

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = false;
    let exact_out = true;
    let amount0 = 1000;
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit);
}

#[test]
#[should_panic(expected: ('SPL',))]
fn test_swap_3000_fee_max_max_price_swap_arbitrary_amount_to_price_zero_for_one_false_price_limit_5_2() {
    let fee = 3000;
    let price0 = 'max';
    let price1 = 'max';

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = false;
    let exact_out = false;
    let sqrt_price_limit = 125270724187523973151104958464;  // encode_price_sqrt(5, 2)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit);
}

#[test]
#[should_panic(expected: ('SPL',))]
fn test_swap_3000_fee_max_max_price_swap_arbitrary_amount_to_price_zero_for_one_true_price_limit_5_2() {
    let fee = 3000;
    let price0 = 'max';
    let price1 = 'max';

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = true;
    let exact_out = false;
    let sqrt_price_limit = 125270724187523973151104958464;  // encode_price_sqrt(5, 2)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit);
}

#[test]
#[should_panic(expected: ('SPL',))]
fn test_swap_3000_fee_max_max_price_swap_arbitrary_amount_to_price_zero_for_one_false_price_limit_2_5() {
    let fee = 3000;
    let price0 = 'max';
    let price1 = 'max';

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = false;
    let exact_out = false;
    let sqrt_price_limit = 50108289675009587501223378944;  // encode_price_sqrt(2, 5)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_max_max_price_swap_arbitrary_amount_to_price_zero_for_one_true_price_limit_2_5() {
    let fee = 3000;
    let price0 = 'max';
    let price1 = 'max';

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = true;
    let exact_out = false;
    let sqrt_price_limit = 50108289675009587501223378944;  // encode_price_sqrt(2, 5)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit);
}

//////
//////

#[test]
#[should_panic(expected: ('SPL',))]
fn test_swap_3000_fee_min_min_price_swap_large_amount_zero_for_one_true_exact_input() {
    let fee = 3000;
    let price0 = 'min';
    let price1 = 'min';

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = true;
    let exact_out = false;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit);
}

#[test]
#[should_panic(expected: ('SPL',))]
fn test_swap_3000_fee_min_min_price_swap_large_amount_zero_for_one_false_exact_input() {
    let fee = 3000;
    let price0 = 'min';
    let price1 = 'min';

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = false;
    let exact_out = false;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit);
}

#[test]
#[should_panic(expected: ('SPL',))]
fn test_swap_3000_fee_min_min_price_swap_large_amount_zero_for_one_true_exact_output() {
    let fee = 3000;
    let price0 = 'min';
    let price1 = 'min';

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = true;
    let exact_out = true;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_min_min_price_swap_large_amount_zero_for_one_false_exact_output() {
    let fee = 3000;
    let price0 = 'min';
    let price1 = 'min';

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = false;
    let exact_out = true;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit);
}

#[test]
#[should_panic(expected: ('SPL',))]
fn test_swap_3000_fee_min_min_price_swap_large_amount_with_price_limit_zero_for_one_true_exact_input() {
    let fee = 3000;
    let price0 = 'min';
    let price1 = 'min';

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = true;
    let exact_out = false;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 56022770974786143748341366784;   // encode_price_sqrt(50, 100)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit);
}

#[test]
#[should_panic(expected: ('SPL',))]
fn test_swap_3000_fee_min_min_price_swap_large_amount_with_price_limit_zero_for_one_false_exact_input() {
    let fee = 3000;
    let price0 = 'min';
    let price1 = 'min';

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = false;
    let exact_out = false;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 112045541949572287496682733568;  // encode_price_sqrt(200, 100)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit);
}

#[test]
#[should_panic(expected: ('SPL',))]
fn test_swap_3000_fee_min_min_price_swap_large_amount_with_price_limit_zero_for_one_true_exact_output() {
    let fee = 3000;
    let price0 = 'min';
    let price1 = 'min';

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = true;
    let exact_out = true;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 56022770974786143748341366784;   // encode_price_sqrt(50, 100)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_min_min_price_swap_large_amount_with_price_limit_zero_for_one_false_exact_output() {
    let fee = 3000;
    let price0 = 'min';
    let price1 = 'min';

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = false;
    let exact_out = true;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 112045541949572287496682733568;  // encode_price_sqrt(200, 100)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit);
}

#[test]
#[should_panic(expected: ('SPL',))]
fn test_swap_3000_fee_min_min_price_swap_small_amount_zero_for_one_true_exact_input() {
    let fee = 3000;
    let price0 = 'min';
    let price1 = 'min';

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = true;
    let exact_out = false;
    let amount0 = 1000;
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_min_min_price_swap_small_amount_zero_for_one_false_exact_input() {
    let fee = 3000;
    let price0 = 'min';
    let price1 = 'min';

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = false;
    let exact_out = false;
    let amount1 = 1000;
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit);
}

#[test]
#[should_panic(expected: ('SPL',))]
fn test_swap_3000_fee_min_min_price_swap_small_amount_zero_for_one_true_exact_output() {
    let fee = 3000;
    let price0 = 'min';
    let price1 = 'min';

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = true;
    let exact_out = true;
    let amount1 = 1000;
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit);
}

#[test]
fn test_swap_3000_fee_min_min_price_swap_small_amount_zero_for_one_false_exact_output() {
    let fee = 3000;
    let price0 = 'min';
    let price1 = 'min';

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = false;
    let exact_out = true;
    let amount0 = 1000;
    let sqrt_price_limit = 0;

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit);
}

#[test]
#[should_panic(expected: ('SPL',))]
fn test_swap_3000_fee_min_min_price_swap_arbitrary_amount_to_price_zero_for_one_false_price_limit_5_2() {
    let fee = 3000;
    let price0 = 'min';
    let price1 = 'min';

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = false;
    let exact_out = false;
    let sqrt_price_limit = 125270724187523973151104958464;  // encode_price_sqrt(5, 2)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit);
}

#[test]
#[should_panic(expected: ('SPL',))]
fn test_swap_3000_fee_min_min_price_swap_arbitrary_amount_to_price_zero_for_one_true_price_limit_5_2() {
    let fee = 3000;
    let price0 = 'min';
    let price1 = 'min';

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = true;
    let exact_out = false;
    let sqrt_price_limit = 125270724187523973151104958464;  // encode_price_sqrt(5, 2)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit);
}

#[test]
#[should_panic(expected: ('SPL',))]
fn test_swap_3000_fee_min_min_price_swap_arbitrary_amount_to_price_zero_for_one_false_price_limit_2_5() {
    let fee = 3000;
    let price0 = 'min';
    let price1 = 'min';

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = false;
    let exact_out = false;
    let sqrt_price_limit = 50108289675009587501223378944;  // encode_price_sqrt(2, 5)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit);
}

#[test]
#[should_panic(expected: ('SPL',))]
fn test_swap_3000_fee_min_min_price_swap_arbitrary_amount_to_price_zero_for_one_true_price_limit_2_5() {
    let fee = 3000;
    let price0 = 'min';
    let price1 = 'min';

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions.append(PoolTestPosition {tick_lower: get_min_tick(fee), tick_upper: get_max_tick(fee), liquidity: 2 * pow(10, 18)});

    let zero_for_one = true;
    let exact_out = false;
    let sqrt_price_limit = 50108289675009587501223378944;  // encode_price_sqrt(2, 5)

    execute_and_test_swap(fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit);
}