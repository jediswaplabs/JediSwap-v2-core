use integer::BoundedInt;
use jediswap_v2_core::libraries::signed_integers::{i16::i16, integer_trait::IntegerTrait};


// i32 represents a signed 32-bit integer.
// The mag field holds the absolute value of the integer.
// The sign field is true for negative integers, and false for non-negative integers.
#[derive(Copy, Drop, Serde, Hash, starknet::Store)]
struct i32 {
    mag: u32,
    sign: bool,
}

impl I32Zeroable of Zeroable<i32> {
    fn zero() -> i32 {
        i32 { mag: 0, sign: false }
    }
    
    #[inline(always)]
    fn is_zero(self: i32) -> bool {
        self == I32Zeroable::zero()
    }
    
    #[inline(always)]
    fn is_non_zero(self: i32) -> bool {
        !self.is_zero()
    }
}

// limit to 2 ** 31 to mirror Solidity implementation
fn i32_new(mag: u32, sign: bool) -> i32 {
    if (sign) {
        assert(mag <= 2147483648, 'i32: out of range');
    } else {
        assert(mag <= 2147483647, 'i32: out of range');
    }
    i32 { mag, sign }
}

// Computes the absolute value of the given i32 integer.
fn i32_abs(a: i32) -> i32 {
    return i32 { mag: a.mag, sign: false };
}

impl i32Impl of IntegerTrait<i32, u32> {
    fn new(mag: u32, sign: bool) -> i32 {
        i32_new(mag, sign)
    }

    fn abs(self: i32) -> i32 {
        i32_abs(self)
    }
}

// Checks if the given i32 integer is zero and has the correct sign.
fn i32_check_sign_zero(x: i32) {
    if (x.mag == 0) {
        assert(x.sign == false, 'sign of 0 must be false');
    }
}

// Adds two i32 integers.
fn i32_add(lhs: i32, rhs: i32) -> i32 {
    i32_check_sign_zero(lhs);
    i32_check_sign_zero(rhs);
    // If both integers have the same sign, 
    // the sum of their absolute values can be returned.
    if (lhs.sign == rhs.sign) {
        let sum = lhs.mag + rhs.mag;
        return ensure_zero_sign_and_check_overflow(i32 { mag: sum, sign: lhs.sign });
    } else {
        // If the integers have different signs, 
        // the larger absolute value is subtracted from the smaller one.
        let (larger, smaller) = if (lhs.mag >= rhs.mag) {
            (lhs, rhs)
        } else {
            (rhs, lhs)
        };
        let difference = larger.mag - smaller.mag;

        return ensure_zero_sign_and_check_overflow(i32 { mag: difference, sign: larger.sign });
    }
}

// Implements the Add trait for i32.
impl i32Add of Add<i32> {
    fn add(lhs: i32, rhs: i32) -> i32 {
        i32_add(lhs, rhs)
    }
}

// Implements the AddEq trait for i32.
impl i32AddEq of AddEq<i32> {
    #[inline(always)]
    fn add_eq(ref self: i32, other: i32) {
        self = Add::add(self, other);
    }
}

// Subtracts two i32 integers.
fn i32_sub(lhs: i32, rhs: i32) -> i32 {
    i32_check_sign_zero(lhs);
    i32_check_sign_zero(rhs);

    if (rhs.mag == 0) {
        return lhs;
    }

    // The subtraction of `lhs` to `rhs` is achieved by negating `rhs` sign and adding it to `lhs`.
    let neg_rhs = ensure_zero_sign_and_check_overflow(i32 { mag: rhs.mag, sign: !rhs.sign });
    return lhs + neg_rhs;
}

// Implements the Sub trait for i32.
impl i32Sub of Sub<i32> {
    fn sub(lhs: i32, rhs: i32) -> i32 {
        i32_sub(lhs, rhs)
    }
}

// Implements the SubEq trait for i32.
impl i32SubEq of SubEq<i32> {
    #[inline(always)]
    fn sub_eq(ref self: i32, other: i32) {
        self = Sub::sub(self, other);
    }
}

// Multiplies two i32 integers.
fn i32_mul(lhs: i32, rhs: i32) -> i32 {
    i32_check_sign_zero(lhs);
    i32_check_sign_zero(rhs);

    // The sign of the product is the XOR of the signs of the operands.
    let sign = lhs.sign ^ rhs.sign;
    // The product is the product of the absolute values of the operands.
    let mag = lhs.mag * rhs.mag;
    return ensure_zero_sign_and_check_overflow(i32 { mag, sign });
}

// Implements the Mul trait for i32.
impl i32Mul of Mul<i32> {
    fn mul(lhs: i32, rhs: i32) -> i32 {
        i32_mul(lhs, rhs)
    }
}

// Implements the MulEq trait for i32.
impl i32MulEq of MulEq<i32> {
    #[inline(always)]
    fn mul_eq(ref self: i32, other: i32) {
        self = Mul::mul(self, other);
    }
}

// Divides the first i32 by the second i32.
fn i32_div(lhs: i32, rhs: i32) -> i32 {
    i32_check_sign_zero(lhs);
    // Check that the divisor is not zero.
    assert(rhs.mag != 0, 'rhs can not be 0');

    // The sign of the quotient is the XOR of the signs of the operands.
    let sign = lhs.sign ^ rhs.sign;

    return ensure_zero_sign_and_check_overflow(i32 { mag: lhs.mag / rhs.mag, sign: sign });

    // TODO check the rounding

    // if (sign == false) {
    //     // If the operands are positive, the quotient is simply their absolute value quotient.
    //     return i32 { mag: lhs.mag / rhs.mag, sign: sign };
    // }

    // // If the operands have different signs, rounding is necessary.
    // // First, check if the quotient is an integer.
    // if (lhs.mag % rhs.mag == 0) {
    //     return i32 { mag: lhs.mag / rhs.mag, sign: sign };
    // }
    
    // return i32 { mag: lhs.mag / rhs.mag, sign: sign };

    // // // If the quotient is not an integer, multiply the dividend by 10 to move the decimal point over.
    // // let quotient = (lhs.mag * 10) / rhs.mag;
    // // let last_digit = quotient % 10;

    // // // Check the last digit to determine rounding direction.
    // // if (last_digit <= 5) {
    // //     return i32 { mag: quotient / 10, sign: sign };
    // // } else {
    // //     return i32 { mag: (quotient / 10) + 1, sign: sign };
    // // }
}

// Implements the Div trait for i32.
impl i32Div of Div<i32> {
    fn div(lhs: i32, rhs: i32) -> i32 {
        i32_div(lhs, rhs)
    }
}

// Implements the DivEq trait for i32.
impl i32DivEq of DivEq<i32> {
    #[inline(always)]
    fn div_eq(ref self: i32, other: i32) {
        self = Div::div(self, other);
    }
}

// Calculates the remainder of the division of a first i32 by a second i32.
fn i32_rem(lhs: i32, rhs: i32) -> i32 {
    i32_check_sign_zero(lhs);
    // Check that the divisor is not zero.
    assert(rhs.mag != 0, 'rhs can not be 0');


    return lhs - (rhs * (lhs / rhs));
}

// Implements the Rem trait for i32.
impl i32Rem of Rem<i32> {
    fn rem(lhs: i32, rhs: i32) -> i32 {
        i32_rem(lhs, rhs)
    }
}

// Implements the RemEq trait for i32.
impl i32RemEq of RemEq<i32> {
    #[inline(always)]
    fn rem_eq(ref self: i32, other: i32) {
        self = Rem::rem(self, other);
    }
}

// Calculates both the quotient and the remainder of the division of a first i32 by a second i32.
fn i32_div_rem(lhs: i32, rhs: i32) -> (i32, i32) {
    let quotient = i32_div(lhs, rhs);
    let remainder = i32_rem(lhs, rhs);

    return (quotient, remainder);
}

// Compares two i32 integers for equality.
fn i32_eq(lhs: i32, rhs: i32) -> bool {
    // Check if the two integers have the same sign and the same absolute value.
    if ((lhs.sign == rhs.sign) & (lhs.mag == rhs.mag)) {
        return true;
    }

    return false;
}

// Compares two i32 integers for inequality.
fn i32_ne(lhs: i32, rhs: i32) -> bool {
    // The result is the inverse of the equal function.
    return !i32_eq(lhs, rhs);
}

// Implements the PartialEq trait for i32.
impl i32PartialEq of PartialEq<i32> {
    #[inline(always)]
    fn eq(lhs: @i32, rhs: @i32) -> bool {
        i32_eq(*lhs, *rhs)
    }

    #[inline(always)]
    fn ne(lhs: @i32, rhs: @i32) -> bool {
        i32_ne(*lhs, *rhs)
    }
}

// Compares two i32 integers for greater than.
fn i32_gt(lhs: i32, rhs: i32) -> bool {
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

// Determines whether the first i32 is less than the second i32.
fn i32_lt(lhs: i32, rhs: i32) -> bool {
    if (lhs == rhs) {
        return false;
    }
    // The result is the inverse of the greater than function.
    return !i32_gt(lhs, rhs);
}

// Checks if the first i32 integer is less than or equal to the second.
fn i32_le(lhs: i32, rhs: i32) -> bool {
    if ((lhs == rhs) || i32_lt(lhs, rhs)) {
        return true;
    } else {
        return false;
    }
}

// Checks if the first i32 integer is greater than or equal to the second.
fn i32_ge(lhs: i32, rhs: i32) -> bool {
    if ((lhs == rhs) || i32_gt(lhs, rhs)) {
        return true;
    } else {
        return false;
    }
}

// Implements the PartialOrd trait for i32.
impl i32PartialOrd of PartialOrd<i32> {
    #[inline(always)]
    fn le(lhs: i32, rhs: i32) -> bool {
        i32_le(lhs, rhs)
    }
    
    #[inline(always)]
    fn ge(lhs: i32, rhs: i32) -> bool {
        i32_ge(lhs, rhs)
    }

    #[inline(always)]
    fn lt(lhs: i32, rhs: i32) -> bool {
        i32_lt(lhs, rhs)
    }
    
    #[inline(always)]
    fn gt(lhs: i32, rhs: i32) -> bool {
        i32_gt(lhs, rhs)
    }
}

// Implements the Neg trait for i32.
impl i32Neg of Neg<i32> {
    #[inline(always)]
    fn neg(a: i32) -> i32 {
        ensure_zero_sign_and_check_overflow(i32 { mag: a.mag, sign: !a.sign })
    }
}

fn ensure_zero_sign_and_check_overflow(a: i32) -> i32 {
    if (a.mag == 0) {
        IntegerTrait::<i32>::new(a.mag, false)
    } else {
        IntegerTrait::<i32>::new(a.mag, a.sign)
    }
}

impl u8Intoi32 of Into<u8, i32> {
    fn into(self: u8) -> i32 {
        IntegerTrait::<i32>::new(self.into(), false)
    }
}

impl i32TryIntou8 of TryInto<i32, u8> {
    fn try_into(self: i32) -> Option<u8> {
        assert(self.sign == false, 'The sign must be positive');
        let max: u8 = BoundedInt::max();
        assert(self.mag <= max.into(), 'Overflow of magnitude');
        self.mag.try_into()
    }
}

impl i32TryIntoi16 of TryInto<i32, i16> {
    fn try_into(self: i32) -> Option<i16> {
        Option::Some(IntegerTrait::<i16>::new(self.mag.try_into().unwrap(), self.sign))
    }
}

impl i32TryIntou128 of TryInto<i32, u128> {
    fn try_into(self: i32) -> Option<u128> {
        assert(self.sign == false, 'The sign must be positive');
        Option::Some(self.mag.into())
    }
}