use core::traits::TryInto;
use starknet::{ContractAddress, contract_address_try_from_felt252};
use integer::BoundedInt;
use jediswap_v2_core::libraries::signed_integers::{
    i32::i32, i128::i128, i256::i256, integer_trait::IntegerTrait
};
use jediswap_v2_core::libraries::math_utils::pow;
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
    declare, ContractClassTrait, start_prank, stop_prank, CheatTarget, spy_events,
    SpyOn, EventSpy, EventFetcher, Event, EventAssertions
};

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

#[derive(Copy, Drop, Serde)]
struct SwapExpectedResults {
    amount0_before: u256,
    amount0_delta: i256,
    amount1_before: u256,
    amount1_delta: i256,
    execution_price: u256,
    fee_growth_global_0_X128_delta: u256,
    fee_growth_global_1_X128_delta: u256,
    pool_price_before: u256,
    pool_price_after: u256,
    tick_before: i32,
    tick_after: i32,
}

fn setup_factory() -> (ContractAddress, ContractAddress) {
    let owner = owner();
    let pool_class = declare("JediSwapV2Pool");

    let factory_class = declare("JediSwapV2Factory");
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
        return IntegerTrait::<i32>::new(887272, true); // math.ceil(-887272 / 2) * 2
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
        return 11505743598341114571880798222544994; // get_max_liquidity_per_tick(60)
    } else {
        return 0;
    }
}

fn create_pool(fee: u32) -> ContractAddress {
    let (_, factory_address) = setup_factory();
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
        pool_dispatcher.initialize(25054144837504793118641380156); //  encode_price_sqrt(1, 10)
    } else if (price0 == 10 && price1 == 1) {
        pool_dispatcher.initialize(250541448375047931186413801569); //  encode_price_sqrt(10, 1)
    } else if (price0 == 1 && price1 == 1) {
        pool_dispatcher.initialize(79228162514264337593543950336); //  encode_price_sqrt(1, 1)
    } else if (price0 == pow(2, 127) && price1 == 1) {
        pool_dispatcher
            .initialize(
                1033437718471923706666374484006904511252097097914
            ); //  encode_price_sqrt(2 ** 127, 1)
    } else if (price0 == 1 && price1 == pow(2, 127)) {
        pool_dispatcher.initialize(6085630636); //  encode_price_sqrt(1, 2 ** 127)
    } else if (price0 == 'max' && price1 == 'max') {
        pool_dispatcher.initialize(MAX_SQRT_RATIO - 1);
    } else if (price0 == 'min' && price1 == 'min') {
        pool_dispatcher.initialize(MIN_SQRT_RATIO);
    }

    pool_address
}

fn get_pool_mint_test_dispatcher() -> IPoolMintTestDispatcher {
    let pool_mint_test_class = declare("PoolMintTest");
    let mut pool_mint_test_constructor_calldata = Default::default();

    let pool_mint_test_address = pool_mint_test_class
        .deploy(@pool_mint_test_constructor_calldata)
        .unwrap();

    IPoolMintTestDispatcher { contract_address: pool_mint_test_address }
}

fn initiate_pool_with_intial_mint(
    fee: u32, price0: u256, price1: u256, pool_test_positions: Array::<PoolTestPosition>
) -> (ContractAddress, IPoolMintTestDispatcher) {
    let pool_address = initialize_pool(fee, price0, price1);

    let pool_mint_test_dispatcher = get_pool_mint_test_dispatcher();

    let pool_dispatcher = IJediSwapV2PoolDispatcher { contract_address: pool_address };

    let token0_dispatcher = IERC20Dispatcher { contract_address: pool_dispatcher.get_token0() };
    start_prank(CheatTarget::One(pool_dispatcher.get_token0()), user1());
    token0_dispatcher
        .approve(pool_mint_test_dispatcher.contract_address, 100 * pow(10, 18) * pow(10, 18));
    stop_prank(CheatTarget::One(pool_dispatcher.get_token0()));

    let token1_dispatcher = IERC20Dispatcher { contract_address: pool_dispatcher.get_token1() };
    start_prank(CheatTarget::One(pool_dispatcher.get_token1()), user1());
    token1_dispatcher
        .approve(pool_mint_test_dispatcher.contract_address, 100 * pow(10, 18) * pow(10, 18));
    stop_prank(CheatTarget::One(pool_dispatcher.get_token1()));

    let mut index = 0;
    loop {
        if (index == pool_test_positions.len()) {
            break;
        }
        let pool_test_position = *pool_test_positions[index];
        start_prank(CheatTarget::One(pool_mint_test_dispatcher.contract_address), user1());
        pool_mint_test_dispatcher
            .mint(
                pool_address,
                user1(),
                pool_test_position.tick_lower,
                pool_test_position.tick_upper,
                pool_test_position.liquidity.try_into().unwrap()
            );
        stop_prank(CheatTarget::One(pool_mint_test_dispatcher.contract_address));
        index += 1;
    };

    (pool_address, pool_mint_test_dispatcher)
}

fn get_pool_swap_test_dispatcher(
    pool_dispatcher: IJediSwapV2PoolDispatcher
) -> IPoolSwapTestDispatcher {
    let pool_swap_test_class = declare("PoolSwapTest");
    let mut pool_swap_test_constructor_calldata = Default::default();

    let pool_swap_test_address = pool_swap_test_class
        .deploy(@pool_swap_test_constructor_calldata)
        .unwrap();

    let pool_swap_test_dispatcher = IPoolSwapTestDispatcher {
        contract_address: pool_swap_test_address
    };

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

fn calculate_execution_price(pool_balance0_delta_mag: u256, pool_balance1_delta_mag: u256) -> u256 {
        if (pool_balance0_delta_mag == 0 && pool_balance1_delta_mag == 0) {
            0
        } else if (pool_balance0_delta_mag == 0) { 
            '-Infinity'.into()
        } else {
            (pool_balance1_delta_mag * pow(2, 96)) / pool_balance0_delta_mag
        }
    }

fn execute_and_test_swap(
    fee: u32,
    price0: u256,
    price1: u256,
    pool_test_positions: Array::<PoolTestPosition>,
    zero_for_one: bool,
    exact_out: bool,
    amount: u256,
    mut sqrt_price_limit: u256,
    expected_results: SwapExpectedResults
) {
    let (pool_address, _) = initiate_pool_with_intial_mint(
        fee, price0, price1, pool_test_positions
    );

    let pool_dispatcher = IJediSwapV2PoolDispatcher { contract_address: pool_address };

    let token0_dispatcher = IERC20Dispatcher { contract_address: pool_dispatcher.get_token0() };
    let pool_balance0 = token0_dispatcher.balance_of(pool_address);

    let token1_dispatcher = IERC20Dispatcher { contract_address: pool_dispatcher.get_token1() };
    let pool_balance1 = token1_dispatcher.balance_of(pool_address);

    let pool_swap_test_dispatcher = get_pool_swap_test_dispatcher(pool_dispatcher);

    let pool_price_before = pool_dispatcher.get_sqrt_price_X96();
    let tick_before = pool_dispatcher.get_tick();

    // 'amount0_before'.print();
    // pool_balance0.print();
    // expected_results.amount0_before.print();

    // 'amount1_before'.print();
    // pool_balance1.print();
    // expected_results.amount1_before.print();

    // 'pool_price_before'.print();
    // pool_price_before.print();
    // expected_results.pool_price_before.print();
    

    // 'tick_before'.print();
    // tick_before.mag.print();
    // tick_before.sign.print();
    // expected_results.tick_before.mag.print();
    // expected_results.tick_before.sign.print();
    
    assert(pool_balance0 == expected_results.amount0_before, 'Wrong amount0_before');
    assert(pool_balance1 == expected_results.amount1_before, 'Wrong amount1_before');
    assert(pool_price_before == expected_results.pool_price_before, 'Wrong pool_price_before');
    assert(tick_before == expected_results.tick_before, 'Wrong tick_before');

    let mut spy = spy_events(
        SpyOn::Multiple(
            array![pool_dispatcher.get_token0(), pool_dispatcher.get_token1(), pool_address]
        )
    );

    start_prank(CheatTarget::One(pool_swap_test_dispatcher.contract_address), user1());
    if (amount != 0) {
        if (exact_out) {
            if (zero_for_one) {
                if (sqrt_price_limit == 0) {
                    sqrt_price_limit = MIN_SQRT_RATIO + 1;
                }
                pool_swap_test_dispatcher
                    .swap_0_for_exact_1(pool_address, amount, user1(), sqrt_price_limit);
            } else {
                if (sqrt_price_limit == 0) {
                    sqrt_price_limit = MAX_SQRT_RATIO - 1;
                }
                pool_swap_test_dispatcher
                    .swap_1_for_exact_0(pool_address, amount, user1(), sqrt_price_limit);
            }
        } else {
            if (zero_for_one) {
                if (sqrt_price_limit == 0) {
                    sqrt_price_limit = MIN_SQRT_RATIO + 1;
                }
                pool_swap_test_dispatcher
                    .swap_exact_0_for_1(pool_address, amount, user1(), sqrt_price_limit);
            } else {
                if (sqrt_price_limit == 0) {
                    sqrt_price_limit = MAX_SQRT_RATIO - 1;
                }
                pool_swap_test_dispatcher
                    .swap_exact_1_for_0(pool_address, amount, user1(), sqrt_price_limit);
            }
        }
    } else {
        if (zero_for_one) {
            pool_swap_test_dispatcher
                .swap_to_lower_sqrt_price(pool_address, sqrt_price_limit, user1());
        } else {
            pool_swap_test_dispatcher
                .swap_to_higher_sqrt_price(pool_address, sqrt_price_limit, user1());
        }
    }
    stop_prank(CheatTarget::One(pool_swap_test_dispatcher.contract_address));

    let pool_balance0_after = token0_dispatcher.balance_of(pool_address);
    let pool_balance1_after = token1_dispatcher.balance_of(pool_address);

    let pool_balance0_delta = IntegerTrait::<i256>::new(pool_balance0_after, false)
        - pool_balance0.into();
    let pool_balance1_delta = IntegerTrait::<i256>::new(pool_balance1_after, false)
        - pool_balance1.into();

    if (pool_balance0_delta < IntegerTrait::<i256>::new(0, false)) {
        spy
            .assert_emitted(
                @array![
                    (
                        pool_dispatcher.get_token0(),
                        ERC20Component::Event::Transfer(
                            ERC20Component::Transfer {
                                from: pool_address,
                                to: user1(),
                                value: (-pool_balance0_delta).try_into().unwrap()
                            }
                        )
                    )
                ]
            );
    } else if (pool_balance0_delta > IntegerTrait::<i256>::new(0, false)) {
        spy
            .assert_emitted(
                @array![
                    (
                        pool_dispatcher.get_token0(),
                        ERC20Component::Event::Transfer(
                            ERC20Component::Transfer {
                                from: user1(),
                                to: pool_address,
                                value: pool_balance0_delta.try_into().unwrap()
                            }
                        )
                    )
                ]
            );
    }

    if (pool_balance1_delta < IntegerTrait::<i256>::new(0, false)) {
        spy
            .assert_emitted(
                @array![
                    (
                        pool_dispatcher.get_token1(),
                        ERC20Component::Event::Transfer(
                            ERC20Component::Transfer {
                                from: pool_address,
                                to: user1(),
                                value: (-pool_balance1_delta).try_into().unwrap()
                            }
                        )
                    )
                ]
            );
    } else if (pool_balance1_delta > IntegerTrait::<i256>::new(0, false)) {
        spy
            .assert_emitted(
                @array![
                    (
                        pool_dispatcher.get_token1(),
                        ERC20Component::Event::Transfer(
                            ERC20Component::Transfer {
                                from: user1(),
                                to: pool_address,
                                value: pool_balance1_delta.try_into().unwrap()
                            }
                        )
                    )
                ]
            );
    }

    let pool_price_after = pool_dispatcher.get_sqrt_price_X96();
    let tick_after = pool_dispatcher.get_tick();
    let liquidity_after = pool_dispatcher.get_liquidity();

    spy
        .assert_emitted(
            @array![
                (
                    pool_address,
                    JediSwapV2Pool::Event::Swap(
                        JediSwapV2Pool::Swap {
                            sender: pool_swap_test_dispatcher.contract_address,
                            recipient: user1(),
                            amount0: pool_balance0_delta,
                            amount1: pool_balance1_delta,
                            sqrt_price_X96: pool_price_after,
                            liquidity: liquidity_after,
                            tick: tick_after
                        }
                    )
                )
            ]
        );
    let execution_price = calculate_execution_price(pool_balance0_delta.mag, pool_balance1_delta.mag);

    // 'amount0_delta'.print();
    // pool_balance0_delta.mag.print();
    // pool_balance0_delta.sign.print();
    // expected_results.amount0_delta.mag.print();
    // expected_results.amount0_delta.sign.print();
    

    // 'amount1_delta'.print();
    // pool_balance1_delta.mag.print();
    // pool_balance1_delta.sign.print();
    // expected_results.amount1_delta.mag.print();
    // expected_results.amount1_delta.sign.print();
    

    // 'execution price'.print();
    // execution_price.print();
    // // let execution_price_felt: felt252 = execution_price.try_into().unwrap();
    // // execution_price_felt.print();
    // expected_results.execution_price.print();
    // // let expected_execution_price_felt: felt252 = expected_results.execution_price.try_into().unwrap();
    // // expected_execution_price_felt.print();
    

    // 'fee_growth_global_0_X128_delta'.print();
    let fee_growth_global_0_X128_delta = pool_dispatcher.get_fee_growth_global_0_X128();
    // fee_growth_global_0_X128_delta.print();
    // expected_results.fee_growth_global_0_X128_delta.print();
    

    // 'fee_growth_global_1_X128_delta'.print();
    let fee_growth_global_1_X128_delta = pool_dispatcher.get_fee_growth_global_1_X128();
    // fee_growth_global_1_X128_delta.print();
    // expected_results.fee_growth_global_1_X128_delta.print();
    

    // 'pool_price_after'.print();
    // pool_price_after.print();
    // expected_results.pool_price_after.print();
    

    // 'tick_after'.print();
    // tick_after.mag.print();
    // tick_after.sign.print();
    // expected_results.tick_after.mag.print();
    // expected_results.tick_after.sign.print();
    
    assert(pool_balance0_delta == expected_results.amount0_delta, 'Wrong amount0_delta');
    assert(pool_balance1_delta == expected_results.amount1_delta, 'Wrong amount1_delta');
    assert(execution_price == expected_results.execution_price, 'Wrong execution price');
    assert(fee_growth_global_0_X128_delta == expected_results.fee_growth_global_0_X128_delta, 'Wrong fee_growth_global_0');
    assert(fee_growth_global_1_X128_delta == expected_results.fee_growth_global_1_X128_delta, 'Wrong fee_growth_global_1');
    assert(pool_price_after == expected_results.pool_price_after, 'Wrong pool_price_after');
    assert(tick_after == expected_results.tick_after, 'Wrong tick_after');
}


//////
//////

#[test]
fn test_swap_3000_fee_1_10_price_max_range_liquidity_swap_large_amount_zero_for_one_true_exact_input() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 10;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = true;
    let exact_out = false;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 0;

    let expected_results = SwapExpectedResults {
        amount0_before: 6324555320336758664,
        amount0_delta: IntegerTrait::<i256>::new(1000000000000000000, false),
        amount1_before: 632455532033675867,
        amount1_delta: IntegerTrait::<i256>::new(86123526743846551, true),
        execution_price: 6823408773163065477913375660,
        fee_growth_global_0_X128_delta: 510423550381407695195061911147652317,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 25054144837504793118641380156,
        pool_price_after: 21642440450923260367468386313,
        tick_before: IntegerTrait::<i32>::new(23028, true),
        tick_after: IntegerTrait::<i32>::new(25955, true),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_1_10_price_max_range_liquidity_swap_large_amount_zero_for_one_false_exact_input() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 10;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = false;
    let exact_out = false;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 0;

    let expected_results = SwapExpectedResults {
        amount0_before: 6324555320336758664,
        amount0_delta: IntegerTrait::<i256>::new(3869747612262812753, true),
        amount1_before: 632455532033675867,
        amount1_delta: IntegerTrait::<i256>::new(1000000000000000000, false),
        execution_price: 20473728638839090420193456859,     // Uni value 20473728638839090420059998540
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 510423550381407865336245371616884047,
        pool_price_before: 25054144837504793118641380156,
        pool_price_after: 64549383850865565330872014953,
        tick_before: IntegerTrait::<i32>::new(23028, true),
        tick_after: IntegerTrait::<i32>::new(4099, true),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_1_10_price_max_range_liquidity_swap_large_amount_zero_for_one_true_exact_output() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 10;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = true;
    let exact_out = true;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 0;

    let expected_results = SwapExpectedResults {
        amount0_before: 6324555320336758664,
        amount0_delta: IntegerTrait::<i256>::new(
            36907032419362389223785084665766560335, false
        ),
        amount1_before: 632455532033675867,
        amount1_delta: IntegerTrait::<i256>::new(632455532033675838, true),
        execution_price: 1357689480,
        fee_growth_global_0_X128_delta: 18838218521532665615644565874197034349094564536667752274,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 25054144837504793118641380156,
        pool_price_after: 4295128740,
        tick_before: IntegerTrait::<i32>::new(23028, true),
        tick_after: IntegerTrait::<i32>::new(887272, true),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_1_10_price_max_range_liquidity_swap_large_amount_zero_for_one_false_exact_output() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 10;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = false;
    let exact_out = true;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 0;

    let expected_results = SwapExpectedResults {
        amount0_before: 6324555320336758664,
        amount0_delta: IntegerTrait::<i256>::new(1000000000000000000, true),
        amount1_before: 632455532033675867,
        amount1_delta: IntegerTrait::<i256>::new(119138326055954425, false),
        execution_price: 9439110658438570579685909958,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 60811007371978153949466126675899993,
        pool_price_before: 25054144837504793118641380156,
        pool_price_after: 29759541500736420511095977100,
        tick_before: IntegerTrait::<i32>::new(23028, true),
        tick_after: IntegerTrait::<i32>::new(19585, true),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit, expected_results
    );
}

#[test]
#[should_panic(expected: ('SPL',))]
fn test_swap_3000_fee_1_10_price_max_range_liquidity_swap_large_amount_with_price_limit_zero_for_one_true_exact_input() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 10;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = true;
    let exact_out = false;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 56022770974786139918731938227; // encode_price_sqrt(50, 100)

    let expected_results = SwapExpectedResults {
        amount0_before: 6324555320336758664,
        amount0_delta: IntegerTrait::<i256>::new(0, false),
        amount1_before: 632455532033675867,
        amount1_delta: IntegerTrait::<i256>::new(0, false),
        execution_price: 0,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 25054144837504793118641380156,
        pool_price_after: 0,
        tick_before: IntegerTrait::<i32>::new(23028, true),
        tick_after: IntegerTrait::<i32>::new(0, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_1_10_price_max_range_liquidity_swap_large_amount_with_price_limit_zero_for_one_false_exact_input() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 10;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = false;
    let exact_out = false;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 112045541949572279837463876454; // encode_price_sqrt(200, 100)

    let expected_results = SwapExpectedResults {
        amount0_before: 6324555320336758664,
        amount0_delta: IntegerTrait::<i256>::new(3869747612262812753, true),
        amount1_before: 632455532033675867,
        amount1_delta: IntegerTrait::<i256>::new(1000000000000000000, false),
        execution_price: 20473728638839090420193456859,     // Uni value 20473728638839090420059998540
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 510423550381407865336245371616884047,
        pool_price_before: 25054144837504793118641380156,
        pool_price_after: 64549383850865565330872014953,
        tick_before: IntegerTrait::<i32>::new(23028, true),
        tick_after: IntegerTrait::<i32>::new(4099, true),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit, expected_results
    );
}

#[test]
#[should_panic(expected: ('SPL',))]
fn test_swap_3000_fee_1_10_price_max_range_liquidity_swap_large_amount_with_price_limit_zero_for_one_true_exact_output() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 10;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = true;
    let exact_out = true;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 56022770974786139918731938227; // encode_price_sqrt(50, 100)

    let expected_results = SwapExpectedResults {
        amount0_before: 6324555320336758664,
        amount0_delta: IntegerTrait::<i256>::new(0, false),
        amount1_before: 632455532033675867,
        amount1_delta: IntegerTrait::<i256>::new(0, false),
        execution_price: 0,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 25054144837504793118641380156,
        pool_price_after: 0,
        tick_before: IntegerTrait::<i32>::new(23028, true),
        tick_after: IntegerTrait::<i32>::new(0, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_1_10_price_max_range_liquidity_swap_large_amount_with_price_limit_zero_for_one_false_exact_output() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 10;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = false;
    let exact_out = true;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 112045541949572279837463876454; // encode_price_sqrt(200, 100)

    let expected_results = SwapExpectedResults {
        amount0_before: 6324555320336758664,
        amount0_delta: IntegerTrait::<i256>::new(1000000000000000000, true),
        amount1_before: 632455532033675867,
        amount1_delta: IntegerTrait::<i256>::new(119138326055954425, false),
        execution_price: 9439110658438570579685909958,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 60811007371978153949466126675899993,
        pool_price_before: 25054144837504793118641380156,
        pool_price_after: 29759541500736420511095977100,
        tick_before: IntegerTrait::<i32>::new(23028, true),
        tick_after: IntegerTrait::<i32>::new(19585, true),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_1_10_price_max_range_liquidity_swap_small_amount_zero_for_one_true_exact_input() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 10;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = true;
    let exact_out = false;
    let amount0 = 1000;
    let sqrt_price_limit = 0;

    let expected_results = SwapExpectedResults {
        amount0_before: 6324555320336758664,
        amount0_delta: IntegerTrait::<i256>::new(1000, false),
        amount1_before: 632455532033675867,
        amount1_delta: IntegerTrait::<i256>::new(99, true),
        execution_price: 7843588088912169421760851083,
        fee_growth_global_0_X128_delta: 510423550381407695195,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 25054144837504793118641380156,
        pool_price_after: 25054144837504789169117478820,
        tick_before: IntegerTrait::<i32>::new(23028, true),
        tick_after: IntegerTrait::<i32>::new(23028, true),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_1_10_price_max_range_liquidity_swap_small_amount_zero_for_one_false_exact_input() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 10;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = false;
    let exact_out = false;
    let amount1 = 1000;
    let sqrt_price_limit = 0;

    let expected_results = SwapExpectedResults {
        amount0_before: 6324555320336758664,
        amount0_delta: IntegerTrait::<i256>::new(9969, true),
        amount1_before: 632455532033675867,
        amount1_delta: IntegerTrait::<i256>::new(1000, false),
        execution_price: 7947453356832614865437250510,  // Uni Value 7947453356832614865647222227
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 510423550381407695195,
        pool_price_before: 25054144837504793118641380156,
        pool_price_after: 25054144837504832613880393516,
        tick_before: IntegerTrait::<i32>::new(23028, true),
        tick_after: IntegerTrait::<i32>::new(23028, true),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_1_10_price_max_range_liquidity_swap_small_amount_zero_for_one_true_exact_output() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 10;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = true;
    let exact_out = true;
    let amount1 = 1000;
    let sqrt_price_limit = 0;

    let expected_results = SwapExpectedResults {
        amount0_before: 6324555320336758664,
        amount0_delta: IntegerTrait::<i256>::new(10032, false),
        amount1_before: 632455532033675867,
        amount1_delta: IntegerTrait::<i256>::new(1000, true),
        execution_price: 7897544110273558372562196006,      // Uni value 7897544110273558372587468147
        fee_growth_global_0_X128_delta: 5274376687274546183682,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 25054144837504793118641380156,
        pool_price_after: 25054144837504753504560123023,
        tick_before: IntegerTrait::<i32>::new(23028, true),
        tick_after: IntegerTrait::<i32>::new(23028, true),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_1_10_price_max_range_liquidity_swap_small_amount_zero_for_one_false_exact_output() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 10;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = false;
    let exact_out = true;
    let amount0 = 1000;
    let sqrt_price_limit = 0;

    let expected_results = SwapExpectedResults {
        amount0_before: 6324555320336758664,
        amount0_delta: IntegerTrait::<i256>::new(1000, true),
        amount1_before: 632455532033675867,
        amount1_delta: IntegerTrait::<i256>::new(102, false),
        execution_price: 8081272576454962434541482934,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 170141183460469231731,
        pool_price_before: 25054144837504793118641380156,
        pool_price_after: 25054144837504797080049505870,
        tick_before: IntegerTrait::<i32>::new(23028, true),
        tick_after: IntegerTrait::<i32>::new(23028, true),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_1_10_price_max_range_liquidity_swap_arbitrary_amount_to_price_zero_for_one_false_price_limit_5_2() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 10;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = false;
    let exact_out = false;
    let sqrt_price_limit = 125270724187523965593206900784; // encode_price_sqrt(5, 2)

    let expected_results = SwapExpectedResults {
        amount0_before: 6324555320336758664,
        amount0_delta: IntegerTrait::<i256>::new(5059644256269406930, true),
        amount1_before: 632455532033675867,
        amount1_delta: IntegerTrait::<i256>::new(2537434431428990440, false),
        execution_price: 39733281100433469262183057466,     // Uni Value 39733281100433469262475982194
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 1295166291350014177337973823092140516,
        pool_price_before: 25054144837504793118641380156,
        pool_price_after: 125270724187523965593206900784,
        tick_before: IntegerTrait::<i32>::new(23028, true),
        tick_after: IntegerTrait::<i32>::new(9163, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit, expected_results
    );
}

#[test]
#[should_panic(expected: ('SPL',))]
fn test_swap_3000_fee_1_10_price_max_range_liquidity_swap_arbitrary_amount_to_price_zero_for_one_true_price_limit_2_5() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 10;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = true;
    let exact_out = false;
    let sqrt_price_limit = 50108289675009586237282760313; // encode_price_sqrt(2, 5)

    let expected_results = SwapExpectedResults {
        amount0_before: 6324555320336758664,
        amount0_delta: IntegerTrait::<i256>::new(0, false),
        amount1_before: 632455532033675867,
        amount1_delta: IntegerTrait::<i256>::new(0, false),
        execution_price: 0,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 25054144837504793118641380156,
        pool_price_after: 0,
        tick_before: IntegerTrait::<i32>::new(23028, true),
        tick_after: IntegerTrait::<i32>::new(0, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit, expected_results
    );
}

#[test]
#[should_panic(expected: ('SPL',))]
fn test_swap_3000_fee_1_10_price_max_range_liquidity_swap_arbitrary_amount_to_price_zero_for_one_true_price_limit_5_2() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 10;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = true;
    let exact_out = false;
    let sqrt_price_limit = 125270724187523965593206900784; // encode_price_sqrt(5, 2)

    let expected_results = SwapExpectedResults {
        amount0_before: 6324555320336758664,
        amount0_delta: IntegerTrait::<i256>::new(0, false),
        amount1_before: 632455532033675867,
        amount1_delta: IntegerTrait::<i256>::new(0, false),
        execution_price: 0,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 25054144837504793118641380156,
        pool_price_after: 0,
        tick_before: IntegerTrait::<i32>::new(23028, true),
        tick_after: IntegerTrait::<i32>::new(0, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_1_10_price_max_range_liquidity_swap_arbitrary_amount_to_price_zero_for_one_false_price_limit_2_5() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 10;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = false;
    let exact_out = false;
    let sqrt_price_limit = 50108289675009586237282760313; // encode_price_sqrt(2, 5)

    let expected_results = SwapExpectedResults {
        amount0_before: 6324555320336758664,
        amount0_delta: IntegerTrait::<i256>::new(3162277660168379331, true),
        amount1_before: 632455532033675867,
        amount1_delta: IntegerTrait::<i256>::new(634358607857247611, false),
        execution_price: 15893312440173387731183844496,     // Uni Value 15893312440173387730977230182
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 323791572837503501799197590655727195,
        pool_price_before: 25054144837504793118641380156,
        pool_price_after: 50108289675009586237282760313,
        tick_before: IntegerTrait::<i32>::new(23028, true),
        tick_after: IntegerTrait::<i32>::new(9164, true),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit, expected_results
    );
}

//////
//////

#[test]
fn test_swap_3000_fee_10_1_price_max_range_liquidity_swap_large_amount_zero_for_one_true_exact_input() {
    let fee = 3000;
    let price0 = 10;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = true;
    let exact_out = false;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 0;

    let expected_results = SwapExpectedResults {
        amount0_before: 632455532033675867,
        amount0_delta: IntegerTrait::<i256>::new(1000000000000000000, false),
        amount1_before: 6324555320336758664,
        amount1_delta: IntegerTrait::<i256>::new(3869747612262812754, true),
        execution_price: 306592992713544507924111903276,
        fee_growth_global_0_X128_delta: 510423550381407865336245371616884048,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 250541448375047931186413801569,
        pool_price_after: 97244952018275677188403231914,
        tick_before: IntegerTrait::<i32>::new(23027, false),
        tick_after: IntegerTrait::<i32>::new(4098, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_10_1_price_max_range_liquidity_swap_large_amount_zero_for_one_false_exact_input() {
    let fee = 3000;
    let price0 = 10;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = false;
    let exact_out = false;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 0;

    let expected_results = SwapExpectedResults {
        amount0_before: 632455532033675867,
        amount0_delta: IntegerTrait::<i256>::new(86123526743846551, true),
        amount1_before: 6324555320336758664,
        amount1_delta: IntegerTrait::<i256>::new(1000000000000000000, false),
        execution_price: 919936346196193352974929932576,    // Uni Value 919936346196193353013622028779
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 510423550381407695195061911147652317,
        pool_price_before: 250541448375047931186413801569,
        pool_price_after: 290036687388408703476795460811,
        tick_before: IntegerTrait::<i32>::new(23027, false),
        tick_after: IntegerTrait::<i32>::new(25954, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_10_1_price_max_range_liquidity_swap_large_amount_zero_for_one_true_exact_output() {
    let fee = 3000;
    let price0 = 10;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = true;
    let exact_out = true;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 0;

    let expected_results = SwapExpectedResults {
        amount0_before: 632455532033675867,
        amount0_delta: IntegerTrait::<i256>::new(119138326055954425, false),
        amount1_before: 6324555320336758664,
        amount1_delta: IntegerTrait::<i256>::new(1000000000000000000, true),
        execution_price: 665009868252254046243383680114,    // Uni Value 665009868252254046240513819058
        fee_growth_global_0_X128_delta: 60811007371978153949466126675899993,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 250541448375047931186413801569,
        pool_price_after: 210927367117915762389641826401,
        tick_before: IntegerTrait::<i32>::new(23027, false),
        tick_after: IntegerTrait::<i32>::new(19584, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_10_1_price_max_range_liquidity_swap_large_amount_zero_for_one_false_exact_output() {
    let fee = 3000;
    let price0 = 10;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = false;
    let exact_out = true;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 0;

    let expected_results = SwapExpectedResults {
        amount0_before: 632455532033675867,
        amount0_delta: IntegerTrait::<i256>::new(632455532033675838, true),
        amount1_before: 6324555320336758664,
        amount1_delta: IntegerTrait::<i256>::new(
            36907032426281581270030941278837275671, false
        ),
        execution_price: 4623370679652723600022818257295531198393401980175,     // Uni Value 4623370679652723600004998355562925450542729658368
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 18838218525064384185660173270402201838945341643205005201,
        pool_price_before: 250541448375047931186413801569,
        pool_price_after: 1461446703485210103287273052203988822378723970341,
        tick_before: IntegerTrait::<i32>::new(23027, false),
        tick_after: IntegerTrait::<i32>::new(887271, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_10_1_price_max_range_liquidity_swap_large_amount_with_price_limit_zero_for_one_true_exact_input() {
    let fee = 3000;
    let price0 = 10;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = true;
    let exact_out = false;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 56022770974786139918731938227; // encode_price_sqrt(50, 100)

    let expected_results = SwapExpectedResults {
        amount0_before: 632455532033675867,
        amount0_delta: IntegerTrait::<i256>::new(1000000000000000000, false),
        amount1_before: 6324555320336758664,
        amount1_delta: IntegerTrait::<i256>::new(3869747612262812754, true),
        execution_price: 306592992713544507924111903276,
        fee_growth_global_0_X128_delta: 510423550381407865336245371616884048,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 250541448375047931186413801569,
        pool_price_after: 97244952018275677188403231914,
        tick_before: IntegerTrait::<i32>::new(23027, false),
        tick_after: IntegerTrait::<i32>::new(4098, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit, expected_results
    );
}

#[test]
#[should_panic(expected: ('SPL',))]
fn test_swap_3000_fee_10_1_price_max_range_liquidity_swap_large_amount_with_price_limit_zero_for_one_false_exact_input() {
    let fee = 3000;
    let price0 = 10;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = false;
    let exact_out = false;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 112045541949572279837463876454; // encode_price_sqrt(200, 100)

    let expected_results = SwapExpectedResults {
        amount0_before: 632455532033675867,
        amount0_delta: IntegerTrait::<i256>::new(0, false),
        amount1_before: 6324555320336758664,
        amount1_delta: IntegerTrait::<i256>::new(0, false),
        execution_price: 0,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 250541448375047931186413801569,
        pool_price_after: 0,
        tick_before: IntegerTrait::<i32>::new(23027, false),
        tick_after: IntegerTrait::<i32>::new(0, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_10_1_price_max_range_liquidity_swap_large_amount_with_price_limit_zero_for_one_true_exact_output() {
    let fee = 3000;
    let price0 = 10;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = true;
    let exact_out = true;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 56022770974786139918731938227; // encode_price_sqrt(50, 100)

    let expected_results = SwapExpectedResults {
        amount0_before: 632455532033675867,
        amount0_delta: IntegerTrait::<i256>::new(119138326055954425, false),
        amount1_before: 6324555320336758664,
        amount1_delta: IntegerTrait::<i256>::new(1000000000000000000, true),
        execution_price: 665009868252254046243383680114,    //Uni Value 665009868252254046240513819058
        fee_growth_global_0_X128_delta: 60811007371978153949466126675899993,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 250541448375047931186413801569,
        pool_price_after: 210927367117915762389641826401,
        tick_before: IntegerTrait::<i32>::new(23027, false),
        tick_after: IntegerTrait::<i32>::new(19584, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit, expected_results
    );
}

#[test]
#[should_panic(expected: ('SPL',))]
fn test_swap_3000_fee_10_1_price_max_range_liquidity_swap_large_amount_with_price_limit_zero_for_one_false_exact_output() {
    let fee = 3000;
    let price0 = 10;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = false;
    let exact_out = true;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 112045541949572279837463876454; // encode_price_sqrt(200, 100)

    let expected_results = SwapExpectedResults {
        amount0_before: 632455532033675867,
        amount0_delta: IntegerTrait::<i256>::new(0, false),
        amount1_before: 6324555320336758664,
        amount1_delta: IntegerTrait::<i256>::new(0, false),
        execution_price: 0,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 250541448375047931186413801569,
        pool_price_after: 0,
        tick_before: IntegerTrait::<i32>::new(23027, false),
        tick_after: IntegerTrait::<i32>::new(0, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_10_1_price_max_range_liquidity_swap_small_amount_zero_for_one_true_exact_input() {
    let fee = 3000;
    let price0 = 10;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = true;
    let exact_out = false;
    let amount0 = 1000;
    let sqrt_price_limit = 0;

    let expected_results = SwapExpectedResults {
        amount0_before: 632455532033675867,
        amount0_delta: IntegerTrait::<i256>::new(1000, false),
        amount1_before: 6324555320336758664,
        amount1_delta: IntegerTrait::<i256>::new(9969, true),
        execution_price: 789825552104701181470039640899,
        fee_growth_global_0_X128_delta: 510423550381407695195,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 250541448375047931186413801569,
        pool_price_after: 250541448375047536234023667962,
        tick_before: IntegerTrait::<i32>::new(23027, false),
        tick_after: IntegerTrait::<i32>::new(23027, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_10_1_price_max_range_liquidity_swap_small_amount_zero_for_one_false_exact_input() {
    let fee = 3000;
    let price0 = 10;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = false;
    let exact_out = false;
    let amount1 = 1000;
    let sqrt_price_limit = 0;

    let expected_results = SwapExpectedResults {
        amount0_before: 632455532033675867,
        amount0_delta: IntegerTrait::<i256>::new(99, true),
        amount1_before: 6324555320336758664,
        amount1_delta: IntegerTrait::<i256>::new(1000, false),
        execution_price: 800284469841053915086302528646,    // Uni Value 800284469841053915078299683948
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 510423550381407695195,
        pool_price_before: 250541448375047931186413801569,
        pool_price_after: 250541448375047970681652814929,
        tick_before: IntegerTrait::<i32>::new(23027, false),
        tick_after: IntegerTrait::<i32>::new(23027, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_10_1_price_max_range_liquidity_swap_small_amount_zero_for_one_true_exact_output() {
    let fee = 3000;
    let price0 = 10;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = true;
    let exact_out = true;
    let amount1 = 1000;
    let sqrt_price_limit = 0;

    let expected_results = SwapExpectedResults {
        amount0_before: 632455532033675867,
        amount0_delta: IntegerTrait::<i256>::new(102, false),
        amount1_before: 6324555320336758664,
        amount1_delta: IntegerTrait::<i256>::new(1000, true),
        execution_price: 776746691316317035230823042509,    // Uni Value 776746691316317035231444439862
        fee_growth_global_0_X128_delta: 170141183460469231731,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 250541448375047931186413801569,
        pool_price_after: 250541448375047891572332544436,
        tick_before: IntegerTrait::<i32>::new(23027, false),
        tick_after: IntegerTrait::<i32>::new(23027, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_10_1_price_max_range_liquidity_swap_small_amount_zero_for_one_false_exact_output() {
    let fee = 3000;
    let price0 = 10;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = false;
    let exact_out = true;
    let amount0 = 1000;
    let sqrt_price_limit = 0;

    let expected_results = SwapExpectedResults {
        amount0_before: 632455532033675867,
        amount0_delta: IntegerTrait::<i256>::new(1000, true),
        amount1_before: 6324555320336758664,
        amount1_delta: IntegerTrait::<i256>::new(10032, false),
        execution_price: 794816926343099834738432909770,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 5274376687274546183682,
        pool_price_before: 250541448375047931186413801569,
        pool_price_after: 250541448375048327327226372892,
        tick_before: IntegerTrait::<i32>::new(23027, false),
        tick_after: IntegerTrait::<i32>::new(23027, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit, expected_results
    );
}

#[test]
#[should_panic(expected: ('SPL',))]
fn test_swap_3000_fee_10_1_price_max_range_liquidity_swap_arbitrary_amount_to_price_zero_for_one_false_price_limit_5_2() {
    let fee = 3000;
    let price0 = 10;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = false;
    let exact_out = false;
    let sqrt_price_limit = 125270724187523965593206900784; // encode_price_sqrt(5, 2)

    let expected_results = SwapExpectedResults {
        amount0_before: 632455532033675867,
        amount0_delta: IntegerTrait::<i256>::new(0, false),
        amount1_before: 6324555320336758664,
        amount1_delta: IntegerTrait::<i256>::new(0, false),
        execution_price: 0,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 250541448375047931186413801569,
        pool_price_after: 0,
        tick_before: IntegerTrait::<i32>::new(23027, false),
        tick_after: IntegerTrait::<i32>::new(0, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_10_1_price_max_range_liquidity_swap_arbitrary_amount_to_price_zero_for_one_true_price_limit_2_5() {
    let fee = 3000;
    let price0 = 10;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = true;
    let exact_out = false;
    let sqrt_price_limit = 50108289675009586237282760313; // encode_price_sqrt(2, 5)

    let expected_results = SwapExpectedResults {
        amount0_before: 632455532033675867,
        amount0_delta: IntegerTrait::<i256>::new(2537434431428990438, false),
        amount1_before: 6324555320336758664,
        amount1_delta: IntegerTrait::<i256>::new(5059644256269406930, true),
        execution_price: 157980956053443089056240226141,    //Uni Value 157980956053443089058530025701
        fee_growth_global_0_X128_delta: 1295166291350014007196790362622908786,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 250541448375047931186413801569,
        pool_price_after: 50108289675009586237282760313,
        tick_before: IntegerTrait::<i32>::new(23027, false),
        tick_after: IntegerTrait::<i32>::new(9164, true),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_10_1_price_max_range_liquidity_swap_arbitrary_amount_to_price_zero_for_one_true_price_limit_5_2() {
    let fee = 3000;
    let price0 = 10;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = true;
    let exact_out = false;
    let sqrt_price_limit = 125270724187523965593206900784; // encode_price_sqrt(5, 2)

    let expected_results = SwapExpectedResults {
        amount0_before: 632455532033675867,
        amount0_delta: IntegerTrait::<i256>::new(634358607857247610, false),
        amount1_before: 6324555320336758664,
        amount1_delta: IntegerTrait::<i256>::new(3162277660168379331, true),
        execution_price: 394952390133607722298076269152,    // Uni Value 394952390133607722301682557316
        fee_growth_global_0_X128_delta: 323791572837503501799197590655727196,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 250541448375047931186413801569,
        pool_price_after: 125270724187523965593206900784,
        tick_before: IntegerTrait::<i32>::new(23027, false),
        tick_after: IntegerTrait::<i32>::new(9163, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit, expected_results
    );
}

#[test]
#[should_panic(expected: ('SPL',))]
fn test_swap_3000_fee_10_1_price_max_range_liquidity_swap_arbitrary_amount_to_price_zero_for_one_false_price_limit_2_5() {
    let fee = 3000;
    let price0 = 10;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = false;
    let exact_out = false;
    let sqrt_price_limit = 50108289675009586237282760313; // encode_price_sqrt(2, 5)

    let expected_results = SwapExpectedResults {
        amount0_before: 632455532033675867,
        amount0_delta: IntegerTrait::<i256>::new(0, false),
        amount1_before: 6324555320336758664,
        amount1_delta: IntegerTrait::<i256>::new(0, false),
        execution_price: 0,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 250541448375047931186413801569,
        pool_price_after: 0,
        tick_before: IntegerTrait::<i32>::new(23027, false),
        tick_after: IntegerTrait::<i32>::new(0, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit, expected_results
    );
}


//////
//////

#[test]
fn test_swap_3000_fee_1_1_price_max_range_liquidity_swap_large_amount_zero_for_one_true_exact_input() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = true;
    let exact_out = false;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 0;

    let expected_results = SwapExpectedResults {
        amount0_before: 2000000000000000000,
        amount0_delta: IntegerTrait::<i256>::new(1000000000000000000, false),
        amount1_before: 2000000000000000000,
        amount1_delta: IntegerTrait::<i256>::new(665331998665331998, true),
        execution_price: 52713031716197226894743303609,
        fee_growth_global_0_X128_delta: 510423550381407695195061911147652317,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 52871646656165724119815782674,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(8090, true),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_1_1_price_max_range_liquidity_swap_large_amount_zero_for_one_false_exact_input() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = false;
    let exact_out = false;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 0;

    let expected_results = SwapExpectedResults {
        amount0_before: 2000000000000000000,
        amount0_delta: IntegerTrait::<i256>::new(665331998665331998, true),
        amount1_before: 2000000000000000000,
        amount1_delta: IntegerTrait::<i256>::new(1000000000000000000, false),
        execution_price: 119080643457999107324622879745,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 510423550381407695195061911147652317,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 118723401527625109883925609578,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(8089, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_1_1_price_max_range_liquidity_swap_large_amount_zero_for_one_true_exact_output() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = true;
    let exact_out = true;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 0;

    let expected_results = SwapExpectedResults {
        amount0_before: 2000000000000000000,
        amount0_delta: IntegerTrait::<i256>::new(2006018054162487463, false),
        amount1_before: 2000000000000000000,
        amount1_delta: IntegerTrait::<i256>::new(1000000000000000000, true),
        execution_price: 39495239013360772278315863723,
        fee_growth_global_0_X128_delta: 1023918857334819954209013958517557896,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 39614081257132168796771975168,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(13864, true),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_1_1_price_max_range_liquidity_swap_large_amount_zero_for_one_false_exact_output() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = false;
    let exact_out = true;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 0;

    let expected_results = SwapExpectedResults {
        amount0_before: 2000000000000000000,
        amount0_delta: IntegerTrait::<i256>::new(1000000000000000000, true),
        amount1_before: 2000000000000000000,
        amount1_delta: IntegerTrait::<i256>::new(2006018054162487463, false),
        execution_price: 158933124401733876866094591743,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 1023918857334819954209013958517557896,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 158456325028528675187087900672,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(13863, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_1_1_price_max_range_liquidity_swap_large_amount_with_price_limit_zero_for_one_true_exact_input() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = true;
    let exact_out = false;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 56022770974786139918731938227; // encode_price_sqrt(50, 100)

    let expected_results = SwapExpectedResults {
        amount0_before: 2000000000000000000,
        amount0_delta: IntegerTrait::<i256>::new(830919884399388263, false),
        amount1_before: 2000000000000000000,
        amount1_delta: IntegerTrait::<i256>::new(585786437626904951, true),
        execution_price: 55854702661861781439099287453,
        fee_growth_global_0_X128_delta: 424121077477644648929101317621422688,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 56022770974786139918731938227,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(6932, true),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_1_1_price_max_range_liquidity_swap_large_amount_with_price_limit_zero_for_one_false_exact_input() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = false;
    let exact_out = false;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 112045541949572279837463876454; // encode_price_sqrt(200, 100)

    let expected_results = SwapExpectedResults {
        amount0_before: 2000000000000000000,
        amount0_delta: IntegerTrait::<i256>::new(585786437626904951, true),
        amount1_before: 2000000000000000000,
        amount1_delta: IntegerTrait::<i256>::new(830919884399388263, false),
        execution_price: 112382690019631173478011159601,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 424121077477644648929101317621422688,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 112045541949572279837463876454,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(6931, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_1_1_price_max_range_liquidity_swap_large_amount_with_price_limit_zero_for_one_true_exact_output() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = true;
    let exact_out = true;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 56022770974786139918731938227; // encode_price_sqrt(50, 100)

    let expected_results = SwapExpectedResults {
        amount0_before: 2000000000000000000,
        amount0_delta: IntegerTrait::<i256>::new(830919884399388263, false),
        amount1_before: 2000000000000000000,
        amount1_delta: IntegerTrait::<i256>::new(585786437626904951, true),
        execution_price: 55854702661861781439099287453,
        fee_growth_global_0_X128_delta: 424121077477644648929101317621422688,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 56022770974786139918731938227,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(6932, true),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_1_1_price_max_range_liquidity_swap_large_amount_with_price_limit_zero_for_one_false_exact_output() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = false;
    let exact_out = true;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 112045541949572279837463876454; // encode_price_sqrt(200, 100)

    let expected_results = SwapExpectedResults {
        amount0_before: 2000000000000000000,
        amount0_delta: IntegerTrait::<i256>::new(585786437626904951, true),
        amount1_before: 2000000000000000000,
        amount1_delta: IntegerTrait::<i256>::new(830919884399388263, false),
        execution_price: 112382690019631173478011159601,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 424121077477644648929101317621422688,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 112045541949572279837463876454,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(6931, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_1_1_price_max_range_liquidity_swap_small_amount_zero_for_one_true_exact_input() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = true;
    let exact_out = false;
    let amount0 = 1000;
    let sqrt_price_limit = 0;

    let expected_results = SwapExpectedResults {
        amount0_before: 2000000000000000000,
        amount0_delta: IntegerTrait::<i256>::new(1000, false),
        amount1_before: 2000000000000000000,
        amount1_delta: IntegerTrait::<i256>::new(996, true),
        execution_price: 78911249864207280243169774534,
        fee_growth_global_0_X128_delta: 510423550381407695195,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 79228162514264298098304936976,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(1, true),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_1_1_price_max_range_liquidity_swap_small_amount_zero_for_one_false_exact_input() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = false;
    let exact_out = false;
    let amount1 = 1000;
    let sqrt_price_limit = 0;

    let expected_results = SwapExpectedResults {
        amount0_before: 2000000000000000000,
        amount0_delta: IntegerTrait::<i256>::new(996, true),
        amount1_before: 2000000000000000000,
        amount1_delta: IntegerTrait::<i256>::new(1000, false),
        execution_price: 79546347905887889150144528449,     // Uni Value 79546347905887889146199029593
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 510423550381407695195,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 79228162514264377088782963696,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(0, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_1_1_price_max_range_liquidity_swap_small_amount_zero_for_one_true_exact_output() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = true;
    let exact_out = true;
    let amount1 = 1000;
    let sqrt_price_limit = 0;

    let expected_results = SwapExpectedResults {
        amount0_before: 2000000000000000000,
        amount0_delta: IntegerTrait::<i256>::new(1005, false),
        amount1_before: 2000000000000000000,
        amount1_delta: IntegerTrait::<i256>::new(1000, true),
        execution_price: 78833992551506803575665622224,
        fee_growth_global_0_X128_delta: 680564733841876926926,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 79228162514264297979462693203,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(1, true),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_1_1_price_max_range_liquidity_swap_small_amount_zero_for_one_false_exact_output() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = false;
    let exact_out = true;
    let amount0 = 1000;
    let sqrt_price_limit = 0;

    let expected_results = SwapExpectedResults {
        amount0_before: 2000000000000000000,
        amount0_delta: IntegerTrait::<i256>::new(1000, true),
        amount1_before: 2000000000000000000,
        amount1_delta: IntegerTrait::<i256>::new(1005, false),
        execution_price: 79624303326835659281511670087,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 680564733841876926926,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 79228162514264377207625207469,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(0, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_1_1_price_max_range_liquidity_swap_arbitrary_amount_to_price_zero_for_one_false_price_limit_5_2() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = false;
    let exact_out = false;
    let sqrt_price_limit = 125270724187523965593206900784; // encode_price_sqrt(5, 2)

    let expected_results = SwapExpectedResults {
        amount0_before: 2000000000000000000,
        amount0_delta: IntegerTrait::<i256>::new(735088935932648267, true),
        amount1_before: 2000000000000000000,
        amount1_delta: IntegerTrait::<i256>::new(1165774985123750584, false),
        execution_price: 125647667189091239372331252954,    // Uni Value 125647667189091239369083622079
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 595039006852697554786973994761078087,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 125270724187523965593206900784,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(9163, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_1_1_price_max_range_liquidity_swap_arbitrary_amount_to_price_zero_for_one_true_price_limit_2_5() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = true;
    let exact_out = false;
    let sqrt_price_limit = 50108289675009586237282760313; // encode_price_sqrt(2, 5)

    let expected_results = SwapExpectedResults {
        amount0_before: 2000000000000000000,
        amount0_delta: IntegerTrait::<i256>::new(1165774985123750584, false),
        amount1_before: 2000000000000000000,
        amount1_delta: IntegerTrait::<i256>::new(735088935932648267, true),
        execution_price: 49957964805984557454241177498,
        fee_growth_global_0_X128_delta: 595039006852697554786973994761078087,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 50108289675009586237282760313,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(9164, true),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit, expected_results
    );
}

#[test]
#[should_panic(expected: ('SPL',))]
fn test_swap_3000_fee_1_1_price_max_range_liquidity_swap_arbitrary_amount_to_price_zero_for_one_true_price_limit_5_2() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = true;
    let exact_out = false;
    let sqrt_price_limit = 125270724187523965593206900784; // encode_price_sqrt(5, 2)

    let expected_results = SwapExpectedResults {
        amount0_before: 2000000000000000000,
        amount0_delta: IntegerTrait::<i256>::new(0, false),
        amount1_before: 2000000000000000000,
        amount1_delta: IntegerTrait::<i256>::new(0, false),
        execution_price: 0,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 0,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(0, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit, expected_results
    );
}

#[test]
#[should_panic(expected: ('SPL',))]
fn test_swap_3000_fee_1_1_price_max_range_liquidity_swap_arbitrary_amount_to_price_zero_for_one_false_price_limit_2_5() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = false;
    let exact_out = false;
    let sqrt_price_limit = 50108289675009586237282760313; // encode_price_sqrt(2, 5)

    let expected_results = SwapExpectedResults {
        amount0_before: 2000000000000000000,
        amount0_delta: IntegerTrait::<i256>::new(0, false),
        amount1_before: 2000000000000000000,
        amount1_delta: IntegerTrait::<i256>::new(0, false),
        execution_price: 0,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 0,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(0, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit, expected_results
    );
}

//////
//////

#[test]
fn test_swap_500_fee_1_1_price_max_range_liquidity_swap_large_amount_zero_for_one_true_exact_input() {
    let fee = 500;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = true;
    let exact_out = false;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 0;

    let expected_results = SwapExpectedResults {
        amount0_before: 2000000000000000000,
        amount0_delta: IntegerTrait::<i256>::new(1000000000000000000, false),
        amount1_before: 2000000000000000000,
        amount1_delta: IntegerTrait::<i256>::new(666444407401233536, true),
        execution_price: 52801165816307521305158135621,
        fee_growth_global_0_X128_delta: 85070591730234956148210572796405514,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 52827579606110576876218426439,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(8107, true),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_500_fee_1_1_price_max_range_liquidity_swap_large_amount_zero_for_one_false_exact_input() {
    let fee = 500;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = false;
    let exact_out = false;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 0;

    let expected_results = SwapExpectedResults {
        amount0_before: 2000000000000000000,
        amount0_delta: IntegerTrait::<i256>::new(666444407401233536, true),
        amount1_before: 2000000000000000000,
        amount1_delta: IntegerTrait::<i256>::new(1000000000000000000, false),
        execution_price: 118881877669602742198194788614,  // Uni value 118881877669602742194461822624
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 85070591730234956148210572796405515,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 118822436730767940180483797837,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(8106, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_500_fee_1_1_price_max_range_liquidity_swap_large_amount_zero_for_one_true_exact_output() {
    let fee = 500;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = true;
    let exact_out = true;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 0;

    let expected_results = SwapExpectedResults {
        amount0_before: 2000000000000000000,
        amount0_delta: IntegerTrait::<i256>::new(2001000500250125077, false),
        amount1_before: 2000000000000000000,
        amount1_delta: IntegerTrait::<i256>::new(1000000000000000000, true),
        execution_price: 39594274216503602426077290889,     // Uni value 39594274216503602426359922503
        fee_growth_global_0_X128_delta: 170226296608774038574344664756091446,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 39614081257132168708939713801,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(13864, true),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_500_fee_1_1_price_max_range_liquidity_swap_large_amount_zero_for_one_false_exact_output() {
    let fee = 500;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = false;
    let exact_out = true;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 0;

    let expected_results = SwapExpectedResults {
        amount0_before: 2000000000000000000,
        amount0_delta: IntegerTrait::<i256>::new(1000000000000000000, true),
        amount1_before: 2000000000000000000,
        amount1_delta: IntegerTrait::<i256>::new(2001000500250125079, false),
        execution_price: 158535592824941147064755447461,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 170226296608774378856711585694554910,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 158456325028528675570246264807,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(13863, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_500_fee_1_1_price_max_range_liquidity_swap_large_amount_with_price_limit_zero_for_one_true_exact_input() {
    let fee = 500;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = true;
    let exact_out = false;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 56022770974786139918731938227; // encode_price_sqrt(50, 100)

    let expected_results = SwapExpectedResults {
        amount0_before: 2000000000000000000,
        amount0_delta: IntegerTrait::<i256>::new(828841545518949575, false),
        amount1_before: 2000000000000000000,
        amount1_delta: IntegerTrait::<i256>::new(585786437626904950, true),
        execution_price: 55994759589298746557872246427,     // Uni value 55994759589298746558112653979
        fee_growth_global_0_X128_delta: 70510040727899606087499539976421836,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 56022770974786139918731938227,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(6932, true),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_500_fee_1_1_price_max_range_liquidity_swap_large_amount_with_price_limit_zero_for_one_false_exact_input() {
    let fee = 500;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = false;
    let exact_out = false;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 112045541949572279837463876454; // encode_price_sqrt(200, 100)

    let expected_results = SwapExpectedResults {
        amount0_before: 2000000000000000000,
        amount0_delta: IntegerTrait::<i256>::new(585786437626904950, true),
        amount1_before: 2000000000000000000,
        amount1_delta: IntegerTrait::<i256>::new(828841545518949574, false),
        execution_price: 112101592745945252910827679782,    // Uni value 112101592745945252910509369552
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 70510040727899435946316079507190105,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 112045541949572279837463876454,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(6931, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_500_fee_1_1_price_max_range_liquidity_swap_large_amount_with_price_limit_zero_for_one_true_exact_output() {
    let fee = 500;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = true;
    let exact_out = true;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 56022770974786139918731938227; // encode_price_sqrt(50, 100)

    let expected_results = SwapExpectedResults {
        amount0_before: 2000000000000000000,
        amount0_delta: IntegerTrait::<i256>::new(828841545518949575, false),
        amount1_before: 2000000000000000000,
        amount1_delta: IntegerTrait::<i256>::new(585786437626904950, true),
        execution_price: 55994759589298746557872246427,     // Uni value 55994759589298746558112653979
        fee_growth_global_0_X128_delta: 70510040727899606087499539976421836,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 56022770974786139918731938227,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(6932, true),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_500_fee_1_1_price_max_range_liquidity_swap_large_amount_with_price_limit_zero_for_one_false_exact_output() {
    let fee = 500;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = false;
    let exact_out = true;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 112045541949572279837463876454; // encode_price_sqrt(200, 100)

    let expected_results = SwapExpectedResults {
        amount0_before: 2000000000000000000,
        amount0_delta: IntegerTrait::<i256>::new(585786437626904950, true),
        amount1_before: 2000000000000000000,
        amount1_delta: IntegerTrait::<i256>::new(828841545518949574, false),
        execution_price: 112101592745945252910827679782,    // Uni value 112101592745945252910509369552
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 70510040727899435946316079507190105,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 112045541949572279837463876454,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(6931, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_500_fee_1_1_price_max_range_liquidity_swap_small_amount_zero_for_one_true_exact_input() {
    let fee = 500;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = true;
    let exact_out = false;
    let amount0 = 1000;
    let sqrt_price_limit = 0;

    let expected_results = SwapExpectedResults {
        amount0_before: 2000000000000000000,
        amount0_delta: IntegerTrait::<i256>::new(1000, false),
        amount1_before: 2000000000000000000,
        amount1_delta: IntegerTrait::<i256>::new(998, true),
        execution_price: 79069706189235808918356862435,
        fee_growth_global_0_X128_delta: 170141183460469231731,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 79228162514264298019076774461,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(1, true),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_500_fee_1_1_price_max_range_liquidity_swap_small_amount_zero_for_one_false_exact_input() {
    let fee = 500;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = false;
    let exact_out = false;
    let amount1 = 1000;
    let sqrt_price_limit = 0;

    let expected_results = SwapExpectedResults {
        amount0_before: 2000000000000000000,
        amount0_delta: IntegerTrait::<i256>::new(998, true),
        amount1_before: 2000000000000000000,
        amount1_delta: IntegerTrait::<i256>::new(1000, false),
        execution_price: 79386936387038414422388727791,     // Uni value 79386936387038414420150016185
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 170141183460469231731,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 79228162514264377168011126211,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(0, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_500_fee_1_1_price_max_range_liquidity_swap_small_amount_zero_for_one_true_exact_output() {
    let fee = 500;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = true;
    let exact_out = true;
    let amount1 = 1000;
    let sqrt_price_limit = 0;

    let expected_results = SwapExpectedResults {
        amount0_before: 2000000000000000000,
        amount0_delta: IntegerTrait::<i256>::new(1002, false),
        amount1_before: 2000000000000000000,
        amount1_delta: IntegerTrait::<i256>::new(1000, true),
        execution_price: 79070022469325686221101746842,     // Uni value 79070022469325686220923048591
        fee_growth_global_0_X128_delta: 170141183460469231731,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 79228162514264297979462693203,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(1, true),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_500_fee_1_1_price_max_range_liquidity_swap_small_amount_zero_for_one_false_exact_output() {
    let fee = 500;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = false;
    let exact_out = true;
    let amount0 = 1000;
    let sqrt_price_limit = 0;

    let expected_results = SwapExpectedResults {
        amount0_before: 2000000000000000000,
        amount0_delta: IntegerTrait::<i256>::new(1000, true),
        amount1_before: 2000000000000000000,
        amount1_delta: IntegerTrait::<i256>::new(1002, false),
        execution_price: 79386618839292866268731038236,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 170141183460469231731,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 79228162514264377207625207469,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(0, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_500_fee_1_1_price_max_range_liquidity_swap_arbitrary_amount_to_price_zero_for_one_false_price_limit_5_2() {
    let fee = 500;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = false;
    let exact_out = false;
    let sqrt_price_limit = 125270724187523965593206900784; // encode_price_sqrt(5, 2)

    let expected_results = SwapExpectedResults {
        amount0_before: 2000000000000000000,
        amount0_delta: IntegerTrait::<i256>::new(735088935932648266, true),
        amount1_before: 2000000000000000000,
        amount1_delta: IntegerTrait::<i256>::new(1162859089713235954, false),
        execution_price: 125333390882965448955978910081,    // Uni value 125333390882965448954948433099
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 98925110860787308007692432636113978,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 125270724187523965593206900784,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(9163, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_500_fee_1_1_price_max_range_liquidity_swap_arbitrary_amount_to_price_zero_for_one_true_price_limit_2_5() {
    let fee = 500;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = true;
    let exact_out = false;
    let sqrt_price_limit = 50108289675009586237282760313; // encode_price_sqrt(2, 5)

    let expected_results = SwapExpectedResults {
        amount0_before: 2000000000000000000,
        amount0_delta: IntegerTrait::<i256>::new(1162859089713235953, false),
        amount1_before: 2000000000000000000,
        amount1_delta: IntegerTrait::<i256>::new(735088935932648266, true),
        execution_price: 50083235530172081232043219158,     // Uni value 50083235530172081232103697237
        fee_growth_global_0_X128_delta: 98925110860787308007692432636113977,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 50108289675009586237282760313,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(9164, true),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit, expected_results
    );
}

#[test]
#[should_panic(expected: ('SPL',))]
fn test_swap_500_fee_1_1_price_max_range_liquidity_swap_arbitrary_amount_to_price_zero_for_one_true_price_limit_5_2() {
    let fee = 500;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = true;
    let exact_out = false;
    let sqrt_price_limit = 125270724187523965593206900784; // encode_price_sqrt(5, 2)

    let expected_results = SwapExpectedResults {
        amount0_before: 2000000000000000000,
        amount0_delta: IntegerTrait::<i256>::new(0, false),
        amount1_before: 2000000000000000000,
        amount1_delta: IntegerTrait::<i256>::new(0, false),
        execution_price: 0,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 0,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(0, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit, expected_results
    );
}

#[test]
#[should_panic(expected: ('SPL',))]
fn test_swap_500_fee_1_1_price_max_range_liquidity_swap_arbitrary_amount_to_price_zero_for_one_false_price_limit_2_5() {
    let fee = 500;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = false;
    let exact_out = false;
    let sqrt_price_limit = 50108289675009586237282760313; // encode_price_sqrt(2, 5)

    let expected_results = SwapExpectedResults {
        amount0_before: 2000000000000000000,
        amount0_delta: IntegerTrait::<i256>::new(0, false),
        amount1_before: 2000000000000000000,
        amount1_delta: IntegerTrait::<i256>::new(0, false),
        execution_price: 0,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 0,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(0, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit, expected_results
    );
}

//////
//////

#[test]
fn test_swap_10000_fee_1_1_price_max_range_liquidity_swap_large_amount_zero_for_one_true_exact_input() {
    let fee = 10000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = true;
    let exact_out = false;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 0;

    let expected_results = SwapExpectedResults {
        amount0_before: 2000000000000000000,
        amount0_delta: IntegerTrait::<i256>::new(1000000000000000000, false),
        amount1_before: 2000000000000000000,
        amount1_delta: IntegerTrait::<i256>::new(662207357859531772, true),
        execution_price: 52465472166636584715366080983,
        fee_growth_global_0_X128_delta: 1701411834604692317316873037158841057,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 52995426430946045213072876479,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(8043, true),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_10000_fee_1_1_price_max_range_liquidity_swap_large_amount_zero_for_one_false_exact_input() {
    let fee = 10000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = false;
    let exact_out = false;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 0;

    let expected_results = SwapExpectedResults {
        amount0_before: 2000000000000000000,
        amount0_delta: IntegerTrait::<i256>::new(662207357859531772, true),
        amount1_before: 2000000000000000000,
        amount1_delta: IntegerTrait::<i256>::new(1000000000000000000, false),
        execution_price: 119642528241237560409334121252,    // Uni Value 119642528241237560407598554831,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 1701411834604692317316873037158841057,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 118446102958825184702348205752,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(8042, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_10000_fee_1_1_price_max_range_liquidity_swap_large_amount_zero_for_one_true_exact_output() {
    let fee = 10000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = true;
    let exact_out = true;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 0;

    let expected_results = SwapExpectedResults {
        amount0_before: 2000000000000000000,
        amount0_delta: IntegerTrait::<i256>::new(2020202020202020203, false),
        amount1_before: 2000000000000000000,
        amount1_delta: IntegerTrait::<i256>::new(1000000000000000000, true),
        execution_price: 39217940444560847089783554300,     // Uni Value 39217940444560847089789496412
        fee_growth_global_0_X128_delta: 3437195625464025050172418213103875650,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 39614081257132168796771975168,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(13864, true),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_10000_fee_1_1_price_max_range_liquidity_swap_large_amount_zero_for_one_false_exact_output() {
    let fee = 10000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = false;
    let exact_out = true;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 0;

    let expected_results = SwapExpectedResults {
        amount0_before: 2000000000000000000,
        amount0_delta: IntegerTrait::<i256>::new(1000000000000000000, true),
        amount1_before: 2000000000000000000,
        amount1_delta: IntegerTrait::<i256>::new(2020202020202020203, false),
        execution_price: 160056893968210783094888099303,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 3437195625464025050172418213103875650,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 158456325028528675187087900672,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(13863, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_10000_fee_1_1_price_max_range_liquidity_swap_large_amount_with_price_limit_zero_for_one_true_exact_input() {
    let fee = 10000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = true;
    let exact_out = false;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 56022770974786139918731938227; // encode_price_sqrt(50, 100)

    let expected_results = SwapExpectedResults {
        amount0_before: 2000000000000000000,
        amount0_delta: IntegerTrait::<i256>::new(836795075501202120, false),
        amount1_before: 2000000000000000000,
        amount1_delta: IntegerTrait::<i256>::new(585786437626904951, true),
        execution_price: 55462543265038278420655474346,     // Uni Value 55462543265038278420760100066
        fee_growth_global_0_X128_delta: 1423733044596672457631004491657125052,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 56022770974786139918731938227,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(6932, true),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_10000_fee_1_1_price_max_range_liquidity_swap_large_amount_with_price_limit_zero_for_one_false_exact_input() {
    let fee = 10000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = false;
    let exact_out = false;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 112045541949572279837463876454; // encode_price_sqrt(200, 100)

    let expected_results = SwapExpectedResults {
        amount0_before: 2000000000000000000,
        amount0_delta: IntegerTrait::<i256>::new(585786437626904951, true),
        amount1_before: 2000000000000000000,
        amount1_delta: IntegerTrait::<i256>::new(836795075501202120, false),
        execution_price: 113177315100578060643676692876,    // Uni Value 113177315100578060647420666263
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 1423733044596672457631004491657125052,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 112045541949572279837463876454,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(6931, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_10000_fee_1_1_price_max_range_liquidity_swap_large_amount_with_price_limit_zero_for_one_true_exact_output() {
    let fee = 10000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = true;
    let exact_out = true;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 56022770974786139918731938227; // encode_price_sqrt(50, 100)

    let expected_results = SwapExpectedResults {
        amount0_before: 2000000000000000000,
        amount0_delta: IntegerTrait::<i256>::new(836795075501202120, false),
        amount1_before: 2000000000000000000,
        amount1_delta: IntegerTrait::<i256>::new(585786437626904951, true),
        execution_price: 55462543265038278420655474346,     // Uni Value 55462543265038278420760100066
        fee_growth_global_0_X128_delta: 1423733044596672457631004491657125052,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 56022770974786139918731938227,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(6932, true),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_10000_fee_1_1_price_max_range_liquidity_swap_large_amount_with_price_limit_zero_for_one_false_exact_output() {
    let fee = 10000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = false;
    let exact_out = true;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 112045541949572279837463876454; // encode_price_sqrt(200, 100)

    let expected_results = SwapExpectedResults {
        amount0_before: 2000000000000000000,
        amount0_delta: IntegerTrait::<i256>::new(585786437626904951, true),
        amount1_before: 2000000000000000000,
        amount1_delta: IntegerTrait::<i256>::new(836795075501202120, false),
        execution_price: 113177315100578060643676692876,    // Uni Value 113177315100578060647420666263
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 1423733044596672457631004491657125052,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 112045541949572279837463876454,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(6931, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_10000_fee_1_1_price_max_range_liquidity_swap_small_amount_zero_for_one_true_exact_input() {
    let fee = 10000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = true;
    let exact_out = false;
    let amount0 = 1000;
    let sqrt_price_limit = 0;

    let expected_results = SwapExpectedResults {
        amount0_before: 2000000000000000000,
        amount0_delta: IntegerTrait::<i256>::new(1000, false),
        amount1_before: 2000000000000000000,
        amount1_delta: IntegerTrait::<i256>::new(989, true),
        execution_price: 78356652726607429880014966882,
        fee_growth_global_0_X128_delta: 1701411834604692317316,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 79228162514264298375603505776,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(1, true),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_10000_fee_1_1_price_max_range_liquidity_swap_small_amount_zero_for_one_false_exact_input() {
    let fee = 10000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = false;
    let exact_out = false;
    let amount1 = 1000;
    let sqrt_price_limit = 0;

    let expected_results = SwapExpectedResults {
        amount0_before: 2000000000000000000,
        amount0_delta: IntegerTrait::<i256>::new(989, true),
        amount1_before: 2000000000000000000,
        amount1_delta: IntegerTrait::<i256>::new(1000, false),
        execution_price: 80109365535150998577900859793,     // Uni Value 80109365535150998576787339612
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 1701411834604692317316,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 79228162514264376811484394896,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(0, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_10000_fee_1_1_price_max_range_liquidity_swap_small_amount_zero_for_one_true_exact_output() {
    let fee = 10000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = true;
    let exact_out = true;
    let amount1 = 1000;
    let sqrt_price_limit = 0;

    let expected_results = SwapExpectedResults {
        amount0_before: 2000000000000000000,
        amount0_delta: IntegerTrait::<i256>::new(1012, false),
        amount1_before: 2000000000000000000,
        amount1_delta: IntegerTrait::<i256>::new(1000, true),
        execution_price: 78288698136624839519312203889,     // Uni Value 78288698136624839519700515832
        fee_growth_global_0_X128_delta: 1871553018065161549048,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 79228162514264297979462693203,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(1, true),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_10000_fee_1_1_price_max_range_liquidity_swap_small_amount_zero_for_one_false_exact_output() {
    let fee = 10000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = false;
    let exact_out = true;
    let amount0 = 1000;
    let sqrt_price_limit = 0;

    let expected_results = SwapExpectedResults {
        amount0_before: 2000000000000000000,
        amount0_delta: IntegerTrait::<i256>::new(1000, true),
        amount1_before: 2000000000000000000,
        amount1_delta: IntegerTrait::<i256>::new(1012, false),
        execution_price: 80178900464435509644666477740,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 1871553018065161549048,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 79228162514264377207625207469,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(0, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_10000_fee_1_1_price_max_range_liquidity_swap_arbitrary_amount_to_price_zero_for_one_false_price_limit_5_2() {
    let fee = 10000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = false;
    let exact_out = false;
    let sqrt_price_limit = 125270724187523965593206900784; // encode_price_sqrt(5, 2)

    let expected_results = SwapExpectedResults {
        amount0_before: 2000000000000000000,
        amount0_delta: IntegerTrait::<i256>::new(735088935932648267, true),
        amount1_before: 2000000000000000000,
        amount1_delta: IntegerTrait::<i256>::new(1174017838553918518, false),
        execution_price: 126536085037902995672590540141,    // Uni Value 126536085037902995675823286947
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 1997487844552658120479227965844634309,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 125270724187523965593206900784,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(9163, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_10000_fee_1_1_price_max_range_liquidity_swap_arbitrary_amount_to_price_zero_for_one_true_price_limit_2_5() {
    let fee = 10000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = true;
    let exact_out = false;
    let sqrt_price_limit = 50108289675009586237282760313; // encode_price_sqrt(2, 5)

    let expected_results = SwapExpectedResults {
        amount0_before: 2000000000000000000,
        amount0_delta: IntegerTrait::<i256>::new(1174017838553918518, false),
        amount1_before: 2000000000000000000,
        amount1_delta: IntegerTrait::<i256>::new(735088935932648267, true),
        execution_price: 49607206778259490326337470064,     // Uni Value 49607206778259490326122741765
        fee_growth_global_0_X128_delta: 1997487844552658120479227965844634309,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 50108289675009586237282760313,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(9164, true),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit, expected_results
    );
}

#[test]
#[should_panic(expected: ('SPL',))]
fn test_swap_10000_fee_1_1_price_max_range_liquidity_swap_arbitrary_amount_to_price_zero_for_one_true_price_limit_5_2() {
    let fee = 10000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = true;
    let exact_out = false;
    let sqrt_price_limit = 125270724187523965593206900784; // encode_price_sqrt(5, 2)

    let expected_results = SwapExpectedResults {
        amount0_before: 2000000000000000000,
        amount0_delta: IntegerTrait::<i256>::new(0, false),
        amount1_before: 2000000000000000000,
        amount1_delta: IntegerTrait::<i256>::new(0, false),
        execution_price: 0,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 0,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(0, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit, expected_results
    );
}

#[test]
#[should_panic(expected: ('SPL',))]
fn test_swap_10000_fee_1_1_price_max_range_liquidity_swap_arbitrary_amount_to_price_zero_for_one_false_price_limit_2_5() {
    let fee = 10000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = false;
    let exact_out = false;
    let sqrt_price_limit = 50108289675009586237282760313; // encode_price_sqrt(2, 5)

    let expected_results = SwapExpectedResults {
        amount0_before: 2000000000000000000,
        amount0_delta: IntegerTrait::<i256>::new(0, false),
        amount1_before: 2000000000000000000,
        amount1_delta: IntegerTrait::<i256>::new(0, false),
        execution_price: 0,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 0,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(0, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit, expected_results
    );
}

//////
//////

#[test]
fn test_swap_3000_fee_1_1_price_0_liquidity_all_liquidity_around_current_price_swap_large_amount_zero_for_one_true_exact_input() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: IntegerTrait::<i32>::new(60, true),
                liquidity: 2 * pow(10, 18)
            }
        );
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: IntegerTrait::<i32>::new(60, false),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = true;
    let exact_out = false;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 0;

    let expected_results = SwapExpectedResults {
        amount0_before: 1994009290088178439,
        amount0_delta: IntegerTrait::<i256>::new(1000000000000000000, false),
        amount1_before: 1994009290088178439,
        amount1_delta: IntegerTrait::<i256>::new(662011820624678025, true),
        execution_price: 52449980110816002175186131547,
        fee_growth_global_0_X128_delta: 510423550381407695195061911147652317,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 52765855989621530048506654453,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(8130, true),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_1_1_price_0_liquidity_all_liquidity_around_current_price_swap_large_amount_zero_for_one_false_exact_input() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: IntegerTrait::<i32>::new(60, true),
                liquidity: 2 * pow(10, 18)
            }
        );
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: IntegerTrait::<i32>::new(60, false),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = false;
    let exact_out = false;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 0;

    let expected_results = SwapExpectedResults {
        amount0_before: 1994009290088178439,
        amount0_delta: IntegerTrait::<i256>::new(662011820624678025, true),
        amount1_before: 1994009290088178439,
        amount1_delta: IntegerTrait::<i256>::new(1000000000000000000, false),
        execution_price: 119677866838547088329370556146,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 510423550381407695195061911147652317,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 118961430979558417485803434075,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(8129, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_1_1_price_0_liquidity_all_liquidity_around_current_price_swap_large_amount_zero_for_one_true_exact_output() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: IntegerTrait::<i32>::new(60, true),
                liquidity: 2 * pow(10, 18)
            }
        );
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: IntegerTrait::<i32>::new(60, false),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = true;
    let exact_out = true;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 0;

    let expected_results = SwapExpectedResults {
        amount0_before: 1994009290088178439,
        amount0_delta: IntegerTrait::<i256>::new(2024171064311638316, false),
        amount1_before: 1994009290088178439,
        amount1_delta: IntegerTrait::<i256>::new(1000000000000000000, true),
        execution_price: 39141040948141174251060330077,
        fee_growth_global_0_X128_delta: 1033184581225259164735720748018047287,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 39376764787897362354836400518,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(13984, true),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_1_1_price_0_liquidity_all_liquidity_around_current_price_swap_large_amount_zero_for_one_false_exact_output() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: IntegerTrait::<i32>::new(60, true),
                liquidity: 2 * pow(10, 18)
            }
        );
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: IntegerTrait::<i32>::new(60, false),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = false;
    let exact_out = true;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 0;

    let expected_results = SwapExpectedResults {
        amount0_before: 1994009290088178439,
        amount0_delta: IntegerTrait::<i256>::new(1000000000000000000, true),
        amount1_before: 1994009290088178439,
        amount1_delta: IntegerTrait::<i256>::new(2024171064311638316, false),
        execution_price: 160371354039953890549698721628,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 1033184581225259164735720748018047287,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 159411311955114659622028629972,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(13983, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_1_1_price_0_liquidity_all_liquidity_around_current_price_swap_large_amount_with_price_limit_zero_for_one_true_exact_input() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: IntegerTrait::<i32>::new(60, true),
                liquidity: 2 * pow(10, 18)
            }
        );
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: IntegerTrait::<i32>::new(60, false),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = true;
    let exact_out = false;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 56022770974786139918731938227; // encode_price_sqrt(50, 100)

    let expected_results = SwapExpectedResults {
        amount0_before: 1994009290088178439,
        amount0_delta: IntegerTrait::<i256>::new(824893095908431542, false),
        amount1_before: 1994009290088178439,
        amount1_delta: IntegerTrait::<i256>::new(579795727715083389, true),
        execution_price: 55687398001432650619721780490,
        fee_growth_global_0_X128_delta: 421044862698692740725170743495410672,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 56022770974786139918731938227,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(6932, true),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_1_1_price_0_liquidity_all_liquidity_around_current_price_swap_large_amount_with_price_limit_zero_for_one_false_exact_input() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: IntegerTrait::<i32>::new(60, true),
                liquidity: 2 * pow(10, 18)
            }
        );
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: IntegerTrait::<i32>::new(60, false),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = false;
    let exact_out = false;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 112045541949572279837463876454; // encode_price_sqrt(200, 100)

    let expected_results = SwapExpectedResults {
        amount0_before: 1994009290088178439,
        amount0_delta: IntegerTrait::<i256>::new(579795727715083389, true),
        amount1_before: 1994009290088178439,
        amount1_delta: IntegerTrait::<i256>::new(824893095908431542, false),
        execution_price: 112720327410973518944361814330,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 421044862698692740725170743495410672,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 112045541949572279837463876454,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(6931, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_1_1_price_0_liquidity_all_liquidity_around_current_price_swap_large_amount_with_price_limit_zero_for_one_true_exact_output() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: IntegerTrait::<i32>::new(60, true),
                liquidity: 2 * pow(10, 18)
            }
        );
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: IntegerTrait::<i32>::new(60, false),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = true;
    let exact_out = true;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 56022770974786139918731938227; // encode_price_sqrt(50, 100)

    let expected_results = SwapExpectedResults {
        amount0_before: 1994009290088178439,
        amount0_delta: IntegerTrait::<i256>::new(824893095908431542, false),
        amount1_before: 1994009290088178439,
        amount1_delta: IntegerTrait::<i256>::new(579795727715083389, true),
        execution_price: 55687398001432650619721780490,
        fee_growth_global_0_X128_delta: 421044862698692740725170743495410672,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 56022770974786139918731938227,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(6932, true),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_1_1_price_0_liquidity_all_liquidity_around_current_price_swap_large_amount_with_price_limit_zero_for_one_false_exact_output() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: IntegerTrait::<i32>::new(60, true),
                liquidity: 2 * pow(10, 18)
            }
        );
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: IntegerTrait::<i32>::new(60, false),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = false;
    let exact_out = true;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 112045541949572279837463876454; // encode_price_sqrt(200, 100)

    let expected_results = SwapExpectedResults {
        amount0_before: 1994009290088178439,
        amount0_delta: IntegerTrait::<i256>::new(579795727715083389, true),
        amount1_before: 1994009290088178439,
        amount1_delta: IntegerTrait::<i256>::new(824893095908431542, false),
        execution_price: 112720327410973518944361814330,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 421044862698692740725170743495410672,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 112045541949572279837463876454,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(6931, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_1_1_price_0_liquidity_all_liquidity_around_current_price_swap_small_amount_zero_for_one_true_exact_input() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: IntegerTrait::<i32>::new(60, true),
                liquidity: 2 * pow(10, 18)
            }
        );
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: IntegerTrait::<i32>::new(60, false),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = true;
    let exact_out = false;
    let amount0 = 1000;
    let sqrt_price_limit = 0;

    let expected_results = SwapExpectedResults {
        amount0_before: 1994009290088178439,
        amount0_delta: IntegerTrait::<i256>::new(1000, false),
        amount1_before: 1994009290088178439,
        amount1_delta: IntegerTrait::<i256>::new(991, true),
        execution_price: 78515109051635958555202054782,
        fee_growth_global_0_X128_delta: 510423550381407695195,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 78990846045029491892619524892,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(61, true),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_1_1_price_0_liquidity_all_liquidity_around_current_price_swap_small_amount_zero_for_one_false_exact_input() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: IntegerTrait::<i32>::new(60, true),
                liquidity: 2 * pow(10, 18)
            }
        );
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: IntegerTrait::<i32>::new(60, false),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = false;
    let exact_out = false;
    let amount1 = 1000;
    let sqrt_price_limit = 0;

    let expected_results = SwapExpectedResults {
        amount0_before: 1994009290088178439,
        amount0_delta: IntegerTrait::<i256>::new(991, true),
        amount1_before: 1994009290088178439,
        amount1_delta: IntegerTrait::<i256>::new(1000, false),
        execution_price: 79947691739923650447572099229,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 510423550381407695195,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 79466191966197684690660788193,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(60, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_1_1_price_0_liquidity_all_liquidity_around_current_price_swap_small_amount_zero_for_one_true_exact_output() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: IntegerTrait::<i32>::new(60, true),
                liquidity: 2 * pow(10, 18)
            }
        );
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: IntegerTrait::<i32>::new(60, false),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = true;
    let exact_out = true;
    let amount1 = 1000;
    let sqrt_price_limit = 0;

    let expected_results = SwapExpectedResults {
        amount0_before: 1994009290088178439,
        amount0_delta: IntegerTrait::<i256>::new(1011, false),
        amount1_before: 1994009290088178439,
        amount1_delta: IntegerTrait::<i256>::new(1000, true),
        execution_price: 78366135028945932337827844051,
        fee_growth_global_0_X128_delta: 680564733841876926926,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 78990846045029491537527118553,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(61, true),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_1_1_price_0_liquidity_all_liquidity_around_current_price_swap_small_amount_zero_for_one_false_exact_output() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: IntegerTrait::<i32>::new(60, true),
                liquidity: 2 * pow(10, 18)
            }
        );
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: IntegerTrait::<i32>::new(60, false),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = false;
    let exact_out = true;
    let amount0 = 1000;
    let sqrt_price_limit = 0;

    let expected_results = SwapExpectedResults {
        amount0_before: 1994009290088178439,
        amount0_delta: IntegerTrait::<i256>::new(1000, true),
        amount1_before: 1994009290088178439,
        amount1_delta: IntegerTrait::<i256>::new(1011, false),
        execution_price: 80099672301921245307072933789,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 680564733841876926926,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 79466191966197685047890046274,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(60, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_1_1_price_0_liquidity_all_liquidity_around_current_price_swap_arbitrary_amount_to_price_zero_for_one_false_price_limit_5_2() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: IntegerTrait::<i32>::new(60, true),
                liquidity: 2 * pow(10, 18)
            }
        );
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: IntegerTrait::<i32>::new(60, false),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = false;
    let exact_out = false;
    let sqrt_price_limit = 125270724187523965593206900784; // encode_price_sqrt(5, 2)

    let expected_results = SwapExpectedResults {
        amount0_before: 1994009290088178439,
        amount0_delta: IntegerTrait::<i256>::new(729098226020826705, true),
        amount1_before: 1994009290088178439,
        amount1_delta: IntegerTrait::<i256>::new(1159748196632793863, false),
        execution_price: 126025157268484831060378085550,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 591962792073745646583043420635066071,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 125270724187523965593206900784,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(9163, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_1_1_price_0_liquidity_all_liquidity_around_current_price_swap_arbitrary_amount_to_price_zero_for_one_true_price_limit_2_5() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: IntegerTrait::<i32>::new(60, true),
                liquidity: 2 * pow(10, 18)
            }
        );
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: IntegerTrait::<i32>::new(60, false),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = true;
    let exact_out = false;
    let sqrt_price_limit = 50108289675009586237282760313; // encode_price_sqrt(2, 5)

    let expected_results = SwapExpectedResults {
        amount0_before: 1994009290088178439,
        amount0_delta: IntegerTrait::<i256>::new(1159748196632793863, false),
        amount1_before: 1994009290088178439,
        amount1_delta: IntegerTrait::<i256>::new(729098226020826705, true),
        execution_price: 49808322968515735205416905375,
        fee_growth_global_0_X128_delta: 591962792073745646583043420635066071,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 50108289675009586237282760313,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(9164, true),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit, expected_results
    );
}

#[test]
#[should_panic(expected: ('SPL',))]
fn test_swap_3000_fee_1_1_price_0_liquidity_all_liquidity_around_current_price_swap_arbitrary_amount_to_price_zero_for_one_true_price_limit_5_2() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: IntegerTrait::<i32>::new(60, true),
                liquidity: 2 * pow(10, 18)
            }
        );
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: IntegerTrait::<i32>::new(60, false),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = true;
    let exact_out = false;
    let sqrt_price_limit = 125270724187523965593206900784; // encode_price_sqrt(5, 2)

    let expected_results = SwapExpectedResults {
        amount0_before: 1994009290088178439,
        amount0_delta: IntegerTrait::<i256>::new(0, false),
        amount1_before: 1994009290088178439,
        amount1_delta: IntegerTrait::<i256>::new(0, false),
        execution_price: 0,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 0,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(0, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit, expected_results
    );
}

#[test]
#[should_panic(expected: ('SPL',))]
fn test_swap_3000_fee_1_1_price_0_liquidity_all_liquidity_around_current_price_swap_arbitrary_amount_to_price_zero_for_one_false_price_limit_2_5() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: IntegerTrait::<i32>::new(60, true),
                liquidity: 2 * pow(10, 18)
            }
        );
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: IntegerTrait::<i32>::new(60, false),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = false;
    let exact_out = false;
    let sqrt_price_limit = 50108289675009586237282760313; // encode_price_sqrt(2, 5)

    let expected_results = SwapExpectedResults {
        amount0_before: 1994009290088178439,
        amount0_delta: IntegerTrait::<i256>::new(0, false),
        amount1_before: 1994009290088178439,
        amount1_delta: IntegerTrait::<i256>::new(0, false),
        execution_price: 0,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 0,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(0, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit, expected_results
    );
}

//////
//////

#[test]
fn test_swap_3000_fee_1_1_price_additional_liquidity_around_current_price_swap_large_amount_zero_for_one_true_exact_input() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: IntegerTrait::<i32>::new(60, true),
                liquidity: 2 * pow(10, 18)
            }
        );
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: IntegerTrait::<i32>::new(60, false),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = true;
    let exact_out = false;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 0;

    let expected_results = SwapExpectedResults {
        amount0_before: 3994009290088178439,
        amount0_delta: IntegerTrait::<i256>::new(1000000000000000000, false),
        amount1_before: 3994009290088178439,
        amount1_delta: IntegerTrait::<i256>::new(795933705287758544, true),
        execution_price: 63060364953119110259100305488,
        fee_growth_global_0_X128_delta: 256749882580179971840679703106063897,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 63344413041367156775711234356,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(4476, true),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_1_1_price_additional_liquidity_around_current_price_swap_large_amount_zero_for_one_false_exact_input() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: IntegerTrait::<i32>::new(60, true),
                liquidity: 2 * pow(10, 18)
            }
        );
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: IntegerTrait::<i32>::new(60, false),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = false;
    let exact_out = false;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 0;

    let expected_results = SwapExpectedResults {
        amount0_before: 3994009290088178439,
        amount0_delta: IntegerTrait::<i256>::new(795933705287758544, true),
        amount1_before: 3994009290088178439,
        amount1_delta: IntegerTrait::<i256>::new(1000000000000000000, false),
        execution_price: 99541157747077087245816192008,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 256749882580179971840679703106063897,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 99094796746911377506159333248,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(4475, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_1_1_price_additional_liquidity_around_current_price_swap_large_amount_zero_for_one_true_exact_output() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: IntegerTrait::<i32>::new(60, true),
                liquidity: 2 * pow(10, 18)
            }
        );
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: IntegerTrait::<i32>::new(60, false),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = true;
    let exact_out = true;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 0;

    let expected_results = SwapExpectedResults {
        amount0_before: 3994009290088178439,
        amount0_delta: IntegerTrait::<i256>::new(1342022152495072924, false),
        amount1_before: 3994009290088178439,
        amount1_delta: IntegerTrait::<i256>::new(1000000000000000000, true),
        execution_price: 59036404404326861098375798613,
        fee_growth_global_0_X128_delta: 344037963272993171369654596359692757,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 59302463651080849956852106891,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(5794, true),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_1_1_price_additional_liquidity_around_current_price_swap_large_amount_zero_for_one_false_exact_output() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: IntegerTrait::<i32>::new(60, true),
                liquidity: 2 * pow(10, 18)
            }
        );
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: IntegerTrait::<i32>::new(60, false),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = false;
    let exact_out = true;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 0;

    let expected_results = SwapExpectedResults {
        amount0_before: 3994009290088178439,
        amount0_delta: IntegerTrait::<i256>::new(1000000000000000000, true),
        amount1_before: 3994009290088178439,
        amount1_delta: IntegerTrait::<i256>::new(1342022152495072924, false),
        execution_price: 106325949195622475113226390857,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 344037963272993171369654596359692757,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 105848920077239893272755499996,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(5793, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_1_1_price_additional_liquidity_around_current_price_swap_large_amount_with_price_limit_zero_for_one_true_exact_input() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: IntegerTrait::<i32>::new(60, true),
                liquidity: 2 * pow(10, 18)
            }
        );
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: IntegerTrait::<i32>::new(60, false),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = true;
    let exact_out = false;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 56022770974786139918731938227; // encode_price_sqrt(50, 100)

    let expected_results = SwapExpectedResults {
        amount0_before: 3994009290088178439,
        amount0_delta: IntegerTrait::<i256>::new(1000000000000000000, false),
        amount1_before: 3994009290088178439,
        amount1_delta: IntegerTrait::<i256>::new(795933705287758544, true),
        execution_price: 63060364953119110259100305488,
        fee_growth_global_0_X128_delta: 256749882580179971840679703106063897,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 63344413041367156775711234356,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(4476, true),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_1_1_price_additional_liquidity_around_current_price_swap_large_amount_with_price_limit_zero_for_one_false_exact_input() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: IntegerTrait::<i32>::new(60, true),
                liquidity: 2 * pow(10, 18)
            }
        );
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: IntegerTrait::<i32>::new(60, false),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = false;
    let exact_out = false;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 112045541949572279837463876454; // encode_price_sqrt(200, 100)

    let expected_results = SwapExpectedResults {
        amount0_before: 3994009290088178439,
        amount0_delta: IntegerTrait::<i256>::new(795933705287758544, true),
        amount1_before: 3994009290088178439,
        amount1_delta: IntegerTrait::<i256>::new(1000000000000000000, false),
        execution_price: 99541157747077087245816192008,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 256749882580179971840679703106063897,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 99094796746911377506159333248,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(4475, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_1_1_price_additional_liquidity_around_current_price_swap_large_amount_with_price_limit_zero_for_one_true_exact_output() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: IntegerTrait::<i32>::new(60, true),
                liquidity: 2 * pow(10, 18)
            }
        );
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: IntegerTrait::<i32>::new(60, false),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = true;
    let exact_out = true;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 56022770974786139918731938227; // encode_price_sqrt(50, 100)

    let expected_results = SwapExpectedResults {
        amount0_before: 3994009290088178439,
        amount0_delta: IntegerTrait::<i256>::new(1342022152495072924, false),
        amount1_before: 3994009290088178439,
        amount1_delta: IntegerTrait::<i256>::new(1000000000000000000, true),
        execution_price: 59036404404326861098375798613,
        fee_growth_global_0_X128_delta: 344037963272993171369654596359692757,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 59302463651080849956852106891,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(5794, true),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_1_1_price_additional_liquidity_around_current_price_swap_large_amount_with_price_limit_zero_for_one_false_exact_output() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: IntegerTrait::<i32>::new(60, true),
                liquidity: 2 * pow(10, 18)
            }
        );
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: IntegerTrait::<i32>::new(60, false),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = false;
    let exact_out = true;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 112045541949572279837463876454; // encode_price_sqrt(200, 100)

    let expected_results = SwapExpectedResults {
        amount0_before: 3994009290088178439,
        amount0_delta: IntegerTrait::<i256>::new(1000000000000000000, true),
        amount1_before: 3994009290088178439,
        amount1_delta: IntegerTrait::<i256>::new(1342022152495072924, false),
        execution_price: 106325949195622475113226390857,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 344037963272993171369654596359692757,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 105848920077239893272755499996,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(5793, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_1_1_price_additional_liquidity_around_current_price_swap_small_amount_zero_for_one_true_exact_input() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: IntegerTrait::<i32>::new(60, true),
                liquidity: 2 * pow(10, 18)
            }
        );
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: IntegerTrait::<i32>::new(60, false),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = true;
    let exact_out = false;
    let amount0 = 1000;
    let sqrt_price_limit = 0;

    let expected_results = SwapExpectedResults {
        amount0_before: 3994009290088178439,
        amount0_delta: IntegerTrait::<i256>::new(1000, false),
        amount1_before: 3994009290088178439,
        amount1_delta: IntegerTrait::<i256>::new(996, true),
        execution_price: 78911249864207280243169774534,
        fee_growth_global_0_X128_delta: 510423550381407695195,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 79228162514264298098304936976,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(1, true),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_1_1_price_additional_liquidity_around_current_price_swap_small_amount_zero_for_one_false_exact_input() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: IntegerTrait::<i32>::new(60, true),
                liquidity: 2 * pow(10, 18)
            }
        );
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: IntegerTrait::<i32>::new(60, false),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = false;
    let exact_out = false;
    let amount1 = 1000;
    let sqrt_price_limit = 0;

    let expected_results = SwapExpectedResults {
        amount0_before: 3994009290088178439,
        amount0_delta: IntegerTrait::<i256>::new(996, true),
        amount1_before: 3994009290088178439,
        amount1_delta: IntegerTrait::<i256>::new(1000, false),
        execution_price: 79546347905887889150144528449,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 510423550381407695195,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 79228162514264377088782963696,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(0, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_1_1_price_additional_liquidity_around_current_price_swap_small_amount_zero_for_one_true_exact_output() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: IntegerTrait::<i32>::new(60, true),
                liquidity: 2 * pow(10, 18)
            }
        );
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: IntegerTrait::<i32>::new(60, false),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = true;
    let exact_out = true;
    let amount1 = 1000;
    let sqrt_price_limit = 0;

    let expected_results = SwapExpectedResults {
        amount0_before: 3994009290088178439,
        amount0_delta: IntegerTrait::<i256>::new(1005, false),
        amount1_before: 3994009290088178439,
        amount1_delta: IntegerTrait::<i256>::new(1000, true),
        execution_price: 78833992551506803575665622224,
        fee_growth_global_0_X128_delta: 680564733841876926926,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 79228162514264297979462693203,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(1, true),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_1_1_price_additional_liquidity_around_current_price_swap_small_amount_zero_for_one_false_exact_output() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: IntegerTrait::<i32>::new(60, true),
                liquidity: 2 * pow(10, 18)
            }
        );
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: IntegerTrait::<i32>::new(60, false),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = false;
    let exact_out = true;
    let amount0 = 1000;
    let sqrt_price_limit = 0;

    let expected_results = SwapExpectedResults {
        amount0_before: 3994009290088178439,
        amount0_delta: IntegerTrait::<i256>::new(1000, true),
        amount1_before: 3994009290088178439,
        amount1_delta: IntegerTrait::<i256>::new(1005, false),
        execution_price: 79624303326835659281511670087,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 680564733841876926926,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 79228162514264377207625207469,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(0, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_1_1_price_additional_liquidity_around_current_price_swap_arbitrary_amount_to_price_zero_for_one_false_price_limit_5_2() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: IntegerTrait::<i32>::new(60, true),
                liquidity: 2 * pow(10, 18)
            }
        );
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: IntegerTrait::<i32>::new(60, false),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = false;
    let exact_out = false;
    let sqrt_price_limit = 125270724187523965593206900784; // encode_price_sqrt(5, 2)

    let expected_results = SwapExpectedResults {
        amount0_before: 3994009290088178439,
        amount0_delta: IntegerTrait::<i256>::new(1464187161953474971, true),
        amount1_before: 3994009290088178439,
        amount1_delta: IntegerTrait::<i256>::new(2325523181756544449, false),
        execution_price: 125835639979987130627044277448,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 595039006852697724928157455230309818,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 125270724187523965593206900784,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(9163, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_1_1_price_additional_liquidity_around_current_price_swap_arbitrary_amount_to_price_zero_for_one_true_price_limit_2_5() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: IntegerTrait::<i32>::new(60, true),
                liquidity: 2 * pow(10, 18)
            }
        );
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: IntegerTrait::<i32>::new(60, false),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = true;
    let exact_out = false;
    let sqrt_price_limit = 50108289675009586237282760313; // encode_price_sqrt(2, 5)

    let expected_results = SwapExpectedResults {
        amount0_before: 3994009290088178439,
        amount0_delta: IntegerTrait::<i256>::new(2325523181756544449, false),
        amount1_before: 3994009290088178439,
        amount1_delta: IntegerTrait::<i256>::new(1464187161953474971, true),
        execution_price: 49883337791940260223200004357,
        fee_growth_global_0_X128_delta: 595039006852697724928157455230309818,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 50108289675009586237282760313,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(9164, true),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit, expected_results
    );
}

#[test]
#[should_panic(expected: ('SPL',))]
fn test_swap_3000_fee_1_1_price_additional_liquidity_around_current_price_swap_arbitrary_amount_to_price_zero_for_one_true_price_limit_5_2() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: IntegerTrait::<i32>::new(60, true),
                liquidity: 2 * pow(10, 18)
            }
        );
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: IntegerTrait::<i32>::new(60, false),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = true;
    let exact_out = false;
    let sqrt_price_limit = 125270724187523965593206900784; // encode_price_sqrt(5, 2)

    let expected_results = SwapExpectedResults {
        amount0_before: 3994009290088178439,
        amount0_delta: IntegerTrait::<i256>::new(0, false),
        amount1_before: 3994009290088178439,
        amount1_delta: IntegerTrait::<i256>::new(0, false),
        execution_price: 0,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 0,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(0, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit, expected_results
    );
}

#[test]
#[should_panic(expected: ('SPL',))]
fn test_swap_3000_fee_1_1_price_additional_liquidity_around_current_price_swap_arbitrary_amount_to_price_zero_for_one_false_price_limit_2_5() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: IntegerTrait::<i32>::new(60, true),
                liquidity: 2 * pow(10, 18)
            }
        );
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: IntegerTrait::<i32>::new(60, false),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = false;
    let exact_out = false;
    let sqrt_price_limit = 50108289675009586237282760313; // encode_price_sqrt(2, 5)

    let expected_results = SwapExpectedResults {
        amount0_before: 3994009290088178439,
        amount0_delta: IntegerTrait::<i256>::new(0, false),
        amount1_before: 3994009290088178439,
        amount1_delta: IntegerTrait::<i256>::new(0, false),
        execution_price: 0,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 0,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(0, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit, expected_results
    );
}

//////
//////

// Next 4 tests don't work because of out of steps issue, removing to cleanup. TODO later
// #[test]
// fn test_swap_500_fee_1_1_price_large_liquidity_around_current_price_stable_swap_large_amount_zero_for_one_true_exact_input() {
//     let fee = 500;
//     let price0 = 1;
//     let price1 = 1;

//     let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
//     pool_test_positions
//         .append(
//             PoolTestPosition {
//                 tick_lower: IntegerTrait::<i32>::new(10, true),
//                 tick_upper: IntegerTrait::<i32>::new(10, false),
//                 liquidity: 2 * pow(10, 18)
//             }
//         );

//     let zero_for_one = true;
//     let exact_out = false;
//     let amount0 = pow(10, 18);
//     let sqrt_price_limit = 0;

//     let expected_results = SwapExpectedResults {
//         amount0_before: 999700069986003,
//         amount0_delta: IntegerTrait::<i256>::new(1000700370186095, false),
//         amount1_before: 999700069986003,
//         amount1_delta: IntegerTrait::<i256>::new(999700069986002, true),
//         execution_price: 79148966034301727736686523337,
//         fee_growth_global_0_X128_delta: 85130172636557991529041720559172,
//         fee_growth_global_1_X128_delta: 0,
//         pool_price_before: 79228162514264337593543950336,
//         pool_price_after: 4295128740,
//         tick_before: IntegerTrait::<i32>::new(0, false),
//         tick_after: IntegerTrait::<i32>::new(887272, true),
//     };

//     execute_and_test_swap(
//         fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit, expected_results
//     );
// }

// #[test]
// fn test_swap_500_fee_1_1_price_large_liquidity_around_current_price_stable_swap_large_amount_zero_for_one_false_exact_input() {
//     let fee = 500;
//     let price0 = 1;
//     let price1 = 1;

//     let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
//     pool_test_positions
//         .append(
//             PoolTestPosition {
//                 tick_lower: IntegerTrait::<i32>::new(10, true),
//                 tick_upper: IntegerTrait::<i32>::new(10, false),
//                 liquidity: 2 * pow(10, 18)
//             }
//         );

//     let zero_for_one = false;
//     let exact_out = false;
//     let amount1 = pow(10, 18);
//     let sqrt_price_limit = 0;

//     let expected_results = SwapExpectedResults {
//         amount0_before: 999700069986003,
//         amount0_delta: IntegerTrait::<i256>::new(999700069986002, true),
//         amount1_before: 999700069986003,
//         amount1_delta: IntegerTrait::<i256>::new(1000700370186095, false),
//         execution_price: 79307438238249361462198734445,
//         fee_growth_global_0_X128_delta: 0,
//         fee_growth_global_1_X128_delta: 85130172636557991529041720559172,
//         pool_price_before: 79228162514264337593543950336,
//         pool_price_after: 1461446703485210103287273052203988822378723970341,
//         tick_before: IntegerTrait::<i32>::new(0, false),
//         tick_after: IntegerTrait::<i32>::new(887271, false),
//     };

//     execute_and_test_swap(
//         fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit, expected_results
//     );
// }

// #[test]
// fn test_swap_500_fee_1_1_price_large_liquidity_around_current_price_stable_swap_large_amount_zero_for_one_true_exact_output() {
//     let fee = 500;
//     let price0 = 1;
//     let price1 = 1;

//     let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
//     pool_test_positions
//         .append(
//             PoolTestPosition {
//                 tick_lower: IntegerTrait::<i32>::new(10, true),
//                 tick_upper: IntegerTrait::<i32>::new(10, false),
//                 liquidity: 2 * pow(10, 18)
//             }
//         );

//     let zero_for_one = true;
//     let exact_out = true;
//     let amount1 = pow(10, 18);
//     let sqrt_price_limit = 0;

//     let expected_results = SwapExpectedResults {
//         amount0_before: 999700069986003,
//         amount0_delta: IntegerTrait::<i256>::new(1000700370186095, false),
//         amount1_before: 999700069986003,
//         amount1_delta: IntegerTrait::<i256>::new(999700069986002, true),
//         execution_price: 79148966034301727736686523337,
//         fee_growth_global_0_X128_delta: 85130172636557991529041720559172,
//         fee_growth_global_1_X128_delta: 0,
//         pool_price_before: 79228162514264337593543950336,
//         pool_price_after: 4295128740,
//         tick_before: IntegerTrait::<i32>::new(0, false),
//         tick_after: IntegerTrait::<i32>::new(887272, true),
//     };

//     execute_and_test_swap(
//         fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit, expected_results
//     );
// }

// #[test]
// fn test_swap_500_fee_1_1_price_large_liquidity_around_current_price_stable_swap_large_amount_zero_for_one_false_exact_output() {
//     let fee = 500;
//     let price0 = 1;
//     let price1 = 1;

//     let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
//     pool_test_positions
//         .append(
//             PoolTestPosition {
//                 tick_lower: IntegerTrait::<i32>::new(10, true),
//                 tick_upper: IntegerTrait::<i32>::new(10, false),
//                 liquidity: 2 * pow(10, 18)
//             }
//         );

//     let zero_for_one = false;
//     let exact_out = true;
//     let amount0 = pow(10, 18);
//     let sqrt_price_limit = 0;

//     let expected_results = SwapExpectedResults {
//         amount0_before: 999700069986003,
//         amount0_delta: IntegerTrait::<i256>::new(999700069986002, true),
//         amount1_before: 999700069986003,
//         amount1_delta: IntegerTrait::<i256>::new(1000700370186095, false),
//         execution_price: 79307438238249361462198734445,
//         fee_growth_global_0_X128_delta: 0,
//         fee_growth_global_1_X128_delta: 85130172636557991529041720559172,
//         pool_price_before: 79228162514264337593543950336,
//         pool_price_after: 1461446703485210103287273052203988822378723970341,
//         tick_before: IntegerTrait::<i32>::new(0, false),
//         tick_after: IntegerTrait::<i32>::new(887271, false),
//     };

//     execute_and_test_swap(
//         fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit, expected_results
//     );
// }

#[test]
fn test_swap_500_fee_1_1_price_large_liquidity_around_current_price_stable_swap_large_amount_with_price_limit_zero_for_one_true_exact_input() {
    let fee = 500;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: IntegerTrait::<i32>::new(10, true),
                tick_upper: IntegerTrait::<i32>::new(10, false),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = true;
    let exact_out = false;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 56022770974786139918731938227; // encode_price_sqrt(50, 100)

    let expected_results = SwapExpectedResults {
        amount0_before: 999700069986003,
        amount0_delta: IntegerTrait::<i256>::new(1000700370186095, false),
        amount1_before: 999700069986003,
        amount1_delta: IntegerTrait::<i256>::new(999700069986002, true),
        execution_price: 79148966034301727736686523337,
        fee_growth_global_0_X128_delta: 85130172636557991529041720559172,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 56022770974786139918731938227,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(6932, true),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_500_fee_1_1_price_large_liquidity_around_current_price_stable_swap_large_amount_with_price_limit_zero_for_one_false_exact_input() {
    let fee = 500;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: IntegerTrait::<i32>::new(10, true),
                tick_upper: IntegerTrait::<i32>::new(10, false),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = false;
    let exact_out = false;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 112045541949572279837463876454; // encode_price_sqrt(200, 100)

    let expected_results = SwapExpectedResults {
        amount0_before: 999700069986003,
        amount0_delta: IntegerTrait::<i256>::new(999700069986002, true),
        amount1_before: 999700069986003,
        amount1_delta: IntegerTrait::<i256>::new(1000700370186095, false),
        execution_price: 79307438238249361462198734445,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 85130172636557991529041720559172,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 112045541949572279837463876454,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(6931, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_500_fee_1_1_price_large_liquidity_around_current_price_stable_swap_large_amount_with_price_limit_zero_for_one_true_exact_output() {
    let fee = 500;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: IntegerTrait::<i32>::new(10, true),
                tick_upper: IntegerTrait::<i32>::new(10, false),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = true;
    let exact_out = true;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 56022770974786139918731938227; // encode_price_sqrt(50, 100)

    let expected_results = SwapExpectedResults {
        amount0_before: 999700069986003,
        amount0_delta: IntegerTrait::<i256>::new(1000700370186095, false),
        amount1_before: 999700069986003,
        amount1_delta: IntegerTrait::<i256>::new(999700069986002, true),
        execution_price: 79148966034301727736686523337,
        fee_growth_global_0_X128_delta: 85130172636557991529041720559172,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 56022770974786139918731938227,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(6932, true),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_500_fee_1_1_price_large_liquidity_around_current_price_stable_swap_large_amount_with_price_limit_zero_for_one_false_exact_output() {
    let fee = 500;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: IntegerTrait::<i32>::new(10, true),
                tick_upper: IntegerTrait::<i32>::new(10, false),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = false;
    let exact_out = true;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 112045541949572279837463876454; // encode_price_sqrt(200, 100)

    let expected_results = SwapExpectedResults {
        amount0_before: 999700069986003,
        amount0_delta: IntegerTrait::<i256>::new(999700069986002, true),
        amount1_before: 999700069986003,
        amount1_delta: IntegerTrait::<i256>::new(1000700370186095, false),
        execution_price: 79307438238249361462198734445,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 85130172636557991529041720559172,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 112045541949572279837463876454,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(6931, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_500_fee_1_1_price_large_liquidity_around_current_price_stable_swap_small_amount_zero_for_one_true_exact_input() {
    let fee = 500;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: IntegerTrait::<i32>::new(10, true),
                tick_upper: IntegerTrait::<i32>::new(10, false),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = true;
    let exact_out = false;
    let amount0 = 1000;
    let sqrt_price_limit = 0;

    let expected_results = SwapExpectedResults {
        amount0_before: 999700069986003,
        amount0_delta: IntegerTrait::<i256>::new(1000, false),
        amount1_before: 999700069986003,
        amount1_delta: IntegerTrait::<i256>::new(998, true),
        execution_price: 79069706189235808918356862435,
        fee_growth_global_0_X128_delta: 170141183460469231731,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 79228162514264298019076774461,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(1, true),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_500_fee_1_1_price_large_liquidity_around_current_price_stable_swap_small_amount_zero_for_one_false_exact_input() {
    let fee = 500;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: IntegerTrait::<i32>::new(10, true),
                tick_upper: IntegerTrait::<i32>::new(10, false),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = false;
    let exact_out = false;
    let amount1 = 1000;
    let sqrt_price_limit = 0;

    let expected_results = SwapExpectedResults {
        amount0_before: 999700069986003,
        amount0_delta: IntegerTrait::<i256>::new(998, true),
        amount1_before: 999700069986003,
        amount1_delta: IntegerTrait::<i256>::new(1000, false),
        execution_price: 79386936387038414422388727791,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 170141183460469231731,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 79228162514264377168011126211,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(0, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_500_fee_1_1_price_large_liquidity_around_current_price_stable_swap_small_amount_zero_for_one_true_exact_output() {
    let fee = 500;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: IntegerTrait::<i32>::new(10, true),
                tick_upper: IntegerTrait::<i32>::new(10, false),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = true;
    let exact_out = true;
    let amount1 = 1000;
    let sqrt_price_limit = 0;

    let expected_results = SwapExpectedResults {
        amount0_before: 999700069986003,
        amount0_delta: IntegerTrait::<i256>::new(1002, false),
        amount1_before: 999700069986003,
        amount1_delta: IntegerTrait::<i256>::new(1000, true),
        execution_price: 79070022469325686221101746842,
        fee_growth_global_0_X128_delta: 170141183460469231731,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 79228162514264297979462693203,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(1, true),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_500_fee_1_1_price_large_liquidity_around_current_price_stable_swap_small_amount_zero_for_one_false_exact_output() {
    let fee = 500;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: IntegerTrait::<i32>::new(10, true),
                tick_upper: IntegerTrait::<i32>::new(10, false),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = false;
    let exact_out = true;
    let amount0 = 1000;
    let sqrt_price_limit = 0;

    let expected_results = SwapExpectedResults {
        amount0_before: 999700069986003,
        amount0_delta: IntegerTrait::<i256>::new(1000, true),
        amount1_before: 999700069986003,
        amount1_delta: IntegerTrait::<i256>::new(1002, false),
        execution_price: 79386618839292866268731038236,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 170141183460469231731,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 79228162514264377207625207469,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(0, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_500_fee_1_1_price_large_liquidity_around_current_price_stable_swap_arbitrary_amount_to_price_zero_for_one_false_price_limit_5_2() {
    let fee = 500;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: IntegerTrait::<i32>::new(10, true),
                tick_upper: IntegerTrait::<i32>::new(10, false),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = false;
    let exact_out = false;
    let sqrt_price_limit = 125270724187523965593206900784; // encode_price_sqrt(5, 2)

    let expected_results = SwapExpectedResults {
        amount0_before: 999700069986003,
        amount0_delta: IntegerTrait::<i256>::new(999700069986002, true),
        amount1_before: 999700069986003,
        amount1_delta: IntegerTrait::<i256>::new(1000700370186095, false),
        execution_price: 79307438238249361462198734445,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 85130172636557991529041720559172,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 125270724187523965593206900784,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(9163, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_500_fee_1_1_price_large_liquidity_around_current_price_stable_swap_arbitrary_amount_to_price_zero_for_one_true_price_limit_2_5() {
    let fee = 500;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: IntegerTrait::<i32>::new(10, true),
                tick_upper: IntegerTrait::<i32>::new(10, false),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = true;
    let exact_out = false;
    let sqrt_price_limit = 50108289675009586237282760313; // encode_price_sqrt(2, 5)

    let expected_results = SwapExpectedResults {
        amount0_before: 999700069986003,
        amount0_delta: IntegerTrait::<i256>::new(1000700370186095, false),
        amount1_before: 999700069986003,
        amount1_delta: IntegerTrait::<i256>::new(999700069986002, true),
        execution_price: 79148966034301727736686523337,
        fee_growth_global_0_X128_delta: 85130172636557991529041720559172,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 50108289675009586237282760313,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(9164, true),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit, expected_results
    );
}

#[test]
#[should_panic(expected: ('SPL',))]
fn test_swap_500_fee_1_1_price_large_liquidity_around_current_price_stable_swap_arbitrary_amount_to_price_zero_for_one_true_price_limit_5_2() {
    let fee = 500;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: IntegerTrait::<i32>::new(10, true),
                tick_upper: IntegerTrait::<i32>::new(10, false),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = true;
    let exact_out = false;
    let sqrt_price_limit = 125270724187523965593206900784; // encode_price_sqrt(5, 2)

    let expected_results = SwapExpectedResults {
        amount0_before: 999700069986003,
        amount0_delta: IntegerTrait::<i256>::new(0, false),
        amount1_before: 999700069986003,
        amount1_delta: IntegerTrait::<i256>::new(0, false),
        execution_price: 0,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 0,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(0, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit, expected_results
    );
}

#[test]
#[should_panic(expected: ('SPL',))]
fn test_swap_500_fee_1_1_price_large_liquidity_around_current_price_stable_swap_arbitrary_amount_to_price_zero_for_one_false_price_limit_2_5() {
    let fee = 500;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: IntegerTrait::<i32>::new(10, true),
                tick_upper: IntegerTrait::<i32>::new(10, false),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = false;
    let exact_out = false;
    let sqrt_price_limit = 50108289675009586237282760313; // encode_price_sqrt(2, 5)

    let expected_results = SwapExpectedResults {
        amount0_before: 999700069986003,
        amount0_delta: IntegerTrait::<i256>::new(0, false),
        amount1_before: 999700069986003,
        amount1_delta: IntegerTrait::<i256>::new(0, false),
        execution_price: 0,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 0,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(0, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit, expected_results
    );
}

//////
//////

#[test]
fn test_swap_3000_fee_1_1_price_token0_liquidity_only_swap_large_amount_zero_for_one_true_exact_input() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: IntegerTrait::<i32>::new(0, false),
                tick_upper: IntegerTrait::<i32>::new(2000 * 60, false),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = true;
    let exact_out = false;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 0;

    let expected_results = SwapExpectedResults {
        amount0_before: 1995041008271423675,
        amount0_delta: IntegerTrait::<i256>::new(0, false),
        amount1_before: 0,
        amount1_delta: IntegerTrait::<i256>::new(0, false),
        execution_price: 0,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 4295128740,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(887272, true),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_1_1_price_token0_liquidity_only_swap_large_amount_zero_for_one_false_exact_input() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: IntegerTrait::<i32>::new(0, false),
                tick_upper: IntegerTrait::<i32>::new(2000 * 60, false),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = false;
    let exact_out = false;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 0;

    let expected_results = SwapExpectedResults {
        amount0_before: 1995041008271423675,
        amount0_delta: IntegerTrait::<i256>::new(665331998665331998, true),
        amount1_before: 0,
        amount1_delta: IntegerTrait::<i256>::new(1000000000000000000, false),
        execution_price: 119080643457999107324622879745,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 510423550381407695195061911147652317,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 118723401527625109883925609578,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(8089, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_1_1_price_token0_liquidity_only_swap_large_amount_zero_for_one_true_exact_output() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: IntegerTrait::<i32>::new(0, false),
                tick_upper: IntegerTrait::<i32>::new(2000 * 60, false),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = true;
    let exact_out = true;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 0;

    let expected_results = SwapExpectedResults {
        amount0_before: 1995041008271423675,
        amount0_delta: IntegerTrait::<i256>::new(0, false),
        amount1_before: 0,
        amount1_delta: IntegerTrait::<i256>::new(0, false),
        execution_price: 0,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 4295128740,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(887272, true),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_1_1_price_token0_liquidity_only_swap_large_amount_zero_for_one_false_exact_output() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: IntegerTrait::<i32>::new(0, false),
                tick_upper: IntegerTrait::<i32>::new(2000 * 60, false),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = false;
    let exact_out = true;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 0;

    let expected_results = SwapExpectedResults {
        amount0_before: 1995041008271423675,
        amount0_delta: IntegerTrait::<i256>::new(1000000000000000000, true),
        amount1_before: 0,
        amount1_delta: IntegerTrait::<i256>::new(2006018054162487463, false),
        execution_price: 158933124401733876866094591743,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 1023918857334819954209013958517557896,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 158456325028528675187087900672,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(13863, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_1_1_price_token0_liquidity_only_swap_large_amount_with_price_limit_zero_for_one_true_exact_input() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: IntegerTrait::<i32>::new(0, false),
                tick_upper: IntegerTrait::<i32>::new(2000 * 60, false),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = true;
    let exact_out = false;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 56022770974786139918731938227; // encode_price_sqrt(50, 100)

    let expected_results = SwapExpectedResults {
        amount0_before: 1995041008271423675,
        amount0_delta: IntegerTrait::<i256>::new(0, false),
        amount1_before: 0,
        amount1_delta: IntegerTrait::<i256>::new(0, false),
        execution_price: 0,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 56022770974786139918731938227,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(6932, true),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_1_1_price_token0_liquidity_only_swap_large_amount_with_price_limit_zero_for_one_false_exact_input() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: IntegerTrait::<i32>::new(0, false),
                tick_upper: IntegerTrait::<i32>::new(2000 * 60, false),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = false;
    let exact_out = false;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 112045541949572279837463876454; // encode_price_sqrt(200, 100)

    let expected_results = SwapExpectedResults {
        amount0_before: 1995041008271423675,
        amount0_delta: IntegerTrait::<i256>::new(585786437626904951, true),
        amount1_before: 0,
        amount1_delta: IntegerTrait::<i256>::new(830919884399388263, false),
        execution_price: 112382690019631173478011159601,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 424121077477644648929101317621422688,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 112045541949572279837463876454,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(6931, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_1_1_price_token0_liquidity_only_swap_large_amount_with_price_limit_zero_for_one_true_exact_output() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: IntegerTrait::<i32>::new(0, false),
                tick_upper: IntegerTrait::<i32>::new(2000 * 60, false),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = true;
    let exact_out = true;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 56022770974786139918731938227; // encode_price_sqrt(50, 100)

    let expected_results = SwapExpectedResults {
        amount0_before: 1995041008271423675,
        amount0_delta: IntegerTrait::<i256>::new(0, false),
        amount1_before: 0,
        amount1_delta: IntegerTrait::<i256>::new(0, false),
        execution_price: 0,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 56022770974786139918731938227,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(6932, true),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_1_1_price_token0_liquidity_only_swap_large_amount_with_price_limit_zero_for_one_false_exact_output() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: IntegerTrait::<i32>::new(0, false),
                tick_upper: IntegerTrait::<i32>::new(2000 * 60, false),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = false;
    let exact_out = true;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 112045541949572279837463876454; // encode_price_sqrt(200, 100)

    let expected_results = SwapExpectedResults {
        amount0_before: 1995041008271423675,
        amount0_delta: IntegerTrait::<i256>::new(585786437626904951, true),
        amount1_before: 0,
        amount1_delta: IntegerTrait::<i256>::new(830919884399388263, false),
        execution_price: 112382690019631173478011159601,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 424121077477644648929101317621422688,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 112045541949572279837463876454,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(6931, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_1_1_price_token0_liquidity_only_swap_small_amount_zero_for_one_true_exact_input() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: IntegerTrait::<i32>::new(0, false),
                tick_upper: IntegerTrait::<i32>::new(2000 * 60, false),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = true;
    let exact_out = false;
    let amount0 = 1000;
    let sqrt_price_limit = 0;

    let expected_results = SwapExpectedResults {
        amount0_before: 1995041008271423675,
        amount0_delta: IntegerTrait::<i256>::new(0, false),
        amount1_before: 0,
        amount1_delta: IntegerTrait::<i256>::new(0, false),
        execution_price: 0,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 4295128740,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(887272, true),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_1_1_price_token0_liquidity_only_swap_small_amount_zero_for_one_false_exact_input() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: IntegerTrait::<i32>::new(0, false),
                tick_upper: IntegerTrait::<i32>::new(2000 * 60, false),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = false;
    let exact_out = false;
    let amount1 = 1000;
    let sqrt_price_limit = 0;

    let expected_results = SwapExpectedResults {
        amount0_before: 1995041008271423675,
        amount0_delta: IntegerTrait::<i256>::new(996, true),
        amount1_before: 0,
        amount1_delta: IntegerTrait::<i256>::new(1000, false),
        execution_price: 79546347905887889150144528449,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 510423550381407695195,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 79228162514264377088782963696,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(0, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_1_1_price_token0_liquidity_only_swap_small_amount_zero_for_one_true_exact_output() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: IntegerTrait::<i32>::new(0, false),
                tick_upper: IntegerTrait::<i32>::new(2000 * 60, false),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = true;
    let exact_out = true;
    let amount1 = 1000;
    let sqrt_price_limit = 0;

    let expected_results = SwapExpectedResults {
        amount0_before: 1995041008271423675,
        amount0_delta: IntegerTrait::<i256>::new(0, false),
        amount1_before: 0,
        amount1_delta: IntegerTrait::<i256>::new(0, false),
        execution_price: 0,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 4295128740,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(887272, true),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_1_1_price_token0_liquidity_only_swap_small_amount_zero_for_one_false_exact_output() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: IntegerTrait::<i32>::new(0, false),
                tick_upper: IntegerTrait::<i32>::new(2000 * 60, false),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = false;
    let exact_out = true;
    let amount0 = 1000;
    let sqrt_price_limit = 0;

    let expected_results = SwapExpectedResults {
        amount0_before: 1995041008271423675,
        amount0_delta: IntegerTrait::<i256>::new(1000, true),
        amount1_before: 0,
        amount1_delta: IntegerTrait::<i256>::new(1005, false),
        execution_price: 79624303326835659281511670087,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 680564733841876926926,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 79228162514264377207625207469,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(0, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_1_1_price_token0_liquidity_only_swap_arbitrary_amount_to_price_zero_for_one_false_price_limit_5_2() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: IntegerTrait::<i32>::new(0, false),
                tick_upper: IntegerTrait::<i32>::new(2000 * 60, false),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = false;
    let exact_out = false;
    let sqrt_price_limit = 125270724187523965593206900784; // encode_price_sqrt(5, 2)

    let expected_results = SwapExpectedResults {
        amount0_before: 1995041008271423675,
        amount0_delta: IntegerTrait::<i256>::new(735088935932648267, true),
        amount1_before: 0,
        amount1_delta: IntegerTrait::<i256>::new(1165774985123750584, false),
        execution_price: 125647667189091239372331252954,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 595039006852697554786973994761078087,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 125270724187523965593206900784,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(9163, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_1_1_price_token0_liquidity_only_swap_arbitrary_amount_to_price_zero_for_one_true_price_limit_2_5() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: IntegerTrait::<i32>::new(0, false),
                tick_upper: IntegerTrait::<i32>::new(2000 * 60, false),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = true;
    let exact_out = false;
    let sqrt_price_limit = 50108289675009586237282760313; // encode_price_sqrt(2, 5)

    let expected_results = SwapExpectedResults {
        amount0_before: 1995041008271423675,
        amount0_delta: IntegerTrait::<i256>::new(0, false),
        amount1_before: 0,
        amount1_delta: IntegerTrait::<i256>::new(0, false),
        execution_price: 0,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 50108289675009586237282760313,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(9164, true),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit, expected_results
    );
}

#[test]
#[should_panic(expected: ('SPL',))]
fn test_swap_3000_fee_1_1_price_token0_liquidity_only_swap_arbitrary_amount_to_price_zero_for_one_true_price_limit_5_2() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: IntegerTrait::<i32>::new(0, false),
                tick_upper: IntegerTrait::<i32>::new(2000 * 60, false),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = true;
    let exact_out = false;
    let sqrt_price_limit = 125270724187523965593206900784; // encode_price_sqrt(5, 2)

    let expected_results = SwapExpectedResults {
        amount0_before: 1995041008271423675,
        amount0_delta: IntegerTrait::<i256>::new(0, false),
        amount1_before: 0,
        amount1_delta: IntegerTrait::<i256>::new(0, false),
        execution_price: 0,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 0,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(0, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit, expected_results
    );
}

#[test]
#[should_panic(expected: ('SPL',))]
fn test_swap_3000_fee_1_1_price_token0_liquidity_only_swap_arbitrary_amount_to_price_zero_for_one_false_price_limit_2_5() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: IntegerTrait::<i32>::new(0, false),
                tick_upper: IntegerTrait::<i32>::new(2000 * 60, false),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = false;
    let exact_out = false;
    let sqrt_price_limit = 50108289675009586237282760313; // encode_price_sqrt(2, 5)

    let expected_results = SwapExpectedResults {
        amount0_before: 1995041008271423675,
        amount0_delta: IntegerTrait::<i256>::new(0, false),
        amount1_before: 0,
        amount1_delta: IntegerTrait::<i256>::new(0, false),
        execution_price: 0,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 0,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(0, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit, expected_results
    );
}

//////
//////

#[test]
fn test_swap_3000_fee_1_1_price_token1_liquidity_only_swap_large_amount_zero_for_one_true_exact_input() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: IntegerTrait::<i32>::new(2000 * 60, true),
                tick_upper: IntegerTrait::<i32>::new(0, false),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = true;
    let exact_out = false;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 0;

    let expected_results = SwapExpectedResults {
        amount0_before: 0,
        amount0_delta: IntegerTrait::<i256>::new(1000000000000000000, false),
        amount1_before: 1995041008271423675,
        amount1_delta: IntegerTrait::<i256>::new(665331998665331998, true),
        execution_price: 52713031716197226894743303609,
        fee_growth_global_0_X128_delta: 510423550381407695195061911147652317,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 52871646656165724119815782674,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(8090, true),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_1_1_price_token1_liquidity_only_swap_large_amount_zero_for_one_false_exact_input() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: IntegerTrait::<i32>::new(2000 * 60, true),
                tick_upper: IntegerTrait::<i32>::new(0, false),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = false;
    let exact_out = false;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 0;

    let expected_results = SwapExpectedResults {
        amount0_before: 0,
        amount0_delta: IntegerTrait::<i256>::new(0, false),
        amount1_before: 1995041008271423675,
        amount1_delta: IntegerTrait::<i256>::new(0, false),
        execution_price: 0,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 1461446703485210103287273052203988822378723970341,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(887271, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_1_1_price_token1_liquidity_only_swap_large_amount_zero_for_one_true_exact_output() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: IntegerTrait::<i32>::new(2000 * 60, true),
                tick_upper: IntegerTrait::<i32>::new(0, false),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = true;
    let exact_out = true;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 0;

    let expected_results = SwapExpectedResults {
        amount0_before: 0,
        amount0_delta: IntegerTrait::<i256>::new(2006018054162487463, false),
        amount1_before: 1995041008271423675,
        amount1_delta: IntegerTrait::<i256>::new(1000000000000000000, true),
        execution_price: 39495239013360772278315863723,
        fee_growth_global_0_X128_delta: 1023918857334819954209013958517557896,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 39614081257132168796771975168,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(13864, true),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_1_1_price_token1_liquidity_only_swap_large_amount_zero_for_one_false_exact_output() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: IntegerTrait::<i32>::new(2000 * 60, true),
                tick_upper: IntegerTrait::<i32>::new(0, false),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = false;
    let exact_out = true;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 0;

    let expected_results = SwapExpectedResults {
        amount0_before: 0,
        amount0_delta: IntegerTrait::<i256>::new(0, false),
        amount1_before: 1995041008271423675,
        amount1_delta: IntegerTrait::<i256>::new(0, false),
        execution_price: 0,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 1461446703485210103287273052203988822378723970341,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(887271, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_1_1_price_token1_liquidity_only_swap_large_amount_with_price_limit_zero_for_one_true_exact_input() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: IntegerTrait::<i32>::new(2000 * 60, true),
                tick_upper: IntegerTrait::<i32>::new(0, false),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = true;
    let exact_out = false;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 56022770974786139918731938227; // encode_price_sqrt(50, 100)

    let expected_results = SwapExpectedResults {
        amount0_before: 0,
        amount0_delta: IntegerTrait::<i256>::new(830919884399388263, false),
        amount1_before: 1995041008271423675,
        amount1_delta: IntegerTrait::<i256>::new(585786437626904951, true),
        execution_price: 55854702661861781439099287453,
        fee_growth_global_0_X128_delta: 424121077477644648929101317621422688,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 56022770974786139918731938227,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(6932, true),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_1_1_price_token1_liquidity_only_swap_large_amount_with_price_limit_zero_for_one_false_exact_input() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: IntegerTrait::<i32>::new(2000 * 60, true),
                tick_upper: IntegerTrait::<i32>::new(0, false),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = false;
    let exact_out = false;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 112045541949572279837463876454; // encode_price_sqrt(200, 100)

    let expected_results = SwapExpectedResults {
        amount0_before: 0,
        amount0_delta: IntegerTrait::<i256>::new(0, false),
        amount1_before: 1995041008271423675,
        amount1_delta: IntegerTrait::<i256>::new(0, false),
        execution_price: 0,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 112045541949572279837463876454,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(6931, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_1_1_price_token1_liquidity_only_swap_large_amount_with_price_limit_zero_for_one_true_exact_output() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: IntegerTrait::<i32>::new(2000 * 60, true),
                tick_upper: IntegerTrait::<i32>::new(0, false),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = true;
    let exact_out = true;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 56022770974786139918731938227; // encode_price_sqrt(50, 100)

    let expected_results = SwapExpectedResults {
        amount0_before: 0,
        amount0_delta: IntegerTrait::<i256>::new(830919884399388263, false),
        amount1_before: 1995041008271423675,
        amount1_delta: IntegerTrait::<i256>::new(585786437626904951, true),
        execution_price: 55854702661861781439099287453,
        fee_growth_global_0_X128_delta: 424121077477644648929101317621422688,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 56022770974786139918731938227,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(6932, true),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_1_1_price_token1_liquidity_only_swap_large_amount_with_price_limit_zero_for_one_false_exact_output() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: IntegerTrait::<i32>::new(2000 * 60, true),
                tick_upper: IntegerTrait::<i32>::new(0, false),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = false;
    let exact_out = true;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 112045541949572279837463876454; // encode_price_sqrt(200, 100)

    let expected_results = SwapExpectedResults {
        amount0_before: 0,
        amount0_delta: IntegerTrait::<i256>::new(0, false),
        amount1_before: 1995041008271423675,
        amount1_delta: IntegerTrait::<i256>::new(0, false),
        execution_price: 0,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 112045541949572279837463876454,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(6931, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_1_1_price_token1_liquidity_only_swap_small_amount_zero_for_one_true_exact_input() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: IntegerTrait::<i32>::new(2000 * 60, true),
                tick_upper: IntegerTrait::<i32>::new(0, false),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = true;
    let exact_out = false;
    let amount0 = 1000;
    let sqrt_price_limit = 0;

    let expected_results = SwapExpectedResults {
        amount0_before: 0,
        amount0_delta: IntegerTrait::<i256>::new(1000, false),
        amount1_before: 1995041008271423675,
        amount1_delta: IntegerTrait::<i256>::new(996, true),
        execution_price: 78911249864207280243169774534,
        fee_growth_global_0_X128_delta: 510423550381407695195,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 79228162514264298098304936976,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(1, true),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_1_1_price_token1_liquidity_only_swap_small_amount_zero_for_one_false_exact_input() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: IntegerTrait::<i32>::new(2000 * 60, true),
                tick_upper: IntegerTrait::<i32>::new(0, false),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = false;
    let exact_out = false;
    let amount1 = 1000;
    let sqrt_price_limit = 0;

    let expected_results = SwapExpectedResults {
        amount0_before: 0,
        amount0_delta: IntegerTrait::<i256>::new(0, false),
        amount1_before: 1995041008271423675,
        amount1_delta: IntegerTrait::<i256>::new(0, false),
        execution_price: 0,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 1461446703485210103287273052203988822378723970341,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(887271, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_1_1_price_token1_liquidity_only_swap_small_amount_zero_for_one_true_exact_output() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: IntegerTrait::<i32>::new(2000 * 60, true),
                tick_upper: IntegerTrait::<i32>::new(0, false),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = true;
    let exact_out = true;
    let amount1 = 1000;
    let sqrt_price_limit = 0;

    let expected_results = SwapExpectedResults {
        amount0_before: 0,
        amount0_delta: IntegerTrait::<i256>::new(1005, false),
        amount1_before: 1995041008271423675,
        amount1_delta: IntegerTrait::<i256>::new(1000, true),
        execution_price: 78833992551506803575665622224,
        fee_growth_global_0_X128_delta: 680564733841876926926,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 79228162514264297979462693203,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(1, true),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_1_1_price_token1_liquidity_only_swap_small_amount_zero_for_one_false_exact_output() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: IntegerTrait::<i32>::new(2000 * 60, true),
                tick_upper: IntegerTrait::<i32>::new(0, false),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = false;
    let exact_out = true;
    let amount0 = 1000;
    let sqrt_price_limit = 0;

    let expected_results = SwapExpectedResults {
        amount0_before: 0,
        amount0_delta: IntegerTrait::<i256>::new(0, false),
        amount1_before: 1995041008271423675,
        amount1_delta: IntegerTrait::<i256>::new(0, false),
        execution_price: 0,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 1461446703485210103287273052203988822378723970341,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(887271, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_1_1_price_token1_liquidity_only_swap_arbitrary_amount_to_price_zero_for_one_false_price_limit_5_2() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: IntegerTrait::<i32>::new(2000 * 60, true),
                tick_upper: IntegerTrait::<i32>::new(0, false),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = false;
    let exact_out = false;
    let sqrt_price_limit = 125270724187523965593206900784; // encode_price_sqrt(5, 2)

    let expected_results = SwapExpectedResults {
        amount0_before: 0,
        amount0_delta: IntegerTrait::<i256>::new(0, false),
        amount1_before: 1995041008271423675,
        amount1_delta: IntegerTrait::<i256>::new(0, false),
        execution_price: 0,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 125270724187523965593206900784,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(9163, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_1_1_price_token1_liquidity_only_swap_arbitrary_amount_to_price_zero_for_one_true_price_limit_2_5() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: IntegerTrait::<i32>::new(2000 * 60, true),
                tick_upper: IntegerTrait::<i32>::new(0, false),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = true;
    let exact_out = false;
    let sqrt_price_limit = 50108289675009586237282760313; // encode_price_sqrt(2, 5)

    let expected_results = SwapExpectedResults {
        amount0_before: 0,
        amount0_delta: IntegerTrait::<i256>::new(1165774985123750584, false),
        amount1_before: 1995041008271423675,
        amount1_delta: IntegerTrait::<i256>::new(735088935932648267, true),
        execution_price: 49957964805984557454241177498,
        fee_growth_global_0_X128_delta: 595039006852697554786973994761078087,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 50108289675009586237282760313,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(9164, true),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit, expected_results
    );
}

#[test]
#[should_panic(expected: ('SPL',))]
fn test_swap_3000_fee_1_1_price_token1_liquidity_only_swap_arbitrary_amount_to_price_zero_for_one_true_price_limit_5_2() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: IntegerTrait::<i32>::new(2000 * 60, true),
                tick_upper: IntegerTrait::<i32>::new(0, false),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = true;
    let exact_out = false;
    let sqrt_price_limit = 125270724187523965593206900784; // encode_price_sqrt(5, 2)

    let expected_results = SwapExpectedResults {
        amount0_before: 0,
        amount0_delta: IntegerTrait::<i256>::new(0, false),
        amount1_before: 1995041008271423675,
        amount1_delta: IntegerTrait::<i256>::new(0, false),
        execution_price: 0,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 0,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(0, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit, expected_results
    );
}

#[test]
#[should_panic(expected: ('SPL',))]
fn test_swap_3000_fee_1_1_price_token1_liquidity_only_swap_arbitrary_amount_to_price_zero_for_one_false_price_limit_2_5() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: IntegerTrait::<i32>::new(2000 * 60, true),
                tick_upper: IntegerTrait::<i32>::new(0, false),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = false;
    let exact_out = false;
    let sqrt_price_limit = 50108289675009586237282760313; // encode_price_sqrt(2, 5)

    let expected_results = SwapExpectedResults {
        amount0_before: 0,
        amount0_delta: IntegerTrait::<i256>::new(0, false),
        amount1_before: 1995041008271423675,
        amount1_delta: IntegerTrait::<i256>::new(0, false),
        execution_price: 0,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 0,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(0, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit, expected_results
    );
}

//////
//////

#[test]
fn test_swap_3000_fee_max_1_price_swap_large_amount_zero_for_one_true_exact_input() {
    let fee = 3000;
    let price0 = pow(2, 127);
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = true;
    let exact_out = false;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 0;

    let expected_results = SwapExpectedResults {
        amount0_before: 1,
        amount0_delta: IntegerTrait::<i256>::new(1000000000000000000, false),
        amount1_before: 26087635650665564424699143612505016738,
        amount1_delta: IntegerTrait::<i256>::new(26087635650665564420687107504180041533, true),
        execution_price: 2066875436943847413014882719210341246685843281057,
        fee_growth_global_0_X128_delta: 510423550381413479995299567101531162,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 1033437718471923706666374484006904511252097097914,
        pool_price_after: 158933124401733886835376621103,
        tick_before: IntegerTrait::<i32>::new(880340, false),
        tick_after: IntegerTrait::<i32>::new(13923, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_max_1_price_swap_large_amount_zero_for_one_false_exact_input() {
    let fee = 3000;
    let price0 = pow(2, 127);
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = false;
    let exact_out = false;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 0;

    let expected_results = SwapExpectedResults {
        amount0_before: 1,
        amount0_delta: IntegerTrait::<i256>::new(0, false),
        amount1_before: 26087635650665564424699143612505016738,
        amount1_delta: IntegerTrait::<i256>::new(1000000000000000000, false),
        execution_price: '-Infinity'.into(),
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 510423550381407695195061911147652317,
        pool_price_before: 1033437718471923706666374484006904511252097097914,
        pool_price_after: 1033437718471923706705869723020265283542478757156,
        tick_before: IntegerTrait::<i32>::new(880340, false),
        tick_after: IntegerTrait::<i32>::new(880340, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_max_1_price_swap_large_amount_zero_for_one_true_exact_output() {
    let fee = 3000;
    let price0 = pow(2, 127);
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = true;
    let exact_out = true;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 0;

    let expected_results = SwapExpectedResults {
        amount0_before: 1,
        amount0_delta: IntegerTrait::<i256>::new(2, false),
        amount1_before: 26087635650665564424699143612505016738,
        amount1_delta: IntegerTrait::<i256>::new(1000000000000000000, true),
        execution_price: 39614081257132168796771975168000000000000000000,
        fee_growth_global_0_X128_delta: 170141183460469231731,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 1033437718471923706666374484006904511252097097914,
        pool_price_after: 1033437718471923706626760402749772342455325122746,
        tick_before: IntegerTrait::<i32>::new(880340, false),
        tick_after: IntegerTrait::<i32>::new(880340, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_max_1_price_swap_large_amount_zero_for_one_false_exact_output() {
    let fee = 3000;
    let price0 = pow(2, 127);
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = false;
    let exact_out = true;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 0;

    let expected_results = SwapExpectedResults {
        amount0_before: 1,
        amount0_delta: IntegerTrait::<i256>::new(0, false),
        amount1_before: 26087635650665564424699143612505016738,
        amount1_delta: IntegerTrait::<i256>::new(
            10740898373457544742072477595619363803, false
        ),
        execution_price: '-Infinity'.into(),
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 5482407482066087054477299856254072312542046383926535301,
        pool_price_before: 1033437718471923706666374484006904511252097097914,
        pool_price_after: 1461446703485210103287273052203988822378723970341,
        tick_before: IntegerTrait::<i32>::new(880340, false),
        tick_after: IntegerTrait::<i32>::new(887271, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_max_1_price_swap_large_amount_with_price_limit_zero_for_one_true_exact_input() {
    let fee = 3000;
    let price0 = pow(2, 127);
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = true;
    let exact_out = false;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 56022770974786139918731938227; // encode_price_sqrt(50, 100)

    let expected_results = SwapExpectedResults {
        amount0_before: 1,
        amount0_delta: IntegerTrait::<i256>::new(1000000000000000000, false),
        amount1_before: 26087635650665564424699143612505016738,
        amount1_delta: IntegerTrait::<i256>::new(26087635650665564420687107504180041533, true),
        execution_price: 2066875436943847413014882719210341246685843281057,
        fee_growth_global_0_X128_delta: 510423550381413479995299567101531162,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 1033437718471923706666374484006904511252097097914,
        pool_price_after: 158933124401733886835376621103,
        tick_before: IntegerTrait::<i32>::new(880340, false),
        tick_after: IntegerTrait::<i32>::new(13923, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit, expected_results
    );
}

#[test]
#[should_panic(expected: ('SPL',))]
fn test_swap_3000_fee_max_1_price_swap_large_amount_with_price_limit_zero_for_one_false_exact_input() {
    let fee = 3000;
    let price0 = pow(2, 127);
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = false;
    let exact_out = false;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 112045541949572279837463876454; // encode_price_sqrt(200, 100)

    let expected_results = SwapExpectedResults {
        amount0_before: 1,
        amount0_delta: IntegerTrait::<i256>::new(0, false),
        amount1_before: 26087635650665564424699143612505016738,
        amount1_delta: IntegerTrait::<i256>::new(0, false),
        execution_price: 0,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 1033437718471923706666374484006904511252097097914,
        pool_price_after: 0,
        tick_before: IntegerTrait::<i32>::new(880340, false),
        tick_after: IntegerTrait::<i32>::new(0, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_max_1_price_swap_large_amount_with_price_limit_zero_for_one_true_exact_output() {
    let fee = 3000;
    let price0 = pow(2, 127);
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = true;
    let exact_out = true;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 56022770974786139918731938227; // encode_price_sqrt(50, 100)

    let expected_results = SwapExpectedResults {
        amount0_before: 1,
        amount0_delta: IntegerTrait::<i256>::new(2, false),
        amount1_before: 26087635650665564424699143612505016738,
        amount1_delta: IntegerTrait::<i256>::new(1000000000000000000, true),
        execution_price: 39614081257132168796771975168000000000000000000,
        fee_growth_global_0_X128_delta: 170141183460469231731,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 1033437718471923706666374484006904511252097097914,
        pool_price_after: 1033437718471923706626760402749772342455325122746,
        tick_before: IntegerTrait::<i32>::new(880340, false),
        tick_after: IntegerTrait::<i32>::new(880340, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit, expected_results
    );
}

#[test]
#[should_panic(expected: ('SPL',))]
fn test_swap_3000_fee_max_1_price_swap_large_amount_with_price_limit_zero_for_one_false_exact_output() {
    let fee = 3000;
    let price0 = pow(2, 127);
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = false;
    let exact_out = true;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 112045541949572279837463876454; // encode_price_sqrt(200, 100)

    let expected_results = SwapExpectedResults {
        amount0_before: 1,
        amount0_delta: IntegerTrait::<i256>::new(0, false),
        amount1_before: 26087635650665564424699143612505016738,
        amount1_delta: IntegerTrait::<i256>::new(0, false),
        execution_price: 0,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 1033437718471923706666374484006904511252097097914,
        pool_price_after: 0,
        tick_before: IntegerTrait::<i32>::new(880340, false),
        tick_after: IntegerTrait::<i32>::new(0, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_max_1_price_swap_small_amount_zero_for_one_true_exact_input() {
    let fee = 3000;
    let price0 = pow(2, 127);
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = true;
    let exact_out = false;
    let amount0 = 1000;
    let sqrt_price_limit = 0;

    let expected_results = SwapExpectedResults {
        amount0_before: 1,
        amount0_delta: IntegerTrait::<i256>::new(1000, false),
        amount1_before: 26087635650665564424699143612505016738,
        amount1_delta: IntegerTrait::<i256>::new(26083549850867114346332688477747755628, true),
        execution_price: 2066551726533415062048129000300151723583406890841111943601096491,
        fee_growth_global_0_X128_delta: 2381976568446569244235,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 1033437718471923706666374484006904511252097097914,
        pool_price_after: 161855205216175642309983856828649147738467364,
        tick_before: IntegerTrait::<i32>::new(880340, false),
        tick_after: IntegerTrait::<i32>::new(705098, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_max_1_price_swap_small_amount_zero_for_one_false_exact_input() {
    let fee = 3000;
    let price0 = pow(2, 127);
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = false;
    let exact_out = false;
    let amount1 = 1000;
    let sqrt_price_limit = 0;

    let expected_results = SwapExpectedResults {
        amount0_before: 1,
        amount0_delta: IntegerTrait::<i256>::new(0, false),
        amount1_before: 26087635650665564424699143612505016738,
        amount1_delta: IntegerTrait::<i256>::new(1000, false),
        execution_price: '-Infinity'.into(),
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 510423550381407695195,
        pool_price_before: 1033437718471923706666374484006904511252097097914,
        pool_price_after: 1033437718471923706666374484006904550747336111274,
        tick_before: IntegerTrait::<i32>::new(880340, false),
        tick_after: IntegerTrait::<i32>::new(880340, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_max_1_price_swap_small_amount_zero_for_one_true_exact_output() {
    let fee = 3000;
    let price0 = pow(2, 127);
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = true;
    let exact_out = true;
    let amount1 = 1000;
    let sqrt_price_limit = 0;

    let expected_results = SwapExpectedResults {
        amount0_before: 1,
        amount0_delta: IntegerTrait::<i256>::new(2, false),
        amount1_before: 26087635650665564424699143612505016738,
        amount1_delta: IntegerTrait::<i256>::new(1000, true),
        execution_price: 39614081257132168796771975168000,
        fee_growth_global_0_X128_delta: 170141183460469231731,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 1033437718471923706666374484006904511252097097914,
        pool_price_after: 1033437718471923706666374484006904471638015840781,
        tick_before: IntegerTrait::<i32>::new(880340, false),
        tick_after: IntegerTrait::<i32>::new(880340, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_max_1_price_swap_small_amount_zero_for_one_false_exact_output() {
    let fee = 3000;
    let price0 = pow(2, 127);
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = false;
    let exact_out = true;
    let amount0 = 1000;
    let sqrt_price_limit = 0;

    let expected_results = SwapExpectedResults {
        amount0_before: 1,
        amount0_delta: IntegerTrait::<i256>::new(0, false),
        amount1_before: 26087635650665564424699143612505016738,
        amount1_delta: IntegerTrait::<i256>::new(
            10740898373457544742072477595619363803, false
        ),
        execution_price: '-Infinity'.into(),
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 5482407482066087054477299856254072312542046383926535301,
        pool_price_before: 1033437718471923706666374484006904511252097097914,
        pool_price_after: 1461446703485210103287273052203988822378723970341,
        tick_before: IntegerTrait::<i32>::new(880340, false),
        tick_after: IntegerTrait::<i32>::new(887271, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit, expected_results
    );
}

#[test]
#[should_panic(expected: ('SPL',))]
fn test_swap_3000_fee_max_1_price_swap_arbitrary_amount_to_price_zero_for_one_false_price_limit_5_2() {
    let fee = 3000;
    let price0 = pow(2, 127);
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = false;
    let exact_out = false;
    let sqrt_price_limit = 125270724187523965593206900784; // encode_price_sqrt(5, 2)

    let expected_results = SwapExpectedResults {
        amount0_before: 1,
        amount0_delta: IntegerTrait::<i256>::new(0, false),
        amount1_before: 26087635650665564424699143612505016738,
        amount1_delta: IntegerTrait::<i256>::new(0, false),
        execution_price: 0,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 1033437718471923706666374484006904511252097097914,
        pool_price_after: 0,
        tick_before: IntegerTrait::<i32>::new(880340, false),
        tick_after: IntegerTrait::<i32>::new(0, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_max_1_price_swap_arbitrary_amount_to_price_zero_for_one_true_price_limit_2_5() {
    let fee = 3000;
    let price0 = pow(2, 127);
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = true;
    let exact_out = false;
    let sqrt_price_limit = 50108289675009586237282760313; // encode_price_sqrt(2, 5)

    let expected_results = SwapExpectedResults {
        amount0_before: 1,
        amount0_delta: IntegerTrait::<i256>::new(3171793039286238109, false),
        amount1_before: 26087635650665564424699143612505016738,
        amount1_delta: IntegerTrait::<i256>::new(26087635650665564423434232548437664977, true),
        execution_price: 651642591853649146619646469369125347958464377893,
        fee_growth_global_0_X128_delta: 1618957864187523123655042148763283097,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 1033437718471923706666374484006904511252097097914,
        pool_price_after: 50108289675009586237282760313,
        tick_before: IntegerTrait::<i32>::new(880340, false),
        tick_after: IntegerTrait::<i32>::new(9164, true),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_max_1_price_swap_arbitrary_amount_to_price_zero_for_one_true_price_limit_5_2() {
    let fee = 3000;
    let price0 = pow(2, 127);
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = true;
    let exact_out = false;
    let sqrt_price_limit = 125270724187523965593206900784; // encode_price_sqrt(5, 2)

    let expected_results = SwapExpectedResults {
        amount0_before: 1,
        amount0_delta: IntegerTrait::<i256>::new(1268717215714495281, false),
        amount1_before: 26087635650665564424699143612505016738,
        amount1_delta: IntegerTrait::<i256>::new(26087635650665564421536865952336637378, true),
        execution_price: 1629106479634122818406861578931628631641876249516,
        fee_growth_global_0_X128_delta: 647583145675012618257449376796101507,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 1033437718471923706666374484006904511252097097914,
        pool_price_after: 125270724187523965593206900784,
        tick_before: IntegerTrait::<i32>::new(880340, false),
        tick_after: IntegerTrait::<i32>::new(9163, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit, expected_results
    );
}

#[test]
#[should_panic(expected: ('SPL',))]
fn test_swap_3000_fee_max_1_price_swap_arbitrary_amount_to_price_zero_for_one_false_price_limit_2_5() {
    let fee = 3000;
    let price0 = pow(2, 127);
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = false;
    let exact_out = false;
    let sqrt_price_limit = 50108289675009586237282760313; // encode_price_sqrt(2, 5)

    let expected_results = SwapExpectedResults {
        amount0_before: 1,
        amount0_delta: IntegerTrait::<i256>::new(0, false),
        amount1_before: 26087635650665564424699143612505016738,
        amount1_delta: IntegerTrait::<i256>::new(0, false),
        execution_price: 0,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 1033437718471923706666374484006904511252097097914,
        pool_price_after: 0,
        tick_before: IntegerTrait::<i32>::new(880340, false),
        tick_after: IntegerTrait::<i32>::new(0, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit, expected_results
    );
}

//////
//////

#[test]
fn test_swap_3000_fee_1_max_price_swap_large_amount_zero_for_one_true_exact_input() {
    let fee = 3000;
    let price0 = 1;
    let price1 = pow(2, 127);

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = true;
    let exact_out = false;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 0;

    let expected_results = SwapExpectedResults {
        amount0_before: 26037782196502120275425782622539039026,
        amount0_delta: IntegerTrait::<i256>::new(1000000000000000000, false),
        amount1_before: 1,
        amount1_delta: IntegerTrait::<i256>::new(0, false),
        execution_price: 0,
        fee_growth_global_0_X128_delta: 170141183460469231731687303715884105728,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 6085630636,
        pool_price_after: 6085630636,
        tick_before: IntegerTrait::<i32>::new(880303, true),
        tick_after: IntegerTrait::<i32>::new(880303, true),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_1_max_price_swap_large_amount_zero_for_one_false_exact_input() {
    let fee = 3000;
    let price0 = 1;
    let price1 = pow(2, 127);

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = false;
    let exact_out = false;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 0;

    let expected_results = SwapExpectedResults {
        amount0_before: 26037782196502120275425782622539039026,
        amount0_delta: IntegerTrait::<i256>::new(26037782196502120271413746514214063808, true),
        amount1_before: 1,
        amount1_delta: IntegerTrait::<i256>::new(1000000000000000000, false),
        execution_price: 3042815318,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 510423550381413820277666488039994629,
        pool_price_before: 6085630636,
        pool_price_after: 39495239013360769732380381856,
        tick_before: IntegerTrait::<i32>::new(880303, true),
        tick_after: IntegerTrait::<i32>::new(13924, true),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_1_max_price_swap_large_amount_zero_for_one_true_exact_output() {
    let fee = 3000;
    let price0 = 1;
    let price1 = pow(2, 127);

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = true;
    let exact_out = true;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 0;

    let expected_results = SwapExpectedResults {
        amount0_before: 26037782196502120275425782622539039026,
        amount0_delta: IntegerTrait::<i256>::new(
            10790901831095468191587263901270792610, false
        ),
        amount1_before: 1,
        amount1_delta: IntegerTrait::<i256>::new(0, false),
        execution_price: 0,
        fee_growth_global_0_X128_delta: 5507930424444982259736347157352787128931407551935325049,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 6085630636,
        pool_price_after: 4295128740,
        tick_before: IntegerTrait::<i32>::new(880303, true),
        tick_after: IntegerTrait::<i32>::new(887272, true),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_1_max_price_swap_large_amount_zero_for_one_false_exact_output() {
    let fee = 3000;
    let price0 = 1;
    let price1 = pow(2, 127);

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = false;
    let exact_out = true;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 0;

    let expected_results = SwapExpectedResults {
        amount0_before: 26037782196502120275425782622539039026,
        amount0_delta: IntegerTrait::<i256>::new(1000000000000000000, true),
        amount1_before: 1,
        amount1_delta: IntegerTrait::<i256>::new(2, false),
        execution_price: 158456325028,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 170141183460469231731,
        pool_price_before: 6085630636,
        pool_price_after: 6085630637,
        tick_before: IntegerTrait::<i32>::new(880303, true),
        tick_after: IntegerTrait::<i32>::new(880303, true),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit, expected_results
    );
}

#[test]
#[should_panic(expected: ('SPL',))]
fn test_swap_3000_fee_1_max_price_swap_large_amount_with_price_limit_zero_for_one_true_exact_input() {
    let fee = 3000;
    let price0 = 1;
    let price1 = pow(2, 127);

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = true;
    let exact_out = false;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 56022770974786139918731938227; // encode_price_sqrt(50, 100)

    let expected_results = SwapExpectedResults {
        amount0_before: 26037782196502120275425782622539039026,
        amount0_delta: IntegerTrait::<i256>::new(0, false),
        amount1_before: 1,
        amount1_delta: IntegerTrait::<i256>::new(0, false),
        execution_price: 0,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 6085630636,
        pool_price_after: 0,
        tick_before: IntegerTrait::<i32>::new(880303, true),
        tick_after: IntegerTrait::<i32>::new(0, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_1_max_price_swap_large_amount_with_price_limit_zero_for_one_false_exact_input() {
    let fee = 3000;
    let price0 = 1;
    let price1 = pow(2, 127);

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = false;
    let exact_out = false;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 112045541949572279837463876454; // encode_price_sqrt(200, 100)

    let expected_results = SwapExpectedResults {
        amount0_before: 26037782196502120275425782622539039026,
        amount0_delta: IntegerTrait::<i256>::new(26037782196502120271413746514214063808, true),
        amount1_before: 1,
        amount1_delta: IntegerTrait::<i256>::new(1000000000000000000, false),
        execution_price: 3042815318,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 510423550381413820277666488039994629,
        pool_price_before: 6085630636,
        pool_price_after: 39495239013360769732380381856,
        tick_before: IntegerTrait::<i32>::new(880303, true),
        tick_after: IntegerTrait::<i32>::new(13924, true),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit, expected_results
    );
}

#[test]
#[should_panic(expected: ('SPL',))]
fn test_swap_3000_fee_1_max_price_swap_large_amount_with_price_limit_zero_for_one_true_exact_output() {
    let fee = 3000;
    let price0 = 1;
    let price1 = pow(2, 127);

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = true;
    let exact_out = true;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 56022770974786139918731938227; // encode_price_sqrt(50, 100)

    let expected_results = SwapExpectedResults {
        amount0_before: 26037782196502120275425782622539039026,
        amount0_delta: IntegerTrait::<i256>::new(0, false),
        amount1_before: 1,
        amount1_delta: IntegerTrait::<i256>::new(0, false),
        execution_price: 0,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 6085630636,
        pool_price_after: 0,
        tick_before: IntegerTrait::<i32>::new(880303, true),
        tick_after: IntegerTrait::<i32>::new(0, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_1_max_price_swap_large_amount_with_price_limit_zero_for_one_false_exact_output() {
    let fee = 3000;
    let price0 = 1;
    let price1 = pow(2, 127);

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = false;
    let exact_out = true;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 112045541949572279837463876454; // encode_price_sqrt(200, 100)

    let expected_results = SwapExpectedResults {
        amount0_before: 26037782196502120275425782622539039026,
        amount0_delta: IntegerTrait::<i256>::new(1000000000000000000, true),
        amount1_before: 1,
        amount1_delta: IntegerTrait::<i256>::new(2, false),
        execution_price: 158456325028,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 170141183460469231731,
        pool_price_before: 6085630636,
        pool_price_after: 6085630637,
        tick_before: IntegerTrait::<i32>::new(880303, true),
        tick_after: IntegerTrait::<i32>::new(880303, true),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_1_max_price_swap_small_amount_zero_for_one_true_exact_input() {
    let fee = 3000;
    let price0 = 1;
    let price1 = pow(2, 127);

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = true;
    let exact_out = false;
    let amount0 = 1000;
    let sqrt_price_limit = 0;

    let expected_results = SwapExpectedResults {
        amount0_before: 26037782196502120275425782622539039026,
        amount0_delta: IntegerTrait::<i256>::new(1000, false),
        amount1_before: 1,
        amount1_delta: IntegerTrait::<i256>::new(0, false),
        execution_price: 0,
        fee_growth_global_0_X128_delta: 170141183460469231731687,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 6085630636,
        pool_price_after: 6085630636,
        tick_before: IntegerTrait::<i32>::new(880303, true),
        tick_after: IntegerTrait::<i32>::new(880303, true),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_1_max_price_swap_small_amount_zero_for_one_false_exact_input() {
    let fee = 3000;
    let price0 = 1;
    let price1 = pow(2, 127);

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = false;
    let exact_out = false;
    let amount1 = 1000;
    let sqrt_price_limit = 0;

    let expected_results = SwapExpectedResults {
        amount0_before: 26037782196502120275425782622539039026,
        amount0_delta: IntegerTrait::<i256>::new(26033697540846965126433148994127431276, true),
        amount1_before: 1,
        amount1_delta: IntegerTrait::<i256>::new(1000, false),
        execution_price: 0,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 2381976568446569244235,
        pool_price_before: 6085630636,
        pool_price_after: 38793068108090,
        tick_before: IntegerTrait::<i32>::new(880303, true),
        tick_after: IntegerTrait::<i32>::new(705093, true),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_1_max_price_swap_small_amount_zero_for_one_true_exact_output() {
    let fee = 3000;
    let price0 = 1;
    let price1 = pow(2, 127);

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = true;
    let exact_out = true;
    let amount1 = 1000;
    let sqrt_price_limit = 0;

    let expected_results = SwapExpectedResults {
        amount0_before: 26037782196502120275425782622539039026,
        amount0_delta: IntegerTrait::<i256>::new(
            10790901831095468191587263901270792610, false
        ),
        amount1_before: 1,
        amount1_delta: IntegerTrait::<i256>::new(0, false),
        execution_price: 0,
        fee_growth_global_0_X128_delta: 5507930424444982259736347157352787128931407551935325049,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 6085630636,
        pool_price_after: 4295128740,
        tick_before: IntegerTrait::<i32>::new(880303, true),
        tick_after: IntegerTrait::<i32>::new(887272, true),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_1_max_price_swap_small_amount_zero_for_one_false_exact_output() {
    let fee = 3000;
    let price0 = 1;
    let price1 = pow(2, 127);

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = false;
    let exact_out = true;
    let amount0 = 1000;
    let sqrt_price_limit = 0;

    let expected_results = SwapExpectedResults {
        amount0_before: 26037782196502120275425782622539039026,
        amount0_delta: IntegerTrait::<i256>::new(1000, true),
        amount1_before: 1,
        amount1_delta: IntegerTrait::<i256>::new(2, false),
        execution_price: 158456325028528675187087900,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 170141183460469231731,
        pool_price_before: 6085630636,
        pool_price_after: 6085630637,
        tick_before: IntegerTrait::<i32>::new(880303, true),
        tick_after: IntegerTrait::<i32>::new(880303, true),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_1_max_price_swap_arbitrary_amount_to_price_zero_for_one_false_price_limit_5_2() {
    let fee = 3000;
    let price0 = 1;
    let price1 = pow(2, 127);

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = false;
    let exact_out = false;
    let sqrt_price_limit = 125270724187523965593206900784; // encode_price_sqrt(5, 2)

    let expected_results = SwapExpectedResults {
        amount0_before: 26037782196502120275425782622539039026,
        amount0_delta: IntegerTrait::<i256>::new(26037782196502120274160871558471687260, true),
        amount1_before: 1,
        amount1_delta: IntegerTrait::<i256>::new(3171793039286238112, false),
        execution_price: 9651180445,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 1618957864187523634078592530170978294,
        pool_price_before: 6085630636,
        pool_price_after: 125270724187523965593206900784,
        tick_before: IntegerTrait::<i32>::new(880303, true),
        tick_after: IntegerTrait::<i32>::new(9163, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit, expected_results
    );
}

#[test]
#[should_panic(expected: ('SPL',))]
fn test_swap_3000_fee_1_max_price_swap_arbitrary_amount_to_price_zero_for_one_true_price_limit_2_5() {
    let fee = 3000;
    let price0 = 1;
    let price1 = pow(2, 127);

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = true;
    let exact_out = false;
    let sqrt_price_limit = 50108289675009586237282760313; // encode_price_sqrt(2, 5)

    let expected_results = SwapExpectedResults {
        amount0_before: 26037782196502120275425782622539039026,
        amount0_delta: IntegerTrait::<i256>::new(0, false),
        amount1_before: 1,
        amount1_delta: IntegerTrait::<i256>::new(0, false),
        execution_price: 0,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 6085630636,
        pool_price_after: 0,
        tick_before: IntegerTrait::<i32>::new(880303, true),
        tick_after: IntegerTrait::<i32>::new(0, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit, expected_results
    );
}

#[test]
#[should_panic(expected: ('SPL',))]
fn test_swap_3000_fee_1_max_price_swap_arbitrary_amount_to_price_zero_for_one_true_price_limit_5_2() {
    let fee = 3000;
    let price0 = 1;
    let price1 = pow(2, 127);

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = true;
    let exact_out = false;
    let sqrt_price_limit = 125270724187523965593206900784; // encode_price_sqrt(5, 2)

    let expected_results = SwapExpectedResults {
        amount0_before: 26037782196502120275425782622539039026,
        amount0_delta: IntegerTrait::<i256>::new(0, false),
        amount1_before: 1,
        amount1_delta: IntegerTrait::<i256>::new(0, false),
        execution_price: 0,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 6085630636,
        pool_price_after: 0,
        tick_before: IntegerTrait::<i32>::new(880303, true),
        tick_after: IntegerTrait::<i32>::new(0, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_1_max_price_swap_arbitrary_amount_to_price_zero_for_one_false_price_limit_2_5() {
    let fee = 3000;
    let price0 = 1;
    let price1 = pow(2, 127);

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = false;
    let exact_out = false;
    let sqrt_price_limit = 50108289675009586237282760313; // encode_price_sqrt(2, 5)

    let expected_results = SwapExpectedResults {
        amount0_before: 26037782196502120275425782622539039026,
        amount0_delta: IntegerTrait::<i256>::new(26037782196502120272263504962370659661, true),
        amount1_before: 1,
        amount1_delta: IntegerTrait::<i256>::new(1268717215714495283, false),
        execution_price: 3860472178,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 647583145675012958539816297734564973,
        pool_price_before: 6085630636,
        pool_price_after: 50108289675009586237282760313,
        tick_before: IntegerTrait::<i32>::new(880303, true),
        tick_after: IntegerTrait::<i32>::new(9164, true),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit, expected_results
    );
}

//////
//////

#[test]
fn test_swap_3000_fee_1_1_price_max_full_range_liquidity_swap_large_amount_zero_for_one_true_exact_input() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: get_max_liquidity_per_tick(fee)
            }
        );

    let zero_for_one = true;
    let exact_out = false;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 0;

    let expected_results = SwapExpectedResults {
        amount0_before: 11505743598341114571255423385623647,
        amount0_delta: IntegerTrait::<i256>::new(1000000000000000000, false),
        amount1_before: 11505743598341114571255423385506404,
        amount1_delta: IntegerTrait::<i256>::new(996999999999999318, true),
        execution_price: 78990478026721490547156483756,
        fee_growth_global_0_X128_delta: 88725000000017597125,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 79228162514264330728235563131,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(1, true),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_1_1_price_max_full_range_liquidity_swap_large_amount_zero_for_one_false_exact_input() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: get_max_liquidity_per_tick(fee)
            }
        );

    let zero_for_one = false;
    let exact_out = false;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 0;

    let expected_results = SwapExpectedResults {
        amount0_before: 11505743598341114571255423385623647,
        amount0_delta: IntegerTrait::<i256>::new(996999999999999232, true),
        amount1_before: 11505743598341114571255423385506404,
        amount1_delta: IntegerTrait::<i256>::new(1000000000000000000, false),
        execution_price: 79466562200866999622731916350,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 88725000000020140575,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 79228162514264344458852337541,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(0, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_1_1_price_max_full_range_liquidity_swap_large_amount_zero_for_one_true_exact_output() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: get_max_liquidity_per_tick(fee)
            }
        );

    let zero_for_one = true;
    let exact_out = true;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 0;

    let expected_results = SwapExpectedResults {
        amount0_before: 11505743598341114571255423385623647,
        amount0_delta: IntegerTrait::<i256>::new(1003009027081361181, false),
        amount1_before: 11505743598341114571255423385506404,
        amount1_delta: IntegerTrait::<i256>::new(1000000000000000000, true),
        execution_price: 78990478026712294996659176097,
        fee_growth_global_0_X128_delta: 88991975927793784300,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 79228162514264330707577664272,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(1, true),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_1_1_price_max_full_range_liquidity_swap_large_amount_zero_for_one_false_exact_output() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: get_max_liquidity_per_tick(fee)
            }
        );

    let zero_for_one = false;
    let exact_out = true;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 0;

    let expected_results = SwapExpectedResults {
        amount0_before: 11505743598341114571255423385623647,
        amount0_delta: IntegerTrait::<i256>::new(1000000000000000000, true),
        amount1_before: 11505743598341114571255423385506404,
        amount1_delta: IntegerTrait::<i256>::new(1003009027081361094, false),
        execution_price: 79466562200876236848270376220,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 88991975927793784300,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 79228162514264344479510236400,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(0, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_1_1_price_max_full_range_liquidity_swap_large_amount_with_price_limit_zero_for_one_true_exact_input() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: get_max_liquidity_per_tick(fee)
            }
        );

    let zero_for_one = true;
    let exact_out = false;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 56022770974786139918731938227; // encode_price_sqrt(50, 100)

    let expected_results = SwapExpectedResults {
        amount0_before: 11505743598341114571255423385623647,
        amount0_delta: IntegerTrait::<i256>::new(1000000000000000000, false),
        amount1_before: 11505743598341114571255423385506404,
        amount1_delta: IntegerTrait::<i256>::new(996999999999999318, true),
        execution_price: 78990478026721490547156483756,
        fee_growth_global_0_X128_delta: 88725000000017597125,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 79228162514264330728235563131,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(1, true),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_1_1_price_max_full_range_liquidity_swap_large_amount_with_price_limit_zero_for_one_false_exact_input() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: get_max_liquidity_per_tick(fee)
            }
        );

    let zero_for_one = false;
    let exact_out = false;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 112045541949572279837463876454; // encode_price_sqrt(200, 100)

    let expected_results = SwapExpectedResults {
        amount0_before: 11505743598341114571255423385623647,
        amount0_delta: IntegerTrait::<i256>::new(996999999999999232, true),
        amount1_before: 11505743598341114571255423385506404,
        amount1_delta: IntegerTrait::<i256>::new(1000000000000000000, false),
        execution_price: 79466562200866999622731916350,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 88725000000020140575,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 79228162514264344458852337541,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(0, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_1_1_price_max_full_range_liquidity_swap_large_amount_with_price_limit_zero_for_one_true_exact_output() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: get_max_liquidity_per_tick(fee)
            }
        );

    let zero_for_one = true;
    let exact_out = true;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 56022770974786139918731938227; // encode_price_sqrt(50, 100)

    let expected_results = SwapExpectedResults {
        amount0_before: 11505743598341114571255423385623647,
        amount0_delta: IntegerTrait::<i256>::new(1003009027081361181, false),
        amount1_before: 11505743598341114571255423385506404,
        amount1_delta: IntegerTrait::<i256>::new(1000000000000000000, true),
        execution_price: 78990478026712294996659176097,
        fee_growth_global_0_X128_delta: 88991975927793784300,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 79228162514264330707577664272,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(1, true),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_1_1_price_max_full_range_liquidity_swap_large_amount_with_price_limit_zero_for_one_false_exact_output() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: get_max_liquidity_per_tick(fee)
            }
        );

    let zero_for_one = false;
    let exact_out = true;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 112045541949572279837463876454; // encode_price_sqrt(200, 100)

    let expected_results = SwapExpectedResults {
        amount0_before: 11505743598341114571255423385623647,
        amount0_delta: IntegerTrait::<i256>::new(1000000000000000000, true),
        amount1_before: 11505743598341114571255423385506404,
        amount1_delta: IntegerTrait::<i256>::new(1003009027081361094, false),
        execution_price: 79466562200876236848270376220,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 88991975927793784300,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 79228162514264344479510236400,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(0, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_1_1_price_max_full_range_liquidity_swap_small_amount_zero_for_one_true_exact_input() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: get_max_liquidity_per_tick(fee)
            }
        );

    let zero_for_one = true;
    let exact_out = false;
    let amount0 = 1000;
    let sqrt_price_limit = 0;

    let expected_results = SwapExpectedResults {
        amount0_before: 11505743598341114571255423385623647,
        amount0_delta: IntegerTrait::<i256>::new(1000, false),
        amount1_before: 11505743598341114571255423385506404,
        amount1_delta: IntegerTrait::<i256>::new(0, false),
        execution_price: 0,
        fee_growth_global_0_X128_delta: 29575000,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 79228162514264337593543950336,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(1, true),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_1_1_price_max_full_range_liquidity_swap_small_amount_zero_for_one_false_exact_input() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: get_max_liquidity_per_tick(fee)
            }
        );

    let zero_for_one = false;
    let exact_out = false;
    let amount1 = 1000;
    let sqrt_price_limit = 0;

    let expected_results = SwapExpectedResults {
        amount0_before: 11505743598341114571255423385623647,
        amount0_delta: IntegerTrait::<i256>::new(0, false),
        amount1_before: 11505743598341114571255423385506404,
        amount1_delta: IntegerTrait::<i256>::new(1000, false),
        execution_price: '-Infinity'.into(),
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 29575000,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 79228162514264337593543950336,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(0, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_1_1_price_max_full_range_liquidity_swap_small_amount_zero_for_one_true_exact_output() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: get_max_liquidity_per_tick(fee)
            }
        );

    let zero_for_one = true;
    let exact_out = true;
    let amount1 = 1000;
    let sqrt_price_limit = 0;

    let expected_results = SwapExpectedResults {
        amount0_before: 11505743598341114571255423385623647,
        amount0_delta: IntegerTrait::<i256>::new(145660, false),
        amount1_before: 11505743598341114571255423385506404,
        amount1_delta: IntegerTrait::<i256>::new(1000, true),
        execution_price: 543925322767158709278758412,
        fee_growth_global_0_X128_delta: 12924275,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 79228162514264337593543950335,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(1, true),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_1_1_price_max_full_range_liquidity_swap_small_amount_zero_for_one_false_exact_output() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: get_max_liquidity_per_tick(fee)
            }
        );

    let zero_for_one = false;
    let exact_out = true;
    let amount0 = 1000;
    let sqrt_price_limit = 0;

    let expected_results = SwapExpectedResults {
        amount0_before: 11505743598341114571255423385623647,
        amount0_delta: IntegerTrait::<i256>::new(1000, true),
        amount1_before: 11505743598341114571255423385506404,
        amount1_delta: IntegerTrait::<i256>::new(145660, false),
        execution_price: 11540374151827743413875611805941,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 12924275,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 79228162514264337593543950337,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(0, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_1_1_price_max_full_range_liquidity_swap_arbitrary_amount_to_price_zero_for_one_false_price_limit_5_2() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: get_max_liquidity_per_tick(fee)
            }
        );

    let zero_for_one = false;
    let exact_out = false;
    let sqrt_price_limit = 125270724187523965593206900784; // encode_price_sqrt(5, 2)

    let expected_results = SwapExpectedResults {
        amount0_before: 11505743598341114571255423385623647,
        amount0_delta: IntegerTrait::<i256>::new(4228872409409224753601131224936259, true),
        amount1_before: 11505743598341114571255423385506404,
        amount1_delta: IntegerTrait::<i256>::new(6706554036096900675845906992220230, false),
        execution_price: 125647667189091239311140321749,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 595039006852697512464428097884749099,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 125270724187523965593206900784,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(9163, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_1_1_price_max_full_range_liquidity_swap_arbitrary_amount_to_price_zero_for_one_true_price_limit_2_5() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: get_max_liquidity_per_tick(fee)
            }
        );

    let zero_for_one = true;
    let exact_out = false;
    let sqrt_price_limit = 50108289675009586237282760313; // encode_price_sqrt(2, 5)

    let expected_results = SwapExpectedResults {
        amount0_before: 11505743598341114571255423385623647,
        amount0_delta: IntegerTrait::<i256>::new(6706554036096900675845906992672697, false),
        amount1_before: 11505743598341114571255423385506404,
        amount1_delta: IntegerTrait::<i256>::new(4228872409409224753601131225116702, true),
        execution_price: 49957964805984557478570912032,
        fee_growth_global_0_X128_delta: 595039006852697512464428097924911949,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 50108289675009586237282760313,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(9164, true),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit, expected_results
    );
}

#[test]
#[should_panic(expected: ('SPL',))]
fn test_swap_3000_fee_1_1_price_max_full_range_liquidity_swap_arbitrary_amount_to_price_zero_for_one_true_price_limit_5_2() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: get_max_liquidity_per_tick(fee)
            }
        );

    let zero_for_one = true;
    let exact_out = false;
    let sqrt_price_limit = 125270724187523965593206900784; // encode_price_sqrt(5, 2)

    let expected_results = SwapExpectedResults {
        amount0_before: 11505743598341114571255423385623647,
        amount0_delta: IntegerTrait::<i256>::new(0, false),
        amount1_before: 11505743598341114571255423385506404,
        amount1_delta: IntegerTrait::<i256>::new(0, false),
        execution_price: 0,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 0,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(0, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit, expected_results
    );
}

#[test]
#[should_panic(expected: ('SPL',))]
fn test_swap_3000_fee_1_1_price_max_full_range_liquidity_swap_arbitrary_amount_to_price_zero_for_one_false_price_limit_2_5() {
    let fee = 3000;
    let price0 = 1;
    let price1 = 1;

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: get_max_liquidity_per_tick(fee)
            }
        );

    let zero_for_one = false;
    let exact_out = false;
    let sqrt_price_limit = 50108289675009586237282760313; // encode_price_sqrt(2, 5)

    let expected_results = SwapExpectedResults {
        amount0_before: 11505743598341114571255423385623647,
        amount0_delta: IntegerTrait::<i256>::new(0, false),
        amount1_before: 11505743598341114571255423385506404,
        amount1_delta: IntegerTrait::<i256>::new(0, false),
        execution_price: 0,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 79228162514264337593543950336,
        pool_price_after: 0,
        tick_before: IntegerTrait::<i32>::new(0, false),
        tick_after: IntegerTrait::<i32>::new(0, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit, expected_results
    );
}

//////
//////

#[test]
fn test_swap_3000_fee_max_max_price_swap_large_amount_zero_for_one_true_exact_input() {
    let fee = 3000;
    let price0 = 'max';
    let price1 = 'max';

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = true;
    let exact_out = false;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 0;

    let expected_results = SwapExpectedResults {
        amount0_before: 0,
        amount0_delta: IntegerTrait::<i256>::new(1000000000000000000, false),
        amount1_before: 36796311329002736532545403775337522448,
        amount1_delta: IntegerTrait::<i256>::new(36796311329002736528533367667012547243, true),
        execution_price: 2915304133899694779621368431969120461154403970070,
        fee_growth_global_0_X128_delta: 510423550381413479995299567101531162,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 1461446703485210103287273052203988822378723970341,
        pool_price_after: 158933124401733886835376621103,
        tick_before: IntegerTrait::<i32>::new(887271, false),
        tick_after: IntegerTrait::<i32>::new(13923, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit, expected_results
    );
}

#[test]
#[should_panic(expected: ('SPL',))]
fn test_swap_3000_fee_max_max_price_swap_large_amount_zero_for_one_false_exact_input() {
    let fee = 3000;
    let price0 = 'max';
    let price1 = 'max';

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = false;
    let exact_out = false;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 0;

    let expected_results = SwapExpectedResults {
        amount0_before: 0,
        amount0_delta: IntegerTrait::<i256>::new(0, false),
        amount1_before: 36796311329002736532545403775337522448,
        amount1_delta: IntegerTrait::<i256>::new(0, false),
        execution_price: 0,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 1461446703485210103287273052203988822378723970341,
        pool_price_after: 0,
        tick_before: IntegerTrait::<i32>::new(887271, false),
        tick_after: IntegerTrait::<i32>::new(0, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_max_max_price_swap_large_amount_zero_for_one_true_exact_output() {
    let fee = 3000;
    let price0 = 'max';
    let price1 = 'max';

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = true;
    let exact_out = true;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 0;

    let expected_results = SwapExpectedResults {
        amount0_before: 0,
        amount0_delta: IntegerTrait::<i256>::new(2, false),
        amount1_before: 36796311329002736532545403775337522448,
        amount1_delta: IntegerTrait::<i256>::new(1000000000000000000, true),
        execution_price: 39614081257132168796771975168000000000000000000,
        fee_growth_global_0_X128_delta: 170141183460469231731,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 1461446703485210103287273052203988822378723970341,
        pool_price_after: 1457652066949847389930003259129161949691061401300,
        tick_before: IntegerTrait::<i32>::new(887271, false),
        tick_after: IntegerTrait::<i32>::new(887219, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit, expected_results
    );
}

#[test]
#[should_panic(expected: ('SPL',))]
fn test_swap_3000_fee_max_max_price_swap_large_amount_zero_for_one_false_exact_output() {
    let fee = 3000;
    let price0 = 'max';
    let price1 = 'max';

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = false;
    let exact_out = true;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 0;

    let expected_results = SwapExpectedResults {
        amount0_before: 0,
        amount0_delta: IntegerTrait::<i256>::new(0, false),
        amount1_before: 36796311329002736532545403775337522448,
        amount1_delta: IntegerTrait::<i256>::new(0, false),
        execution_price: 0,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 1461446703485210103287273052203988822378723970341,
        pool_price_after: 0,
        tick_before: IntegerTrait::<i32>::new(887271, false),
        tick_after: IntegerTrait::<i32>::new(0, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_max_max_price_swap_large_amount_with_price_limit_zero_for_one_true_exact_input() {
    let fee = 3000;
    let price0 = 'max';
    let price1 = 'max';

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = true;
    let exact_out = false;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 56022770974786139918731938227; // encode_price_sqrt(50, 100)

    let expected_results = SwapExpectedResults {
        amount0_before: 0,
        amount0_delta: IntegerTrait::<i256>::new(1000000000000000000, false),
        amount1_before: 36796311329002736532545403775337522448,
        amount1_delta: IntegerTrait::<i256>::new(36796311329002736528533367667012547243, true),
        execution_price: 2915304133899694779621368431969120461154403970070,
        fee_growth_global_0_X128_delta: 510423550381413479995299567101531162,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 1461446703485210103287273052203988822378723970341,
        pool_price_after: 158933124401733886835376621103,
        tick_before: IntegerTrait::<i32>::new(887271, false),
        tick_after: IntegerTrait::<i32>::new(13923, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit, expected_results
    );
}

#[test]
#[should_panic(expected: ('SPL',))]
fn test_swap_3000_fee_max_max_price_swap_large_amount_with_price_limit_zero_for_one_false_exact_input() {
    let fee = 3000;
    let price0 = 'max';
    let price1 = 'max';

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = false;
    let exact_out = false;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 112045541949572279837463876454; // encode_price_sqrt(200, 100)

    let expected_results = SwapExpectedResults {
        amount0_before: 0,
        amount0_delta: IntegerTrait::<i256>::new(0, false),
        amount1_before: 36796311329002736532545403775337522448,
        amount1_delta: IntegerTrait::<i256>::new(0, false),
        execution_price: 0,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 1461446703485210103287273052203988822378723970341,
        pool_price_after: 0,
        tick_before: IntegerTrait::<i32>::new(887271, false),
        tick_after: IntegerTrait::<i32>::new(0, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_max_max_price_swap_large_amount_with_price_limit_zero_for_one_true_exact_output() {
    let fee = 3000;
    let price0 = 'max';
    let price1 = 'max';

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = true;
    let exact_out = true;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 56022770974786139918731938227; // encode_price_sqrt(50, 100)

    let expected_results = SwapExpectedResults {
        amount0_before: 0,
        amount0_delta: IntegerTrait::<i256>::new(2, false),
        amount1_before: 36796311329002736532545403775337522448,
        amount1_delta: IntegerTrait::<i256>::new(1000000000000000000, true),
        execution_price: 39614081257132168796771975168000000000000000000,
        fee_growth_global_0_X128_delta: 170141183460469231731,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 1461446703485210103287273052203988822378723970341,
        pool_price_after: 1457652066949847389930003259129161949691061401300,
        tick_before: IntegerTrait::<i32>::new(887271, false),
        tick_after: IntegerTrait::<i32>::new(887219, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit, expected_results
    );
}

#[test]
#[should_panic(expected: ('SPL',))]
fn test_swap_3000_fee_max_max_price_swap_large_amount_with_price_limit_zero_for_one_false_exact_output() {
    let fee = 3000;
    let price0 = 'max';
    let price1 = 'max';

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = false;
    let exact_out = true;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 112045541949572279837463876454; // encode_price_sqrt(200, 100)

    let expected_results = SwapExpectedResults {
        amount0_before: 0,
        amount0_delta: IntegerTrait::<i256>::new(0, false),
        amount1_before: 36796311329002736532545403775337522448,
        amount1_delta: IntegerTrait::<i256>::new(0, false),
        execution_price: 0,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 1461446703485210103287273052203988822378723970341,
        pool_price_after: 0,
        tick_before: IntegerTrait::<i32>::new(887271, false),
        tick_after: IntegerTrait::<i32>::new(0, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_max_max_price_swap_small_amount_zero_for_one_true_exact_input() {
    let fee = 3000;
    let price0 = 'max';
    let price1 = 'max';

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = true;
    let exact_out = false;
    let amount0 = 1000;
    let sqrt_price_limit = 0;

    let expected_results = SwapExpectedResults {
        amount0_before: 0,
        amount0_delta: IntegerTrait::<i256>::new(1000, false),
        amount1_before: 36796311329002736532545403775337522448,
        amount1_delta: IntegerTrait::<i256>::new(36792225529204286454178948640580261338, true),
        execution_price: 2914980423489262428654614713058930938051967579854568255823772909,
        fee_growth_global_0_X128_delta: 2381976568446569244235,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 1461446703485210103287273052203988822378723970341,
        pool_price_after: 161855205216175642309983856828649147738467364,
        tick_before: IntegerTrait::<i32>::new(887271, false),
        tick_after: IntegerTrait::<i32>::new(705098, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit, expected_results
    );
}

#[test]
#[should_panic(expected: ('SPL',))]
fn test_swap_3000_fee_max_max_price_swap_small_amount_zero_for_one_false_exact_input() {
    let fee = 3000;
    let price0 = 'max';
    let price1 = 'max';

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = false;
    let exact_out = false;
    let amount1 = 1000;
    let sqrt_price_limit = 0;

    let expected_results = SwapExpectedResults {
        amount0_before: 0,
        amount0_delta: IntegerTrait::<i256>::new(0, false),
        amount1_before: 36796311329002736532545403775337522448,
        amount1_delta: IntegerTrait::<i256>::new(0, false),
        execution_price: 0,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 1461446703485210103287273052203988822378723970341,
        pool_price_after: 0,
        tick_before: IntegerTrait::<i32>::new(887271, false),
        tick_after: IntegerTrait::<i32>::new(0, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_max_max_price_swap_small_amount_zero_for_one_true_exact_output() {
    let fee = 3000;
    let price0 = 'max';
    let price1 = 'max';

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = true;
    let exact_out = true;
    let amount1 = 1000;
    let sqrt_price_limit = 0;

    let expected_results = SwapExpectedResults {
        amount0_before: 0,
        amount0_delta: IntegerTrait::<i256>::new(2, false),
        amount1_before: 36796311329002736532545403775337522448,
        amount1_delta: IntegerTrait::<i256>::new(1000, true),
        execution_price: 39614081257132168796771975168000,
        fee_growth_global_0_X128_delta: 170141183460469231731,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 1461446703485210103287273052203988822378723970341,
        pool_price_after: 1457652066949847389969617340386294078873752119335,
        tick_before: IntegerTrait::<i32>::new(887271, false),
        tick_after: IntegerTrait::<i32>::new(887219, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit, expected_results
    );
}

#[test]
#[should_panic(expected: ('SPL',))]
fn test_swap_3000_fee_max_max_price_swap_small_amount_zero_for_one_false_exact_output() {
    let fee = 3000;
    let price0 = 'max';
    let price1 = 'max';

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = false;
    let exact_out = true;
    let amount0 = 1000;
    let sqrt_price_limit = 0;

    let expected_results = SwapExpectedResults {
        amount0_before: 0,
        amount0_delta: IntegerTrait::<i256>::new(0, false),
        amount1_before: 36796311329002736532545403775337522448,
        amount1_delta: IntegerTrait::<i256>::new(0, false),
        execution_price: 0,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 1461446703485210103287273052203988822378723970341,
        pool_price_after: 0,
        tick_before: IntegerTrait::<i32>::new(887271, false),
        tick_after: IntegerTrait::<i32>::new(0, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit, expected_results
    );
}

#[test]
#[should_panic(expected: ('SPL',))]
fn test_swap_3000_fee_max_max_price_swap_arbitrary_amount_to_price_zero_for_one_false_price_limit_5_2() {
    let fee = 3000;
    let price0 = 'max';
    let price1 = 'max';

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = false;
    let exact_out = false;
    let sqrt_price_limit = 125270724187523965593206900784; // encode_price_sqrt(5, 2)

    let expected_results = SwapExpectedResults {
        amount0_before: 0,
        amount0_delta: IntegerTrait::<i256>::new(0, false),
        amount1_before: 36796311329002736532545403775337522448,
        amount1_delta: IntegerTrait::<i256>::new(0, false),
        execution_price: 0,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 1461446703485210103287273052203988822378723970341,
        pool_price_after: 0,
        tick_before: IntegerTrait::<i32>::new(887271, false),
        tick_after: IntegerTrait::<i32>::new(0, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_max_max_price_swap_arbitrary_amount_to_price_zero_for_one_true_price_limit_2_5() {
    let fee = 3000;
    let price0 = 'max';
    let price1 = 'max';

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = true;
    let exact_out = false;
    let sqrt_price_limit = 50108289675009586237282760313; // encode_price_sqrt(2, 5)

    let expected_results = SwapExpectedResults {
        amount0_before: 0,
        amount0_delta: IntegerTrait::<i256>::new(3171793039286238109, false),
        amount1_before: 36796311329002736532545403775337522448,
        amount1_delta: IntegerTrait::<i256>::new(36796311329002736531280492711270170687, true),
        execution_price: 919134413182184767224001988600040418227710411433,
        fee_growth_global_0_X128_delta: 1618957864187523123655042148763283097,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 1461446703485210103287273052203988822378723970341,
        pool_price_after: 50108289675009586237282760313,
        tick_before: IntegerTrait::<i32>::new(887271, false),
        tick_after: IntegerTrait::<i32>::new(9164, true),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_max_max_price_swap_arbitrary_amount_to_price_zero_for_one_true_price_limit_5_2() {
    let fee = 3000;
    let price0 = 'max';
    let price1 = 'max';

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = true;
    let exact_out = false;
    let sqrt_price_limit = 125270724187523965593206900784; // encode_price_sqrt(5, 2)

    let expected_results = SwapExpectedResults {
        amount0_before: 0,
        amount0_delta: IntegerTrait::<i256>::new(1268717215714495281, false),
        amount1_before: 36796311329002736532545403775337522448,
        amount1_delta: IntegerTrait::<i256>::new(36796311329002736529383126115169143088, true),
        execution_price: 2297836032955461850204543222226920982186476540948,
        fee_growth_global_0_X128_delta: 647583145675012618257449376796101507,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 1461446703485210103287273052203988822378723970341,
        pool_price_after: 125270724187523965593206900784,
        tick_before: IntegerTrait::<i32>::new(887271, false),
        tick_after: IntegerTrait::<i32>::new(9163, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit, expected_results
    );
}

#[test]
#[should_panic(expected: ('SPL',))]
fn test_swap_3000_fee_max_max_price_swap_arbitrary_amount_to_price_zero_for_one_false_price_limit_2_5() {
    let fee = 3000;
    let price0 = 'max';
    let price1 = 'max';

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = false;
    let exact_out = false;
    let sqrt_price_limit = 50108289675009586237282760313; // encode_price_sqrt(2, 5)

    let expected_results = SwapExpectedResults {
        amount0_before: 0,
        amount0_delta: IntegerTrait::<i256>::new(0, false),
        amount1_before: 36796311329002736532545403775337522448,
        amount1_delta: IntegerTrait::<i256>::new(0, false),
        execution_price: 0,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 1461446703485210103287273052203988822378723970341,
        pool_price_after: 0,
        tick_before: IntegerTrait::<i32>::new(887271, false),
        tick_after: IntegerTrait::<i32>::new(0, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit, expected_results
    );
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
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = true;
    let exact_out = false;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 0;

    let expected_results = SwapExpectedResults {
        amount0_before: 36796311322104302062438284732106019258,
        amount0_delta: IntegerTrait::<i256>::new(0, false),
        amount1_before: 0,
        amount1_delta: IntegerTrait::<i256>::new(0, false),
        execution_price: 0,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 4295128739,
        pool_price_after: 0,
        tick_before: IntegerTrait::<i32>::new(887272, true),
        tick_after: IntegerTrait::<i32>::new(0, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_min_min_price_swap_large_amount_zero_for_one_false_exact_input() {
    let fee = 3000;
    let price0 = 'min';
    let price1 = 'min';

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = false;
    let exact_out = false;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 0;

    let expected_results = SwapExpectedResults {
        amount0_before: 36796311322104302062438284732106019258,
        amount0_delta: IntegerTrait::<i256>::new(36796311322104302058426248623781044040, true),
        amount1_before: 0,
        amount1_delta: IntegerTrait::<i256>::new(1000000000000000000, false),
        execution_price: 2153155022,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 510423550381413820277666488039994629,
        pool_price_before: 4295128739,
        pool_price_after: 39495239013360769732380381856,
        tick_before: IntegerTrait::<i32>::new(887272, true),
        tick_after: IntegerTrait::<i32>::new(13924, true),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit, expected_results
    );
}

#[test]
#[should_panic(expected: ('SPL',))]
fn test_swap_3000_fee_min_min_price_swap_large_amount_zero_for_one_true_exact_output() {
    let fee = 3000;
    let price0 = 'min';
    let price1 = 'min';

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = true;
    let exact_out = true;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 0;

    let expected_results = SwapExpectedResults {
        amount0_before: 36796311322104302062438284732106019258,
        amount0_delta: IntegerTrait::<i256>::new(0, false),
        amount1_before: 0,
        amount1_delta: IntegerTrait::<i256>::new(0, false),
        execution_price: 0,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 4295128739,
        pool_price_after: 0,
        tick_before: IntegerTrait::<i32>::new(887272, true),
        tick_after: IntegerTrait::<i32>::new(0, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_min_min_price_swap_large_amount_zero_for_one_false_exact_output() {
    let fee = 3000;
    let price0 = 'min';
    let price1 = 'min';

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = false;
    let exact_out = true;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 0;

    let expected_results = SwapExpectedResults {
        amount0_before: 36796311322104302062438284732106019258,
        amount0_delta: IntegerTrait::<i256>::new(1000000000000000000, true),
        amount1_before: 0,
        amount1_delta: IntegerTrait::<i256>::new(2, false),
        execution_price: 158456325028,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 170141183460469231731,
        pool_price_before: 4295128739,
        pool_price_after: 4306310045,
        tick_before: IntegerTrait::<i32>::new(887272, true),
        tick_after: IntegerTrait::<i32>::new(887220, true),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit, expected_results
    );
}

#[test]
#[should_panic(expected: ('SPL',))]
fn test_swap_3000_fee_min_min_price_swap_large_amount_with_price_limit_zero_for_one_true_exact_input() {
    let fee = 3000;
    let price0 = 'min';
    let price1 = 'min';

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = true;
    let exact_out = false;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 56022770974786139918731938227; // encode_price_sqrt(50, 100)

    let expected_results = SwapExpectedResults {
        amount0_before: 36796311322104302062438284732106019258,
        amount0_delta: IntegerTrait::<i256>::new(0, false),
        amount1_before: 0,
        amount1_delta: IntegerTrait::<i256>::new(0, false),
        execution_price: 0,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 4295128739,
        pool_price_after: 0,
        tick_before: IntegerTrait::<i32>::new(887272, true),
        tick_after: IntegerTrait::<i32>::new(0, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_min_min_price_swap_large_amount_with_price_limit_zero_for_one_false_exact_input() {
    let fee = 3000;
    let price0 = 'min';
    let price1 = 'min';

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = false;
    let exact_out = false;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 112045541949572279837463876454; // encode_price_sqrt(200, 100)

    let expected_results = SwapExpectedResults {
        amount0_before: 36796311322104302062438284732106019258,
        amount0_delta: IntegerTrait::<i256>::new(36796311322104302058426248623781044040, true),
        amount1_before: 0,
        amount1_delta: IntegerTrait::<i256>::new(1000000000000000000, false),
        execution_price: 2153155022,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 510423550381413820277666488039994629,
        pool_price_before: 4295128739,
        pool_price_after: 39495239013360769732380381856,
        tick_before: IntegerTrait::<i32>::new(887272, true),
        tick_after: IntegerTrait::<i32>::new(13924, true),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit, expected_results
    );
}

#[test]
#[should_panic(expected: ('SPL',))]
fn test_swap_3000_fee_min_min_price_swap_large_amount_with_price_limit_zero_for_one_true_exact_output() {
    let fee = 3000;
    let price0 = 'min';
    let price1 = 'min';

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = true;
    let exact_out = true;
    let amount1 = pow(10, 18);
    let sqrt_price_limit = 56022770974786139918731938227; // encode_price_sqrt(50, 100)

    let expected_results = SwapExpectedResults {
        amount0_before: 36796311322104302062438284732106019258,
        amount0_delta: IntegerTrait::<i256>::new(0, false),
        amount1_before: 0,
        amount1_delta: IntegerTrait::<i256>::new(0, false),
        execution_price: 0,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 4295128739,
        pool_price_after: 0,
        tick_before: IntegerTrait::<i32>::new(887272, true),
        tick_after: IntegerTrait::<i32>::new(0, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_min_min_price_swap_large_amount_with_price_limit_zero_for_one_false_exact_output() {
    let fee = 3000;
    let price0 = 'min';
    let price1 = 'min';

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = false;
    let exact_out = true;
    let amount0 = pow(10, 18);
    let sqrt_price_limit = 112045541949572279837463876454; // encode_price_sqrt(200, 100)

    let expected_results = SwapExpectedResults {
        amount0_before: 36796311322104302062438284732106019258,
        amount0_delta: IntegerTrait::<i256>::new(1000000000000000000, true),
        amount1_before: 0,
        amount1_delta: IntegerTrait::<i256>::new(2, false),
        execution_price: 158456325028,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 170141183460469231731,
        pool_price_before: 4295128739,
        pool_price_after: 4306310045,
        tick_before: IntegerTrait::<i32>::new(887272, true),
        tick_after: IntegerTrait::<i32>::new(887220, true),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit, expected_results
    );
}

#[test]
#[should_panic(expected: ('SPL',))]
fn test_swap_3000_fee_min_min_price_swap_small_amount_zero_for_one_true_exact_input() {
    let fee = 3000;
    let price0 = 'min';
    let price1 = 'min';

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = true;
    let exact_out = false;
    let amount0 = 1000;
    let sqrt_price_limit = 0;

    let expected_results = SwapExpectedResults {
        amount0_before: 36796311322104302062438284732106019258,
        amount0_delta: IntegerTrait::<i256>::new(0, false),
        amount1_before: 0,
        amount1_delta: IntegerTrait::<i256>::new(0, false),
        execution_price: 0,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 4295128739,
        pool_price_after: 0,
        tick_before: IntegerTrait::<i32>::new(887272, true),
        tick_after: IntegerTrait::<i32>::new(0, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_min_min_price_swap_small_amount_zero_for_one_false_exact_input() {
    let fee = 3000;
    let price0 = 'min';
    let price1 = 'min';

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = false;
    let exact_out = false;
    let amount1 = 1000;
    let sqrt_price_limit = 0;

    let expected_results = SwapExpectedResults {
        amount0_before: 36796311322104302062438284732106019258,
        amount0_delta: IntegerTrait::<i256>::new(36792226666449146913445651103694411508, true),
        amount1_before: 0,
        amount1_delta: IntegerTrait::<i256>::new(1000, false),
        execution_price: 0,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 2381976568446569244235,
        pool_price_before: 4295128739,
        pool_price_after: 38793068108090,
        tick_before: IntegerTrait::<i32>::new(887272, true),
        tick_after: IntegerTrait::<i32>::new(705093, true),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit, expected_results
    );
}

#[test]
#[should_panic(expected: ('SPL',))]
fn test_swap_3000_fee_min_min_price_swap_small_amount_zero_for_one_true_exact_output() {
    let fee = 3000;
    let price0 = 'min';
    let price1 = 'min';

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = true;
    let exact_out = true;
    let amount1 = 1000;
    let sqrt_price_limit = 0;

    let expected_results = SwapExpectedResults {
        amount0_before: 36796311322104302062438284732106019258,
        amount0_delta: IntegerTrait::<i256>::new(0, false),
        amount1_before: 0,
        amount1_delta: IntegerTrait::<i256>::new(0, false),
        execution_price: 0,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 4295128739,
        pool_price_after: 0,
        tick_before: IntegerTrait::<i32>::new(887272, true),
        tick_after: IntegerTrait::<i32>::new(0, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount1, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_min_min_price_swap_small_amount_zero_for_one_false_exact_output() {
    let fee = 3000;
    let price0 = 'min';
    let price1 = 'min';

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = false;
    let exact_out = true;
    let amount0 = 1000;
    let sqrt_price_limit = 0;

    let expected_results = SwapExpectedResults {
        amount0_before: 36796311322104302062438284732106019258,
        amount0_delta: IntegerTrait::<i256>::new(1000, true),
        amount1_before: 0,
        amount1_delta: IntegerTrait::<i256>::new(2, false),
        execution_price: 158456325028528675187087900,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 170141183460469231731,
        pool_price_before: 4295128739,
        pool_price_after: 4306310045,
        tick_before: IntegerTrait::<i32>::new(887272, true),
        tick_after: IntegerTrait::<i32>::new(887220, true),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, amount0, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_min_min_price_swap_arbitrary_amount_to_price_zero_for_one_false_price_limit_5_2() {
    let fee = 3000;
    let price0 = 'min';
    let price1 = 'min';

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = false;
    let exact_out = false;
    let sqrt_price_limit = 125270724187523965593206900784; // encode_price_sqrt(5, 2)

    let expected_results = SwapExpectedResults {
        amount0_before: 36796311322104302062438284732106019258,
        amount0_delta: IntegerTrait::<i256>::new(36796311322104302061173373668038667492, true),
        amount1_before: 0,
        amount1_delta: IntegerTrait::<i256>::new(3171793039286238112, false),
        execution_price: 6829362111,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 1618957864187523634078592530170978294,
        pool_price_before: 4295128739,
        pool_price_after: 125270724187523965593206900784,
        tick_before: IntegerTrait::<i32>::new(887272, true),
        tick_after: IntegerTrait::<i32>::new(9163, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit, expected_results
    );
}

#[test]
#[should_panic(expected: ('SPL',))]
fn test_swap_3000_fee_min_min_price_swap_arbitrary_amount_to_price_zero_for_one_true_price_limit_2_5() {
    let fee = 3000;
    let price0 = 'min';
    let price1 = 'min';

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = true;
    let exact_out = false;
    let sqrt_price_limit = 50108289675009586237282760313; // encode_price_sqrt(2, 5)

    let expected_results = SwapExpectedResults {
        amount0_before: 36796311322104302062438284732106019258,
        amount0_delta: IntegerTrait::<i256>::new(0, false),
        amount1_before: 0,
        amount1_delta: IntegerTrait::<i256>::new(0, false),
        execution_price: 0,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 4295128739,
        pool_price_after: 0,
        tick_before: IntegerTrait::<i32>::new(887272, true),
        tick_after: IntegerTrait::<i32>::new(0, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit, expected_results
    );
}

#[test]
#[should_panic(expected: ('SPL',))]
fn test_swap_3000_fee_min_min_price_swap_arbitrary_amount_to_price_zero_for_one_true_price_limit_5_2() {
    let fee = 3000;
    let price0 = 'min';
    let price1 = 'min';

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = true;
    let exact_out = false;
    let sqrt_price_limit = 125270724187523965593206900784; // encode_price_sqrt(5, 2)

    let expected_results = SwapExpectedResults {
        amount0_before: 36796311322104302062438284732106019258,
        amount0_delta: IntegerTrait::<i256>::new(0, false),
        amount1_before: 0,
        amount1_delta: IntegerTrait::<i256>::new(0, false),
        execution_price: 0,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 0,
        pool_price_before: 4295128739,
        pool_price_after: 0,
        tick_before: IntegerTrait::<i32>::new(887272, true),
        tick_after: IntegerTrait::<i32>::new(0, false),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit, expected_results
    );
}

#[test]
fn test_swap_3000_fee_min_min_price_swap_arbitrary_amount_to_price_zero_for_one_false_price_limit_2_5() {
    let fee = 3000;
    let price0 = 'min';
    let price1 = 'min';

    let mut pool_test_positions = ArrayTrait::<PoolTestPosition>::new();
    pool_test_positions
        .append(
            PoolTestPosition {
                tick_lower: get_min_tick(fee),
                tick_upper: get_max_tick(fee),
                liquidity: 2 * pow(10, 18)
            }
        );

    let zero_for_one = false;
    let exact_out = false;
    let sqrt_price_limit = 50108289675009586237282760313; // encode_price_sqrt(2, 5)

    let expected_results = SwapExpectedResults {
        amount0_before: 36796311322104302062438284732106019258,
        amount0_delta: IntegerTrait::<i256>::new(36796311322104302059276007071937639893, true),
        amount1_before: 0,
        amount1_delta: IntegerTrait::<i256>::new(1268717215714495283, false),
        execution_price: 2731744844,
        fee_growth_global_0_X128_delta: 0,
        fee_growth_global_1_X128_delta: 647583145675012958539816297734564973,
        pool_price_before: 4295128739,
        pool_price_after: 50108289675009586237282760313,
        tick_before: IntegerTrait::<i32>::new(887272, true),
        tick_after: IntegerTrait::<i32>::new(9164, true),
    };

    execute_and_test_swap(
        fee, price0, price1, pool_test_positions, zero_for_one, exact_out, 0, sqrt_price_limit, expected_results
    );
}
