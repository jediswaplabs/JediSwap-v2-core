use integer::BoundedInt;
use jediswap_v2_core::libraries::sqrt_price_math::SqrtPriceMath::{MAX_UINT160, R96, get_next_sqrt_price_from_input, get_next_sqrt_price_from_output, get_amount0_delta_unsigned, get_amount1_delta_unsigned};
use yas_core::utils::math_utils::{ pow, FullMath::mul_div, BitShift::BitShiftTrait };
use snforge_std::PrintTrait;

fn expand_to_18_decimals(n: u256) -> u256 {
    n * pow(10, 18)
}

// TODO encode_price_sqrt

#[test]
#[should_panic(expected: ('sqrt_p_x96 or liquidity <= 0',))]
fn test_get_next_sqrt_price_from_input_from_input_fails_if_price_is_zero() {
    get_next_sqrt_price_from_input(0, 0, expand_to_18_decimals(1) / 10, false);
}

#[test]
#[should_panic(expected: ('sqrt_p_x96 or liquidity <= 0',))]
fn test_get_next_sqrt_price_from_input_fails_if_liquidity_is_zero() {
    get_next_sqrt_price_from_input(1, 0, expand_to_18_decimals(1) / 10, true);
}

#[test]
#[should_panic(expected: ('does not fit uint160',))]
fn test_get_next_sqrt_price_from_input_fails_if_input_amount_overflows_price() {
    let price = MAX_UINT160;
    let liquidity = 1024;
    let amount_in = 1024;
    get_next_sqrt_price_from_input(price, liquidity, amount_in, false);
}

#[test]
fn test_get_next_sqrt_price_from_input_any_input_amount_cannot_underflow_the_price() {
    let price = 1;
    let liquidity = 1;
    let amount_in = pow(2, 255);
    let next_price = get_next_sqrt_price_from_input(price, liquidity, amount_in, true);

    assert(next_price == price, 'incorrect next_price');
}

#[test]
fn test_get_next_sqrt_price_from_input_returns_input_price_if_amount_in_is_zero_and_zero_for_one_equals_true() {
    let price = 79228162514264337593543950336; // encode_price_sqrt(1, 1);
    let liquidity: u128 = (expand_to_18_decimals(1) / 10).try_into().unwrap();
    let amount_in = 0;

    let next_price = get_next_sqrt_price_from_input(price, liquidity, amount_in, true);

    assert(next_price == price, 'incorrect next_price');
}

#[test]
fn test_get_next_sqrt_price_from_input_returns_input_price_if_amount_in_is_zero_and_zero_for_one_equals_false() {
    let price = 79228162514264337593543950336; // encode_price_sqrt(1, 1);
    let liquidity: u128 = (expand_to_18_decimals(1) / 10).try_into().unwrap();
    let amount_in = 0;

    let next_price = get_next_sqrt_price_from_input(price, liquidity, amount_in, true);

    assert(next_price == price, 'incorrect next_price');
}

#[test]
fn test_get_next_sqrt_price_from_input_returns_the_minumum_price_for_max_inputs() { // TODO getting u256_mul Overflow
    let price = MAX_UINT160;
    let liquidity: u128 = BoundedInt::max();
    let max_amount_no_overflow: u256 = BoundedInt::max() - (liquidity.into().shl(R96) / price);

    let next_price = get_next_sqrt_price_from_input(price, liquidity, max_amount_no_overflow, true);
    assert(next_price == 1, 'incorrect next_price');
}

#[test]
fn test_get_next_sqrt_price_from_input_input_amount_of_0_dot_1_token1() {
    let price = 79228162514264337593543950336; // encode_price_sqrt(1, 1);
    let liquidity: u128 = expand_to_18_decimals(1).try_into().unwrap();
    let amount = expand_to_18_decimals(1) / 10;

    let next_price = get_next_sqrt_price_from_input(price, liquidity, amount, false);
    assert(next_price == 87150978765690771352898345369, 'incorrect next_price');
}

#[test]
fn test_get_next_sqrt_price_from_input_input_amount_of_0_dot_1_token0() {
    let price = 79228162514264337593543950336; // encode_price_sqrt(1, 1);
    let liquidity: u128 = expand_to_18_decimals(1).try_into().unwrap();
    let amount = expand_to_18_decimals(1) / 10;

    let next_price = get_next_sqrt_price_from_input(price, liquidity, amount, true);
    assert(next_price == 72025602285694852357767227579, 'incorrect next_price');
}

#[test]
fn test_get_next_sqrt_price_from_input_amount_in_gt_uint_96_max_and_zero_for_one_equals_true() {
    let price = 79228162514264337593543950336; // encode_price_sqrt(1, 1);
    let liquidity: u128 = expand_to_18_decimals(10).try_into().unwrap();
    let amount = pow(2, 100);

    let next_price = get_next_sqrt_price_from_input(price, liquidity, amount, true);
    assert(next_price == 624999999995069620, 'incorrect next_price');
}

#[test]
fn test_get_next_sqrt_price_from_input_can_return_1_with_enough_amount_and_zero_for_one_equals_true() { // TODO u256_mul Overflow
    let price = 79228162514264337593543950336; // encode_price_sqrt(1, 1);
    let liquidity: u128 = 1;
    let amount = BoundedInt::max() / 2;

    let next_price = get_next_sqrt_price_from_input(price, liquidity, amount, true);
    assert(next_price == 1, 'incorrect next_price');
}


#[test]
#[should_panic(expected: ('sqrt_p_x96 or liquidity <= 0',))]
fn test_get_next_sqrt_price_from_output_fails_if_price_is_zero() {
    get_next_sqrt_price_from_output(0, 0, expand_to_18_decimals(1) / 10, false);
}

#[test]
#[should_panic(expected: ('sqrt_p_x96 or liquidity <= 0',))]
fn test_get_next_sqrt_price_from_output_fails_if_liquidity_is_zero() {
    get_next_sqrt_price_from_output(1, 0, expand_to_18_decimals(1) / 10, true);
}

#[test]
#[should_panic(expected: ('denominator negative',))]
fn test_get_next_sqrt_price_from_output_fails_if_output_amount_is_exactly_virtual_reserves_of_token0() {
    let price = 20282409603651670423947251286016;
    let liquidity = 1024;
    let amount_out = 4;
    get_next_sqrt_price_from_output(price, liquidity, amount_out, false);
}

#[test]
#[should_panic(expected: ('denominator negative',))]
fn test_get_next_sqrt_price_from_output_fails_if_output_amount_is_greater_than_virtual_reserves_of_token0() {
    let price = 20282409603651670423947251286016;
    let liquidity = 1024;
    let amount_out = 5;
    get_next_sqrt_price_from_output(price, liquidity, amount_out, false);
}

#[test]
#[should_panic(expected: ('sqrt_p_x96 < quotient',))]
fn test_get_next_sqrt_price_from_output_fails_if_output_amount_is_greater_than_virtual_reserves_of_token1() {
    let price = 20282409603651670423947251286016;
    let liquidity = 1024;
    let amount_out = 262145;
    get_next_sqrt_price_from_output(price, liquidity, amount_out, true);
}

#[test]
#[should_panic(expected: ('sqrt_p_x96 < quotient',))]
fn test_get_next_sqrt_price_from_output_fails_if_output_amount_is_exactly_virtual_reserves_of_token1() {
    let price = 20282409603651670423947251286016;
    let liquidity = 1024;
    let amount_out = 262144;
    get_next_sqrt_price_from_output(price, liquidity, amount_out, true);
}

#[test]
fn test_get_next_sqrt_price_from_output_output_amount_is_just_less_than_virtual_reservers_of_token1() {
    let price = 20282409603651670423947251286016;
    let liquidity = 1024;
    let amount_out = 262143;

    let next_price = get_next_sqrt_price_from_output(price, liquidity, amount_out, true);

    assert(next_price == 77371252455336267181195264, 'incorrect next_price');
}


#[test]
#[should_panic(expected: ('denominator negative',))]
fn test_get_next_sqrt_price_from_output_puzzling_echidna() {
    let price = 20282409603651670423947251286016;
    let liquidity = 1024;
    let amount_out = 4;
    get_next_sqrt_price_from_output(price, liquidity, amount_out, false);
}


#[test]
fn test_get_next_sqrt_price_from_output_returns_input_price_if_amount_in_is_zero_and_zero_for_one_equals_true() {
    let price = 79228162514264337593543950336; // encode_price_sqrt(1, 1);;
    let liquidity: u128 = expand_to_18_decimals(1).try_into().unwrap() / 10;
    let next_price = get_next_sqrt_price_from_output(price, liquidity, 0, true);

    assert(next_price == price, 'next price not equal');
}

#[test]
fn test_get_next_sqrt_price_from_output_returns_input_price_if_amount_in_is_zero_and_zero_for_one_equals_false() {
    let price = 79228162514264337593543950336; // encode_price_sqrt(1, 1);
    let liquidity: u128 = expand_to_18_decimals(1).try_into().unwrap() / 10;
    let next_price = get_next_sqrt_price_from_output(price, liquidity, 0, false);

    assert(next_price == price, 'next price not equal');
}

#[test]
fn test_get_next_sqrt_price_from_output_output_amount_of_0_dot_1_token1() {
    let price = 79228162514264337593543950336; // encode_price_sqrt(1, 1);
    let liquidity: u128 = expand_to_18_decimals(1).try_into().unwrap();
    let amount_out = expand_to_18_decimals(1) / 10;

    let next_price = get_next_sqrt_price_from_output(price, liquidity, amount_out, false);

    assert(next_price == 88031291682515930659493278152, 'incorrect next_price');
}

#[test]
fn test_get_next_sqrt_price_from_output_output_amount_of_0_dot_1_token0() {
    let price = 79228162514264337593543950336; // encode_price_sqrt(1, 1);
    let liquidity: u128 = expand_to_18_decimals(1).try_into().unwrap();
    let amount_out = expand_to_18_decimals(1) / 10;

    let next_price = get_next_sqrt_price_from_output(price, liquidity, amount_out, true);
    
    assert(next_price == 71305346262837903834189555302, 'incorrect next_price');
}

#[test]
#[should_panic(expected: ('mul_div u256 overflow',))]   // TODO is this correct error?
fn test_get_next_sqrt_price_from_output_fails_if_amount_out_is_impossible_in_zero_for_one_direction() {
    let price = 79228162514264337593543950336; // encode_price_sqrt(1, 1);
    let liquidity = 1;
    let amount_out: u256 = BoundedInt::max();
    get_next_sqrt_price_from_output(price, liquidity, amount_out, true);
}

#[test]
#[should_panic(expected: ('u256_mul Overflow',))]   // TODO is this correct error?
fn test_get_next_sqrt_price_from_output_fails_if_amount_out_is_impossible_in_one_to_zero_direction() {
    let price = 79228162514264337593543950336; // encode_price_sqrt(1, 1);
    let liquidity = 1;
    let amount_out: u256 = BoundedInt::max();
    get_next_sqrt_price_from_output(price, liquidity, amount_out, false);
}

#[test]
fn test_get_amount0_delta_unsigned_returns_0_if_liquidity_is_0() {
    let sqrt_a_x96 = 79228162514264337593543950336; // encode_price_sqrt(1, 1)
    let sqrt_b_x96 = 112045541949572279837463876454; // encode_price_sqrt(2, 1)
    
    let amount0 = get_amount0_delta_unsigned(sqrt_a_x96, sqrt_b_x96, 0, true);  // encode_price_sqrt(1, 1), encode_price_sqrt(2, 1);
    
    assert(amount0 == 0, 'amount0 not 0');
}


#[test]
fn test_get_amount0_delta_unsigned_returns_0_if_prices_are_equal() {
    let sqrt_a_x96 = 79228162514264337593543950336; // encode_price_sqrt(1, 1)
    
    let amount0 = get_amount0_delta_unsigned(sqrt_a_x96, sqrt_a_x96, 0, true);    // encode_price_sqrt(1, 1), encode_price_sqrt(1, 1);

    assert(amount0 == 0, 'amount0 not 0');
}

#[test]
fn test_get_amount0_delta_unsigned_returns_0_1_amount1_for_price_of_1_to_1_21() {
    let sqrt_a_x96 = 79228162514264337593543950336; // encode_price_sqrt(1, 1)
    let sqrt_b_x96 = 87150978765690771352898345369; // encode_price_sqrt(121, 100)
    
    let amount0 = get_amount0_delta_unsigned(sqrt_a_x96, sqrt_b_x96, expand_to_18_decimals(1).try_into().unwrap(), true);

    assert(amount0 == 90909090909090910, 'incorrect amount0');

    let amount0_rounded_down = get_amount0_delta_unsigned(sqrt_a_x96, sqrt_b_x96, expand_to_18_decimals(1).try_into().unwrap(), false);
    
    assert(amount0_rounded_down == amount0 - 1, 'incorrect amount0_rounded_down');
}

#[test]
fn test_get_amount0_delta_unsigned_works_for_prices_that_overflow() {
    let sqrt_a_x96 = 2787593149816327920953038481947722450866090; // encode_price_sqrt(2 ** 90, 1)
    let sqrt_b_x96 = 22300745198530623480214298539844178181255951; // encode_price_sqrt(2 ** 96, 1)
    let liquidity: u128 = expand_to_18_decimals(1).try_into().unwrap();
    
    let amount_0_up = get_amount0_delta_unsigned(sqrt_a_x96, sqrt_b_x96, liquidity, true);

    let amount_0_down = get_amount0_delta_unsigned(sqrt_a_x96, sqrt_b_x96, liquidity, false);
    
    assert(amount_0_up == amount_0_down + 1, 'amount_0_up not amount_0_down+1');
}


#[test]
fn test_get_amount1_delta_unsigned_returns_0_if_liquidity_is_0() {
    let sqrt_a_x96 = 79228162514264337593543950336; // encode_price_sqrt(1, 1)
    let sqrt_b_x96 = 112045541949572279837463876454; // encode_price_sqrt(2, 1)
    
    let amount1 = get_amount1_delta_unsigned(sqrt_a_x96, sqrt_b_x96, 0, true);
    
    assert(amount1 == 0, 'amount1 not 0');
}

#[test]
fn test_get_amount1_delta_unsigned_returns_0_if_prices_are_eq() {
    let sqrt_a_x96 = 79228162514264337593543950336; // encode_price_sqrt(1, 1)
    
    let amount1 = get_amount1_delta_unsigned(sqrt_a_x96, sqrt_a_x96, expand_to_18_decimals(1).try_into().unwrap(), true);
    
    assert(amount1 == 0, 'amount1 not 0');
}

#[test]
fn test_get_amount1_delta_unsigned_returns_0_1_amount1_for_price_1_to_1_21() {
    let sqrt_a_x96 = 79228162514264337593543950336; // encode_price_sqrt(1, 1)
    let sqrt_b_x96 = 87150978765690771352898345369; // encode_price_sqrt(121, 100)

    let liquidity: u128 = expand_to_18_decimals(1).try_into().unwrap();

    let amount1 = get_amount1_delta_unsigned(sqrt_a_x96, sqrt_b_x96, liquidity, true);

    assert(amount1 == 100000000000000000, 'incorrect amount1');

    let amount1_rounded_down = get_amount1_delta_unsigned(sqrt_a_x96, sqrt_b_x96, expand_to_18_decimals(1).try_into().unwrap(), false);
    
    assert(amount1_rounded_down == amount1 - 1, 'incorrect amount1_rounded_down');
}
