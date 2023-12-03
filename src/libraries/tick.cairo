use yas_core::numbers::signed_integer::{i32::i32, i64::i64, i128::i128, integer_trait::IntegerTrait};

#[derive(Copy, Drop, Serde, starknet::Store)]
struct TickInfo {
    // @notice The total position liquidity that references this tick
    liquidity_gross: u128,
    // @notice Amount of net liquidity added (subtracted) when tick is crossed from left to right (right to left),
    liquidity_net: i128,
    // @notice Fee growth for token0 per unit of liquidity on the _other_ side of this tick (relative to the current tick)
    fee_growth_outside_0_X128: u256,
    // @notice Fee growth for token1 per unit of liquidity on the _other_ side of this tick (relative to the current tick)
    fee_growth_outside_1_X128: u256,
}

impl DefaultTickInfo of Default<TickInfo> {
    fn default() -> TickInfo {
        TickInfo {
            liquidity_gross: 0,
            liquidity_net: IntegerTrait::<i128>::new(0, false),
            fee_growth_outside_0_X128: 0,
            fee_growth_outside_1_X128: 0
        }
    }
}

#[starknet::interface]
trait ITick<TState> {
    fn tick_spacing_to_max_liquidity_per_tick(self: @TState, tick_spacing: i32) -> u128;
    fn get_fee_growth_inside(self: @TState, tick_lower: i32, tick_upper: i32, tick_current: i32, fee_growth_global_0_X128: u256, fee_growth_global_1_X128: u256) -> (u256, u256);
    fn update(ref self: TState, tick: i32, tick_current: i32, liquidity_delta: i128, fee_growth_global_0_X128: u256, fee_growth_global_1_X128: u256, upper: bool, max_liquidity: u128) -> bool;
    fn clear(ref self: TState, tick: i32);
    fn cross(ref self: TState, tick: i32, fee_growth_global_0_X128: u256, fee_growth_global_1_X128: u256) -> i128;
}

#[starknet::component]
mod TickComponent {
    use super::{TickInfo};

    use integer::BoundedInt;
    use poseidon::poseidon_hash_span;

    use yas_core::libraries::liquidity_math::LiquidityMath;
    use yas_core::numbers::signed_integer::{i32::{i32, i32TryIntou128, i32_div_no_round}, i64::i64, i128::i128, integer_trait::IntegerTrait};
    use yas_core::utils::math_utils::mod_subtraction;
    use jediswap_v2_core::libraries::tick_math::TickMath::{MIN_TICK, MAX_TICK};

    #[storage]
    struct Storage {
        ticks: LegacyMap::<i32, TickInfo>   // @notice Represents all the ticks in the pool
    }

    #[embeddable_as(Tick)]
    impl TickImpl<TContractState, +HasComponent<TContractState>> of super::ITick<ComponentState<TContractState>> {
        // @notice Derives max liquidity per tick from given tick spacing
        // @dev Executed within the pool constructor
        // @param tick_spacing The amount of required tick separation, realized in multiples of `tick_spacing`
        //     e.g., a tick_spacing of 3 requires ticks to be initialized every 3rd tick i.e., ..., -6, -3, 0, 3, 6, ...
        // @return The max liquidity per tick
        fn tick_spacing_to_max_liquidity_per_tick(self: @ComponentState<TContractState>, tick_spacing: i32) -> u128 {
            let min_tick = i32_div_no_round(MIN_TICK(), tick_spacing) * tick_spacing;
            let max_tick = i32_div_no_round(MAX_TICK(), tick_spacing) * tick_spacing;
            let num_ticks = i32_div_no_round((max_tick - min_tick), tick_spacing) + IntegerTrait::<i32>::new(1, false);

            let max_u128: u128 = BoundedInt::max();
            max_u128 / num_ticks.try_into().expect('num ticks cannot be negative!')
        }

        // @notice Retrieves fee growth data
        // @param tick_lower The lower tick boundary of the position
        // @param tick_upper The upper tick boundary of the position
        // @param tick_current The current tick
        // @param fee_growth_global_0_X128 The all-time global fee growth, per unit of liquidity, in token0
        // @param fee_growth_global_1_X128 The all-time global fee growth, per unit of liquidity, in token1
        // @return fee_growth_inside_0_X128 The all-time fee growth in token0, per unit of liquidity, inside the position's tick boundaries
        // @return fee_growth_inside_1_X128 The all-time fee growth in token1, per unit of liquidity, inside the position's tick boundaries
        fn get_fee_growth_inside(self: @ComponentState<TContractState>, tick_lower: i32, tick_upper: i32, tick_current: i32, fee_growth_global_0_X128: u256, fee_growth_global_1_X128: u256) -> (u256, u256) {
            let lower: TickInfo = self.ticks.read(tick_lower);
            let upper: TickInfo = self.ticks.read(tick_upper);

            // calculate fee growth below
            let (fee_growth_below_0_X128, fee_growth_below_1_X128) = if (tick_current >= tick_lower) {
                (lower.fee_growth_outside_0_X128, lower.fee_growth_outside_1_X128)
            } else {
                (fee_growth_global_0_X128 - lower.fee_growth_outside_0_X128, fee_growth_global_1_X128 - lower.fee_growth_outside_1_X128)
            };

            // calculate fee growth above
            let (fee_growth_above_0_X128, fee_growth_above_1_X128) = if (tick_current < tick_upper) {
                (upper.fee_growth_outside_0_X128, upper.fee_growth_outside_1_X128)
            } else {
                (fee_growth_global_0_X128 - upper.fee_growth_outside_0_X128, fee_growth_global_1_X128 - upper.fee_growth_outside_1_X128)
            };

            // this function mimics the u256 overflow that occurs in Solidity, TODO
            // (
            //     mod_subtraction(
            //         mod_subtraction(fee_growth_global_0_X128, fee_growth_below_0_X128),
            //         fee_growth_above_0_X128
            //     ),
            //     mod_subtraction(
            //         mod_subtraction(fee_growth_global_1_X128, fee_growth_below_1_X128),
            //         fee_growth_above_1_X128
            //     )
            // )
            (fee_growth_global_0_X128 - fee_growth_below_0_X128 - fee_growth_above_0_X128, fee_growth_global_1_X128 - fee_growth_below_1_X128 - fee_growth_above_1_X128)
        }

        // @notice Updates a tick and returns true if the tick was flipped from initialized to uninitialized, or vice versa
        // @param tick The tick that will be updated
        // @param tick_current The current tick
        // @param liquidity_delta A new amount of liquidity to be added (subtracted) when tick is crossed from left to right (right to left)
        // @param fee_growth_global_0_X128 The all-time global fee growth, per unit of liquidity, in token0
        // @param fee_growth_global_1_X128 The all-time global fee growth, per unit of liquidity, in token1
        // @param seconds_per_liquidity_cumulative_X128 The all-time seconds per max(1, liquidity) of the pool
        // @param tick_cumulative The tick * time elapsed since the pool was first initialized
        // @param upper true for updating a position's upper tick, or false for updating a position's lower tick
        // @param max_liquidity The maximum liquidity allocation for a single tick
        // @return flipped Whether the tick was flipped from initialized to uninitialized, or vice versa
        fn update(ref self: ComponentState<TContractState>, tick: i32, tick_current: i32, liquidity_delta: i128, fee_growth_global_0_X128: u256, fee_growth_global_1_X128: u256, upper: bool, max_liquidity: u128) -> bool {
            let mut tick_info: TickInfo = self.ticks.read(tick);

            let liquidity_gross_before: u128 = tick_info.liquidity_gross;
            let liquidity_gross_after = if (liquidity_delta < IntegerTrait::<i128>::new(0, false)) {
                    liquidity_gross_before - liquidity_delta.mag
                } else {
                    liquidity_gross_before + liquidity_delta.mag
                };
            assert(liquidity_gross_after <= max_liquidity, 'LO');

            let flipped = (liquidity_gross_after == 0) != (liquidity_gross_before == 0);

            if (liquidity_gross_before == 0) {
                // by convention, we assume that all growth before a tick was initialized happened _below_ the tick
                if (tick <= tick_current) {
                    tick_info.fee_growth_outside_0_X128 = fee_growth_global_0_X128;
                    tick_info.fee_growth_outside_1_X128 = fee_growth_global_1_X128;
                }
            }

            tick_info.liquidity_gross = liquidity_gross_after;

            // when the lower (upper) tick is crossed left to right (right to left), liquidity must be added (removed)
            tick_info.liquidity_net =
                    if (upper) {
                        tick_info.liquidity_net - liquidity_delta
                    } else {
                        tick_info.liquidity_net + liquidity_delta
                    };

            self.ticks.write(tick, tick_info);
            flipped
        }

        /// @notice Clears tick data
        /// @param tick The tick that will be cleared
        fn clear(ref self: ComponentState<TContractState>, tick: i32) {
            self.ticks.write(tick, Default::default());
        }

        /// @notice Transitions to next tick as needed by price movement
        /// @param tick The destination tick of the transition
        /// @param fee_growth_global_0_X128 The all-time global fee growth, per unit of liquidity, in token0
        /// @param fee_growth_global_1_X128 The all-time global fee growth, per unit of liquidity, in token1
        /// @return liquidity_net The amount of liquidity added (subtracted) when tick is crossed from left to right (right to left)
        fn cross(ref self: ComponentState<TContractState>, tick: i32, fee_growth_global_0_X128: u256, fee_growth_global_1_X128: u256) -> i128 {
            let mut tick_info: TickInfo = self.ticks.read(tick);
            tick_info.fee_growth_outside_0_X128 = fee_growth_global_0_X128 - tick_info.fee_growth_outside_0_X128;
            tick_info.fee_growth_outside_1_X128 = fee_growth_global_1_X128 - tick_info.fee_growth_outside_1_X128;
            self.ticks.write(tick, tick_info);
            tick_info.liquidity_net
        }
    }
}