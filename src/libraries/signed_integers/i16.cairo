use integer::BoundedInt;
use jediswap_v2_core::libraries::signed_integers::integer_trait::IntegerTrait;


// i16 represents a signed 16-bit integer.
// The mag field holds the absolute value of the integer.
// The sign field is true for negative integers, and false for non-negative integers.
#[derive(Copy, Drop, Serde, Hash, starknet::Store)]
struct i16 {
    mag: u16,
    sign: bool,
}

impl I16Zeroable of Zeroable<i16> {
    fn zero() -> i16 {
        i16 { mag: 0, sign: false }
    }
    
    #[inline(always)]
    fn is_zero(self: i16) -> bool {
        self == I16Zeroable::zero()
    }
    
    #[inline(always)]
    fn is_non_zero(self: i16) -> bool {
        !self.is_zero()
    }
}

// limit to 2 ** 31 to mirror Solidity implementation
fn i16_new(mag: u16, sign: bool) -> i16 {
    if (sign) {
        assert(mag <= 32768, 'i16: out of range');
    } else {
        assert(mag <= 32767, 'i16: out of range');
    }
    i16 { mag, sign }
}

impl i16Impl of IntegerTrait<i16, u16> {
    fn new(mag: u16, sign: bool) -> i16 {
        i16_new(mag, sign)
    }
}

// Checks if the given i16 integer is zero and has the correct sign.
fn i16_check_sign_zero(x: i16) {
    if (x.mag == 0) {
        assert(x.sign == false, 'sign of 0 must be false');
    }
}

// Adds two i16 integers.
fn i16_add(lhs: i16, rhs: i16) -> i16 {
    i16_check_sign_zero(lhs);
    i16_check_sign_zero(rhs);
    // If both integers have the same sign, 
    // the sum of their absolute values can be returned.
    if (lhs.sign == rhs.sign) {
        let sum = lhs.mag + rhs.mag;
        return ensure_zero_sign_and_check_overflow(i16 { mag: sum, sign: lhs.sign });
    } else {
        // If the integers have different signs, 
        // the larger absolute value is subtracted from the smaller one.
        let (larger, smaller) = if (lhs.mag >= rhs.mag) {
            (lhs, rhs)
        } else {
            (rhs, lhs)
        };
        let difference = larger.mag - smaller.mag;

        return ensure_zero_sign_and_check_overflow(i16 { mag: difference, sign: larger.sign });
    }
}

// Implements the Add trait for i16.
impl i16Add of Add<i16> {
    fn add(lhs: i16, rhs: i16) -> i16 {
        i16_add(lhs, rhs)
    }
}

// Implements the AddEq trait for i16.
impl i16AddEq of AddEq<i16> {
    #[inline(always)]
    fn add_eq(ref self: i16, other: i16) {
        self = Add::add(self, other);
    }
}

// Subtracts two i16 integers.
fn i16_sub(lhs: i16, rhs: i16) -> i16 {
    i16_check_sign_zero(lhs);
    i16_check_sign_zero(rhs);

    if (rhs.mag == 0) {
        return lhs;
    }

    // The subtraction of `lhs` to `rhs` is achieved by negating `rhs` sign and adding it to `lhs`.
    let neg_rhs = ensure_zero_sign_and_check_overflow(i16 { mag: rhs.mag, sign: !rhs.sign });
    return lhs + neg_rhs;
}

// Implements the Sub trait for i16.
impl i16Sub of Sub<i16> {
    fn sub(lhs: i16, rhs: i16) -> i16 {
        i16_sub(lhs, rhs)
    }
}

// Implements the SubEq trait for i16.
impl i16SubEq of SubEq<i16> {
    #[inline(always)]
    fn sub_eq(ref self: i16, other: i16) {
        self = Sub::sub(self, other);
    }
}

// Multiplies two i16 integers.
fn i16_mul(lhs: i16, rhs: i16) -> i16 {
    i16_check_sign_zero(lhs);
    i16_check_sign_zero(rhs);

    // The sign of the product is the XOR of the signs of the operands.
    let sign = lhs.sign ^ rhs.sign;
    // The product is the product of the absolute values of the operands.
    let mag = lhs.mag * rhs.mag;
    return ensure_zero_sign_and_check_overflow(i16 { mag, sign });
}

// Implements the Mul trait for i16.
impl i16Mul of Mul<i16> {
    fn mul(lhs: i16, rhs: i16) -> i16 {
        i16_mul(lhs, rhs)
    }
}

// Implements the MulEq trait for i16.
impl i16MulEq of MulEq<i16> {
    #[inline(always)]
    fn mul_eq(ref self: i16, other: i16) {
        self = Mul::mul(self, other);
    }
}

// Divides the first i16 by the second i16.
fn i16_div(lhs: i16, rhs: i16) -> i16 {
    i16_check_sign_zero(lhs);
    // Check that the divisor is not zero.
    assert(rhs.mag != 0, 'rhs can not be 0');

    // The sign of the quotient is the XOR of the signs of the operands.
    let sign = lhs.sign ^ rhs.sign;

    return ensure_zero_sign_and_check_overflow(i16 { mag: lhs.mag / rhs.mag, sign: sign });

    // TODO check the rounding

    // if (sign == false) {
    //     // If the operands are positive, the quotient is simply their absolute value quotient.
    //     return i16 { mag: lhs.mag / rhs.mag, sign: sign };
    // }

    // // If the operands have different signs, rounding is necessary.
    // // First, check if the quotient is an integer.
    // if (lhs.mag % rhs.mag == 0) {
    //     return i16 { mag: lhs.mag / rhs.mag, sign: sign };
    // }
    
    // return i16 { mag: lhs.mag / rhs.mag, sign: sign };

    // // If the quotient is not an integer, multiply the dividend by 10 to move the decimal point over.
    // let quotient = (lhs.mag * 10) / rhs.mag;
    // let last_digit = quotient % 10;

    // // Check the last digit to determine rounding direction.
    // if (last_digit <= 5) {
    //     return i16 { mag: quotient / 10, sign: sign };
    // } else {
    //     return i16 { mag: (quotient / 10) + 1, sign: sign };
    // }
}

// Implements the Div trait for i16.
impl i16Div of Div<i16> {
    fn div(lhs: i16, rhs: i16) -> i16 {
        i16_div(lhs, rhs)
    }
}

// Implements the DivEq trait for i16.
impl i16DivEq of DivEq<i16> {
    #[inline(always)]
    fn div_eq(ref self: i16, other: i16) {
        self = Div::div(self, other);
    }
}

// Calculates the remainder of the division of a first i16 by a second i16.
fn i16_rem(lhs: i16, rhs: i16) -> i16 {
    i16_check_sign_zero(lhs);
    // Check that the divisor is not zero.
    assert(rhs.mag != 0, 'rhs can not be 0');

    return lhs - (rhs * (lhs / rhs));
}

// Implements the Rem trait for i16.
impl i16Rem of Rem<i16> {
    fn rem(lhs: i16, rhs: i16) -> i16 {
        i16_rem(lhs, rhs)
    }
}

// Implements the RemEq trait for i16.
impl i16RemEq of RemEq<i16> {
    #[inline(always)]
    fn rem_eq(ref self: i16, other: i16) {
        self = Rem::rem(self, other);
    }
}

// Calculates both the quotient and the remainder of the division of a first i16 by a second i16.
fn i16_div_rem(lhs: i16, rhs: i16) -> (i16, i16) {
    let quotient = i16_div(lhs, rhs);
    let remainder = i16_rem(lhs, rhs);

    return (quotient, remainder);
}

// Compares two i16 integers for equality.
fn i16_eq(lhs: i16, rhs: i16) -> bool {
    // Check if the two integers have the same sign and the same absolute value.
    if ((lhs.sign == rhs.sign) & (lhs.mag == rhs.mag)) {
        return true;
    }

    return false;
}

// Compares two i16 integers for inequality.
fn i16_ne(lhs: i16, rhs: i16) -> bool {
    // The result is the inverse of the equal function.
    return !i16_eq(lhs, rhs);
}

// Implements the PartialEq trait for i16.
impl i16PartialEq of PartialEq<i16> {
    #[inline(always)]
    fn eq(lhs: @i16, rhs: @i16) -> bool {
        i16_eq(*lhs, *rhs)
    }

    #[inline(always)]
    fn ne(lhs: @i16, rhs: @i16) -> bool {
        i16_ne(*lhs, *rhs)
    }
}

// Compares two i16 integers for greater than.
fn i16_gt(lhs: i16, rhs: i16) -> bool {
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

// Determines whether the first i16 is less than the second i16.
fn i16_lt(lhs: i16, rhs: i16) -> bool {
    if (lhs == rhs) {
        return false;
    }
    // The result is the inverse of the greater than function.
    return !i16_gt(lhs, rhs);
}

// Checks if the first i16 integer is less than or equal to the second.
fn i16_le(lhs: i16, rhs: i16) -> bool {
    if ((lhs == rhs) || i16_lt(lhs, rhs)) {
        return true;
    } else {
        return false;
    }
}

// Checks if the first i16 integer is greater than or equal to the second.
fn i16_ge(lhs: i16, rhs: i16) -> bool {
    if ((lhs == rhs) || i16_gt(lhs, rhs)) {
        return true;
    } else {
        return false;
    }
}

// Implements the PartialOrd trait for i16.
impl i16PartialOrd of PartialOrd<i16> {
    #[inline(always)]
    fn le(lhs: i16, rhs: i16) -> bool {
        i16_le(lhs, rhs)
    }
    
    #[inline(always)]
    fn ge(lhs: i16, rhs: i16) -> bool {
        i16_ge(lhs, rhs)
    }

    #[inline(always)]
    fn lt(lhs: i16, rhs: i16) -> bool {
        i16_lt(lhs, rhs)
    }
    
    #[inline(always)]
    fn gt(lhs: i16, rhs: i16) -> bool {
        i16_gt(lhs, rhs)
    }
}

// Implements the Neg trait for i16.
impl i16Neg of Neg<i16> {
    #[inline(always)]
    fn neg(a: i16) -> i16 {
        ensure_zero_sign_and_check_overflow(i16 { mag: a.mag, sign: !a.sign })
    }
}

fn ensure_zero_sign_and_check_overflow(a: i16) -> i16 {
    if (a.mag == 0) {
        IntegerTrait::<i16>::new(a.mag, false)
    } else {
        IntegerTrait::<i16>::new(a.mag, a.sign)
    }
}
