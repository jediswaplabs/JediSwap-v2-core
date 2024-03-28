use core::traits::TryInto;
use starknet::{ContractAddress, contract_address_try_from_felt252};
use openzeppelin::upgrades::upgradeable::UpgradeableComponent;
use openzeppelin::security::interface::{IPausableDispatcher, IPausableDispatcherTrait};
use jediswap_v2_core::jediswap_v2_factory::{
    IJediSwapV2FactoryDispatcher, IJediSwapV2FactoryDispatcherTrait, JediSwapV2Factory
};
use openzeppelin::security::pausable::PausableComponent;
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
fn test_pause_fails_with_wrong_caller() {
    let (_, factory_address) = setup_factory();

    let factory_dispatcher = IJediSwapV2FactoryDispatcher { contract_address: factory_address };

    factory_dispatcher.pause();
}

#[test]
fn test_pause_succeeds_with_owner_emits_event() {
    let (owner, factory_address) = setup_factory();

    let factory_dispatcher = IJediSwapV2FactoryDispatcher { contract_address: factory_address };

    let mut spy = spy_events(SpyOn::One(factory_address));

    start_prank(CheatTarget::One(factory_address), owner);
    factory_dispatcher.pause();
    stop_prank(CheatTarget::One(factory_address));

    let pausable_dispatcher = IPausableDispatcher { contract_address: factory_address };
    assert(pausable_dispatcher.is_paused(), 'Not Paused');

    spy
        .assert_emitted(
            @array![
                (
                    factory_address,
                    PausableComponent::Event::Paused(PausableComponent::Paused { account: owner })
                )
            ]
        );
}

#[test]
#[should_panic(expected: ('Pausable: paused',))]
fn test_create_pool_fails_when_paused() {
    let (owner, factory_address) = setup_factory();

    let factory_dispatcher = IJediSwapV2FactoryDispatcher { contract_address: factory_address };

    start_prank(CheatTarget::One(factory_address), owner);
    factory_dispatcher.pause();
    stop_prank(CheatTarget::One(factory_address));

    factory_dispatcher.create_pool(token0(), token1(), 100);
}

#[test]
#[should_panic(expected: ('Caller is not the owner',))]
fn test_unpause_fails_with_wrong_caller() {
    let (_, factory_address) = setup_factory();

    let factory_dispatcher = IJediSwapV2FactoryDispatcher { contract_address: factory_address };

    factory_dispatcher.unpause();
}

#[test]
#[should_panic(expected: ('Pausable: not paused',))]
fn test_unpause_fails_when_not_paused() {
    let (owner, factory_address) = setup_factory();

    let factory_dispatcher = IJediSwapV2FactoryDispatcher { contract_address: factory_address };

    start_prank(CheatTarget::One(factory_address), owner);
    factory_dispatcher.unpause();
    stop_prank(CheatTarget::One(factory_address));
}

#[test]
fn test_unpause_succeeds_with_owner_emits_event() {
    let (owner, factory_address) = setup_factory();

    let factory_dispatcher = IJediSwapV2FactoryDispatcher { contract_address: factory_address };

    let mut spy = spy_events(SpyOn::One(factory_address));

    start_prank(CheatTarget::One(factory_address), owner);
    factory_dispatcher.pause();
    stop_prank(CheatTarget::One(factory_address));

    let pausable_dispatcher = IPausableDispatcher { contract_address: factory_address };
    assert(pausable_dispatcher.is_paused(), 'Not Paused');

    start_prank(CheatTarget::One(factory_address), owner);
    factory_dispatcher.unpause();
    stop_prank(CheatTarget::One(factory_address));

    assert(!pausable_dispatcher.is_paused(), 'Still Paused');

    spy
        .assert_emitted(
            @array![
                (
                    factory_address,
                    PausableComponent::Event::Unpaused(
                        PausableComponent::Unpaused { account: owner }
                    )
                )
            ]
        );
}

#[test]
fn test_create_pool_works_after_unpause() {
    let (owner, factory_address) = setup_factory();

    let factory_dispatcher = IJediSwapV2FactoryDispatcher { contract_address: factory_address };

    start_prank(CheatTarget::One(factory_address), owner);
    factory_dispatcher.pause();
    stop_prank(CheatTarget::One(factory_address));

    start_prank(CheatTarget::One(factory_address), owner);
    factory_dispatcher.unpause();
    stop_prank(CheatTarget::One(factory_address));

    factory_dispatcher.create_pool(token0(), token1(), 100);
}

