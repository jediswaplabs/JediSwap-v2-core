use integer::BoundedInt;
use jediswap_v2_core::libraries::signed_integers::{i256::i256, integer_trait::IntegerTrait};
use jediswap_v2_core::libraries::math_utils::pow;

trait BitShiftTrait<T> {
        fn shl(self: @T, n: T) -> T;
        fn shr(self: @T, n: T) -> T;
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

impl I256BitShift of BitShiftTrait<i256> {
    #[inline(always)]
    fn shl(self: @i256, n: i256) -> i256 {
        let mut new_mag = self.mag.shl(n.mag);
        // Left shift operation: mag << n
        if *self.sign {
            new_mag = new_mag & BoundedInt::<u256>::max() / 2;
        } else {
            new_mag = new_mag & ((BoundedInt::<u256>::max() / 2) - 1);
        };

        IntegerTrait::<i256>::new(new_mag, *self.sign)
    }

    #[inline(always)]
    fn shr(self: @i256, n: i256) -> i256 {
        let mut new_mag = self.mag.shr(n.mag);
        let mut new_sign = *self.sign;
        if (*self.sign) {
            new_mag += 1_u256;
        };
        if (new_mag == 0) {
            new_sign == false;
            // if (*self.sign) {
            //     new_sign = true;
            //     new_mag = 1;
            // } else {
            //     new_sign == false;
            // };
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