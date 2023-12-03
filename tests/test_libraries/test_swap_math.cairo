use jediswap_v2_core::libraries::sqrt_price_math::SqrtPriceMath;
use jediswap_v2_core::libraries::swap_math::SwapMath;
use yas_core::numbers::signed_integer::i256::{i256, i256TryIntou256};

use yas_core::numbers::signed_integer::integer_trait::IntegerTrait;

fn expand_to_18_decimals(n: u256) -> u256 {
    n * 1000000000000000000
}

// TODO encode_price_sqrt

// exact amount in that gets capped at price target in one to zero
#[test]
fn test_amount_in_gets_capped_at_price_target_in_one_to_zero() {
    let price = 79228162514264337593543950336; //  encode_price_sqrt(1, 1) 
    let price_target = 79623317895830914510639640423;   //  encode_price_sqrt(101, 100) 
    let liquidity: u128 = expand_to_18_decimals(2).try_into().unwrap();
    let amount = IntegerTrait::<i256>::new(expand_to_18_decimals(1), false);
    let fee: u32 = 600;
    let zero_to_one = false;

    let (sqrt_q_x96, amount_in, amount_out, fee_amount) = SwapMath::compute_swap_step(
        price, price_target, liquidity, amount, fee
    );

    assert(amount_in == 9975124224178055, 'incorrect amount_in');
    assert(fee_amount == 5988667735148, 'incorrect fee_amount');
    assert(amount_out == 9925619580021728, 'incorrect amount_out');
    assert(
        amount_in + fee_amount < amount.try_into().unwrap(), 'entire amount is not used'
    );

    let price_after_whole_input_amount = SqrtPriceMath::get_next_sqrt_price_from_input(
        price, liquidity, amount.try_into().unwrap(), zero_to_one
    );

    assert(sqrt_q_x96 == price_target, 'price is capped at price target');
    assert(
        sqrt_q_x96 < price_after_whole_input_amount, 'price < price after whole input'
    ); // price is less than price after whole input amount
}

// exact amount out that gets capped at price target in one to zero
#[test]
fn test_amount_out_gets_capped_at_price_target_in_one_to_zero() {
    let price = 79228162514264337593543950336; // encode_price_sqrt(1, 1)
    let price_target = 79623317895830914510639640423;  // encode_price_sqrt(101, 100)
    let liquidity: u128 = expand_to_18_decimals(2).try_into().unwrap();
    let amount = IntegerTrait::<i256>::new(expand_to_18_decimals(1), true);
    let fee = 600;
    let zero_to_one = false;

    let (sqrt_q_x96, amount_in, amount_out, fee_amount) = SwapMath::compute_swap_step(
        price, price_target, liquidity, amount, fee
    );

    assert(amount_in == 9975124224178055, 'incorrect amount_in');
    assert(fee_amount == 5988667735148, 'incorrect fee_amount');
    assert(amount_out == 9925619580021728, 'incorrect amount_out');
    assert(amount_out < expand_to_18_decimals(1), 'entire amount out isnt returned');

    let price_after_whole_input_amount = SqrtPriceMath::get_next_sqrt_price_from_output(
        price, liquidity, expand_to_18_decimals(1), zero_to_one
    );

    assert(sqrt_q_x96 == price_target, 'price is capped at price target');
    assert(sqrt_q_x96 < price_after_whole_input_amount, 'price < price after whole input');
}

// exact amount in that is fully spent in one to zero
#[test]
fn test_amount_in_that_is_fully_spent_in_one_to_zero() {
    let price = 79228162514264337593543950336; // encode_price_sqrt(1, 1) 
    let price_target = 250541448375047931186413801569; // encode_price_sqrt(1000, 100)

    let liquidity: u128 = expand_to_18_decimals(2).try_into().unwrap();
    let amount = IntegerTrait::<i256>::new(expand_to_18_decimals(1), false);
    let fee = 600;
    let zero_to_one = false;

    let (sqrt_q_x96, amount_in, amount_out, fee_amount) = SwapMath::compute_swap_step(
        price, price_target, liquidity, amount, fee
    );

    assert(amount_in == 999400000000000000, 'incorrect amount_in');
    assert(fee_amount == 600000000000000, 'incorrect fee_amount');
    assert(amount_out == 666399946655997866, 'incorrect amount_out');
    assert(
        amount_in + fee_amount == amount.try_into().unwrap(), 'entire amount is not used'
    );

    let price_after_whole_import_amount_less_fee =
        SqrtPriceMath::get_next_sqrt_price_from_input(
        price, liquidity, amount.try_into().unwrap() - fee_amount, zero_to_one
    );

    assert(sqrt_q_x96 < price_target, 'price is capped at price target');
    assert(
        sqrt_q_x96 == price_after_whole_import_amount_less_fee, 'price = p_after_amount_less_fee'
    );
}

// exact amount out that is fully received in one to zero
#[test]
fn test_amount_out_that_is_fully_received_in_one_to_zero() {
    let price = 79228162514264337593543950336; // encode_price_sqrt(1, 1)
    let price_target = 792281625142643375935439503360; // encode_price_sqrt(10000, 100)

    let liquidity: u128 = expand_to_18_decimals(2).try_into().unwrap();
    let amount = IntegerTrait::<i256>::new(expand_to_18_decimals(1), true);
    let fee = 600;
    let zero_to_one = false;

    let (sqrt_q_x96, amount_in, amount_out, fee_amount) = SwapMath::compute_swap_step(
        price, price_target, liquidity, amount, fee
    );

    assert(amount_in == 2000000000000000000, 'incorrect amount_in');
    assert(fee_amount == 1200720432259356, 'incorrect fee_amount');
    assert(amount_out == expand_to_18_decimals(1), 'incorrect amount_out');

    let price_after_whole_output_amount = SqrtPriceMath::get_next_sqrt_price_from_output(
        price, liquidity, expand_to_18_decimals(1), zero_to_one
    );

    assert(sqrt_q_x96 < price_target, 'price doest reach price target');
    assert(sqrt_q_x96 == price_after_whole_output_amount, 'price = price after whole out');
}

// amount out is capped at the desired amount out
#[test]
fn test_amount_out_is_capped_at_the_desired_amount_out() {
    let price = 417332158212080721273783715441582;
    let price_target = 1452870262520218020823638996;
    let liquidity: u128 = 159344665391607089467575320103;
    let amount = IntegerTrait::<i256>::new(1, true);
    let fee = 1;

    let (sqrt_q_x96, amount_in, amount_out, fee_amount) = SwapMath::compute_swap_step(
        price, price_target, liquidity, amount, fee
    );

    assert(amount_in == 1, 'incorrect amount_in');
    assert(fee_amount == 1, 'incorrect fee_amount');
    assert(amount_out == 1, 'incorrect amount_out'); // would be 2 if not capped
    assert(
        sqrt_q_x96 == 417332158212080721273783715441581,
        'incorrect sqrt_q_x96'
    );
}

// target price of 1 uses partial input amount
#[test]
fn test_target_price_of_1_uses_partial_input_amount() {
    let price = 2;
    let price_target = 1;
    let liquidity: u128 = 1;
    let amount = IntegerTrait::<i256>::new(3915081100057732413702495386755767, false);
    let fee = 1;

    let (sqrt_q_x96, amount_in, amount_out, fee_amount) = SwapMath::compute_swap_step(
        price, price_target, liquidity, amount, fee
    );
    assert(amount_in == 39614081257132168796771975168, 'incorrect amount_in');
    assert(fee_amount == 39614120871253040049813, 'incorrect fee_amount');
    assert(
        amount_in + fee_amount <= 3915081100057732413702495386755767,
        'incorrect amount_in+fee_amount'
    );
    assert(amount_out <= 0, 'incorrect amount_out');
    assert(sqrt_q_x96 == 1, 'incorrect sqrt_q_x96');
}

// entire input amount taken as fee
#[test]
fn test_entire_input_amount_taken_as_fee() {
    let price = 2413;
    let price_target = 79887613182836312;
    let liquidity: u128 = 1985041575832132834610021537970;
    let amount = IntegerTrait::<i256>::new(10, false);
    let fee = 1872;

    let (sqrt_q_x96, amount_in, amount_out, fee_amount) = SwapMath::compute_swap_step(
        price, price_target, liquidity, amount, fee
    );

    assert(amount_in == 0, 'incorrect amount_in');
    assert(fee_amount == 10, 'incorrect fee_amount');
    assert(amount_out <= 0, 'incorrect amount_out');
    assert(sqrt_q_x96 == 2413, 'incorrect sqrt_q_x96');
}

// handles intermediate insufficient liquidity in zero for one exact output case
#[test]
fn test_handles_intermediate_insufficient_liq_in_zero_to_one_exact_output_case() {
    let price = 20282409603651670423947251286016;
    let price_target = price * 11 / 10;
    let liquidity: u128 = 1024;
    // virtual reserves of one are only 4
    // https://www.wolframalpha.com/input/?i=1024+%2F+%2820282409603651670423947251286016+%2F+2**96%29
    let amount_remaining = IntegerTrait::<i256>::new(4, true);
    let fee = 3000;

    let (sqrt_q_x96, amount_in, amount_out, fee_amount) = SwapMath::compute_swap_step(
        price, price_target, liquidity, amount_remaining, fee
    );

    assert(amount_in == 26215, 'incorrect amount_in');
    assert(amount_out == 0, 'incorrect amount_out');
    assert(sqrt_q_x96 == price_target, 'incorrect sqrt_q_x96');
    assert(fee_amount == 79, 'incorrect fee_amount');
}

// handles intermediate insufficient liquidity in one to zero exact output case
#[test]
fn test_handles_intermediate_insufficient_liq_in_zero_for_on_exact_output_case() {
    let price = 20282409603651670423947251286016;
    let price_target = price * 9 / 10;
    let liquidity: u128 = 1024;
    // virtual reserves of zero are only 262144
    // https://www.wolframalpha.com/input/?i=1024+*+%2820282409603651670423947251286016+%2F+2**96%29
    let amount_remaining = IntegerTrait::<i256>::new(263000, true);
    let fee = 3000;

    let (sqrt_q_x96, amount_in, amount_out, fee_amount) = SwapMath::compute_swap_step(
        price, price_target, liquidity, amount_remaining, fee
    );

    assert(amount_in == 1, 'incorrect amount_in');
    assert(fee_amount == 1, 'incorrect fee_amount');
    assert(amount_out == 26214, 'incorrect amount_out');
    assert(sqrt_q_x96 == price_target, 'incorrect sqrt_q_x96');
}