use core::traits::TryInto;
use integer::BoundedInt;
use starknet::{ContractAddress, contract_address_try_from_felt252};
use openzeppelin::upgrades::upgradeable::UpgradeableComponent;
use openzeppelin::security::interface::{IPausableDispatcher, IPausableDispatcherTrait};
use openzeppelin::token::erc20::{
    ERC20Component, interface::{IERC20Dispatcher, IERC20DispatcherTrait}
};
use jediswap_v2_core::jediswap_v2_factory::{
    IJediSwapV2FactoryDispatcher, IJediSwapV2FactoryDispatcherTrait, JediSwapV2Factory
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
use openzeppelin::security::pausable::PausableComponent;
use snforge_std::{
    declare, ContractClassTrait, start_prank, stop_prank, CheatTarget, spy_events,
    SpyOn, EventSpy, EventFetcher, Event, EventAssertions
};
use jediswap_v2_core::libraries::signed_integers::{i32::i32, i128::i128, integer_trait::IntegerTrait};
use jediswap_v2_core::libraries::math_utils::pow;

use super::utils::{owner, user1, token0_1};

//TODO Use setup when available

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

fn create_pool() -> (ContractAddress, ContractAddress, ContractAddress) {
    let (owner, factory_address) = setup_factory();

    let fee = 3000;
    let factory_dispatcher = IJediSwapV2FactoryDispatcher { contract_address: factory_address };
    
    let (token0, token1) = token0_1();

    factory_dispatcher.create_pool(token0, token1, fee);

    let pool_address = factory_dispatcher.get_pool(token0, token1, fee);

    (owner, factory_address, pool_address)
}

#[test]
#[should_panic(expected: ('Paused',))]
fn test_initialize_pool_fails_when_paused() {
    let (owner, factory_address, pool_address) = create_pool();

    let factory_dispatcher = IJediSwapV2FactoryDispatcher { contract_address: factory_address };

    start_prank(CheatTarget::One(factory_address), owner);
    factory_dispatcher.pause();
    stop_prank(CheatTarget::One(factory_address));

    let pool_dispatcher = IJediSwapV2PoolDispatcher { contract_address: pool_address };

    pool_dispatcher.initialize(25054144837504793750611689472); //  encode_price_sqrt(1, 10)
}

#[test]
fn test_initialize_pool_works_after_unpause() {
    let (owner, factory_address, pool_address) = create_pool();

    let factory_dispatcher = IJediSwapV2FactoryDispatcher { contract_address: factory_address };

    start_prank(CheatTarget::One(factory_address), owner);
    factory_dispatcher.pause();
    stop_prank(CheatTarget::One(factory_address));

    start_prank(CheatTarget::One(factory_address), owner);
    factory_dispatcher.unpause();
    stop_prank(CheatTarget::One(factory_address));

    let pool_dispatcher = IJediSwapV2PoolDispatcher { contract_address: pool_address };

    pool_dispatcher.initialize(25054144837504793750611689472); //  encode_price_sqrt(1, 10)
}

fn initialize_pool_1_10() -> (ContractAddress, ContractAddress, ContractAddress) {
    let (owner, factory_address, pool_address) = create_pool();

    let pool_dispatcher = IJediSwapV2PoolDispatcher { contract_address: pool_address };

    pool_dispatcher.initialize(25054144837504793750611689472); //  encode_price_sqrt(1, 10)

    (owner, factory_address, pool_address)
}

fn get_pool_mint_test_dispatcher() -> IPoolMintTestDispatcher {
    let pool_mint_test_class = declare("PoolMintTest");
    let mut pool_mint_test_constructor_calldata = Default::default();

    let pool_mint_test_address = pool_mint_test_class
        .deploy(@pool_mint_test_constructor_calldata)
        .unwrap();

    IPoolMintTestDispatcher { contract_address: pool_mint_test_address }
}

fn get_min_tick() -> i32 {
    IntegerTrait::<i32>::new(887220, true) // math.ceil(-887272 / 60) * 60
}

fn get_max_tick() -> i32 {
    IntegerTrait::<i32>::new(887220, false) // math.floor(887272 / 60) * 60
}

#[test]
#[should_panic(expected: ('Paused',))]
fn test_mint_fails_when_paused() {
    let (owner, factory_address, pool_address) = create_pool();

    let factory_dispatcher = IJediSwapV2FactoryDispatcher { contract_address: factory_address };

    start_prank(CheatTarget::One(factory_address), owner);
    factory_dispatcher.pause();
    stop_prank(CheatTarget::One(factory_address));

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
fn test_mint_succeeds_after_unpause() {
    let (owner, factory_address, pool_address) = initialize_pool_1_10();

    let factory_dispatcher = IJediSwapV2FactoryDispatcher { contract_address: factory_address };

    start_prank(CheatTarget::One(factory_address), owner);
    factory_dispatcher.pause();
    stop_prank(CheatTarget::One(factory_address));

    start_prank(CheatTarget::One(factory_address), owner);
    factory_dispatcher.unpause();
    stop_prank(CheatTarget::One(factory_address));

    let pool_dispatcher = IJediSwapV2PoolDispatcher { contract_address: pool_address };
    let pool_mint_test_dispatcher = get_pool_mint_test_dispatcher();

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

    assert(pool_dispatcher.get_tick() == IntegerTrait::<i32>::new(23028, true), 'Incorrect tick');
}

#[test]
#[should_panic(expected: ('Invalid caller',))]
fn test_burn_pause_fails_with_wrong_caller() {
    let (_, _, pool_address) = initialize_pool_1_10();

    let pool_dispatcher = IJediSwapV2PoolDispatcher { contract_address: pool_address };

    pool_dispatcher.pause_burn();
}

#[test]
#[should_panic(expected: ('Invalid caller',))]
fn test_burn_unpause_fails_with_wrong_caller() {
    let (_, _, pool_address) = initialize_pool_1_10();

    let pool_dispatcher = IJediSwapV2PoolDispatcher { contract_address: pool_address };

    pool_dispatcher.unpause_burn();
}

#[test]
#[should_panic(expected: ('Burn Paused',))]
fn test_burn_fails_when_burn_paused() {
    let (owner, _, pool_address) = initialize_pool_1_10();

    let pool_dispatcher = IJediSwapV2PoolDispatcher { contract_address: pool_address };
    let pool_mint_test_dispatcher = get_pool_mint_test_dispatcher();

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

    start_prank(CheatTarget::One(pool_address), owner);
    pool_dispatcher.pause_burn();
    stop_prank(CheatTarget::One(pool_address));

    start_prank(CheatTarget::One(pool_address), user1());
    pool_dispatcher
        .burn(IntegerTrait::<i32>::new(240, true), IntegerTrait::<i32>::new(0, false), 10000);
    stop_prank(CheatTarget::One(pool_address));
}

#[test]
fn test_burn_succeeds_after_burn_unpaused() {
    let (owner, _, pool_address) = initialize_pool_1_10();

    let pool_dispatcher = IJediSwapV2PoolDispatcher { contract_address: pool_address };
    let pool_mint_test_dispatcher = get_pool_mint_test_dispatcher();

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

    start_prank(CheatTarget::One(pool_address), owner);
    pool_dispatcher.pause_burn();
    stop_prank(CheatTarget::One(pool_address));

    start_prank(CheatTarget::One(pool_address), owner);
    pool_dispatcher.unpause_burn();
    stop_prank(CheatTarget::One(pool_address));

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
fn test_burn_succeeds_when_paused() {
    let (owner, factory_address, pool_address) = initialize_pool_1_10();

    let factory_dispatcher = IJediSwapV2FactoryDispatcher { contract_address: factory_address };

    let pool_dispatcher = IJediSwapV2PoolDispatcher { contract_address: pool_address };
    let pool_mint_test_dispatcher = get_pool_mint_test_dispatcher();

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

    start_prank(CheatTarget::One(factory_address), owner);
    factory_dispatcher.pause();
    stop_prank(CheatTarget::One(factory_address));

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
fn test_burn_succeeds_after_unpause() {
    let (owner, factory_address, pool_address) = initialize_pool_1_10();

    let factory_dispatcher = IJediSwapV2FactoryDispatcher { contract_address: factory_address };

    let pool_dispatcher = IJediSwapV2PoolDispatcher { contract_address: pool_address };
    let pool_mint_test_dispatcher = get_pool_mint_test_dispatcher();

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

    start_prank(CheatTarget::One(factory_address), owner);
    factory_dispatcher.pause();
    stop_prank(CheatTarget::One(factory_address));

    start_prank(CheatTarget::One(factory_address), owner);
    factory_dispatcher.unpause();
    stop_prank(CheatTarget::One(factory_address));

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
#[should_panic(expected: ('Burn Paused',))]
fn test_collect_fails_when_burn_paused() {
    let (owner, _, pool_address) = initialize_pool_1_10();

    let pool_dispatcher = IJediSwapV2PoolDispatcher { contract_address: pool_address };
    start_prank(CheatTarget::One(pool_address), owner);
    pool_dispatcher.pause_burn();
    stop_prank(CheatTarget::One(pool_address));

    start_prank(CheatTarget::One(pool_address), user1());
    let (_, _) = pool_dispatcher
        .collect(
            user1(),
            get_min_tick(),
            get_max_tick(),
            BoundedInt::<u128>::max(),
            BoundedInt::<u128>::max()
        );
    stop_prank(CheatTarget::One(pool_address));
}

#[test]
fn test_collect_succeeds_after_burn_unpaused() {
    let (owner, _, pool_address) = initialize_pool_1_10();

    let pool_dispatcher = IJediSwapV2PoolDispatcher { contract_address: pool_address };
    start_prank(CheatTarget::One(pool_address), owner);
    pool_dispatcher.pause_burn();
    stop_prank(CheatTarget::One(pool_address));
    start_prank(CheatTarget::One(pool_address), owner);
    pool_dispatcher.unpause_burn();
    stop_prank(CheatTarget::One(pool_address));

    start_prank(CheatTarget::One(pool_address), user1());
    let (_, _) = pool_dispatcher
        .collect(
            user1(),
            get_min_tick(),
            get_max_tick(),
            BoundedInt::<u128>::max(),
            BoundedInt::<u128>::max()
        );
    stop_prank(CheatTarget::One(pool_address));
}

#[test]
fn test_collect_succeeds_when_paused() {
    let (owner, factory_address, pool_address) = initialize_pool_1_10();

    let factory_dispatcher = IJediSwapV2FactoryDispatcher { contract_address: factory_address };

    start_prank(CheatTarget::One(factory_address), owner);
    factory_dispatcher.pause();
    stop_prank(CheatTarget::One(factory_address));

    let pool_dispatcher = IJediSwapV2PoolDispatcher { contract_address: pool_address };

    start_prank(CheatTarget::One(pool_address), user1());
    let (_, _) = pool_dispatcher
        .collect(
            user1(),
            get_min_tick(),
            get_max_tick(),
            BoundedInt::<u128>::max(),
            BoundedInt::<u128>::max()
        );
    stop_prank(CheatTarget::One(pool_address));
}

#[test]
fn test_collect_succeeds_after_unpause() {
    let (owner, factory_address, pool_address) = initialize_pool_1_10();

    let factory_dispatcher = IJediSwapV2FactoryDispatcher { contract_address: factory_address };

    start_prank(CheatTarget::One(factory_address), owner);
    factory_dispatcher.pause();
    stop_prank(CheatTarget::One(factory_address));

    start_prank(CheatTarget::One(factory_address), owner);
    factory_dispatcher.unpause();
    stop_prank(CheatTarget::One(factory_address));

    let pool_dispatcher = IJediSwapV2PoolDispatcher { contract_address: pool_address };

    start_prank(CheatTarget::One(pool_address), user1());
    let (_, _) = pool_dispatcher
        .collect(
            user1(),
            get_min_tick(),
            get_max_tick(),
            BoundedInt::<u128>::max(),
            BoundedInt::<u128>::max()
        );
    stop_prank(CheatTarget::One(pool_address));
}

fn get_pool_swap_test_dispatcher() -> IPoolSwapTestDispatcher {
    let pool_swap_test_class = declare("PoolSwapTest");
    let mut pool_swap_test_constructor_calldata = Default::default();

    let pool_swap_test_address = pool_swap_test_class
        .deploy(@pool_swap_test_constructor_calldata)
        .unwrap();

    IPoolSwapTestDispatcher { contract_address: pool_swap_test_address }
}

#[test]
#[should_panic(expected: ('Paused',))]
fn test_swap_fails_when_paused() {
    let (owner, factory_address, pool_address) = initialize_pool_1_10();

    let factory_dispatcher = IJediSwapV2FactoryDispatcher { contract_address: factory_address };

    start_prank(CheatTarget::One(factory_address), owner);
    factory_dispatcher.pause();
    stop_prank(CheatTarget::One(factory_address));
    
    let pool_swap_test_dispatcher = get_pool_swap_test_dispatcher();

    start_prank(CheatTarget::One(pool_swap_test_dispatcher.contract_address), user1());
    pool_swap_test_dispatcher.swap_exact_1_for_0(pool_address, 2 * pow(10, 18), user1(), 0);
    stop_prank(CheatTarget::One(pool_swap_test_dispatcher.contract_address));
}

#[test]
#[should_panic(expected: ('SPL',))]
fn test_swap_enters_after_unpause() {
    let (owner, factory_address, pool_address) = initialize_pool_1_10();

    let factory_dispatcher = IJediSwapV2FactoryDispatcher { contract_address: factory_address };

    start_prank(CheatTarget::One(factory_address), owner);
    factory_dispatcher.pause();
    stop_prank(CheatTarget::One(factory_address));

    start_prank(CheatTarget::One(factory_address), owner);
    factory_dispatcher.unpause();
    stop_prank(CheatTarget::One(factory_address));
    
    let pool_swap_test_dispatcher = get_pool_swap_test_dispatcher();

    start_prank(CheatTarget::One(pool_swap_test_dispatcher.contract_address), user1());
    pool_swap_test_dispatcher.swap_exact_1_for_0(pool_address, 2 * pow(10, 18), user1(), 0);
    stop_prank(CheatTarget::One(pool_swap_test_dispatcher.contract_address));
}
