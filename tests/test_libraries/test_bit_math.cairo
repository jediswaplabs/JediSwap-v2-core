use core::traits::TryInto;
use integer::BoundedInt;
use jediswap_v2_core::libraries::bit_math::{most_significant_bit, least_significant_bit};
use jediswap_v2_core::libraries::math_utils::pow;

#[test]
#[should_panic(expected: ('should be > 0',))]
fn test_most_significant_bit_reverts_for_0() {
    most_significant_bit(0);
}

#[test]
fn test_most_significant_bit_for_1() {
    assert(most_significant_bit(1) == 0, 'not for 1');
}

#[test]
fn test_most_significant_bit_for_2() {
    assert(most_significant_bit(2) == 1, 'not for 2');
}

#[test]
fn test_most_significant_bit_for_max() {
    assert(most_significant_bit(BoundedInt::max()) == 255, 'not for max');
}

#[test]
fn test_most_significant_bit_for_all_powers_of_2() {
    let mut index: u8 = 0;
    loop {
        assert(most_significant_bit(pow(2, index.into())) == index, index.into());
        if(index == 255) {
            break;
        }
        index += 1;
    }
}

#[test]
#[should_panic(expected: ('should be > 0',))]
fn test_least_significant_bit_reverts_for_0() {
    least_significant_bit(0);
}

#[test]
fn test_least_significant_bit_for_1() {
    assert(least_significant_bit(1) == 0, 'not for 1');
}

#[test]
fn test_least_significant_bit_for_2() {
    assert(least_significant_bit(2) == 1, 'not for 2');
}

#[test]
fn test_least_significant_bit_for_max() {
    assert(least_significant_bit(BoundedInt::max()) == 0, 'not for max');
}

#[test]
fn test_least_significant_bit_for_all_powers_of_2() {
    let mut index: u8 = 0;
    loop {
        assert(least_significant_bit(pow(2, index.into())) == index, index.into());
        if(index == 255) {
            break;
        }
        index += 1;
    }
}