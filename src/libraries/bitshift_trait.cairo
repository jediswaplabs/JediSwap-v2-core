use integer::{u256_safe_div_rem, u256_try_as_non_zero, BoundedInt};
use jediswap_v2_core::libraries::signed_integers::{i256::i256, integer_trait::IntegerTrait};
use jediswap_v2_core::libraries::math_utils::pow;

trait BitShiftTrait<T> {
    fn shl(self: @T, n: T) -> T;
    fn shr(self: @T, n: T) -> T;
}

trait BitShiftTraitRoundUp<T> {
    fn shr_round_up(self: @T, n: T) -> T;
}

impl U256BitShift of BitShiftTrait<u256> {
    #[inline(always)]
    fn shl(self: @u256, n: u256) -> u256 {
        *self * pow(2, n)
    }

    #[inline(always)]
    fn shr(self: @u256, n: u256) -> u256 {
        *self / pow(2, n)
    }
}

impl U256BitShiftRoundUp of BitShiftTraitRoundUp<u256> {
    #[inline(always)]
    fn shr_round_up(self: @u256, n: u256) -> u256 {
        let (q, r) = u256_safe_div_rem(*self, u256_try_as_non_zero(pow(2, n)).expect('shr by zero'));
        if (r != 0) {
            q + 1
        } else {
            q
        }
    }
}

impl I256BitShift of BitShiftTrait<i256> {
    #[inline(always)]
    fn shl(self: @i256, n: i256) -> i256 {
        let mut new_mag = self.mag.shl(n.mag);
        // Left shift operation: mag << n
        
        // Doesn't support solidity type(int256).min
        new_mag = new_mag & ((BoundedInt::<u256>::max() / 2));

        IntegerTrait::<i256>::new(new_mag, *self.sign)
    }

    #[inline(always)]
    fn shr(self: @i256, n: i256) -> i256 {
        let mut new_mag = 0;
        let mut new_sign = *self.sign;
        if (*self.sign) {
            new_mag = self.mag.shr_round_up(n.mag);
            // new_mag += 1_u256;
        } else {
            new_mag = self.mag.shr(n.mag);
        };
        
        if (new_mag == 0) {
            new_sign == false;
        };

        // Right shift operation: mag >> n
        IntegerTrait::<i256>::new(new_mag, new_sign)
    }
}

impl U32BitShift of BitShiftTrait<u32> {
    #[inline(always)]
    fn shl(self: @u32, n: u32) -> u32 {
        *self * pow(2, n.into()).try_into().unwrap()
    }

    #[inline(always)]
    fn shr(self: @u32, n: u32) -> u32 {
        *self / pow(2, n.into()).try_into().unwrap()
    }
}

impl U8BitShift of BitShiftTrait<u8> {
    #[inline(always)]
    fn shl(self: @u8, n: u8) -> u8 {
        *self * pow(2, n.into()).try_into().unwrap()
    }

    #[inline(always)]
    fn shr(self: @u8, n: u8) -> u8 {
        *self / pow(2, n.into()).try_into().unwrap()
    }
}