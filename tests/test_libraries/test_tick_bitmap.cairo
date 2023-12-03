use array::ArrayTrait;
use starknet::{ ContractAddress };
use traits::{ Into, TryInto };
use option::OptionTrait;
use integer::{BoundedInt};
use yas_core::numbers::signed_integer::{i32::i32, integer_trait::IntegerTrait};
use snforge_std::{ declare, ContractClassTrait };

#[starknet::interface]
trait ITickBitmap<T> {
    fn next_initialized_tick_within_one_word(self: @T, pool_hash: felt252, tick: i32, tick_spacing: i32, search_left: bool) -> (i32, bool);
    fn flip_tick(ref self: T, pool_hash: felt252, tick: i32, tick_spacing: i32);
}

//TODO Use setup when available

fn get_tick_bitmap_dispatcher() ->  ITickBitmapDispatcher {
    let tick_bitmap_class = declare('TickBitmap');
    let tick_bitmap_address = tick_bitmap_class.deploy(@ArrayTrait::new()).unwrap();
    let tick_bitmap_dispatcher = ITickBitmapDispatcher { contract_address: tick_bitmap_address };
    tick_bitmap_dispatcher
}

fn is_initialized(tick_bitmap_dispatcher: ITickBitmapDispatcher, tick: i32) -> bool {
    let (next, initialized) = tick_bitmap_dispatcher.next_initialized_tick_within_one_word('pool_hash', tick, IntegerTrait::<i32>::new(1, false), true);
    if (next == tick) {
        return initialized;
    } else {
        return false;
    }
}

fn flip_tick(tick_bitmap_dispatcher: ITickBitmapDispatcher, tick: i32) {
    tick_bitmap_dispatcher.flip_tick('pool_hash', tick, IntegerTrait::<i32>::new(1, false));
}

fn flip_ticks(tick_bitmap_dispatcher: ITickBitmapDispatcher) {
    flip_tick(tick_bitmap_dispatcher, IntegerTrait::<i32>::new(10000, true));
    flip_tick(tick_bitmap_dispatcher, IntegerTrait::<i32>::new(200, true));
    flip_tick(tick_bitmap_dispatcher, IntegerTrait::<i32>::new(55, true));
    flip_tick(tick_bitmap_dispatcher, IntegerTrait::<i32>::new(4, true));
    flip_tick(tick_bitmap_dispatcher, IntegerTrait::<i32>::new(70, false));
    flip_tick(tick_bitmap_dispatcher, IntegerTrait::<i32>::new(78, false));
    flip_tick(tick_bitmap_dispatcher, IntegerTrait::<i32>::new(84, false));
    flip_tick(tick_bitmap_dispatcher, IntegerTrait::<i32>::new(139, false));
    flip_tick(tick_bitmap_dispatcher, IntegerTrait::<i32>::new(240, false));
    flip_tick(tick_bitmap_dispatcher, IntegerTrait::<i32>::new(535, false));
}

#[test]
fn test_is_initialized_is_false_at_first() {
    let tick_bitmap_dispatcher = get_tick_bitmap_dispatcher();

    assert(!is_initialized(tick_bitmap_dispatcher, IntegerTrait::<i32>::new(1, false)), 'Initialized');
}

#[test]
fn test_is_initialized_is_flipped_by_flip_tick() {
    let tick_bitmap_dispatcher = get_tick_bitmap_dispatcher();

    flip_tick(tick_bitmap_dispatcher, IntegerTrait::<i32>::new(1, false));

    assert(is_initialized(tick_bitmap_dispatcher, IntegerTrait::<i32>::new(1, false)), 'Not Initialized');
}

#[test]
fn test_is_initialized_is_flipped_back_by_flip_tick() {
    let tick_bitmap_dispatcher = get_tick_bitmap_dispatcher();

    flip_tick(tick_bitmap_dispatcher, IntegerTrait::<i32>::new(1, false));
    flip_tick(tick_bitmap_dispatcher, IntegerTrait::<i32>::new(1, false));

    assert(!is_initialized(tick_bitmap_dispatcher, IntegerTrait::<i32>::new(1, false)), 'Not Flipped');
}

#[test]
fn test_is_initialized_is_not_changed_by_flip_to_different_tick() {
    let tick_bitmap_dispatcher = get_tick_bitmap_dispatcher();

    flip_tick(tick_bitmap_dispatcher, IntegerTrait::<i32>::new(2, false));

    assert(!is_initialized(tick_bitmap_dispatcher, IntegerTrait::<i32>::new(1, false)), 'Flipped');
}

#[test]
fn test_is_initialized_is_not_changed_by_flip_to_different_tick_on_another_word() {
    let tick_bitmap_dispatcher = get_tick_bitmap_dispatcher();

    flip_tick(tick_bitmap_dispatcher, IntegerTrait::<i32>::new(1 + 256, false));

    assert(is_initialized(tick_bitmap_dispatcher, IntegerTrait::<i32>::new(257, false)), 'Not Initialized');
    assert(!is_initialized(tick_bitmap_dispatcher, IntegerTrait::<i32>::new(1, false)), 'Flipped');
}

#[test]
fn test_flip_tick_flips_only_the_specified_tick() {
    let tick_bitmap_dispatcher = get_tick_bitmap_dispatcher();

    flip_tick(tick_bitmap_dispatcher, IntegerTrait::<i32>::new(230, true));

    assert(is_initialized(tick_bitmap_dispatcher, IntegerTrait::<i32>::new(230, true)), 'Not Initialized');
    assert(!is_initialized(tick_bitmap_dispatcher, IntegerTrait::<i32>::new(231, true)), 'Initialized');
    assert(!is_initialized(tick_bitmap_dispatcher, IntegerTrait::<i32>::new(229, true)), 'Initialized');
    assert(!is_initialized(tick_bitmap_dispatcher, IntegerTrait::<i32>::new(230 + 256, true)), 'Initialized');
    assert(!is_initialized(tick_bitmap_dispatcher, IntegerTrait::<i32>::new(26, false)), 'Initialized');

    flip_tick(tick_bitmap_dispatcher, IntegerTrait::<i32>::new(230, true));

    assert(!is_initialized(tick_bitmap_dispatcher, IntegerTrait::<i32>::new(230, true)), 'Initialized');
    assert(!is_initialized(tick_bitmap_dispatcher, IntegerTrait::<i32>::new(231, true)), 'Initialized');
    assert(!is_initialized(tick_bitmap_dispatcher, IntegerTrait::<i32>::new(229, true)), 'Initialized');
    assert(!is_initialized(tick_bitmap_dispatcher, IntegerTrait::<i32>::new(230 + 256, true)), 'Initialized');
    assert(!is_initialized(tick_bitmap_dispatcher, IntegerTrait::<i32>::new(26, false)), 'Initialized');
}

#[test]
fn test_flip_tick_reverts_only_itself() {
    let tick_bitmap_dispatcher = get_tick_bitmap_dispatcher();

    flip_tick(tick_bitmap_dispatcher, IntegerTrait::<i32>::new(259, true));
    flip_tick(tick_bitmap_dispatcher, IntegerTrait::<i32>::new(229, true));
    flip_tick(tick_bitmap_dispatcher, IntegerTrait::<i32>::new(500, false));
    flip_tick(tick_bitmap_dispatcher, IntegerTrait::<i32>::new(259, true));
    flip_tick(tick_bitmap_dispatcher, IntegerTrait::<i32>::new(229, true));
    flip_tick(tick_bitmap_dispatcher, IntegerTrait::<i32>::new(259, true));

    assert(is_initialized(tick_bitmap_dispatcher, IntegerTrait::<i32>::new(259, true)), 'Not Initialized');
    assert(!is_initialized(tick_bitmap_dispatcher, IntegerTrait::<i32>::new(229, true)), 'Initialized');
    assert(is_initialized(tick_bitmap_dispatcher, IntegerTrait::<i32>::new(500, false)), 'Not Initialized');
}

#[test]
fn test_next_initialized_tick_within_one_word_search_left_false_returns_tick_to_right_if_at_initialized_tick() {
    let tick_bitmap_dispatcher = get_tick_bitmap_dispatcher();
    
    flip_ticks(tick_bitmap_dispatcher);

    let (next, initialized) = tick_bitmap_dispatcher.next_initialized_tick_within_one_word('pool_hash', IntegerTrait::<i32>::new(78, false), IntegerTrait::<i32>::new(1, false), false);

    assert(next == IntegerTrait::<i32>::new(84, false), 'Not 84');
    assert(initialized, 'Not Initialized');
}

#[test]
fn test_next_initialized_tick_within_one_word_search_left_false_returns_tick_to_right_if_at_initialized_tick_2() {
    let tick_bitmap_dispatcher = get_tick_bitmap_dispatcher();
    
    flip_ticks(tick_bitmap_dispatcher);

    let (next, initialized) = tick_bitmap_dispatcher.next_initialized_tick_within_one_word('pool_hash', IntegerTrait::<i32>::new(55, true), IntegerTrait::<i32>::new(1, false), false);

    assert(next == IntegerTrait::<i32>::new(4, true), 'Not -4');
    assert(initialized, 'Not Initialized');
}

#[test]
fn test_next_initialized_tick_within_one_word_search_left_false_returns_tick_directly_to_the_right() {
    let tick_bitmap_dispatcher = get_tick_bitmap_dispatcher();
    
    flip_ticks(tick_bitmap_dispatcher);

    let (next, initialized) = tick_bitmap_dispatcher.next_initialized_tick_within_one_word('pool_hash', IntegerTrait::<i32>::new(77, false), IntegerTrait::<i32>::new(1, false), false);

    assert(next == IntegerTrait::<i32>::new(78, false), 'Not 78');
    assert(initialized, 'Not Initialized');
}

#[test]
fn test_next_initialized_tick_within_one_word_search_left_false_returns_tick_directly_to_the_right_2() {
    let tick_bitmap_dispatcher = get_tick_bitmap_dispatcher();
    
    flip_ticks(tick_bitmap_dispatcher);

    let (next, initialized) = tick_bitmap_dispatcher.next_initialized_tick_within_one_word('pool_hash', IntegerTrait::<i32>::new(56, true), IntegerTrait::<i32>::new(1, false), false);

    assert(next == IntegerTrait::<i32>::new(55, true), 'Not -55');
    assert(initialized, 'Not Initialized');
}

#[test]
fn test_next_initialized_tick_within_one_word_search_left_false_returns_the_next_words_initialized_tick_if_on_the_right_boundary() {
    let tick_bitmap_dispatcher = get_tick_bitmap_dispatcher();
    
    flip_ticks(tick_bitmap_dispatcher);

    let (next, initialized) = tick_bitmap_dispatcher.next_initialized_tick_within_one_word('pool_hash', IntegerTrait::<i32>::new(255, false), IntegerTrait::<i32>::new(1, false), false);

    assert(next == IntegerTrait::<i32>::new(511, false), 'Not 511');
    assert(!initialized, 'Initialized');
}

#[test]
fn test_next_initialized_tick_within_one_word_search_left_false_returns_the_next_words_initialized_tick_if_on_the_right_boundary_2() {
    let tick_bitmap_dispatcher = get_tick_bitmap_dispatcher();
    
    flip_ticks(tick_bitmap_dispatcher);

    let (next, initialized) = tick_bitmap_dispatcher.next_initialized_tick_within_one_word('pool_hash', IntegerTrait::<i32>::new(257, true), IntegerTrait::<i32>::new(1, false), false);

    assert(next == IntegerTrait::<i32>::new(200, true), 'Not -200');
    assert(initialized, 'Not Initialized');
}

#[test]
fn test_next_initialized_tick_within_one_word_search_left_false_returns_the_next_initialized_tick_from_the_next_word() {
    let tick_bitmap_dispatcher = get_tick_bitmap_dispatcher();
    
    flip_ticks(tick_bitmap_dispatcher);
    flip_tick(tick_bitmap_dispatcher, IntegerTrait::<i32>::new(340, false));

    let (next, initialized) = tick_bitmap_dispatcher.next_initialized_tick_within_one_word('pool_hash', IntegerTrait::<i32>::new(328, false), IntegerTrait::<i32>::new(1, false), false);

    assert(next == IntegerTrait::<i32>::new(340, false), 'Not 340');
    assert(initialized, 'Not Initialized');
}

#[test]
fn test_next_initialized_tick_within_one_word_search_left_false_does_not_exceed_boundary() {
    let tick_bitmap_dispatcher = get_tick_bitmap_dispatcher();
    
    flip_ticks(tick_bitmap_dispatcher);

    let (next, initialized) = tick_bitmap_dispatcher.next_initialized_tick_within_one_word('pool_hash', IntegerTrait::<i32>::new(508, false), IntegerTrait::<i32>::new(1, false), false);

    assert(next == IntegerTrait::<i32>::new(511, false), 'Not 511');
    assert(!initialized, 'Initialized');
}

#[test]
fn test_next_initialized_tick_within_one_word_search_left_false_skips_entire_word() {
    let tick_bitmap_dispatcher = get_tick_bitmap_dispatcher();
    
    flip_ticks(tick_bitmap_dispatcher);

    let (next, initialized) = tick_bitmap_dispatcher.next_initialized_tick_within_one_word('pool_hash', IntegerTrait::<i32>::new(255, false), IntegerTrait::<i32>::new(1, false), false);

    assert(next == IntegerTrait::<i32>::new(511, false), 'Not 511');
    assert(!initialized, 'Initialized');
}

#[test]
fn test_next_initialized_tick_within_one_word_search_left_false_skips_half_word() {
    let tick_bitmap_dispatcher = get_tick_bitmap_dispatcher();
    
    flip_ticks(tick_bitmap_dispatcher);

    let (next, initialized) = tick_bitmap_dispatcher.next_initialized_tick_within_one_word('pool_hash', IntegerTrait::<i32>::new(383, false), IntegerTrait::<i32>::new(1, false), false);

    assert(next == IntegerTrait::<i32>::new(511, false), 'Not 511');
    assert(!initialized, 'Initialized');
}

#[test]
fn test_next_initialized_tick_within_one_word_search_left_true_returns_same_tick_if_initialized() {
    let tick_bitmap_dispatcher = get_tick_bitmap_dispatcher();
    
    flip_ticks(tick_bitmap_dispatcher);

    let (next, initialized) = tick_bitmap_dispatcher.next_initialized_tick_within_one_word('pool_hash', IntegerTrait::<i32>::new(78, false), IntegerTrait::<i32>::new(1, false), true);

    assert(next == IntegerTrait::<i32>::new(78, false), 'Not 78');
    assert(initialized, 'Not Initialized');
}

#[test]
fn test_next_initialized_tick_within_one_word_search_left_true_returns_tick_directly_to_the_left_if_not_initialized() {
    let tick_bitmap_dispatcher = get_tick_bitmap_dispatcher();
    
    flip_ticks(tick_bitmap_dispatcher);

    let (next, initialized) = tick_bitmap_dispatcher.next_initialized_tick_within_one_word('pool_hash', IntegerTrait::<i32>::new(79, false), IntegerTrait::<i32>::new(1, false), true);

    assert(next == IntegerTrait::<i32>::new(78, false), 'Not 78');
    assert(initialized, 'Not Initialized');
}

#[test]
fn test_next_initialized_tick_within_one_word_search_left_true_will_not_exceed_the_word_boundary() {
    let tick_bitmap_dispatcher = get_tick_bitmap_dispatcher();
    
    flip_ticks(tick_bitmap_dispatcher);

    let (next, initialized) = tick_bitmap_dispatcher.next_initialized_tick_within_one_word('pool_hash', IntegerTrait::<i32>::new(258, false), IntegerTrait::<i32>::new(1, false), true);

    assert(next == IntegerTrait::<i32>::new(256, false), 'Not 256');
    assert(!initialized, 'Initialized');
}

#[test]
fn test_next_initialized_tick_within_one_word_search_left_true_at_the_word_boundary() {
    let tick_bitmap_dispatcher = get_tick_bitmap_dispatcher();
    
    flip_ticks(tick_bitmap_dispatcher);

    let (next, initialized) = tick_bitmap_dispatcher.next_initialized_tick_within_one_word('pool_hash', IntegerTrait::<i32>::new(256, false), IntegerTrait::<i32>::new(1, false), true);

    assert(next == IntegerTrait::<i32>::new(256, false), 'Not 256');
    assert(!initialized, 'Initialized');
}

#[test]
fn test_next_initialized_tick_within_one_word_search_left_true_at_the_word_boundary_right() {
    let tick_bitmap_dispatcher = get_tick_bitmap_dispatcher();
    
    flip_ticks(tick_bitmap_dispatcher);

    let (next, initialized) = tick_bitmap_dispatcher.next_initialized_tick_within_one_word('pool_hash', IntegerTrait::<i32>::new(257, true), IntegerTrait::<i32>::new(1, false), true);

    assert(next == IntegerTrait::<i32>::new(512, true), 'Not -512');
    assert(!initialized, 'Initialized');
}

#[test]
fn test_next_initialized_tick_within_one_word_search_left_true_entire_empty_word() {
    let tick_bitmap_dispatcher = get_tick_bitmap_dispatcher();
    
    flip_ticks(tick_bitmap_dispatcher);

    let (next, initialized) = tick_bitmap_dispatcher.next_initialized_tick_within_one_word('pool_hash', IntegerTrait::<i32>::new(1023, false), IntegerTrait::<i32>::new(1, false), true);

    assert(next == IntegerTrait::<i32>::new(768, false), 'Not 768');
    assert(!initialized, 'Initialized');
}

#[test]
fn test_next_initialized_tick_within_one_word_search_left_true_halfway_through_empty_word() {
    let tick_bitmap_dispatcher = get_tick_bitmap_dispatcher();
    
    flip_ticks(tick_bitmap_dispatcher);

    let (next, initialized) = tick_bitmap_dispatcher.next_initialized_tick_within_one_word('pool_hash', IntegerTrait::<i32>::new(900, false), IntegerTrait::<i32>::new(1, false), true);

    assert(next == IntegerTrait::<i32>::new(768, false), 'Not 768');
    assert(!initialized, 'Initialized');
}