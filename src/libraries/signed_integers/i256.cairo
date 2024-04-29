use integer::BoundedInt;
use jediswap_v2_core::libraries::signed_integers::{integer_trait::IntegerTrait};


// i256 represents a signed 256-bit integer.
// The mag field holds the absolute value of the integer.
// The sign field is true for negative integers, and false for non-negative integers.
#[derive(Copy, Drop, Serde, starknet::Store)]
struct i256 {
    mag: u256,
    sign: bool,
}

impl I256Zeroable of Zeroable<i256> {
    fn zero() -> i256 {
        i256 { mag: 0, sign: false }
    }
    
    #[inline(always)]
    fn is_zero(self: i256) -> bool {
        self == I256Zeroable::zero()
    }
    
    #[inline(always)]
    fn is_non_zero(self: i256) -> bool {
        !self.is_zero()
    }
}

// limit to 2 ** 255 to mirror Solidity implementation
fn i256_new(mag: u256, sign: bool) -> i256 {
    if (sign) {
        assert(mag <= 57896044618658097711785492504343953926634992332820282019728792003956564819968, 'i256: out of range');
    } else {
        assert(mag <= 57896044618658097711785492504343953926634992332820282019728792003956564819967, 'i256: out of range');
    }
    i256 { mag, sign }
}

impl i256Impl of IntegerTrait<i256, u256> {
    fn new(mag: u256, sign: bool) -> i256 {
        i256_new(mag, sign)
    }
}

// Checks if the given i256 integer is zero and has the correct sign.
fn i256_check_sign_zero(x: i256) {
    if (x.mag == 0) {
        assert(x.sign == false, 'sign of 0 must be false');
    }
}

// Adds two i256 integers.
fn i256_add(lhs: i256, rhs: i256) -> i256 {
    i256_check_sign_zero(lhs);
    i256_check_sign_zero(rhs);
    // If both integers have the same sign, 
    // the sum of their absolute values can be returned.
    if (lhs.sign == rhs.sign) {
        let sum = lhs.mag + rhs.mag;
        return ensure_zero_sign_and_check_overflow(i256 { mag: sum, sign: lhs.sign });
    } else {
        // If the integers have different signs, 
        // the larger absolute value is subtracted from the smaller one.
        let (larger, smaller) = if (lhs.mag >= rhs.mag) {
            (lhs, rhs)
        } else {
            (rhs, lhs)
        };
        let difference = larger.mag - smaller.mag;

        return ensure_zero_sign_and_check_overflow(i256 { mag: difference, sign: larger.sign });
    }
}

// Implements the Add trait for i256.
impl i256Add of Add<i256> {
    fn add(lhs: i256, rhs: i256) -> i256 {
        i256_add(lhs, rhs)
    }
}

// Implements the AddEq trait for i256.
impl i256AddEq of AddEq<i256> {
    #[inline(always)]
    fn add_eq(ref self: i256, other: i256) {
        self = Add::add(self, other);
    }
}

// Subtracts two i256 integers.
fn i256_sub(lhs: i256, rhs: i256) -> i256 {
    i256_check_sign_zero(lhs);
    i256_check_sign_zero(rhs);

    if (rhs.mag == 0) {
        return lhs;
    }

    // The subtraction of `lhs` to `rhs` is achieved by negating `rhs` sign and adding it to `lhs`.
    let neg_rhs = ensure_zero_sign_and_check_overflow(i256 { mag: rhs.mag, sign: !rhs.sign });
    return lhs + neg_rhs;
}

// Implements the Sub trait for i256.
impl i256Sub of Sub<i256> {
    fn sub(lhs: i256, rhs: i256) -> i256 {
        i256_sub(lhs, rhs)
    }
}

// Implements the SubEq trait for i256.
impl i256SubEq of SubEq<i256> {
    #[inline(always)]
    fn sub_eq(ref self: i256, other: i256) {
        self = Sub::sub(self, other);
    }
}

// Multiplies two i256 integers.
fn i256_mul(lhs: i256, rhs: i256) -> i256 {
    i256_check_sign_zero(lhs);
    i256_check_sign_zero(rhs);

    // The sign of the product is the XOR of the signs of the operands.
    let sign = lhs.sign ^ rhs.sign;
    // The product is the product of the absolute values of the operands.
    let mag = lhs.mag * rhs.mag;
    return ensure_zero_sign_and_check_overflow(i256 { mag, sign });
}

// Implements the Mul trait for i256.
impl i256Mul of Mul<i256> {
    fn mul(lhs: i256, rhs: i256) -> i256 {
        i256_mul(lhs, rhs)
    }
}

// Implements the MulEq trait for i256.
impl i256MulEq of MulEq<i256> {
    #[inline(always)]
    fn mul_eq(ref self: i256, other: i256) {
        self = Mul::mul(self, other);
    }
}

// Divides the first i256 by the second i256.
fn i256_div(lhs: i256, rhs: i256) -> i256 {
    i256_check_sign_zero(lhs);
    // Check that the divisor is not zero.
    assert(rhs.mag != 0, 'rhs can not be 0');

    // The sign of the quotient is the XOR of the signs of the operands.
    let sign = lhs.sign ^ rhs.sign;

    return ensure_zero_sign_and_check_overflow(i256 { mag: lhs.mag / rhs.mag, sign: sign });
}

// Implements the Div trait for i256.
impl i256Div of Div<i256> {
    fn div(lhs: i256, rhs: i256) -> i256 {
        i256_div(lhs, rhs)
    }
}

// Implements the DivEq trait for i256.
impl i256DivEq of DivEq<i256> {
    #[inline(always)]
    fn div_eq(ref self: i256, other: i256) {
        self = Div::div(self, other);
    }
}

// Calculates the remainder of the division of a first i256 by a second i256.
fn i256_rem(lhs: i256, rhs: i256) -> i256 {
    i256_check_sign_zero(lhs);
    // Check that the divisor is not zero.
    assert(rhs.mag != 0, 'rhs can not be 0');

    return lhs - (rhs * (lhs / rhs));
}

// Implements the Rem trait for i256.
impl i256Rem of Rem<i256> {
    fn rem(lhs: i256, rhs: i256) -> i256 {
        i256_rem(lhs, rhs)
    }
}

// Implements the RemEq trait for i256.
impl i256RemEq of RemEq<i256> {
    #[inline(always)]
    fn rem_eq(ref self: i256, other: i256) {
        self = Rem::rem(self, other);
    }
}

// Calculates both the quotient and the remainder of the division of a first i256 by a second i256.
fn i256_div_rem(lhs: i256, rhs: i256) -> (i256, i256) {
    let quotient = i256_div(lhs, rhs);
    let remainder = i256_rem(lhs, rhs);

    return (quotient, remainder);
}

// Compares two i256 integers for equality.
fn i256_eq(lhs: i256, rhs: i256) -> bool {
    // Check if the two integers have the same sign and the same absolute value.
    if ((lhs.sign == rhs.sign) & (lhs.mag == rhs.mag)) {
        return true;
    }

    return false;
}

// Compares two i256 integers for inequality.
fn i256_ne(lhs: i256, rhs: i256) -> bool {
    // The result is the inverse of the equal function.
    return !i256_eq(lhs, rhs);
}

// Implements the PartialEq trait for i256.
impl i256PartialEq of PartialEq<i256> {
    #[inline(always)]
    fn eq(lhs: @i256, rhs: @i256) -> bool {
        i256_eq(*lhs, *rhs)
    }

    #[inline(always)]
    fn ne(lhs: @i256, rhs: @i256) -> bool {
        i256_ne(*lhs, *rhs)
    }
}

// Compares two i256 integers for greater than.
fn i256_gt(lhs: i256, rhs: i256) -> bool {
    // Check if `lhs` is negative and `rhs` is positive.
    if (lhs.sign & !rhs.sign) {
        return false;
    }
    // Check if `lhs` is positive and `rhs` is negative.
    if (!lhs.sign & rhs.sign) {
        return true;
    }
    // If `lhs` and `rhs` have the same sign, compare their absolute values.
    if (lhs.sign & rhs.sign) {
        return lhs.mag < rhs.mag;
    } else {
        return lhs.mag > rhs.mag;
    }
}

// Determines whether the first i256 is less than the second i256.
fn i256_lt(lhs: i256, rhs: i256) -> bool {
    if (lhs == rhs) {
        return false;
    }
    // The result is the inverse of the greater than function.
    return !i256_gt(lhs, rhs);
}

// Checks if the first i256 integer is less than or equal to the second.
fn i256_le(lhs: i256, rhs: i256) -> bool {
    if ((lhs == rhs) || i256_lt(lhs, rhs)) {
        return true;
    } else {
        return false;
    }
}

// Checks if the first i256 integer is greater than or equal to the second.
fn i256_ge(lhs: i256, rhs: i256) -> bool {
    if ((lhs == rhs) || i256_gt(lhs, rhs)) {
        return true;
    } else {
        return false;
    }
}

// Implements the PartialOrd trait for i256.
impl i256PartialOrd of PartialOrd<i256> {
    #[inline(always)]
    fn le(lhs: i256, rhs: i256) -> bool {
        i256_le(lhs, rhs)
    }
    
    #[inline(always)]
    fn ge(lhs: i256, rhs: i256) -> bool {
        i256_ge(lhs, rhs)
    }

    #[inline(always)]
    fn lt(lhs: i256, rhs: i256) -> bool {
        i256_lt(lhs, rhs)
    }
    
    #[inline(always)]
    fn gt(lhs: i256, rhs: i256) -> bool {
        i256_gt(lhs, rhs)
    }
}

// Implements the Neg trait for i256.
impl i256Neg of Neg<i256> {
    #[inline(always)]
    fn neg(a: i256) -> i256 {
        ensure_zero_sign_and_check_overflow(i256 { mag: a.mag, sign: !a.sign })
    }
}

fn ensure_zero_sign_and_check_overflow(a: i256) -> i256 {
    if (a.mag == 0) {
        IntegerTrait::<i256>::new(a.mag, false)
    } else {
        IntegerTrait::<i256>::new(a.mag, a.sign)
    }
}

impl i256TryIntou256 of TryInto<i256, u256> {
    fn try_into(self: i256) -> Option<u256> {
        assert(self.sign == false, 'The sign must be positive');
        Option::Some(self.mag)
    }
}

impl u256Intoi256 of Into<u256, i256> {
    fn into(self: u256) -> i256 {
        IntegerTrait::<i256>::new(self, false)
    }
}

fn two_complement_if_nec(x: i256) -> i256 {
    let mag = if x.sign {
        ~(x.mag) + 1
    } else {
        x.mag
    };

    i256 { mag: mag, sign: x.sign }
}

fn bitwise_or(x: i256, y: i256) -> i256 {
    let x = two_complement_if_nec(x);
    let y = two_complement_if_nec(y);
    let sign = x.sign || y.sign;
    let mag = if sign {
        ~(x.mag | y.mag) + 1
    } else {
        x.mag | y.mag
    };

    IntegerTrait::<i256>::new(mag, sign)
}
