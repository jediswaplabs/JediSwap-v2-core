use jediswap_v2_core::libraries::signed_integers::i32::i32;

#[starknet::interface]
trait ITickBitmap<TState> {
    fn next_initialized_tick_within_one_word(
        ref self: TState, tick: i32, tick_spacing: u32, search_left: bool
    ) -> (i32, bool);
    fn flip_tick(ref self: TState, tick: i32, tick_spacing: u32);
}


// Packed tick initialized state library
// Stores a packed mapping of tick index to its initialized state
// The mapping uses i16 for keys since ticks are max i24 and there are 256 (2^8) values per word.
#[starknet::component]
mod TickBitmapComponent {
    use integer::BoundedInt;
    use jediswap_v2_core::libraries::bit_math::{most_significant_bit, least_significant_bit};
    use jediswap_v2_core::libraries::signed_integers::{i16::i16, i32::i32, integer_trait::IntegerTrait};
    use jediswap_v2_core::libraries::bitshift_trait::BitShiftTrait;

    #[storage]
    struct Storage {
        bitmap: LegacyMap<
            i16, u256
        >, // @notice Represents initialization of the ticks in all the pools (pool_hash, word_pos, pos_mask)
    }

    #[embeddable_as(TickBitmap)]
    impl TickBitmapImpl<
        TContractState, +HasComponent<TContractState>
    > of super::ITickBitmap<ComponentState<TContractState>> {
        // @notice Flips the initialized state for a given tick from false to true, or vice versa
        // @param pool_hash The pool in which tick to flip
        // @param tick The tick to flip
        // @param tick_spacing The spacing between usable ticks
        fn flip_tick(ref self: ComponentState<TContractState>, tick: i32, tick_spacing: u32) {
            let tick_spacing_i = IntegerTrait::<i32>::new(tick_spacing, false);
            assert(tick % tick_spacing_i == IntegerTrait::<i32>::new(0, false), 'tick misaligned');
            let (word_pos, bit_pos) = position(tick / tick_spacing_i);
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
        fn next_initialized_tick_within_one_word(
            ref self: ComponentState<TContractState>,
            tick: i32,
            tick_spacing: u32,
            search_left: bool
        ) -> (i32, bool) {
            let tick_spacing_i = IntegerTrait::<i32>::new(tick_spacing, false);
            let mut compressed: i32 = tick / tick_spacing_i;
            if ((tick < IntegerTrait::<i32>::new(0, false))
                && (tick % tick_spacing_i != IntegerTrait::<i32>::new(0, false))) {
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
                    (compressed - (bit_pos - most_significant_bit(masked)).into())
                        * tick_spacing_i
                } else {
                    (compressed - bit_pos.into()) * tick_spacing_i
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
                    (compressed
                        + IntegerTrait::<i32>::new(1, false)
                        + (least_significant_bit(masked) - bit_pos).into())
                        * tick_spacing_i
                } else {
                    (compressed
                        + IntegerTrait::<i32>::new(1, false)
                        + (BoundedInt::<u8>::max() - bit_pos).into())
                        * tick_spacing_i
                };
                return (next, initialized);
            }
        }
    }

    #[generate_trait]
    impl InternalImpl<
        TContractState, +HasComponent<TContractState>
    > of InternalTrait<TContractState> {
        fn is_initialized(ref self: ComponentState<TContractState>, tick: i32) -> bool {
            let (next, initialized) = TickBitmapImpl::next_initialized_tick_within_one_word(
                ref self, tick, 1, true
            );
            if next == tick {
                initialized
            } else {
                false
            }
        }
    }

    // @notice Calculates the word value based on a tick input
    // @dev For ticks between 0 and 255 inclusive, it returns 0
    //      For ticks greater than 255, it divides the tick by 256
    //      For ticks less than 0 but greater than or equal to -256, it returns -1
    //      For other negative ticks, it divides the tick by 256 and subtracts 1
    // @param tick An i32 input representing the tick value
    // @return calculated word
    fn calculate_word(tick: i32) -> i16 {
        let zero = IntegerTrait::<i32>::new(0, false);
        let one_negative = IntegerTrait::<i32>::new(1, true);
        let upper_bound = IntegerTrait::<i32>::new(255, false);
        let divisor = IntegerTrait::<i32>::new(256, false);
        let negative_lower_bound = IntegerTrait::<i32>::new(256, true);

        let result = if tick >= zero && tick <= upper_bound { //tick: [0, 255]
            zero
        } else if tick > upper_bound { //tick: [256, 887272]
            tick / divisor
        } else if tick >= negative_lower_bound { //tick: [-256, -1]
            one_negative
        } else { //tick: [-887272, -257]
            if (tick % divisor != zero) {   // TODO check this modulo
                IntegerTrait::<i32>::new((tick.mag / divisor.mag) + 1, true)
            } else {
                IntegerTrait::<i32>::new((tick.mag / divisor.mag), true)
            }
        };
        result.try_into().expect('calculate_word')
    }

    // @notice Calculates the bit value based on a given tick input
    // @param tick An i32 input representing the tick value
    // @return calculated bit
    fn calculate_bit(tick: i32) -> u8 {
        let bit = tick % IntegerTrait::<i32>::new(256, false);
        // This converts int8 to uint8 by wrapping around.
        if (bit.sign) {
            (256 - bit.mag).try_into().expect('calculate_bit')
        } else {
            bit.mag.try_into().expect('calculate_bit')
        }
    }

    // @notice Computes the position in the mapping where the initialized bit for a tick lives
    // @param tick The tick for which to compute the position
    // @return The key in the mapping containing the word in which the bit is stored
    // @return The bit position in the word where the flag is stored
    fn position(tick: i32) -> (i16, u8) {
        let word_pos: i16 = calculate_word(tick);
        let bit_pos: u8 = calculate_bit(tick);
        (word_pos, bit_pos)
    }
}
