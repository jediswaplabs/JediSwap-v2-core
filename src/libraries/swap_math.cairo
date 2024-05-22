// Computes the result of a swap within ticks
// Contains methods for computing the result of a swap within a single tick price range, i.e., a single tick.
mod SwapMath {
    use jediswap_v2_core::libraries::full_math::{div_rounding_up, mul_div, mul_div_rounding_up};
    use jediswap_v2_core::libraries::signed_integers::{i256::i256, integer_trait::IntegerTrait};
    use jediswap_v2_core::libraries::sqrt_price_math::SqrtPriceMath::{
        get_amount0_delta_unsigned, get_amount1_delta_unsigned, get_next_sqrt_price_from_input,
        get_next_sqrt_price_from_output
    };

    // @notice Computes the result of swapping some amount in, or amount out, given the parameters of the swap
    // @param sqrt_ratio_current_x96 The current sqrt price of the pool
    // @param sqrt_ratio_target_x96 The price that cannot be exceeded, from which the direction of the swap is inferred
    // @param liquidity The usable liquidity
    // @param amount_remaining How much input or output amount is remaining to be swapped in/out
    // @param fee_pips The fee taken from the input amount, expressed in hundredths of a bip
    // @return The price after swapping the amount in/out, not to exceed the price target
    // @return The amount to be swapped in, of either token0 or token1, based on the direction of the swap
    // @return The amount to be received, of either token0 or token1, based on the direction of the swap
    // @return The amount of input that will be taken as a fee
    fn compute_swap_step(
        sqrt_ratio_current_x96: u256,
        sqrt_ratio_target_x96: u256,
        liquidity: u128,
        amount_remaining: i256,
        fee_pips: u32
    ) -> (u256, u256, u256, u256) {
        let zero_for_one = sqrt_ratio_current_x96 >= sqrt_ratio_target_x96;
        let exact_in = amount_remaining >= IntegerTrait::<i256>::new(0, false);
        let mut sqrt_ratio_next_x96 = 0;
        let mut amount_in = 0;
        let mut amount_out = 0;
        let mut fee_amount = 0;

        if (exact_in) {
            let amount_remaining_less_fee = mul_div(
                amount_remaining.mag, 1000000 - fee_pips.into(), 1000000
            );
            amount_in =
                if (zero_for_one) {
                    get_amount0_delta_unsigned(
                        sqrt_ratio_target_x96, sqrt_ratio_current_x96, liquidity, true
                    )
                } else {
                    get_amount1_delta_unsigned(
                        sqrt_ratio_current_x96, sqrt_ratio_target_x96, liquidity, true
                    )
                };
            if (amount_remaining_less_fee >= amount_in) {
                sqrt_ratio_next_x96 = sqrt_ratio_target_x96;
            } else {
                sqrt_ratio_next_x96 =
                    get_next_sqrt_price_from_input(
                        sqrt_ratio_current_x96, liquidity, amount_remaining_less_fee, zero_for_one
                    );
            }
        } else {
            amount_out =
                if (zero_for_one) {
                    get_amount1_delta_unsigned(
                        sqrt_ratio_target_x96, sqrt_ratio_current_x96, liquidity, false
                    )
                } else {
                    get_amount0_delta_unsigned(
                        sqrt_ratio_current_x96, sqrt_ratio_target_x96, liquidity, false
                    )
                };

            if (amount_remaining.mag >= amount_out) {
                sqrt_ratio_next_x96 = sqrt_ratio_target_x96;
            } else {
                sqrt_ratio_next_x96 =
                    get_next_sqrt_price_from_output(
                        sqrt_ratio_current_x96, liquidity, amount_remaining.mag, zero_for_one
                    );
            }
        }

        let max = sqrt_ratio_target_x96 == sqrt_ratio_next_x96;

        // get the input/output amounts
        if (zero_for_one) {
            amount_in =
                if (max && exact_in) {
                    amount_in
                } else {
                    get_amount0_delta_unsigned(
                        sqrt_ratio_next_x96, sqrt_ratio_current_x96, liquidity, true
                    )
                };

            amount_out =
                if (max && !exact_in) {
                    amount_out
                } else {
                    get_amount1_delta_unsigned(
                        sqrt_ratio_next_x96, sqrt_ratio_current_x96, liquidity, false
                    )
                };
        } else {
            amount_in =
                if (max && exact_in) {
                    amount_in
                } else {
                    get_amount1_delta_unsigned(
                        sqrt_ratio_current_x96, sqrt_ratio_next_x96, liquidity, true
                    )
                };

            amount_out =
                if (max && !exact_in) {
                    amount_out
                } else {
                    get_amount0_delta_unsigned(
                        sqrt_ratio_current_x96, sqrt_ratio_next_x96, liquidity, false
                    )
                };
        }

        // cap the output amount to not exceed the remaining output amount
        if (!exact_in && amount_out > amount_remaining.mag) {
            amount_out = amount_remaining.mag;
        }

        if (exact_in && sqrt_ratio_next_x96 != sqrt_ratio_target_x96) {
            // we didn't reach the target, so take the remainder of the maximum input as fee
            fee_amount = amount_remaining.mag - amount_in;
        } else {
            fee_amount = mul_div_rounding_up(amount_in, fee_pips.into(), 1000000 - fee_pips.into());
        }

        (sqrt_ratio_next_x96, amount_in, amount_out, fee_amount)
    }
}
