use integer::BoundedInt;
use jediswap_v2_core::libraries::signed_integers::{integer_trait::IntegerTrait};


// i128 represents a signed 128-bit integer.
// The mag field holds the absolute value of the integer.
// The sign field is true for negative integers, and false for non-negative integers.
#[derive(Copy, Drop, Serde, starknet::Store)]
struct i128 {
    mag: u128,
    sign: bool,
}

impl I128Zeroable of Zeroable<i128> {
    fn zero() -> i128 {
        i128 { mag: 0, sign: false }
    }
    
    #[inline(always)]
    fn is_zero(self: i128) -> bool {
        self == I128Zeroable::zero()
    }
    
    #[inline(always)]
    fn is_non_zero(self: i128) -> bool {
        !self.is_zero()
    }
}

// limit to 2 ** 127 to mirror Solidity implementation
fn i128_new(mag: u128, sign: bool) -> i128 {
    if (sign) {
        assert(mag <= 170141183460469231731687303715884105728, 'i128: out of range');
    } else {
        assert(mag <= 170141183460469231731687303715884105727, 'i128: out of range');
    }
    i128 { mag, sign }
}

impl i128Impl of IntegerTrait<i128, u128> {
    fn new(mag: u128, sign: bool) -> i128 {
        i128_new(mag, sign)
    }
}

// Checks if the given i128 integer is zero and has the correct sign.
fn i128_check_sign_zero(x: i128) {
    if (x.mag == 0) {
        assert(x.sign == false, 'sign of 0 must be false');
    }
}

// Adds two i128 integers.
fn i128_add(lhs: i128, rhs: i128) -> i128 {
    i128_check_sign_zero(lhs);
    i128_check_sign_zero(rhs);
    // If both integers have the same sign, 
    // the sum of their absolute values can be returned.
    if (lhs.sign == rhs.sign) {
        let sum = lhs.mag + rhs.mag;
        return ensure_zero_sign_and_check_overflow(i128 { mag: sum, sign: lhs.sign });
    } else {
        // If the integers have different signs, 
        // the larger absolute value is subtracted from the smaller one.
        let (larger, smaller) = if (lhs.mag >= rhs.mag) {
            (lhs, rhs)
        } else {
            (rhs, lhs)
        };
        let difference = larger.mag - smaller.mag;

        return ensure_zero_sign_and_check_overflow(i128 { mag: difference, sign: larger.sign });
    }
}

// Implements the Add trait for i128.
impl i128Add of Add<i128> {
    fn add(lhs: i128, rhs: i128) -> i128 {
        i128_add(lhs, rhs)
    }
}

// Implements the AddEq trait for i128.
impl i128AddEq of AddEq<i128> {
    #[inline(always)]
    fn add_eq(ref self: i128, other: i128) {
        self = Add::add(self, other);
    }
}

// Subtracts two i128 integers.
fn i128_sub(lhs: i128, rhs: i128) -> i128 {
    i128_check_sign_zero(lhs);
    i128_check_sign_zero(rhs);

    if (rhs.mag == 0) {
        return lhs;
    }

    // The subtraction of `lhs` to `rhs` is achieved by negating `rhs` sign and adding it to `lhs`.
    let neg_rhs = ensure_zero_sign_and_check_overflow(i128 { mag: rhs.mag, sign: !rhs.sign });
    return lhs + neg_rhs;
}

// Implements the Sub trait for i128.
impl i128Sub of Sub<i128> {
    fn sub(lhs: i128, rhs: i128) -> i128 {
        i128_sub(lhs, rhs)
    }
}

// Implements the SubEq trait for i128.
impl i128SubEq of SubEq<i128> {
    #[inline(always)]
    fn sub_eq(ref self: i128, other: i128) {
        self = Sub::sub(self, other);
    }
}

// Multiplies two i128 integers.
fn i128_mul(lhs: i128, rhs: i128) -> i128 {
    i128_check_sign_zero(lhs);
    i128_check_sign_zero(rhs);

    // The sign of the product is the XOR of the signs of the operands.
    let sign = lhs.sign ^ rhs.sign;
    // The product is the product of the absolute values of the operands.
    let mag = lhs.mag * rhs.mag;
    return ensure_zero_sign_and_check_overflow(i128 { mag, sign });
}

// Implements the Mul trait for i128.
impl i128Mul of Mul<i128> {
    fn mul(lhs: i128, rhs: i128) -> i128 {
        i128_mul(lhs, rhs)
    }
}

// Implements the MulEq trait for i128.
impl i128MulEq of MulEq<i128> {
    #[inline(always)]
    fn mul_eq(ref self: i128, other: i128) {
        self = Mul::mul(self, other);
    }
}

// Divides the first i128 by the second i128.
fn i128_div(lhs: i128, rhs: i128) -> i128 {
    i128_check_sign_zero(lhs);
    // Check that the divisor is not zero.
    assert(rhs.mag != 0, 'rhs can not be 0');

    // The sign of the quotient is the XOR of the signs of the operands.
    let sign = lhs.sign ^ rhs.sign;

    return ensure_zero_sign_and_check_overflow(i128 { mag: lhs.mag / rhs.mag, sign: sign });
}

// Implements the Div trait for i128.
impl i128Div of Div<i128> {
    fn div(lhs: i128, rhs: i128) -> i128 {
        i128_div(lhs, rhs)
    }
}

// Implements the DivEq trait for i128.
impl i128DivEq of DivEq<i128> {
    #[inline(always)]
    fn div_eq(ref self: i128, other: i128) {
        self = Div::div(self, other);
    }
}

// Calculates the remainder of the division of a first i128 by a second i128.
fn i128_rem(lhs: i128, rhs: i128) -> i128 {
    i128_check_sign_zero(lhs);
    // Check that the divisor is not zero.
    assert(rhs.mag != 0, 'rhs can not be 0');

    return lhs - (rhs * (lhs / rhs));
}

// Implements the Rem trait for i128.
impl i128Rem of Rem<i128> {
    fn rem(lhs: i128, rhs: i128) -> i128 {
        i128_rem(lhs, rhs)
    }
}

// Implements the RemEq trait for i128.
impl i128RemEq of RemEq<i128> {
    #[inline(always)]
    fn rem_eq(ref self: i128, other: i128) {
        self = Rem::rem(self, other);
    }
}

// Calculates both the quotient and the remainder of the division of a first i128 by a second i128.
fn i128_div_rem(lhs: i128, rhs: i128) -> (i128, i128) {
    let quotient = i128_div(lhs, rhs);
    let remainder = i128_rem(lhs, rhs);

    return (quotient, remainder);
}

// Compares two i128 integers for equality.
fn i128_eq(lhs: i128, rhs: i128) -> bool {
    // Check if the two integers have the same sign and the same absolute value.
    if ((lhs.sign == rhs.sign) & (lhs.mag == rhs.mag)) {
        return true;
    }

    return false;
}

// Compares two i128 integers for inequality.
fn i128_ne(lhs: i128, rhs: i128) -> bool {
    // The result is the inverse of the equal function.
    return !i128_eq(lhs, rhs);
}

// Implements the PartialEq trait for i128.
impl i128PartialEq of PartialEq<i128> {
    #[inline(always)]
    fn eq(lhs: @i128, rhs: @i128) -> bool {
        i128_eq(*lhs, *rhs)
    }

    #[inline(always)]
    fn ne(lhs: @i128, rhs: @i128) -> bool {
        i128_ne(*lhs, *rhs)
    }
}

// Compares two i128 integers for greater than.
fn i128_gt(lhs: i128, rhs: i128) -> bool {
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

// Determines whether the first i128 is less than the second i128.
fn i128_lt(lhs: i128, rhs: i128) -> bool {
    if (lhs == rhs) {
        return false;
    }
    // The result is the inverse of the greater than function.
    return !i128_gt(lhs, rhs);
}

// Checks if the first i128 integer is less than or equal to the second.
fn i128_le(lhs: i128, rhs: i128) -> bool {
    if ((lhs == rhs) || i128_lt(lhs, rhs)) {
        return true;
    } else {
        return false;
    }
}

// Checks if the first i128 integer is greater than or equal to the second.
fn i128_ge(lhs: i128, rhs: i128) -> bool {
    if ((lhs == rhs) || i128_gt(lhs, rhs)) {
        return true;
    } else {
        return false;
    }
}

// Implements the PartialOrd trait for i128.
impl i128PartialOrd of PartialOrd<i128> {
    #[inline(always)]
    fn le(lhs: i128, rhs: i128) -> bool {
        i128_le(lhs, rhs)
    }
    
    #[inline(always)]
    fn ge(lhs: i128, rhs: i128) -> bool {
        i128_ge(lhs, rhs)
    }

    #[inline(always)]
    fn lt(lhs: i128, rhs: i128) -> bool {
        i128_lt(lhs, rhs)
    }
    
    #[inline(always)]
    fn gt(lhs: i128, rhs: i128) -> bool {
        i128_gt(lhs, rhs)
    }
}

// Implements the Neg trait for i128.
impl i128Neg of Neg<i128> {
    #[inline(always)]
    fn neg(a: i128) -> i128 {
        ensure_zero_sign_and_check_overflow(i128 { mag: a.mag, sign: !a.sign })
    }
}

fn ensure_zero_sign_and_check_overflow(a: i128) -> i128 {
    if (a.mag == 0) {
        IntegerTrait::<i128>::new(a.mag, false)
    } else {
        IntegerTrait::<i128>::new(a.mag, a.sign)
    }
}

impl u128Intoi128 of Into<u128, i128> {
    fn into(self: u128) -> i128 {
        IntegerTrait::<i128>::new(self, false)
    }
}
