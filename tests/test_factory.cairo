use starknet::{ContractAddress, contract_address_try_from_felt252};
use openzeppelin::access::ownable::{
    OwnableComponent, interface::{IOwnableDispatcher, IOwnableDispatcherTrait}
};
use jediswap_v2_core::jediswap_v2_factory::{
    IJediSwapV2FactoryDispatcher, IJediSwapV2FactoryDispatcherTrait, JediSwapV2Factory
};
use jediswap_v2_core::jediswap_v2_pool::{IJediSwapV2PoolDispatcher, IJediSwapV2PoolDispatcherTrait};
use snforge_std::{
    PrintTrait, declare, ContractClassTrait, start_prank, stop_prank, CheatTarget, spy_events,
    SpyOn, EventSpy, EventFetcher, Event, EventAssertions
};
use openzeppelin::security::interface::{IPausableDispatcher, IPausableDispatcherTrait};

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

#[test]
fn test_owner_on_deployment() {
    let (owner, factory_address) = setup_factory();
    let ownable_dispatcher = IOwnableDispatcher { contract_address: factory_address };

    assert(ownable_dispatcher.owner() == owner, 'Invalid owner');
}

#[test]
fn test_initial_enabled_fee_amounts() {
    let (owner, factory_address) = setup_factory();
    let factory_dispatcher = IJediSwapV2FactoryDispatcher { contract_address: factory_address };

    assert(factory_dispatcher.fee_amount_tick_spacing(100) == 2, 'Invalid fee amount');
    assert(factory_dispatcher.fee_amount_tick_spacing(500) == 10, 'Invalid fee amount');
    assert(factory_dispatcher.fee_amount_tick_spacing(3000) == 60, 'Invalid fee amount');
    assert(factory_dispatcher.fee_amount_tick_spacing(10000) == 200, 'Invalid fee amount');
}

#[test]
fn test_initial_fee_protocol() {
    let (owner, factory_address) = setup_factory();
    let factory_dispatcher = IJediSwapV2FactoryDispatcher { contract_address: factory_address };

    assert(factory_dispatcher.get_fee_protocol() == 0, 'Invalid fee protcol');
}

#[test]
fn test_initial_paused_state() {
    let (owner, factory_address) = setup_factory();

    let pausable_dispatcher = IPausableDispatcher { contract_address: factory_address };
    
    assert(!pausable_dispatcher.is_paused(), 'Paused');
}

#[test]
#[should_panic(expected: ('tokens must be different',))]
fn test_create_pool_fails_if_tokena_equals_tokenb() {
    let (owner, factory_address) = setup_factory();
    let factory_dispatcher = IJediSwapV2FactoryDispatcher { contract_address: factory_address };

    factory_dispatcher.create_pool(token0(), token0(), 100);
}

#[test]
#[should_panic(expected: ('tokens must be non zero',))]
fn test_create_pool_fails_if_tokena_is_zero() {
    let (owner, factory_address) = setup_factory();
    let factory_dispatcher = IJediSwapV2FactoryDispatcher { contract_address: factory_address };

    factory_dispatcher.create_pool(contract_address_try_from_felt252(0).unwrap(), token0(), 100);
}

#[test]
#[should_panic(expected: ('tokens must be non zero',))]
fn test_create_pool_fails_if_tokenb_is_zero() {
    let (owner, factory_address) = setup_factory();
    let factory_dispatcher = IJediSwapV2FactoryDispatcher { contract_address: factory_address };

    factory_dispatcher.create_pool(token0(), contract_address_try_from_felt252(0).unwrap(), 100);
}

#[test]
#[should_panic(expected: ('tick spacing not initialized',))]
fn test_create_pool_fails_if_fee_amount_is_not_enabled() {
    let (owner, factory_address) = setup_factory();
    let factory_dispatcher = IJediSwapV2FactoryDispatcher { contract_address: factory_address };

    factory_dispatcher.create_pool(token0(), token1(), 250);
}

#[test]
fn test_create_pool_succeeds_for_fee_100() {
    let (owner, factory_address) = setup_factory();
    let pool_address = create_pool(factory_address, 100);

    let pool_dispatcher = IJediSwapV2PoolDispatcher { contract_address: pool_address };

    assert(pool_dispatcher.get_factory() == factory_address, 'Invalid Factory');
    assert(pool_dispatcher.get_token0() == token0(), 'Invalid token0');
    assert(pool_dispatcher.get_token1() == token1(), 'Invalid token1');
    assert(pool_dispatcher.get_fee() == 100, 'Invalid fee');
    assert(pool_dispatcher.get_tick_spacing() == 2, 'Invalid tick spacing');
}

#[test]
fn test_create_pool_succeeds_for_fee_500() {
    let (owner, factory_address) = setup_factory();
    let pool_address = create_pool(factory_address, 500);

    let pool_dispatcher = IJediSwapV2PoolDispatcher { contract_address: pool_address };

    assert(pool_dispatcher.get_factory() == factory_address, 'Invalid Factory');
    assert(pool_dispatcher.get_token0() == token0(), 'Invalid token0');
    assert(pool_dispatcher.get_token1() == token1(), 'Invalid token1');
    assert(pool_dispatcher.get_fee() == 500, 'Invalid fee');
    assert(pool_dispatcher.get_tick_spacing() == 10, 'Invalid tick spacing');
}

#[test]
fn test_create_pool_succeeds_for_fee_3000() {
    let (owner, factory_address) = setup_factory();
    let pool_address = create_pool(factory_address, 3000);

    let pool_dispatcher = IJediSwapV2PoolDispatcher { contract_address: pool_address };

    assert(pool_dispatcher.get_factory() == factory_address, 'Invalid Factory');
    assert(pool_dispatcher.get_token0() == token0(), 'Invalid token0');
    assert(pool_dispatcher.get_token1() == token1(), 'Invalid token1');
    assert(pool_dispatcher.get_fee() == 3000, 'Invalid fee');
    assert(pool_dispatcher.get_tick_spacing() == 60, 'Invalid tick spacing');
}

#[test]
fn test_create_pool_succeeds_for_fee_10000() {
    let (owner, factory_address) = setup_factory();
    let pool_address = create_pool(factory_address, 10000);

    let pool_dispatcher = IJediSwapV2PoolDispatcher { contract_address: pool_address };

    assert(pool_dispatcher.get_factory() == factory_address, 'Invalid Factory');
    assert(pool_dispatcher.get_token0() == token0(), 'Invalid token0');
    assert(pool_dispatcher.get_token1() == token1(), 'Invalid token1');
    assert(pool_dispatcher.get_fee() == 10000, 'Invalid fee');
    assert(pool_dispatcher.get_tick_spacing() == 200, 'Invalid tick spacing');
}

#[test]
fn test_create_pool_succeeds_get_pool_in_reverse() {
    let (owner, factory_address) = setup_factory();
    let pool_address = create_pool(factory_address, 100);

    let factory_dispatcher = IJediSwapV2FactoryDispatcher { contract_address: factory_address };

    let pool_address_reverse = factory_dispatcher.get_pool(token1(), token0(), 100);

    assert(pool_address == pool_address_reverse, 'Invalid Pool');
}

#[test]
fn test_create_pool_succeeds_pool_created_event() {
    let (owner, factory_address) = setup_factory();
    let mut spy = spy_events(SpyOn::One(factory_address));

    let pool_address = create_pool(factory_address, 100);

    spy
        .assert_emitted(
            @array![
                (
                    factory_address,
                    JediSwapV2Factory::Event::PoolCreated(
                        JediSwapV2Factory::PoolCreated {
                            token0: token0(),
                            token1: token1(),
                            fee: 100,
                            tick_spacing: 2,
                            pool: pool_address
                        }
                    )
                )
            ]
        );
}

#[test]
#[should_panic(expected: ('pool already created',))]
fn test_create_pool_fails_if_already_created() {
    let (owner, factory_address) = setup_factory();
    let pool_address = create_pool(factory_address, 100);
    create_pool(factory_address, 100);
}

#[test]
#[should_panic(expected: ('Caller is not the owner',))]
fn test_transfer_ownership_fails_with_wrong_caller() {
    let (owner, factory_address) = setup_factory();

    let ownable_dispatcher = IOwnableDispatcher { contract_address: factory_address };
    ownable_dispatcher.transfer_ownership(new_owner());
}

#[test]
fn test_transfer_ownership_succeeds_with_owner() {
    let (owner, factory_address) = setup_factory();

    let ownable_dispatcher = IOwnableDispatcher { contract_address: factory_address };

    let mut spy = spy_events(SpyOn::One(factory_address));

    start_prank(CheatTarget::One(factory_address), owner);
    ownable_dispatcher.transfer_ownership(new_owner());
    stop_prank(CheatTarget::One(factory_address));

    assert(ownable_dispatcher.owner() == new_owner(), 'Invalid owner');

    spy
        .assert_emitted(
            @array![
                (
                    factory_address,
                    OwnableComponent::Event::OwnershipTransferred(
                        OwnableComponent::OwnershipTransferred {
                            previous_owner: owner, new_owner: new_owner()
                        }
                    )
                )
            ]
        );
}

#[test]
#[should_panic(expected: ('Caller is not the owner',))]
fn test_enable_fee_amount_fails_with_wrong_caller() {
    let (owner, factory_address) = setup_factory();

    let factory_dispatcher = IJediSwapV2FactoryDispatcher { contract_address: factory_address };

    factory_dispatcher.enable_fee_amount(1000, 20);
}

#[test]
#[should_panic(expected: ('fee cannot be above 100000',))]
fn test_enable_fee_amount_fails_if_fee_is_too_large() {
    let (owner, factory_address) = setup_factory();

    let factory_dispatcher = IJediSwapV2FactoryDispatcher { contract_address: factory_address };

    start_prank(CheatTarget::One(factory_address), owner);
    factory_dispatcher.enable_fee_amount(1000000, 20);
    stop_prank(CheatTarget::One(factory_address));
}

#[test]
#[should_panic(expected: ('invalid tick_spacing',))]
fn test_enable_fee_amount_fails_if_tick_spacing_is_too_small() {
    let (owner, factory_address) = setup_factory();

    let factory_dispatcher = IJediSwapV2FactoryDispatcher { contract_address: factory_address };

    start_prank(CheatTarget::One(factory_address), owner);
    factory_dispatcher.enable_fee_amount(1000, 0);
    stop_prank(CheatTarget::One(factory_address));
}

#[test]
#[should_panic(expected: ('invalid tick_spacing',))]
fn test_enable_fee_amount_fails_if_tick_spacing_is_too_large() {
    let (owner, factory_address) = setup_factory();

    let factory_dispatcher = IJediSwapV2FactoryDispatcher { contract_address: factory_address };

    start_prank(CheatTarget::One(factory_address), owner);
    factory_dispatcher.enable_fee_amount(1000, 16834);
    stop_prank(CheatTarget::One(factory_address));
}

#[test]
#[should_panic(expected: ('fee already enabled',))]
fn test_enable_fee_amount_fails_if_fee_already_enabled() {
    let (owner, factory_address) = setup_factory();

    let factory_dispatcher = IJediSwapV2FactoryDispatcher { contract_address: factory_address };

    start_prank(CheatTarget::One(factory_address), owner);
    factory_dispatcher.enable_fee_amount(100, 2);
    stop_prank(CheatTarget::One(factory_address));
}

#[test]
fn test_enable_fee_amount_succeeds_and_emits_event() {
    let (owner, factory_address) = setup_factory();

    let factory_dispatcher = IJediSwapV2FactoryDispatcher { contract_address: factory_address };

    let mut spy = spy_events(SpyOn::One(factory_address));

    start_prank(CheatTarget::One(factory_address), owner);
    factory_dispatcher.enable_fee_amount(1000, 20);
    stop_prank(CheatTarget::One(factory_address));

    assert(factory_dispatcher.fee_amount_tick_spacing(1000) == 20, 'Invalid fee amount');

    spy
        .assert_emitted(
            @array![
                (
                    factory_address,
                    JediSwapV2Factory::Event::FeeAmountEnabled(
                        JediSwapV2Factory::FeeAmountEnabled { fee: 1000, tick_spacing: 20 }
                    )
                )
            ]
        );
}

#[test]
fn test_enable_fee_amount_succeeds_and_pool_can_be_created() {
    let (owner, factory_address) = setup_factory();

    let factory_dispatcher = IJediSwapV2FactoryDispatcher { contract_address: factory_address };

    let mut spy = spy_events(SpyOn::One(factory_address));

    start_prank(CheatTarget::One(factory_address), owner);
    factory_dispatcher.enable_fee_amount(1000, 20);
    stop_prank(CheatTarget::One(factory_address));

    let pool_address = create_pool(factory_address, 1000);

    let pool_dispatcher = IJediSwapV2PoolDispatcher { contract_address: pool_address };

    assert(pool_dispatcher.get_factory() == factory_address, 'Invalid Factory');
    assert(pool_dispatcher.get_token0() == token0(), 'Invalid token0');
    assert(pool_dispatcher.get_token1() == token1(), 'Invalid token1');
    assert(pool_dispatcher.get_fee() == 1000, 'Invalid fee');
    assert(pool_dispatcher.get_tick_spacing() == 20, 'Invalid tick spacing');
}

#[test]
#[should_panic(expected: ('Caller is not the owner',))]
fn test_set_fee_protocol_fails_with_wrong_caller() {
    let (owner, factory_address) = setup_factory();

    let factory_dispatcher = IJediSwapV2FactoryDispatcher { contract_address: factory_address };

    factory_dispatcher.set_fee_protocol(6);
}

#[test]
fn test_set_fee_protocol_succeeds_with_owner() {
    let (owner, factory_address) = setup_factory();

    let factory_dispatcher = IJediSwapV2FactoryDispatcher { contract_address: factory_address };

    start_prank(CheatTarget::One(factory_address), owner);
    factory_dispatcher.set_fee_protocol(6);
    stop_prank(CheatTarget::One(factory_address));

    assert(factory_dispatcher.get_fee_protocol() == 6, 'Incorrect fee protocol');
}

#[test]
fn test_set_fee_protocol_succeeds_with_owner_emits_event() {
    let (owner, factory_address) = setup_factory();

    let factory_dispatcher = IJediSwapV2FactoryDispatcher { contract_address: factory_address };

    let mut spy = spy_events(SpyOn::One(factory_address));

    start_prank(CheatTarget::One(factory_address), owner);
    factory_dispatcher.set_fee_protocol(6);
    stop_prank(CheatTarget::One(factory_address));

    spy
        .assert_emitted(
            @array![
                (
                    factory_address,
                    JediSwapV2Factory::Event::SetFeeProtocol(
                        JediSwapV2Factory::SetFeeProtocol {
                            old_fee_protocol: 0, new_fee_protocol: 6
                        }
                    )
                )
            ]
        );
}

#[test]
#[should_panic(expected: ('incorrect fee_protocol',))]
fn test_set_fee_protocol_fails_for_out_of_bounds_change_lower() {
    let (owner, factory_address) = setup_factory();

    let factory_dispatcher = IJediSwapV2FactoryDispatcher { contract_address: factory_address };

    start_prank(CheatTarget::One(factory_address), owner);
    factory_dispatcher.set_fee_protocol(3);
    stop_prank(CheatTarget::One(factory_address));
}

#[test]
#[should_panic(expected: ('incorrect fee_protocol',))]
fn test_set_fee_protocol_fails_for_out_of_bounds_change_upper() {
    let (owner, factory_address) = setup_factory();

    let factory_dispatcher = IJediSwapV2FactoryDispatcher { contract_address: factory_address };

    start_prank(CheatTarget::One(factory_address), owner);
    factory_dispatcher.set_fee_protocol(11);
    stop_prank(CheatTarget::One(factory_address));
}
