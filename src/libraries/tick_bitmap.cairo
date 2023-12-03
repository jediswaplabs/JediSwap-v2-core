use yas_core::numbers::signed_integer::i32::i32;

#[starknet::interface]
trait ITickBitmap<TState> {
    fn next_initialized_tick_within_one_word(ref self: TState, tick: i32, tick_spacing: i32, search_left: bool) -> (i32, bool);
    fn flip_tick(ref self: TState, tick: i32, tick_spacing: i32);
}


// Packed tick initialized state library
// Stores a packed mapping of tick index to its initialized state
// The mapping uses i16 for keys since ticks are max i24 and there are 256 (2^8) values per word.
#[starknet::component]
mod TickBitmapComponent {
    use integer::BoundedInt;
    use yas_core::libraries::bit_math::BitMath;
    use yas_core::libraries::tick_bitmap::TickBitmap::position;
    use yas_core::numbers::signed_integer::{i16::i16, i32::{i32, u8Intoi32, i32TryIntoi16, i32TryIntou8, mod_i32}, integer_trait::IntegerTrait};
    use yas_core::utils::math_utils::{BitShift::BitShiftTrait, pow};

    #[storage]
    struct Storage {
        bitmap: LegacyMap<i16, u256>,    // @notice Represents initialization of the ticks in all the pools (pool_hash, word_pos, pos_mask)
    }

    #[embeddable_as(TickBitmap)]
    impl TickBitmapImpl<TContractState, +HasComponent<TContractState>> of super::ITickBitmap<ComponentState<TContractState>> {
        // @notice Flips the initialized state for a given tick from false to true, or vice versa
        // @param pool_hash The pool in which tick to flip
        // @param tick The tick to flip
        // @param tick_spacing The spacing between usable ticks
        fn flip_tick(ref self: ComponentState<TContractState>, tick: i32, tick_spacing: i32) {
            assert(tick % tick_spacing == IntegerTrait::<i32>::new(0, false), 'tick misaligned');

            let (word_pos, bit_pos) = position(tick / tick_spacing);
            let mask: u256 = 1_u256.shl(bit_pos.into());
            let word = self.bitmap.read(word_pos);
            self.bitmap.write(word_pos, word ^ mask);
        }

        // @notice Returns the next initialized tick contained in the same word (or adjacent word) as the tick that is either
        // to the left (less than or equal to) or right (greater than) of the given tick
        // @param tick The starting tick
        // @param tick_spacing The spacing between usable ticks
        // @param search_left Whether to search for the next initialized tick to the left (less than or equal to the starting tick)
        // @return The next initialized or uninitialized tick up to 256 ticks away from the current tick
        // @return Whether the next tick is initialized, as the function only searches within up to 256 ticks
        fn next_initialized_tick_within_one_word(ref self: ComponentState<TContractState>, tick: i32, tick_spacing: i32, search_left: bool) -> (i32, bool) {
            let mut compressed: i32 = tick / tick_spacing;
            if ((tick < IntegerTrait::<i32>::new(0, false)) && (tick % tick_spacing != IntegerTrait::<i32>::new(0, false))) {
                compressed -= IntegerTrait::<i32>::new(1, false); // round towards negative infinity
            };

            if (search_left) {
                let (word_pos, bit_pos) = position(compressed);
                let word: u256 = self.bitmap.read(word_pos);
                // all the 1s at or to the right of the current bitPos
                let mask: u256 = 1_u256.shl(bit_pos.into()) - 1 + 1_u256.shl(bit_pos.into());
                let masked: u256 = word & mask;

                // if there are no initialized ticks to the right of or at the current tick, return rightmost in the word
                let initialized = masked != 0;
                // overflow/underflow is possible, but prevented externally by limiting both tickSpacing and tick
                let next = if (initialized) {
                    (compressed - (bit_pos - BitMath::most_significant_bit(masked)).into()) * tick_spacing 
                    } else {
                    (compressed - bit_pos.into()) * tick_spacing
                    };
                return (next, initialized);
            } else {
                // start from the word of the next tick, since the current tick state doesn't matter
                let (word_pos, bit_pos) = position(compressed + IntegerTrait::<i32>::new(1, false));
                let word: u256 = self.bitmap.read(word_pos);
                // all the 1s at or to the left of the bitPos
                let mask: u256 = ~(1_u256.shl(bit_pos.into()) - 1);
                let masked: u256 = word & mask;

                // if there are no initialized ticks to the left of the current tick, return leftmost in the word
                let initialized = masked != 0;
                // overflow/underflow is possible, but prevented externally by limiting both tickSpacing and tick
                let next = if initialized {
                    (compressed + IntegerTrait::<i32>::new(1, false) + (BitMath::least_significant_bit(masked) - bit_pos).into()) * tick_spacing
                    } else {
                    (compressed + IntegerTrait::<i32>::new(1, false) + (BoundedInt::<u8>::max() - bit_pos).into()) * tick_spacing
                    };
                return (next, initialized);
            }
        }
    }

    #[generate_trait]
    impl InternalImpl<TContractState, +HasComponent<TContractState>> of InternalTrait<TContractState> {
        
        fn is_initialized(ref self: ComponentState<TContractState>, tick: i32) -> bool {
            let (next, initialized) = TickBitmapImpl::next_initialized_tick_within_one_word(ref self, tick, IntegerTrait::<i32>::new(1, false), true);
            if next == tick {
                initialized
            } else {
                false
            }
        }
    }
}