mod TickMath {
    use integer::BoundedInt;

    use jediswap_v2_core::libraries::signed_integers::{i32::i32, i256::{i256, bitwise_or}, integer_trait::IntegerTrait};
    use jediswap_v2_core::libraries::bitshift_trait::BitShiftTrait;

    impl i256TryIntoi32 of TryInto<i256, i32> {
        fn try_into(self: i256) -> Option<i32> {
            Option::Some(IntegerTrait::<i32>::new(self.mag.try_into().unwrap(), self.sign))
        }
    }

    // The minimum tick that may be passed to `get_sqrt_ratio_at_tick` computed from log base 1.0001 of 2**-128
    fn MIN_TICK() -> i32 {
        IntegerTrait::<i32>::new(887272, true)
    }

    // The maximum tick that may be passed to `get_sqrt_ratio_at_tick` computed from log base 1.0001 of 2**128
    fn MAX_TICK() -> i32 {
        IntegerTrait::<i32>::new(887272, false)
    }

    // The minimum value that can be returned from `get_sqrt_ratio_at_tick`. Equivalent to get_sqrt_ratio_at_tick(MIN_TICK).
    const MIN_SQRT_RATIO: u256 = 4295128739;
    // The maximum value that can be returned from `get_sqrt_ratio_at_tick`. Equivalent to get_sqrt_ratio_at_tick(MAX_TICK).
    const MAX_SQRT_RATIO: u256 = 1461446703485210103287273052203988822378723970342;

    // @notice Calculates sqrt(1.0001^tick) * 2^96
    // @dev Throws if |tick| > max tick
    // @param tick The input tick for the above formula
    // @return A Fixed point Q64.96 number representing the sqrt of the ratio of the two assets (token1/token0)
    // at the given tick`
    fn get_sqrt_ratio_at_tick(tick: i32) -> u256 {
        assert(tick.abs() <= MAX_TICK(), 'Invalid Tick');

        let abs_tick: u256 = tick.mag.into();
        let mut ratio = if ((abs_tick & 0x1) != 0) {
            0xfffcb933bd6fad37aa2d162d1a594001
        } else {
            0x100000000000000000000000000000000
        };

        if ((abs_tick & 0x2) != 0) {
            ratio = (ratio * 0xfff97272373d413259a46990580e213a).shr(128)
        };
        if ((abs_tick & 0x4) != 0) {
            ratio = (ratio * 0xfff2e50f5f656932ef12357cf3c7fdcc).shr(128)
        };
        if ((abs_tick & 0x8) != 0) {
            ratio = (ratio * 0xffe5caca7e10e4e61c3624eaa0941cd0).shr(128)
        };
        if ((abs_tick & 0x10) != 0) {
            ratio = (ratio * 0xffcb9843d60f6159c9db58835c926644).shr(128)
        };
        if ((abs_tick & 0x20) != 0) {
            ratio = (ratio * 0xff973b41fa98c081472e6896dfb254c0).shr(128)
        };
        if ((abs_tick & 0x40) != 0) {
            ratio = (ratio * 0xff2ea16466c96a3843ec78b326b52861).shr(128)
        };
        if ((abs_tick & 0x80) != 0) {
            ratio = (ratio * 0xfe5dee046a99a2a811c461f1969c3053).shr(128)
        };
        if ((abs_tick & 0x100) != 0) {
            ratio = (ratio * 0xfcbe86c7900a88aedcffc83b479aa3a4).shr(128)
        };
        if ((abs_tick & 0x200) != 0) {
            ratio = (ratio * 0xf987a7253ac413176f2b074cf7815e54).shr(128)
        };
        if ((abs_tick & 0x400) != 0) {
            ratio = (ratio * 0xf3392b0822b70005940c7a398e4b70f3).shr(128)
        };
        if ((abs_tick & 0x800) != 0) {
            ratio = (ratio * 0xe7159475a2c29b7443b29c7fa6e889d9).shr(128)
        };
        if ((abs_tick & 0x1000) != 0) {
            ratio = (ratio * 0xd097f3bdfd2022b8845ad8f792aa5825).shr(128)
        };
        if ((abs_tick & 0x2000) != 0) {
            ratio = (ratio * 0xa9f746462d870fdf8a65dc1f90e061e5).shr(128)
        };
        if ((abs_tick & 0x4000) != 0) {
            ratio = (ratio * 0x70d869a156d2a1b890bb3df62baf32f7).shr(128)
        };
        if ((abs_tick & 0x8000) != 0) {
            ratio = (ratio * 0x31be135f97d08fd981231505542fcfa6).shr(128)
        };
        if ((abs_tick & 0x10000) != 0) {
            ratio = (ratio * 0x9aa508b5b7a84e1c677de54f3e99bc9).shr(128)
        };
        if ((abs_tick & 0x20000) != 0) {
            ratio = (ratio * 0x5d6af8dedb81196699c329225ee604).shr(128)
        };
        if ((abs_tick & 0x40000) != 0) {
            ratio = (ratio * 0x2216e584f5fa1ea926041bedfe98).shr(128)
        };
        if ((abs_tick & 0x80000) != 0) {
            ratio = (ratio * 0x48a170391f7dc42444e8fa2).shr(128)
        };

        if (tick > IntegerTrait::<i32>::new(0, false)) {
            ratio = BoundedInt::max() / ratio;
        }

        let to_add = if (ratio % (1.shl(32)) == 0) {
            0
        } else {
            1
        };
        // this divides by 1<<32 rounding up to go from a Q128.128 to a Q128.96.
        // we round up in the division so get_tick_at_sqrt_ratio of the output price is always consistent
        return ((ratio.shr(32)) + to_add); // & ((1.shl(160)) - 1); TODO check this casting
    }

    // Returns 1 if a > b, otherwise returns 0.
    // This is not the behavior in Cairo.
    fn is_gt_as_int(a: u256, b: u256) -> u256 {
        if a > b {
            1
        } else {
            0
        }
    }

    // @notice Calculates the greatest tick value such that get_sqrt_ratio_at_tick(tick) <= ratio
    // @dev Throws in case sqrt_price_x96 < MIN_SQRT_RATIO, as MIN_SQRT_RATIO is the lowest value getRatioAtTick may
    // ever return.
    // @param sqrt_price_x96 The sqrt ratio for which to compute the tick as a Q64.96
    // @return The greatest tick for which the ratio is less than or equal to the input ratio
    fn get_tick_at_sqrt_ratio(sqrt_price_x96: u256) -> i32 {
        // second inequality must be < because the price can never reach the price at the max tick
        assert(
            sqrt_price_x96 >= MIN_SQRT_RATIO && sqrt_price_x96 < MAX_SQRT_RATIO,
            'Invalid sqrt ratio'
        );
        let ratio = sqrt_price_x96.shl(32);
        let mut r = ratio.clone();
        let mut msb = 0;

        let f = is_gt_as_int(r, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF).shl(7);
        msb = msb | f;
        r = r.shr(f);

        let f = is_gt_as_int(r, 0xFFFFFFFFFFFFFFFF).shl(6);
        msb = msb | f;
        r = r.shr(f);

        let f = is_gt_as_int(r, 0xFFFFFFFF).shl(5);
        msb = msb | f;
        r = r.shr(f);

        let f = is_gt_as_int(r, 0xFFFF).shl(4);
        msb = msb | f;
        r = r.shr(f);

        let f = is_gt_as_int(r, 0xFF).shl(3);
        msb = msb | f;
        r = r.shr(f);

        let f = is_gt_as_int(r, 0xF).shl(2);
        msb = msb | f;
        r = r.shr(f);

        let f = is_gt_as_int(r, 0x3).shl(1);
        msb = msb | f;
        r = r.shr(f);

        let f = is_gt_as_int(r, 0x1);
        msb = msb | f;

        if (msb >= 128) {
            r = ratio.shr(msb - 127)
        } else {
            r = ratio.shl(127 - msb)
        }

        let mut log_2: i256 = (IntegerTrait::<i256>::new(msb, false)
            - IntegerTrait::<i256>::new(128, false))
            .shl(IntegerTrait::<i256>::new(64, false));

        r = (r * r).shr(127);
        let f = r.shr(128);
        log_2 = bitwise_or(log_2, IntegerTrait::<i256>::new(f.shl(63), false));
        r = r.shr(f);

        r = (r * r).shr(127);
        let f = r.shr(128);
        log_2 = bitwise_or(log_2, IntegerTrait::<i256>::new(f.shl(62), false));
        r = r.shr(f);

        r = (r * r).shr(127);
        let f = r.shr(128);
        log_2 = bitwise_or(log_2, IntegerTrait::<i256>::new(f.shl(61), false));
        r = r.shr(f);

        r = (r * r).shr(127);
        let f = r.shr(128);
        log_2 = bitwise_or(log_2, IntegerTrait::<i256>::new(f.shl(60), false));
        r = r.shr(f);

        r = (r * r).shr(127);
        let f = r.shr(128);
        log_2 = bitwise_or(log_2, IntegerTrait::<i256>::new(f.shl(59), false));
        r = r.shr(f);

        r = (r * r).shr(127);
        let f = r.shr(128);
        log_2 = bitwise_or(log_2, IntegerTrait::<i256>::new(f.shl(58), false));
        r = r.shr(f);

        r = (r * r).shr(127);
        let f = r.shr(128);
        log_2 = bitwise_or(log_2, IntegerTrait::<i256>::new(f.shl(57), false));
        r = r.shr(f);

        r = (r * r).shr(127);
        let f = r.shr(128);
        log_2 = bitwise_or(log_2, IntegerTrait::<i256>::new(f.shl(56), false));
        r = r.shr(f);

        r = (r * r).shr(127);
        let f = r.shr(128);
        log_2 = bitwise_or(log_2, IntegerTrait::<i256>::new(f.shl(55), false));
        r = r.shr(f);

        r = (r * r).shr(127);
        let f = r.shr(128);
        log_2 = bitwise_or(log_2, IntegerTrait::<i256>::new(f.shl(54), false));
        r = r.shr(f);

        r = (r * r).shr(127);
        let f = r.shr(128);
        log_2 = bitwise_or(log_2, IntegerTrait::<i256>::new(f.shl(53), false));
        r = r.shr(f);

        r = (r * r).shr(127);
        let f = r.shr(128);
        log_2 = bitwise_or(log_2, IntegerTrait::<i256>::new(f.shl(52), false));
        r = r.shr(f);

        r = (r * r).shr(127);
        let f = r.shr(128);

        log_2 = bitwise_or(log_2, IntegerTrait::<i256>::new(f.shl(51), false));
        r = r.shr(f);

        r = (r * r).shr(127);
        let f = r.shr(128);
        log_2 = bitwise_or(log_2, IntegerTrait::<i256>::new(f.shl(50), false));

        let log_sqrt10001 = log_2
            * IntegerTrait::<i256>::new(255738958999603826347141, false); // 128.128 number

        let tick_low_i256 = (log_sqrt10001
            - IntegerTrait::<i256>::new(3402992956809132418596140100660247210, false))
            .shr(IntegerTrait::<i256>::new(128, false));

        let tick_low: i32 = tick_low_i256.try_into().unwrap();

        let tick_high_i256 = (log_sqrt10001
            + IntegerTrait::<i256>::new(291339464771989622907027621153398088495, false))
            .shr(IntegerTrait::<i256>::new(128, false));

        let tick_high: i32 = tick_high_i256.try_into().unwrap();

        let tick = if (tick_low == tick_high) {
            tick_low
        } else {
            if (get_sqrt_ratio_at_tick(tick_high) <= sqrt_price_x96) {
                tick_high
            } else {
                tick_low
            }
        };

        tick
    }
}
