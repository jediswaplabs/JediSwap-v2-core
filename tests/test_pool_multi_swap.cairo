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

use super::utils::{owner, user1, user2, token0_1_2};

fn get_min_tick() -> i32 {
    IntegerTrait::<i32>::new(887220, true) // math.ceil(-887272 / 60) * 60
}

fn get_max_tick() -> i32 {
    IntegerTrait::<i32>::new(887220, false) // math.floor(887272 / 60) * 60
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

fn create_pools() -> (ContractAddress, ContractAddress) {
    let (owner, factory_address) = setup_factory();
    let fee = 3000;
    let factory_dispatcher = IJediSwapV2FactoryDispatcher { contract_address: factory_address };
    let (token0, token1, token2) = token0_1_2();


    factory_dispatcher.create_pool(token0, token1, fee);
    factory_dispatcher.create_pool(token1, token2, fee);

    let pool_0_1_address = factory_dispatcher.get_pool(token0, token1, fee);
    let pool_1_2_address = factory_dispatcher.get_pool(token1, token2, fee);

    (pool_0_1_address, pool_1_2_address)
}

fn initialize_pools_1_1() -> (ContractAddress, ContractAddress) {
    let (pool_0_1_address, pool_1_2_address) = create_pools();

    let pool_0_1_dispatcher = IJediSwapV2PoolDispatcher { contract_address: pool_0_1_address };
    let pool_1_2_dispatcher = IJediSwapV2PoolDispatcher { contract_address: pool_1_2_address };

    pool_0_1_dispatcher.initialize(79228162514264337593543950336);  //  encode_price_sqrt(1, 1)
    pool_1_2_dispatcher.initialize(79228162514264337593543950336);  //  encode_price_sqrt(1, 1)

    (pool_0_1_address, pool_1_2_address)
}

fn get_pool_mint_test_dispatcher() -> IPoolMintTestDispatcher {
    let pool_mint_test_class = declare('PoolMintTest');
    let mut pool_mint_test_constructor_calldata = Default::default();

    let pool_mint_test_address = pool_mint_test_class.deploy(@pool_mint_test_constructor_calldata).unwrap();

    IPoolMintTestDispatcher { contract_address: pool_mint_test_address }
}

fn get_pool_swap_test_dispatcher() -> IPoolSwapTestDispatcher {
    let pool_swap_test_class = declare('PoolSwapTest');
    let mut pool_swap_test_constructor_calldata = Default::default();

    let pool_swap_test_address = pool_swap_test_class.deploy(@pool_swap_test_constructor_calldata).unwrap();

    IPoolSwapTestDispatcher { contract_address: pool_swap_test_address }
}

fn initiate_pools_1_1_with_intial_mint() -> (ContractAddress, ContractAddress, IPoolMintTestDispatcher) {
    let (pool_0_1_address, pool_1_2_address) = initialize_pools_1_1();

    let pool_mint_test_dispatcher = get_pool_mint_test_dispatcher();

    let pool_0_1_dispatcher = IJediSwapV2PoolDispatcher { contract_address: pool_0_1_address };

    let token0_dispatcher = IERC20Dispatcher { contract_address: pool_0_1_dispatcher.get_token0() };
    start_prank(CheatTarget::One(pool_0_1_dispatcher.get_token0()), user1());
    token0_dispatcher.approve(pool_mint_test_dispatcher.contract_address, 100 * pow(10, 18));
    stop_prank(CheatTarget::One(pool_0_1_dispatcher.get_token0()));

    let token1_dispatcher = IERC20Dispatcher { contract_address: pool_0_1_dispatcher.get_token1() };
    start_prank(CheatTarget::One(pool_0_1_dispatcher.get_token1()), user1());
    token1_dispatcher.approve(pool_mint_test_dispatcher.contract_address, 100 * pow(10, 18));
    stop_prank(CheatTarget::One(pool_0_1_dispatcher.get_token1()));

    start_prank(CheatTarget::One(pool_mint_test_dispatcher.contract_address), user1());
    pool_mint_test_dispatcher.mint(pool_0_1_address, user1(), get_min_tick(), get_max_tick(), pow(10, 18).try_into().unwrap());
    stop_prank(CheatTarget::One(pool_mint_test_dispatcher.contract_address));

    let pool_1_2_dispatcher = IJediSwapV2PoolDispatcher { contract_address: pool_1_2_address };

    let token0_dispatcher = IERC20Dispatcher { contract_address: pool_1_2_dispatcher.get_token0() };
    start_prank(CheatTarget::One(pool_1_2_dispatcher.get_token0()), user1());
    token0_dispatcher.approve(pool_mint_test_dispatcher.contract_address, 100 * pow(10, 18));
    stop_prank(CheatTarget::One(pool_1_2_dispatcher.get_token0()));

    let token1_dispatcher = IERC20Dispatcher { contract_address: pool_1_2_dispatcher.get_token1() };
    start_prank(CheatTarget::One(pool_1_2_dispatcher.get_token1()), user1());
    token1_dispatcher.approve(pool_mint_test_dispatcher.contract_address, 100 * pow(10, 18));
    stop_prank(CheatTarget::One(pool_1_2_dispatcher.get_token1()));

    start_prank(CheatTarget::One(pool_mint_test_dispatcher.contract_address), user1());
    pool_mint_test_dispatcher.mint(pool_1_2_address, user1(), get_min_tick(), get_max_tick(), pow(10, 18).try_into().unwrap());
    stop_prank(CheatTarget::One(pool_mint_test_dispatcher.contract_address));

    (pool_0_1_address, pool_1_2_address, pool_mint_test_dispatcher)
}

#[test]
fn test_multi_swap() {
    let (pool_0_1_address, pool_1_2_address, pool_mint_test_dispatcher)  = initiate_pools_1_1_with_intial_mint();

    let pool_0_1_dispatcher = IJediSwapV2PoolDispatcher { contract_address: pool_0_1_address };
    let pool_1_2_dispatcher = IJediSwapV2PoolDispatcher { contract_address: pool_1_2_address };

    let input_token = pool_0_1_dispatcher.get_token0();
    let output_token = pool_1_2_dispatcher.get_token1();
    let token1 = pool_0_1_dispatcher.get_token1();

    assert(pool_0_1_dispatcher.get_token1() == pool_1_2_dispatcher.get_token0(), 'Pool mismatch');

    let pool_swap_test_dispatcher = get_pool_swap_test_dispatcher();
    
    let input_token_dispatcher = IERC20Dispatcher { contract_address: input_token };
    start_prank(CheatTarget::One(input_token), user1());
    input_token_dispatcher.approve(pool_swap_test_dispatcher.contract_address, 100 * pow(10, 18));
    stop_prank(CheatTarget::One(input_token));

    start_prank(CheatTarget::One(pool_swap_test_dispatcher.contract_address), user1());
    pool_swap_test_dispatcher.swap_for_exact_1_multi(user1(), pool_0_1_address, pool_1_2_address, 100);
    stop_prank(CheatTarget::One(pool_swap_test_dispatcher.contract_address));
}