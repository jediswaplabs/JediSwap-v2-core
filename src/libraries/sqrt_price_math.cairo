mod SqrtPriceMath {
    use core::integer::u256_overflow_mul;
    use jediswap_v2_core::libraries::signed_integers::{i128::i128, i256::i256, integer_trait::IntegerTrait};
    use jediswap_v2_core::libraries::bitshift_trait::BitShiftTrait;
    use jediswap_v2_core::libraries::full_math::{div_rounding_up, mul_div, mul_div_rounding_up};
    use snforge_std::{PrintTrait};

    const R96: u256 = 96;
    const Q96: u256 = 0x1000000000000000000000000; // 79228162514264337593543950336 2**96
    const Q128: u256 =
        0x100000000000000000000000000000000; //   340282366920938463463374607431768211456  2**128
    const MAX_UINT160: u256 = 1461501637330902918203684832716283019655932542975; // (2 ** 160) - 1

    // @notice Gets the next square root price given a delta of token0.
    // @dev Always rounds up, because in the exact output case (increasing price) we need to move the price at least
    // far enough to get the desired output amount, and in the exact input case (decreasing price) we need to move the
    // price less in order to not send too much output.
    // The most precise formula for this is liquidity * sqrt_p_x96 / (liquidity +- amount * sqrt_p_x96),
    // if this is impossible because of overflow, we calculate liquidity / (liquidity / sqrt_p_x96 +- amount).
    // @param sqrt_p_x96 The starting price, i.e. before accounting for the token0 delta
    // @param liquidity The amount of usable liquidity
    // @param amount How much of token0 to add or remove from virtual reserves
    // @param add Whether to add or remove the amount of token0
    // @return The price after adding or removing amount(depending on add above)
    fn get_next_sqrt_price_from_amount0_rounding_up(
        sqrt_p_x96: u256, liquidity: u128, amount: u256, add: bool
    ) -> u256 {
        // we short circuit amount == 0 because the result is otherwise not guaranteed to equal the input price
        if (amount == 0) {
            return sqrt_p_x96;
        }

        let numerator = liquidity.into().shl(R96);
        let (product, overflow) = u256_overflow_mul(amount, sqrt_p_x96);

        if (add) {
            if (!overflow) {
                let denominator = numerator + product;
                if (denominator >= numerator) {
                    return mul_div_rounding_up(numerator, sqrt_p_x96, denominator);
                }
            }
            return div_rounding_up(numerator, (numerator / sqrt_p_x96) + amount);
        } else {
            // if the product overflows, we know the denominator underflows
            // in addition, we must check that the denominator does not underflow
            assert(!overflow, 'product overflows');
            assert(numerator > product, 'denominator negative');
            let denominator = numerator - product;
            let to_return = mul_div_rounding_up(numerator, sqrt_p_x96, denominator);
            assert(to_return <= MAX_UINT160, 'does not fit uint160');
            return to_return;
        }
    }

    // @notice Gets the next sqrt price given a delta of token1
    // @dev Always rounds down, because in the exact output case (decreasing price) we need to move the price at least
    // far enough to get the desired output amount, and in the exact input case (increasing price) we need to move the
    // price less in order to not send too much output.
    // The formula we compute is within <1 wei of the lossless version: sqrt_p_x96 +- amount / liquidity
    // @param sqrt_p_x96 The starting price(before accounting for the token1 delta)
    // @param liquidity The amount of usable liquidity
    // @param amount  How much of token1 to add, or remove, from virtual reserves
    // @param add Whether to add, or remove, the amount of token1
    // @return The price after adding or removing `amount`
    fn get_next_sqrt_price_from_amount1_rounding_down(
        sqrt_p_x96: u256, liquidity: u128, amount: u256, add: bool
    ) -> u256 {
        // if we're adding (subtracting), rounding down requires rounding the quotient down (up)
        // in both cases, avoid a mulDiv for most inputs
        if (add) {
            let quotient = if (amount <= MAX_UINT160) {
                amount.shl(R96) / liquidity.into()
            } else {
                mul_div(amount, Q96, liquidity.into())
            };
            let to_return = sqrt_p_x96 + quotient;
            assert(to_return <= MAX_UINT160, 'does not fit uint160');
            return to_return;
        } else {
            let quotient = if (amount <= MAX_UINT160) {
                div_rounding_up(amount.shl(R96), liquidity.into())
            } else {
                mul_div_rounding_up(amount, Q96, liquidity.into())
            };
            assert(sqrt_p_x96 > quotient, 'sqrt_p_x96 < quotient');
            return sqrt_p_x96 - quotient;
        }
    }

    // @notice Returns the next square root price given an input amount of token0 or token1
    // @dev Throws if the price or liquidity is 0, or if the next price is out of bounds
    // @param sqrt_p_x96 The starting price, i.e., before accounting for the input amount
    // @param liquidity The amount of usable liquidity
    // @param amount_in How much of token0 or token1 is being swapped in
    // @param zero_for_one Whether the amount in is token0 or token1
    // @return The price after adding the input amount to token0 or token1
    fn get_next_sqrt_price_from_input(
        sqrt_p_x96: u256, liquidity: u128, amount_in: u256, zero_for_one: bool
    ) -> u256 {
        assert(sqrt_p_x96 > 0 && liquidity > 0, 'sqrt_p_x96 or liquidity <= 0');
        if (zero_for_one) {
            return get_next_sqrt_price_from_amount0_rounding_up(
                sqrt_p_x96, liquidity, amount_in, true
            );
        } else {
            return get_next_sqrt_price_from_amount1_rounding_down(
                sqrt_p_x96, liquidity, amount_in, true
            );
        }
    }

    // @notice Gets the next sqrt price given an output amount of token0 or token1
    // @dev Throws if the price or liquidity is 0 or the next price is out of bounds
    // @param sqrt_p_x96 The starting price before accounting for the output amount
    // @param liquidity The amount of usable liquidity
    // @param amount_out How much of token0 or token1 is being swapped out
    // @param zero_for_one Whether the amount out is token0 or token1
    // @return The price after removing the output amount of token0 or token1
    fn get_next_sqrt_price_from_output(
        sqrt_p_x96: u256, liquidity: u128, amount_out: u256, zero_for_one: bool
    ) -> u256 {
        assert(sqrt_p_x96 > 0 && liquidity > 0, 'sqrt_p_x96 or liquidity <= 0');

        if (zero_for_one) {
            return get_next_sqrt_price_from_amount1_rounding_down(
                sqrt_p_x96, liquidity, amount_out, false
            );
        } else {
            return get_next_sqrt_price_from_amount0_rounding_up(
                sqrt_p_x96, liquidity, amount_out, false
            );
        }
    }

    // @notice Gets the amount0 delta between two prices
    // @dev Calculates `liquidity / sqrt(lower) - liquidity / sqrt(upper)`,
    // i.e., `liquidity * (sqrt(upper) - sqrt(lower)) / (sqrt(upper) * sqrt(lower))`
    // @param sqrt_ratio_a_x96 A sqrt price
    // @param sqrt_ratio_b_x96 Another sqrt price
    // @param liquidity The amount of usable liquidity
    // @param round_up Indicates whether to round the amount up or down
    // @return Amount of token0 required to cover a position of size liquidity between the two passed prices
    fn get_amount0_delta_unsigned(
        sqrt_ratio_a_x96: u256, sqrt_ratio_b_x96: u256, liquidity: u128, round_up: bool
    ) -> u256 {
        let mut sqrt_ratio_lower_x96 = sqrt_ratio_a_x96;
        let mut sqrt_ratio_upper_x96 = sqrt_ratio_b_x96;

        if (sqrt_ratio_a_x96 > sqrt_ratio_b_x96) {
            sqrt_ratio_lower_x96 = sqrt_ratio_b_x96;
            sqrt_ratio_upper_x96 = sqrt_ratio_a_x96;
        }

        let numerator_1: u256 = liquidity.into().shl(R96);
        let numerator_2 = sqrt_ratio_upper_x96 - sqrt_ratio_lower_x96;

        assert(sqrt_ratio_lower_x96 > 0, 'less than 0');

        if (round_up) {
            return div_rounding_up(
                mul_div_rounding_up(numerator_1, numerator_2, sqrt_ratio_upper_x96),
                sqrt_ratio_lower_x96
            );
        } else {
            return mul_div(numerator_1, numerator_2, sqrt_ratio_upper_x96) / sqrt_ratio_lower_x96;
        }
    }

    // @notice Gets the amount1 delta between two prices
    // @dev Calculates liquidity * (sqrt(upper) - sqrt(lower))
    // @param sqrt_ratio_a_x96 A sqrt price
    // @param sqrt_ratio_b_x96 Another sqrt price
    // @param liquidity The amount of usable liquidity
    // @param round_up Whether to round the amount up or down
    // @return Amount of token1 required to cover a position of size liquidity between the two passed prices
    fn get_amount1_delta_unsigned(
        sqrt_ratio_a_x96: u256, sqrt_ratio_b_x96: u256, liquidity: u128, round_up: bool
    ) -> u256 {
        let mut sqrt_ratio_lower_x96 = sqrt_ratio_a_x96;
        let mut sqrt_ratio_upper_x96 = sqrt_ratio_b_x96;

        if (sqrt_ratio_a_x96 > sqrt_ratio_b_x96) {
            sqrt_ratio_lower_x96 = sqrt_ratio_b_x96;
            sqrt_ratio_upper_x96 = sqrt_ratio_a_x96;
        }

        if (round_up) {
            return mul_div_rounding_up(
                liquidity.into(), sqrt_ratio_upper_x96 - sqrt_ratio_lower_x96, Q96
            );
        } else {
            return mul_div(liquidity.into(), sqrt_ratio_upper_x96 - sqrt_ratio_lower_x96, Q96);
        }
    }

    // @notice Helper that gets signed token0 delta
    // @param sqrt_ratio_a_x96 A sqrt price
    // @param sqrt_ratio_b_x96 Another sqrt price
    // @param liquidity The change in liquidity for which to compute the amount0 delta
    // @return Amount of token0 corresponding to the passed liquidity_delta between the two prices
    fn get_amount0_delta(sqrt_ratio_a_x96: u256, sqrt_ratio_b_x96: u256, liquidity: i128) -> i256 {
        if (liquidity < IntegerTrait::<i128>::new(0, false)) {
            return IntegerTrait::<
                i256
            >::new(
                get_amount0_delta_unsigned(
                    sqrt_ratio_a_x96, sqrt_ratio_b_x96, liquidity.mag, false
                ),
                true
            );
        } else {
            return IntegerTrait::<
                i256
            >::new(
                get_amount0_delta_unsigned(sqrt_ratio_a_x96, sqrt_ratio_b_x96, liquidity.mag, true),
                false
            );
        }
    }

    // @notice Helper that gets signed token1 delta
    // @param sqrt_ratio_a_x96 A sqrt price
    // @param sqrt_ratio_b_x96 Another sqrt price
    // @param liquidity The change in liquidity for which to compute the amount1 delta
    // @return Amount of token1 corresponding to the passed liquidity_delta between the two prices
    fn get_amount1_delta(sqrt_ratio_a_x96: u256, sqrt_ratio_b_x96: u256, liquidity: i128) -> i256 {
        if (liquidity < IntegerTrait::<i128>::new(0, false)) {
            return IntegerTrait::<
                i256
            >::new(
                get_amount1_delta_unsigned(
                    sqrt_ratio_a_x96, sqrt_ratio_b_x96, liquidity.mag, false
                ),
                true
            );
        } else {
            return IntegerTrait::<
                i256
            >::new(
                get_amount1_delta_unsigned(sqrt_ratio_a_x96, sqrt_ratio_b_x96, liquidity.mag, true),
                false
            );
        }
    }
}
