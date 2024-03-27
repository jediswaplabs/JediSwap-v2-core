use integer::BoundedInt;
use jediswap_v2_core::libraries::full_math::{mul_div, mul_div_rounding_up};
use jediswap_v2_core::libraries::sqrt_price_math::SqrtPriceMath::Q128;

#[test]
#[should_panic(expected: ('mul_div by zero',))]
fn test_mul_div_reverts_if_denominator_is_0() {
    mul_div(Q128, 5, 0);
}

#[test]
#[should_panic(expected: ('mul_div by zero',))]
fn test_mul_div_reverts_if_denominator_is_0_and_numerator_overflows() {
    mul_div(Q128, Q128, 0);
}

#[test]
#[should_panic(expected: ('mul_div u256 overflow',))]
fn test_mul_div_reverts_if_output_overflows() {
    mul_div(Q128, Q128, 1);
}

#[test]
#[should_panic(expected: ('mul_div u256 overflow',))]
fn test_mul_div_reverts_on_overflow_with_all_max_inputs() {
    mul_div(BoundedInt::max(), BoundedInt::max(), BoundedInt::max() - 1);
}

#[test]
fn test_mul_div_all_max_inputs() {
    assert(mul_div(BoundedInt::max(), BoundedInt::max(), BoundedInt::max()) == BoundedInt::max(), 'not equal');
}

#[test]
fn test_mul_div_accurate_without_phantom_overflow() {
    let result = Q128 / 3;
    assert(mul_div(Q128, 50 * Q128 / 100, 150 * Q128 / 100) == result, 'not equal');
}

#[test]
fn test_mul_div_accurate_with_phantom_overflow() {
    let result = 4375 * Q128 / 1000;
    assert(mul_div(Q128, 35 * Q128, 8 * Q128) == result, 'not equal');
}

#[test]
fn test_mul_div_accurate_with_phantom_overflow_and_repeating_decimal() {
    let result = Q128 / 3;
    assert(mul_div(Q128, 1000 * Q128, 3000 * Q128) == result, 'not equal');
}

#[test]
#[should_panic(expected: ('mul_div by zero',))]
fn test_mul_div_rounding_up_reverts_if_denominator_is_0() {
    mul_div_rounding_up(Q128, 5, 0);
}

#[test]
#[should_panic(expected: ('mul_div by zero',))]
fn test_mul_div_rounding_up_reverts_if_denominator_is_0_and_numerator_overflows() {
    mul_div_rounding_up(Q128, Q128, 0);
}

#[test]
#[should_panic(expected: ('mul_div u256 overflow',))]
fn test_mul_div_rounding_up_reverts_if_output_overflows() {
    mul_div_rounding_up(Q128, Q128, 1);
}

#[test]
#[should_panic(expected: ('mul_div u256 overflow',))]
fn test_mul_div_rounding_up_reverts_on_overflow_with_all_max_inputs() {
    mul_div_rounding_up(BoundedInt::max(), BoundedInt::max(), BoundedInt::max() - 1);
}

#[test]
#[should_panic(expected: ('mul_div_rounding_up overflow',))]
fn test_mul_div_rounding_up_reverts_if_mul_div_overflows_256_bits_after_rounding_up() {
    mul_div_rounding_up(535006138814359, 432862656469423142931042426214547535783388063929571229938474969, 2);
}

#[test]
#[should_panic(expected: ('mul_div_rounding_up overflow',))]
fn test_mul_div_rounding_up_reverts_if_mul_div_overflows_256_bits_after_rounding_up_2() {
    mul_div_rounding_up(115792089237316195423570985008687907853269984659341747863450311749907997002549, 115792089237316195423570985008687907853269984659341747863450311749907997002550, 115792089237316195423570985008687907853269984653042931687443039491902864365164);
}

#[test]
fn test_mul_div_rouding_up_all_max_inputs() {
    assert(mul_div_rounding_up(BoundedInt::max(), BoundedInt::max(), BoundedInt::max()) == BoundedInt::max(), 'not equal');
}

#[test]
fn test_mul_div_rouding_up_accurate_without_phantom_overflow() {
    let result = Q128 / 3 + 1;
    assert(mul_div_rounding_up(Q128, 50 * Q128 / 100, 150 * Q128 / 100) == result, 'not equal');
}

#[test]
fn test_mul_div_rouding_up_accurate_with_phantom_overflow() {
    let result = 4375 * Q128 / 1000;
    assert(mul_div_rounding_up(Q128, 35 * Q128, 8 * Q128) == result, 'not equal');
}

#[test]
fn test_mul_div_rouding_up_accurate_with_phantom_overflow_and_repeating_decimal() {
    let result = Q128 / 3 + 1;
    assert(mul_div_rounding_up(Q128, 1000 * Q128, 3000 * Q128) == result, 'not equal');
}