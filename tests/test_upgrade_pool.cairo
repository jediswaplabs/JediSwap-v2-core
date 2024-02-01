use core::traits::TryInto;
use starknet::{ContractAddress, contract_address_try_from_felt252};
use openzeppelin::upgrades::upgradeable::UpgradeableComponent;
use jediswap_v2_core::jediswap_v2_factory::{
    IJediSwapV2FactoryDispatcher, IJediSwapV2FactoryDispatcherTrait, JediSwapV2Factory
};
use jediswap_v2_core::test_contracts::jediswap_v2_pool_v2::{
    IJediSwapV2PoolV2Dispatcher, IJediSwapV2PoolV2DispatcherTrait, JediSwapV2PoolV2
};
use jediswap_v2_core::jediswap_v2_pool::{IJediSwapV2PoolDispatcher, IJediSwapV2PoolDispatcherTrait};
use snforge_std::{
    PrintTrait, declare, ContractClassTrait, start_prank, stop_prank, CheatTarget, spy_events,
    SpyOn, EventSpy, EventFetcher, Event, EventAssertions
};

use super::utils::{owner, new_owner, token0, token1};

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

fn create_pool(factory_address: ContractAddress, fee: u32) -> ContractAddress {
    let factory_dispatcher = IJediSwapV2FactoryDispatcher { contract_address: factory_address };

    factory_dispatcher.create_pool(token0(), token1(), fee);

    let pool_address = factory_dispatcher.get_pool(token0(), token1(), fee);

    pool_address
}

fn initialize_pool_1_10(factory_address: ContractAddress, fee: u32) -> ContractAddress {
    let pool_address = create_pool(factory_address, fee);

    let pool_dispatcher = IJediSwapV2PoolDispatcher { contract_address: pool_address };

    pool_dispatcher.initialize(25054144837504793750611689472); //  encode_price_sqrt(1, 10)

    pool_address
}

#[test]
#[should_panic(expected: ('Invalid caller',))]
fn test_upgrade_fails_with_wrong_caller() {
    let (owner, factory_address) = setup_factory();
    let pool_address = initialize_pool_1_10(factory_address, 100);

    let pool_dispatcher = IJediSwapV2PoolDispatcher { contract_address: pool_address };

    let new_pool_class_hash = declare('JediSwapV2PoolV2').class_hash;

    pool_dispatcher.upgrade(new_pool_class_hash);
}

#[test]
fn test_upgrade_succeeds_with_owner_emits_event() {
    let (owner, factory_address) = setup_factory();
    let pool_address = initialize_pool_1_10(factory_address, 100);

    let pool_dispatcher = IJediSwapV2PoolDispatcher { contract_address: pool_address };

    let new_pool_class_hash = declare('JediSwapV2PoolV2').class_hash;

    let mut spy = spy_events(SpyOn::One(pool_address));

    start_prank(CheatTarget::One(pool_address), owner);
    pool_dispatcher.upgrade(new_pool_class_hash);
    stop_prank(CheatTarget::One(pool_address));

    spy
        .assert_emitted(
            @array![
                (
                    pool_address,
                    UpgradeableComponent::Event::Upgraded(
                        UpgradeableComponent::Upgraded {
                            class_hash: new_pool_class_hash
                        }
                    )
                )
            ]
        );
}

#[test]
#[should_panic(expected: ('Class hash cannot be zero',))]
fn test_upgrade_fails_with_zero_class_hash() {
    let (owner, factory_address) = setup_factory();
    let pool_address = initialize_pool_1_10(factory_address, 100);

    let pool_dispatcher = IJediSwapV2PoolDispatcher { contract_address: pool_address };

    start_prank(CheatTarget::One(pool_address), owner);
    pool_dispatcher.upgrade(0.try_into().unwrap());
    stop_prank(CheatTarget::One(pool_address));
}

#[test]
#[should_panic]
fn test_upgrade_succeeds_old_selector_fails() {
    let (owner, factory_address) = setup_factory();
    let pool_address = initialize_pool_1_10(factory_address, 100);

    let pool_dispatcher = IJediSwapV2PoolDispatcher { contract_address: pool_address };

    let new_pool_class_hash = declare('JediSwapV2PoolV2').class_hash;

    start_prank(CheatTarget::One(pool_address), owner);
    pool_dispatcher.upgrade(new_pool_class_hash);
    stop_prank(CheatTarget::One(pool_address));

    pool_dispatcher.get_factory();
}

#[test]
fn test_upgrade_succeeds_new_selector() {
    let (owner, factory_address) = setup_factory();
    let pool_address = initialize_pool_1_10(factory_address, 100);

    let pool_dispatcher = IJediSwapV2PoolDispatcher { contract_address: pool_address };

    let new_pool_class_hash = declare('JediSwapV2PoolV2').class_hash;

    start_prank(CheatTarget::One(pool_address), owner);
    pool_dispatcher.upgrade(new_pool_class_hash);
    stop_prank(CheatTarget::One(pool_address));

    let pool_dispatcher = IJediSwapV2PoolV2Dispatcher { contract_address: pool_address };

    assert(pool_dispatcher.get_factory_v2() == factory_address, 'New selector fails');
}

#[test]
fn test_upgrade_succeeds_state_remians_same() {
    let (owner, factory_address) = setup_factory();
    let pool_address = initialize_pool_1_10(factory_address, 100);

    let pool_dispatcher = IJediSwapV2PoolDispatcher { contract_address: pool_address };

    let token0_address = pool_dispatcher.get_token0();

    let new_pool_class_hash = declare('JediSwapV2PoolV2').class_hash;

    start_prank(CheatTarget::One(pool_address), owner);
    pool_dispatcher.upgrade(new_pool_class_hash);
    stop_prank(CheatTarget::One(pool_address));

    assert(pool_dispatcher.get_token0() == token0_address, 'State changed');
}
