use core::traits::TryInto;
use starknet::{ContractAddress, contract_address_try_from_felt252};
use openzeppelin::upgrades::upgradeable::UpgradeableComponent;
use jediswap_v2_core::jediswap_v2_factory::{
    IJediSwapV2FactoryDispatcher, IJediSwapV2FactoryDispatcherTrait, JediSwapV2Factory
};
use jediswap_v2_core::test_contracts::jediswap_v2_factory_v2::{
    IJediSwapV2FactoryV2Dispatcher, IJediSwapV2FactoryV2DispatcherTrait, JediSwapV2FactoryV2
};
use jediswap_v2_core::jediswap_v2_pool::{IJediSwapV2PoolDispatcher, IJediSwapV2PoolDispatcherTrait};
use snforge_std::{
    declare, ContractClassTrait, start_prank, stop_prank, CheatTarget, spy_events,
    SpyOn, EventSpy, EventFetcher, Event, EventAssertions
};

use super::utils::{owner, new_owner, token0, token1};

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

#[test]
#[should_panic(expected: ('Caller is not the owner',))]
fn test_upgrade_fails_with_wrong_caller() {
    let (_, factory_address) = setup_factory();

    let factory_dispatcher = IJediSwapV2FactoryDispatcher { contract_address: factory_address };

    let new_pool_class_hash = declare("JediSwapV2PoolV2").class_hash;

    let new_factory_class_hash = declare("JediSwapV2FactoryV2").class_hash;

    factory_dispatcher.upgrade(new_factory_class_hash, new_pool_class_hash);
}

#[test]
fn test_upgrade_succeeds_with_owner_emits_event() {
    let (owner, factory_address) = setup_factory();

    let factory_dispatcher = IJediSwapV2FactoryDispatcher { contract_address: factory_address };

    let new_pool_class_hash = declare("JediSwapV2PoolV2").class_hash;

    let new_factory_class_hash = declare("JediSwapV2FactoryV2").class_hash;

    let mut spy = spy_events(SpyOn::One(factory_address));

    start_prank(CheatTarget::One(factory_address), owner);
    factory_dispatcher.upgrade(new_factory_class_hash, new_pool_class_hash);
    stop_prank(CheatTarget::One(factory_address));

    spy
        .assert_emitted(
            @array![
                (
                    factory_address,
                    UpgradeableComponent::Event::Upgraded(
                        UpgradeableComponent::Upgraded { class_hash: new_factory_class_hash }
                    )
                )
            ]
        );
    spy
        .assert_emitted(
            @array![
                (
                    factory_address,
                    JediSwapV2Factory::Event::UpgradedPoolClassHash(
                        JediSwapV2Factory::UpgradedPoolClassHash { class_hash: new_pool_class_hash }
                    )
                )
            ]
        );
}

#[test]
#[should_panic(expected: ('Class hash cannot be zero',))]
fn test_upgrade_fails_with_zero_class_hash() {
    let (owner, factory_address) = setup_factory();

    let factory_dispatcher = IJediSwapV2FactoryDispatcher { contract_address: factory_address };

    let new_pool_class_hash = declare("JediSwapV2PoolV2").class_hash;

    start_prank(CheatTarget::One(factory_address), owner);
    factory_dispatcher.upgrade(0.try_into().unwrap(), new_pool_class_hash);
    stop_prank(CheatTarget::One(factory_address));
}

#[test]
#[should_panic]
fn test_upgrade_succeeds_old_selector_fails() {
    let (owner, factory_address) = setup_factory();

    let factory_dispatcher = IJediSwapV2FactoryDispatcher { contract_address: factory_address };

    let new_pool_class_hash = declare("JediSwapV2PoolV2").class_hash;

    let new_factory_class_hash = declare("JediSwapV2FactoryV2").class_hash;

    start_prank(CheatTarget::One(factory_address), owner);
    factory_dispatcher.upgrade(new_factory_class_hash, new_pool_class_hash);
    stop_prank(CheatTarget::One(factory_address));

    factory_dispatcher.get_fee_protocol();
}

#[test]
fn test_upgrade_succeeds_new_selector() {
    let (owner, factory_address) = setup_factory();

    let factory_dispatcher = IJediSwapV2FactoryDispatcher { contract_address: factory_address };

    let new_pool_class_hash = declare("JediSwapV2PoolV2").class_hash;

    let new_factory_class_hash = declare("JediSwapV2FactoryV2").class_hash;

    start_prank(CheatTarget::One(factory_address), owner);
    factory_dispatcher.upgrade(new_factory_class_hash, new_pool_class_hash);
    stop_prank(CheatTarget::One(factory_address));

    let factory_dispatcher = IJediSwapV2FactoryV2Dispatcher { contract_address: factory_address };

    assert(factory_dispatcher.get_fee_protocol_v2() == 0, 'New selector fails');
}

#[test]
fn test_upgrade_succeeds_new_pool_class_hash() {
    let (owner, factory_address) = setup_factory();

    let factory_dispatcher = IJediSwapV2FactoryDispatcher { contract_address: factory_address };

    let new_pool_class_hash = declare("JediSwapV2PoolV2").class_hash;

    let new_factory_class_hash = declare("JediSwapV2FactoryV2").class_hash;

    start_prank(CheatTarget::One(factory_address), owner);
    factory_dispatcher.upgrade(new_factory_class_hash, new_pool_class_hash);
    stop_prank(CheatTarget::One(factory_address));

    assert(factory_dispatcher.get_pool_class_hash() == new_pool_class_hash, 'New selector fails');
}

#[test]
fn test_upgrade_succeeds_with_zero_pool_class_hash() {
    let (owner, factory_address) = setup_factory();

    let factory_dispatcher = IJediSwapV2FactoryDispatcher { contract_address: factory_address };

    let pool_class_hash = factory_dispatcher.get_pool_class_hash();

    let new_factory_class_hash = declare("JediSwapV2FactoryV2").class_hash;

    start_prank(CheatTarget::One(factory_address), owner);
    factory_dispatcher.upgrade(new_factory_class_hash, 0.try_into().unwrap());
    stop_prank(CheatTarget::One(factory_address));

    assert(factory_dispatcher.get_pool_class_hash() == pool_class_hash, 'Pool hash changed');
}

#[test]
fn test_upgrade_succeeds_state_remains_same() {
    let (owner, factory_address) = setup_factory();

    let factory_dispatcher = IJediSwapV2FactoryDispatcher { contract_address: factory_address };

    let new_pool_class_hash = declare("JediSwapV2PoolV2").class_hash;

    let new_factory_class_hash = declare("JediSwapV2FactoryV2").class_hash;

    let tick_spacing_100 = factory_dispatcher.fee_amount_tick_spacing(100);

    start_prank(CheatTarget::One(factory_address), owner);
    factory_dispatcher.upgrade(new_factory_class_hash, new_pool_class_hash);
    stop_prank(CheatTarget::One(factory_address));

    assert(factory_dispatcher.fee_amount_tick_spacing(100) == tick_spacing_100, 'State changed');
}
