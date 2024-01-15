use integer::BoundedInt;
use jediswap_v2_core::libraries::tick::{TickInfo, TickComponent::{Tick, InternalImpl}};
use yas_core::numbers::signed_integer::{i32::i32, i128::i128, integer_trait::IntegerTrait};
use snforge_std::PrintTrait;

#[starknet::contract]
mod TickMock {
    use jediswap_v2_core::libraries::tick::TickComponent;

    component!(path: TickComponent, storage: tick_storage, event: TickEvent);

    #[abi(embed_v0)]
    impl TickImpl = TickComponent::Tick<ContractState>;

    impl TickInternalImpl = TickComponent::InternalImpl<ContractState>;

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        #[flat]
        TickEvent: TickComponent::Event
    }

    #[storage]
    struct Storage {
        #[substorage(v0)]
        tick_storage: TickComponent::Storage
    }
}

fn STATE() -> TickMock::ContractState {
    TickMock::contract_state_for_testing()
}

// def get_min_tick(tick_spacing):
//     return math.ceil(-887272/tick_spacing) * tick_spacing

// def get_max_tick(tick_spacing):
//     return math.floor(887272/tick_spacing) * tick_spacing

// def get_max_liquidity_per_tick(tick_spacing):
//     return ((2 ** 128) - 1)/((get_max_tick(tick_spacing) - get_min_tick(tick_spacing)) / tick_spacing + 1)
//     print(f'{result:.0f}')

// fn flip_tick(mut state: TickMock::ContractState, tick: i32) ->  TickMock::ContractState {
//     state.tick_bitmap_storage.flip_tick(tick, 1);
//     state
// }

// fn flip_ticks(mut state: TickBitmapMock::ContractState) ->  TickBitmapMock::ContractState {
//     state = flip_tick(state, IntegerTrait::<i32>::new(10000, true));
//     state = flip_tick(state, IntegerTrait::<i32>::new(200, true));
//     state = flip_tick(state, IntegerTrait::<i32>::new(55, true));
//     state = flip_tick(state, IntegerTrait::<i32>::new(4, true));
//     state = flip_tick(state, IntegerTrait::<i32>::new(70, false));
//     state = flip_tick(state, IntegerTrait::<i32>::new(78, false));
//     state = flip_tick(state, IntegerTrait::<i32>::new(84, false));
//     state = flip_tick(state, IntegerTrait::<i32>::new(139, false));
//     state = flip_tick(state, IntegerTrait::<i32>::new(240, false));
//     state = flip_tick(state, IntegerTrait::<i32>::new(535, false));
//     state
// }

#[test]
fn test_tick_spacing_to_max_liquidity_per_tick_returns_correct_value_for_100_fee() {
    let mut state = STATE();
    assert(
        state
            .tick_storage
            .tick_spacing_to_max_liquidity_per_tick(2) == 383514844834609487117690504987493,
        'Incorrect tick spacing for 100'
    );
}

#[test]
fn test_tick_spacing_to_max_liquidity_per_tick_returns_correct_value_for_500_fee() {
    let mut state = STATE();
    assert(
        state
            .tick_storage
            .tick_spacing_to_max_liquidity_per_tick(10) == 1917569901783203986719870431555990,
        'Incorrect tick spacing for 500'
    );
}

#[test]
fn test_tick_spacing_to_max_liquidity_per_tick_returns_correct_value_for_3000_fee() {
    let mut state = STATE();
    assert(
        state
            .tick_storage
            .tick_spacing_to_max_liquidity_per_tick(60) == 11505743598341114571880798222544994,
        'Incorrect tick spacing for 3000'
    );
}

#[test]
fn test_tick_spacing_to_max_liquidity_per_tick_returns_correct_value_for_10000_fee() {
    let mut state = STATE();
    assert(
        state
            .tick_storage
            .tick_spacing_to_max_liquidity_per_tick(200) == 38350317471085141830651933667504588,
        'Incorrect tick spacing for10000'
    );
}

#[test]
fn test_tick_spacing_to_max_liquidity_per_tick_returns_correct_value_for_entire_range() {
    let mut state = STATE();
    assert(
        state.tick_storage.tick_spacing_to_max_liquidity_per_tick(887272) == BoundedInt::max() / 3,
        'Incorrect tick spacing for max'
    );
}

#[test]
fn test_tick_spacing_to_max_liquidity_per_tick_returns_correct_value_for_2302() {
    let mut state = STATE();
    assert(
        state
            .tick_storage
            .tick_spacing_to_max_liquidity_per_tick(2302) == 441351967472034323558203122479595605,
        'Incorrect tick spacing for 2302'
    );
}

#[test]
fn test_get_fee_growth_inside_returns_all_for_two_uninitialized_ticks_if_tick_is_inside() {
    let mut state = STATE();
    let (fee_growth_inside_0_X128, fee_growth_inside_1_X128) = state
        .tick_storage
        .get_fee_growth_inside(
            IntegerTrait::<i32>::new(2, true),
            IntegerTrait::<i32>::new(2, false),
            IntegerTrait::<i32>::new(0, false),
            15,
            15
        );
    assert(fee_growth_inside_0_X128 == 15, 'Incorrect fee 0');
    assert(fee_growth_inside_1_X128 == 15, 'Incorrect fee 1');
}

#[test]
fn test_get_fee_growth_inside_returns_0_for_two_uninitialized_ticks_if_tick_is_above() {
    let mut state = STATE();
    let (fee_growth_inside_0_X128, fee_growth_inside_1_X128) = state
        .tick_storage
        .get_fee_growth_inside(
            IntegerTrait::<i32>::new(2, true),
            IntegerTrait::<i32>::new(2, false),
            IntegerTrait::<i32>::new(4, false),
            15,
            15
        );
    assert(fee_growth_inside_0_X128 == 0, 'Incorrect fee 0');
    assert(fee_growth_inside_1_X128 == 0, 'Incorrect fee 1');
}

#[test]
fn test_get_fee_growth_inside_returns_0_for_two_uninitialized_ticks_if_tick_is_below() {
    let mut state = STATE();
    let (fee_growth_inside_0_X128, fee_growth_inside_1_X128) = state
        .tick_storage
        .get_fee_growth_inside(
            IntegerTrait::<i32>::new(2, true),
            IntegerTrait::<i32>::new(2, false),
            IntegerTrait::<i32>::new(4, true),
            15,
            15
        );
    assert(fee_growth_inside_0_X128 == 0, 'Incorrect fee 0');
    assert(fee_growth_inside_1_X128 == 0, 'Incorrect fee 1');
}

#[test]
fn test_get_fee_growth_inside_substracts_upper_tick_if_below() {
    let mut state = STATE();
    let tick_info = TickInfo {
        liquidity_gross: 0,
        liquidity_net: IntegerTrait::<i128>::new(0, false),
        fee_growth_outside_0_X128: 2,
        fee_growth_outside_1_X128: 3
    };
    state.tick_storage.set_tick(IntegerTrait::<i32>::new(2, false), tick_info);
    let (fee_growth_inside_0_X128, fee_growth_inside_1_X128) = state
        .tick_storage
        .get_fee_growth_inside(
            IntegerTrait::<i32>::new(2, true),
            IntegerTrait::<i32>::new(2, false),
            IntegerTrait::<i32>::new(0, false),
            15,
            15
        );
    assert(fee_growth_inside_0_X128 == 13, 'Incorrect fee 0');
    assert(fee_growth_inside_1_X128 == 12, 'Incorrect fee 1');
}

#[test]
fn test_get_fee_growth_inside_substracts_lower_tick_if_above() {
    let mut state = STATE();
    let tick_info = TickInfo {
        liquidity_gross: 0,
        liquidity_net: IntegerTrait::<i128>::new(0, false),
        fee_growth_outside_0_X128: 2,
        fee_growth_outside_1_X128: 3
    };
    state.tick_storage.set_tick(IntegerTrait::<i32>::new(2, true), tick_info);
    let (fee_growth_inside_0_X128, fee_growth_inside_1_X128) = state
        .tick_storage
        .get_fee_growth_inside(
            IntegerTrait::<i32>::new(2, true),
            IntegerTrait::<i32>::new(2, false),
            IntegerTrait::<i32>::new(0, false),
            15,
            15
        );
    assert(fee_growth_inside_0_X128 == 13, 'Incorrect fee 0');
    assert(fee_growth_inside_1_X128 == 12, 'Incorrect fee 1');
}

#[test]
fn test_get_fee_growth_inside_substracts_upper_and_lower_tick_if_inside() {
    let mut state = STATE();
    let tick_info = TickInfo {
        liquidity_gross: 0,
        liquidity_net: IntegerTrait::<i128>::new(0, false),
        fee_growth_outside_0_X128: 2,
        fee_growth_outside_1_X128: 3
    };
    state.tick_storage.set_tick(IntegerTrait::<i32>::new(2, true), tick_info);
    let tick_info = TickInfo {
        liquidity_gross: 0,
        liquidity_net: IntegerTrait::<i128>::new(0, false),
        fee_growth_outside_0_X128: 4,
        fee_growth_outside_1_X128: 1
    };
    state.tick_storage.set_tick(IntegerTrait::<i32>::new(2, false), tick_info);
    let (fee_growth_inside_0_X128, fee_growth_inside_1_X128) = state
        .tick_storage
        .get_fee_growth_inside(
            IntegerTrait::<i32>::new(2, true),
            IntegerTrait::<i32>::new(2, false),
            IntegerTrait::<i32>::new(0, false),
            15,
            15
        );
    assert(fee_growth_inside_0_X128 == 9, 'Incorrect fee 0');
    assert(fee_growth_inside_1_X128 == 11, 'Incorrect fee 1');
}

#[test]
fn test_get_fee_growth_inside_works_correctly_with_overflow_on_inside_tick() {
    let mut state = STATE();
    let tick_info = TickInfo {
        liquidity_gross: 0,
        liquidity_net: IntegerTrait::<i128>::new(0, false),
        fee_growth_outside_0_X128: BoundedInt::max() - 3,
        fee_growth_outside_1_X128: BoundedInt::max() - 2
    };
    state.tick_storage.set_tick(IntegerTrait::<i32>::new(2, true), tick_info);
    let tick_info = TickInfo {
        liquidity_gross: 0,
        liquidity_net: IntegerTrait::<i128>::new(0, false),
        fee_growth_outside_0_X128: 3,
        fee_growth_outside_1_X128: 5
    };
    state.tick_storage.set_tick(IntegerTrait::<i32>::new(2, false), tick_info);
    let (fee_growth_inside_0_X128, fee_growth_inside_1_X128) = state
        .tick_storage
        .get_fee_growth_inside(
            IntegerTrait::<i32>::new(2, true),
            IntegerTrait::<i32>::new(2, false),
            IntegerTrait::<i32>::new(0, false),
            15,
            15
        );
    assert(fee_growth_inside_0_X128 == 16, 'Incorrect fee 0');
    assert(fee_growth_inside_1_X128 == 13, 'Incorrect fee 1');
}

#[test]
fn test_update_flips_from_zero_to_nonzero() {
    let mut state = STATE();
    let updated = state
        .tick_storage
        .update(
            IntegerTrait::<i32>::new(0, false),
            IntegerTrait::<i32>::new(0, false),
            IntegerTrait::<i128>::new(1, false),
            0,
            0,
            false,
            3
        );
    assert(updated, 'Incorrect updated');
}

#[test]
fn test_update_does_not_flip_from_nonzero_to_greater_nonzero() {
    let mut state = STATE();
    state
        .tick_storage
        .update(
            IntegerTrait::<i32>::new(0, false),
            IntegerTrait::<i32>::new(0, false),
            IntegerTrait::<i128>::new(1, false),
            0,
            0,
            false,
            3
        );
    let updated = state
        .tick_storage
        .update(
            IntegerTrait::<i32>::new(0, false),
            IntegerTrait::<i32>::new(0, false),
            IntegerTrait::<i128>::new(1, false),
            0,
            0,
            false,
            3
        );
    assert(!updated, 'Incorrect updated');
}

#[test]
fn test_update_flips_from_nonzero_to_zero() {
    let mut state = STATE();
    state
        .tick_storage
        .update(
            IntegerTrait::<i32>::new(0, false),
            IntegerTrait::<i32>::new(0, false),
            IntegerTrait::<i128>::new(1, false),
            0,
            0,
            false,
            3
        );
    let updated = state
        .tick_storage
        .update(
            IntegerTrait::<i32>::new(0, false),
            IntegerTrait::<i32>::new(0, false),
            IntegerTrait::<i128>::new(1, true),
            0,
            0,
            false,
            3
        );
    assert(updated, 'Incorrect updated');
}

#[test]
fn test_update_does_not_flip_from_nonzero_to_lesser_nonzero() {
    let mut state = STATE();
    state
        .tick_storage
        .update(
            IntegerTrait::<i32>::new(0, false),
            IntegerTrait::<i32>::new(0, false),
            IntegerTrait::<i128>::new(2, false),
            0,
            0,
            false,
            3
        );
    let updated = state
        .tick_storage
        .update(
            IntegerTrait::<i32>::new(0, false),
            IntegerTrait::<i32>::new(0, false),
            IntegerTrait::<i128>::new(1, true),
            0,
            0,
            false,
            3
        );
    assert(!updated, 'Incorrect updated');
}

#[test]
#[should_panic(expected: ('LO',))]
fn test_update_reverts_if_total_liquidity_gross_is_greater_than_max() {
    let mut state = STATE();
    state
        .tick_storage
        .update(
            IntegerTrait::<i32>::new(0, false),
            IntegerTrait::<i32>::new(0, false),
            IntegerTrait::<i128>::new(2, false),
            0,
            0,
            false,
            3
        );
    state
        .tick_storage
        .update(
            IntegerTrait::<i32>::new(0, false),
            IntegerTrait::<i32>::new(0, false),
            IntegerTrait::<i128>::new(1, false),
            0,
            0,
            true,
            3
        );
    state
        .tick_storage
        .update(
            IntegerTrait::<i32>::new(0, false),
            IntegerTrait::<i32>::new(0, false),
            IntegerTrait::<i128>::new(1, false),
            0,
            0,
            false,
            3
        );
}

#[test]
fn test_update_nets_the_liquidity_based_on_upper_tick() {
    let mut state = STATE();
    state
        .tick_storage
        .update(
            IntegerTrait::<i32>::new(0, false),
            IntegerTrait::<i32>::new(0, false),
            IntegerTrait::<i128>::new(2, false),
            0,
            0,
            false,
            10
        );
    state
        .tick_storage
        .update(
            IntegerTrait::<i32>::new(0, false),
            IntegerTrait::<i32>::new(0, false),
            IntegerTrait::<i128>::new(1, false),
            0,
            0,
            true,
            10
        );
    state
        .tick_storage
        .update(
            IntegerTrait::<i32>::new(0, false),
            IntegerTrait::<i32>::new(0, false),
            IntegerTrait::<i128>::new(3, false),
            0,
            0,
            true,
            10
        );
    state
        .tick_storage
        .update(
            IntegerTrait::<i32>::new(0, false),
            IntegerTrait::<i32>::new(0, false),
            IntegerTrait::<i128>::new(1, false),
            0,
            0,
            false,
            10
        );
    let tick_info = state.tick_storage.get_tick(IntegerTrait::<i32>::new(0, false));
    assert(tick_info.liquidity_gross == 2 + 1 + 3 + 1, 'Incorrect liquidity_gross');
    assert(
        tick_info.liquidity_net == IntegerTrait::<i128>::new(2, false)
            + IntegerTrait::<i128>::new(1, true)
            + IntegerTrait::<i128>::new(3, true)
            + IntegerTrait::<i128>::new(1, false),
        'Incorrect liquidity_net'
    );
}

#[test]
#[should_panic(expected: ('int: out of range',))]
fn test_update_reverts_on_overflow_liquidity_gross() {
    let mut state = STATE();
    state
        .tick_storage
        .update(
            IntegerTrait::<i32>::new(0, false),
            IntegerTrait::<i32>::new(0, false),
            IntegerTrait::<i128>::new((BoundedInt::max() / 2) - 1, false),
            0,
            0,
            false,
            BoundedInt::max()
        );
    state
        .tick_storage
        .update(
            IntegerTrait::<i32>::new(0, false),
            IntegerTrait::<i32>::new(0, false),
            IntegerTrait::<i128>::new((BoundedInt::max() / 2) - 1, false),
            0,
            0,
            false,
            BoundedInt::max()
        );
}

#[test]
fn test_update_assumes_all_growth_happens_below_ticks_lte_current_tick() {
    let mut state = STATE();
    state
        .tick_storage
        .update(
            IntegerTrait::<i32>::new(1, false),
            IntegerTrait::<i32>::new(1, false),
            IntegerTrait::<i128>::new(1, false),
            1,
            2,
            false,
            BoundedInt::max()
        );
    let tick_info = state.tick_storage.get_tick(IntegerTrait::<i32>::new(1, false));
    assert(tick_info.fee_growth_outside_0_X128 == 1, 'Incorrect fee 0');
    assert(tick_info.fee_growth_outside_1_X128 == 2, 'Incorrect fee 0');
}

#[test]
fn test_update_does_not_set_any_growth_fields_if_tick_is_already_initialized() {
    let mut state = STATE();
    state
        .tick_storage
        .update(
            IntegerTrait::<i32>::new(1, false),
            IntegerTrait::<i32>::new(1, false),
            IntegerTrait::<i128>::new(1, false),
            1,
            2,
            false,
            BoundedInt::max()
        );
    state
        .tick_storage
        .update(
            IntegerTrait::<i32>::new(1, false),
            IntegerTrait::<i32>::new(1, false),
            IntegerTrait::<i128>::new(1, false),
            6,
            7,
            false,
            BoundedInt::max()
        );
    let tick_info = state.tick_storage.get_tick(IntegerTrait::<i32>::new(1, false));
    assert(tick_info.fee_growth_outside_0_X128 == 1, 'Incorrect fee 0');
    assert(tick_info.fee_growth_outside_1_X128 == 2, 'Incorrect fee 0');
}

#[test]
fn test_update_does_not_set_any_growth_fields_for_ticks_greater_than_current_tick() {
    let mut state = STATE();
    state
        .tick_storage
        .update(
            IntegerTrait::<i32>::new(1, false),
            IntegerTrait::<i32>::new(1, false),
            IntegerTrait::<i128>::new(1, false),
            1,
            2,
            false,
            BoundedInt::max()
        );
    state
        .tick_storage
        .update(
            IntegerTrait::<i32>::new(1, false),
            IntegerTrait::<i32>::new(1, false),
            IntegerTrait::<i128>::new(1, false),
            6,
            7,
            false,
            BoundedInt::max()
        );
    let tick_info = state.tick_storage.get_tick(IntegerTrait::<i32>::new(2, false));
    assert(tick_info.fee_growth_outside_0_X128 == 0, 'Incorrect fee 0');
    assert(tick_info.fee_growth_outside_1_X128 == 0, 'Incorrect fee 0');
}

#[test]
fn test_clear_deletes_all_the_data_in_the_tick() {
    let mut state = STATE();
    let tick_info = TickInfo {
        liquidity_gross: 3,
        liquidity_net: IntegerTrait::<i128>::new(4, false),
        fee_growth_outside_0_X128: 1,
        fee_growth_outside_1_X128: 2
    };
    state.tick_storage.set_tick(IntegerTrait::<i32>::new(2, false), tick_info);
    state.tick_storage.clear(IntegerTrait::<i32>::new(2, false));
    let tick_info = state.tick_storage.get_tick(IntegerTrait::<i32>::new(2, false));
    assert(tick_info.fee_growth_outside_0_X128 == 0, 'Incorrect fee 0');
    assert(tick_info.fee_growth_outside_1_X128 == 0, 'Incorrect fee 0');
    assert(tick_info.liquidity_gross == 0, 'Incorrect liquidity_gross');
    assert(
        tick_info.liquidity_net == IntegerTrait::<i128>::new(0, false), 'Incorrect liquidity_net'
    );
}

#[test]
fn test_cross_flips_the_growth_variables() {
    let mut state = STATE();
    let tick_info = TickInfo {
        liquidity_gross: 3,
        liquidity_net: IntegerTrait::<i128>::new(4, false),
        fee_growth_outside_0_X128: 1,
        fee_growth_outside_1_X128: 2
    };
    state.tick_storage.set_tick(IntegerTrait::<i32>::new(2, false), tick_info);
    state.tick_storage.cross(IntegerTrait::<i32>::new(2, false), 7, 9);
    let tick_info = state.tick_storage.get_tick(IntegerTrait::<i32>::new(2, false));
    assert(tick_info.fee_growth_outside_0_X128 == 6, 'Incorrect fee 0');
    assert(tick_info.fee_growth_outside_1_X128 == 7, 'Incorrect fee 0');
}

#[test]
fn test_cross_two_flips_are_no_op() {
    let mut state = STATE();
    let tick_info = TickInfo {
        liquidity_gross: 3,
        liquidity_net: IntegerTrait::<i128>::new(4, false),
        fee_growth_outside_0_X128: 1,
        fee_growth_outside_1_X128: 2
    };
    state.tick_storage.set_tick(IntegerTrait::<i32>::new(2, false), tick_info);
    state.tick_storage.cross(IntegerTrait::<i32>::new(2, false), 7, 9);
    state.tick_storage.cross(IntegerTrait::<i32>::new(2, false), 7, 9);
    let tick_info = state.tick_storage.get_tick(IntegerTrait::<i32>::new(2, false));
    assert(tick_info.fee_growth_outside_0_X128 == 1, 'Incorrect fee 0');
    assert(tick_info.fee_growth_outside_1_X128 == 2, 'Incorrect fee 0');
}
