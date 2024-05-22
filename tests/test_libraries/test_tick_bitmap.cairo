use jediswap_v2_core::libraries::tick_bitmap::TickBitmapComponent::{TickBitmap, InternalImpl};
use jediswap_v2_core::libraries::signed_integers::{i32::i32, integer_trait::IntegerTrait};

#[starknet::contract]
mod TickBitmapMock {
    use jediswap_v2_core::libraries::tick_bitmap::TickBitmapComponent;

    component!(path: TickBitmapComponent, storage: tick_bitmap_storage, event: TickBitmapEvent);

    #[abi(embed_v0)]
    impl TickBitmapImpl = TickBitmapComponent::TickBitmap<ContractState>;

    impl TickBitmapInternalImpl = TickBitmapComponent::InternalImpl<ContractState>;

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        #[flat]
        TickBitmapEvent: TickBitmapComponent::Event
    }

    #[storage]
    struct Storage {
        #[substorage(v0)]
        tick_bitmap_storage: TickBitmapComponent::Storage
    }
}

fn STATE() -> TickBitmapMock::ContractState {
    TickBitmapMock::contract_state_for_testing()
}

fn flip_tick(mut state: TickBitmapMock::ContractState, tick: i32) -> TickBitmapMock::ContractState {
    state.tick_bitmap_storage.flip_tick(tick, 1);
    state
}

fn flip_ticks(mut state: TickBitmapMock::ContractState) -> TickBitmapMock::ContractState {
    state = flip_tick(state, IntegerTrait::<i32>::new(10000, true));
    state = flip_tick(state, IntegerTrait::<i32>::new(200, true));
    state = flip_tick(state, IntegerTrait::<i32>::new(55, true));
    state = flip_tick(state, IntegerTrait::<i32>::new(4, true));
    state = flip_tick(state, IntegerTrait::<i32>::new(70, false));
    state = flip_tick(state, IntegerTrait::<i32>::new(78, false));
    state = flip_tick(state, IntegerTrait::<i32>::new(84, false));
    state = flip_tick(state, IntegerTrait::<i32>::new(139, false));
    state = flip_tick(state, IntegerTrait::<i32>::new(240, false));
    state = flip_tick(state, IntegerTrait::<i32>::new(535, false));
    state
}

#[test]
fn test_is_initialized_is_false_at_first() {
    let mut state = STATE();
    assert(
        !state.tick_bitmap_storage.is_initialized(IntegerTrait::<i32>::new(1, false)), 'Initialized'
    );
}

#[test]
fn test_is_initialized_is_flipped_by_flip_tick() {
    let mut state = STATE();

    state = flip_tick(state, IntegerTrait::<i32>::new(1, false));

    assert(
        state.tick_bitmap_storage.is_initialized(IntegerTrait::<i32>::new(1, false)),
        'Not Initialized'
    );
}

#[test]
fn test_is_initialized_is_flipped_back_by_flip_tick() {
    let mut state = STATE();

    state = flip_tick(state, IntegerTrait::<i32>::new(1, false));
    state = flip_tick(state, IntegerTrait::<i32>::new(1, false));

    assert(
        !state.tick_bitmap_storage.is_initialized(IntegerTrait::<i32>::new(1, false)), 'Not Flipped'
    );
}

#[test]
fn test_is_initialized_is_not_changed_by_flip_to_different_tick() {
    let mut state = STATE();

    state = flip_tick(state, IntegerTrait::<i32>::new(2, false));

    assert(
        !state.tick_bitmap_storage.is_initialized(IntegerTrait::<i32>::new(1, false)), 'Flipped'
    );
}

#[test]
fn test_is_initialized_is_not_changed_by_flip_to_different_tick_on_another_word() {
    let mut state = STATE();

    state = flip_tick(state, IntegerTrait::<i32>::new(1 + 256, false));

    assert(
        state.tick_bitmap_storage.is_initialized(IntegerTrait::<i32>::new(257, false)),
        'Not Initialized'
    );
    assert(
        !state.tick_bitmap_storage.is_initialized(IntegerTrait::<i32>::new(1, false)), 'Flipped'
    );
}

#[test]
fn test_flip_tick_flips_only_the_specified_tick() {
    let mut state = STATE();

    state = flip_tick(state, IntegerTrait::<i32>::new(230, true));

    assert(
        state.tick_bitmap_storage.is_initialized(IntegerTrait::<i32>::new(230, true)),
        'Not Initialized'
    );
    assert(
        !state.tick_bitmap_storage.is_initialized(IntegerTrait::<i32>::new(231, true)),
        'Initialized'
    );
    assert(
        !state.tick_bitmap_storage.is_initialized(IntegerTrait::<i32>::new(229, true)),
        'Initialized'
    );
    assert(
        !state.tick_bitmap_storage.is_initialized(IntegerTrait::<i32>::new(230 + 256, true)),
        'Initialized'
    );
    assert(
        !state.tick_bitmap_storage.is_initialized(IntegerTrait::<i32>::new(26, false)),
        'Initialized'
    );

    state = flip_tick(state, IntegerTrait::<i32>::new(230, true));

    assert(
        !state.tick_bitmap_storage.is_initialized(IntegerTrait::<i32>::new(230, true)),
        'Initialized'
    );
    assert(
        !state.tick_bitmap_storage.is_initialized(IntegerTrait::<i32>::new(231, true)),
        'Initialized'
    );
    assert(
        !state.tick_bitmap_storage.is_initialized(IntegerTrait::<i32>::new(229, true)),
        'Initialized'
    );
    assert(
        !state.tick_bitmap_storage.is_initialized(IntegerTrait::<i32>::new(230 + 256, true)),
        'Initialized'
    );
    assert(
        !state.tick_bitmap_storage.is_initialized(IntegerTrait::<i32>::new(26, false)),
        'Initialized'
    );
}

#[test]
fn test_flip_tick_reverts_only_itself() {
    let mut state = STATE();

    state = flip_tick(state, IntegerTrait::<i32>::new(259, true));
    state = flip_tick(state, IntegerTrait::<i32>::new(229, true));
    state = flip_tick(state, IntegerTrait::<i32>::new(500, false));
    state = flip_tick(state, IntegerTrait::<i32>::new(259, true));
    state = flip_tick(state, IntegerTrait::<i32>::new(229, true));
    state = flip_tick(state, IntegerTrait::<i32>::new(259, true));

    assert(
        state.tick_bitmap_storage.is_initialized(IntegerTrait::<i32>::new(259, true)),
        'Not Initialized'
    );
    assert(
        !state.tick_bitmap_storage.is_initialized(IntegerTrait::<i32>::new(229, true)),
        'Initialized'
    );
    assert(
        state.tick_bitmap_storage.is_initialized(IntegerTrait::<i32>::new(500, false)),
        'Not Initialized'
    );
}

#[test]
fn test_next_initialized_tick_within_one_word_search_left_false_returns_tick_to_right_if_at_initialized_tick() {
    let mut state = STATE();

    state = flip_ticks(state);

    let (next, initialized) = state
        .tick_bitmap_storage
        .next_initialized_tick_within_one_word(IntegerTrait::<i32>::new(78, false), 1, false);

    assert(next == IntegerTrait::<i32>::new(84, false), 'Not 84');
    assert(initialized, 'Not Initialized');
}

#[test]
fn test_next_initialized_tick_within_one_word_search_left_false_returns_tick_to_right_if_at_initialized_tick_2() {
    let mut state = STATE();

    state = flip_ticks(state);

    let (next, initialized) = state
        .tick_bitmap_storage
        .next_initialized_tick_within_one_word(IntegerTrait::<i32>::new(55, true), 1, false);

    assert(next == IntegerTrait::<i32>::new(4, true), 'Not -4');
    assert(initialized, 'Not Initialized');
}

#[test]
fn test_next_initialized_tick_within_one_word_search_left_false_returns_tick_directly_to_the_right() {
    let mut state = STATE();

    state = flip_ticks(state);

    let (next, initialized) = state
        .tick_bitmap_storage
        .next_initialized_tick_within_one_word(IntegerTrait::<i32>::new(77, false), 1, false);

    assert(next == IntegerTrait::<i32>::new(78, false), 'Not 78');
    assert(initialized, 'Not Initialized');
}

#[test]
fn test_next_initialized_tick_within_one_word_search_left_false_returns_tick_directly_to_the_right_2() {
    let mut state = STATE();

    state = flip_ticks(state);

    let (next, initialized) = state
        .tick_bitmap_storage
        .next_initialized_tick_within_one_word(IntegerTrait::<i32>::new(56, true), 1, false);

    assert(next == IntegerTrait::<i32>::new(55, true), 'Not -55');
    assert(initialized, 'Not Initialized');
}

#[test]
fn test_next_initialized_tick_within_one_word_search_left_false_returns_the_next_words_initialized_tick_if_on_the_right_boundary() {
    let mut state = STATE();

    state = flip_ticks(state);

    let (next, initialized) = state
        .tick_bitmap_storage
        .next_initialized_tick_within_one_word(IntegerTrait::<i32>::new(255, false), 1, false);

    assert(next == IntegerTrait::<i32>::new(511, false), 'Not 511');
    assert(!initialized, 'Initialized');
}

#[test]
fn test_next_initialized_tick_within_one_word_search_left_false_returns_the_next_words_initialized_tick_if_on_the_right_boundary_2() {
    let mut state = STATE();

    state = flip_ticks(state);

    let (next, initialized) = state
        .tick_bitmap_storage
        .next_initialized_tick_within_one_word(IntegerTrait::<i32>::new(257, true), 1, false);

    assert(next == IntegerTrait::<i32>::new(200, true), 'Not -200');
    assert(initialized, 'Not Initialized');
}

#[test]
fn test_next_initialized_tick_within_one_word_search_left_false_returns_the_next_initialized_tick_from_the_next_word() {
    let mut state = STATE();

    state = flip_ticks(state);
    state = flip_tick(state, IntegerTrait::<i32>::new(340, false));

    let (next, initialized) = state
        .tick_bitmap_storage
        .next_initialized_tick_within_one_word(IntegerTrait::<i32>::new(328, false), 1, false);

    assert(next == IntegerTrait::<i32>::new(340, false), 'Not 340');
    assert(initialized, 'Not Initialized');
}

#[test]
fn test_next_initialized_tick_within_one_word_search_left_false_does_not_exceed_boundary() {
    let mut state = STATE();

    state = flip_ticks(state);

    let (next, initialized) = state
        .tick_bitmap_storage
        .next_initialized_tick_within_one_word(IntegerTrait::<i32>::new(508, false), 1, false);

    assert(next == IntegerTrait::<i32>::new(511, false), 'Not 511');
    assert(!initialized, 'Initialized');
}

#[test]
fn test_next_initialized_tick_within_one_word_search_left_false_skips_entire_word() {
    let mut state = STATE();

    state = flip_ticks(state);

    let (next, initialized) = state
        .tick_bitmap_storage
        .next_initialized_tick_within_one_word(IntegerTrait::<i32>::new(255, false), 1, false);

    assert(next == IntegerTrait::<i32>::new(511, false), 'Not 511');
    assert(!initialized, 'Initialized');
}

#[test]
fn test_next_initialized_tick_within_one_word_search_left_false_skips_half_word() {
    let mut state = STATE();

    state = flip_ticks(state);

    let (next, initialized) = state
        .tick_bitmap_storage
        .next_initialized_tick_within_one_word(IntegerTrait::<i32>::new(383, false), 1, false);

    assert(next == IntegerTrait::<i32>::new(511, false), 'Not 511');
    assert(!initialized, 'Initialized');
}

#[test]
fn test_next_initialized_tick_within_one_word_search_left_true_returns_same_tick_if_initialized() {
    let mut state = STATE();

    state = flip_ticks(state);

    let (next, initialized) = state
        .tick_bitmap_storage
        .next_initialized_tick_within_one_word(IntegerTrait::<i32>::new(78, false), 1, true);

    assert(next == IntegerTrait::<i32>::new(78, false), 'Not 78');
    assert(initialized, 'Not Initialized');
}

#[test]
fn test_next_initialized_tick_within_one_word_search_left_true_returns_tick_directly_to_the_left_if_not_initialized() {
    let mut state = STATE();

    state = flip_ticks(state);

    let (next, initialized) = state
        .tick_bitmap_storage
        .next_initialized_tick_within_one_word(IntegerTrait::<i32>::new(79, false), 1, true);

    assert(next == IntegerTrait::<i32>::new(78, false), 'Not 78');
    assert(initialized, 'Not Initialized');
}

#[test]
fn test_next_initialized_tick_within_one_word_search_left_true_will_not_exceed_the_word_boundary() {
    let mut state = STATE();

    state = flip_ticks(state);

    let (next, initialized) = state
        .tick_bitmap_storage
        .next_initialized_tick_within_one_word(IntegerTrait::<i32>::new(258, false), 1, true);

    assert(next == IntegerTrait::<i32>::new(256, false), 'Not 256');
    assert(!initialized, 'Initialized');
}

#[test]
fn test_next_initialized_tick_within_one_word_search_left_true_at_the_word_boundary() {
    let mut state = STATE();

    state = flip_ticks(state);

    let (next, initialized) = state
        .tick_bitmap_storage
        .next_initialized_tick_within_one_word(IntegerTrait::<i32>::new(256, false), 1, true);

    assert(next == IntegerTrait::<i32>::new(256, false), 'Not 256');
    assert(!initialized, 'Initialized');
}

#[test]
fn test_next_initialized_tick_within_one_word_search_left_true_at_the_word_boundary_right() {
    let mut state = STATE();

    state = flip_ticks(state);

    let (next, initialized) = state
        .tick_bitmap_storage
        .next_initialized_tick_within_one_word(IntegerTrait::<i32>::new(257, true), 1, true);

    assert(next == IntegerTrait::<i32>::new(512, true), 'Not -512');
    assert(!initialized, 'Initialized');
}

#[test]
fn test_next_initialized_tick_within_one_word_search_left_true_entire_empty_word() {
    let mut state = STATE();

    state = flip_ticks(state);

    let (next, initialized) = state
        .tick_bitmap_storage
        .next_initialized_tick_within_one_word(IntegerTrait::<i32>::new(1023, false), 1, true);

    assert(next == IntegerTrait::<i32>::new(768, false), 'Not 768');
    assert(!initialized, 'Initialized');
}

#[test]
fn test_next_initialized_tick_within_one_word_search_left_true_halfway_through_empty_word() {
    let mut state = STATE();

    state = flip_ticks(state);

    let (next, initialized) = state
        .tick_bitmap_storage
        .next_initialized_tick_within_one_word(IntegerTrait::<i32>::new(900, false), 1, true);

    assert(next == IntegerTrait::<i32>::new(768, false), 'Not 768');
    assert(!initialized, 'Initialized');
}
