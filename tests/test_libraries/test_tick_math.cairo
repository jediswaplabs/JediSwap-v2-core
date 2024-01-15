use jediswap_v2_core::libraries::tick_math::TickMath::{
    MIN_TICK, MAX_TICK, MAX_SQRT_RATIO, MIN_SQRT_RATIO, get_sqrt_ratio_at_tick,
    get_tick_at_sqrt_ratio
};
use jediswap_v2_core::libraries::sqrt_price_math::SqrtPriceMath::{Q96};
use yas_core::numbers::signed_integer::{i32::i32, integer_trait::IntegerTrait};
use snforge_std::PrintTrait;

#[test]
fn test_min_tick_equals_negative_max_tick() {
    assert(MIN_TICK() == -MAX_TICK(), 'MIN_TICK not -MAX_TICK');
}

#[test]
#[should_panic(expected: ('Invalid Tick',))]
fn test_get_sqrt_ratio_at_tick_fails_for_too_low() {
    let value = MIN_TICK() - IntegerTrait::<i32>::new(1, false);
    get_sqrt_ratio_at_tick(value);
}

#[test]
#[should_panic(expected: ('Invalid Tick',))]
fn test_get_sqrt_ratio_at_tick_fails_for_too_high() {
    let value = MAX_TICK() + IntegerTrait::<i32>::new(1, false);
    get_sqrt_ratio_at_tick(value);
}

#[test]
fn test_get_sqrt_ratio_at_tick_is_valid_min_tick() {
    assert(get_sqrt_ratio_at_tick(MIN_TICK()) == MIN_SQRT_RATIO, 'incorrect ratio at MIN_TICK');
    assert(get_sqrt_ratio_at_tick(MIN_TICK()) == 4295128739, 'incorrect ratio at MIN_TICK');
}

#[test]
fn test_get_sqrt_ratio_at_tick_is_valid_min_tick_add_one() {
    let value = MIN_TICK() + IntegerTrait::<i32>::new(1, false);
    assert(get_sqrt_ratio_at_tick(value) == 4295343490, 'incorrect ratio at MIN_TICK + 1');
}

#[test]
fn test_get_sqrt_ratio_at_tick_is_valid_max_tick() {
    assert(get_sqrt_ratio_at_tick(MAX_TICK()) == MAX_SQRT_RATIO, 'incorrect ratio at MAX_TICK');
    assert(
        get_sqrt_ratio_at_tick(MAX_TICK()) == 1461446703485210103287273052203988822378723970342,
        'incorrect ratio at MAX_TICK'
    );
}

#[test]
fn test_get_sqrt_ratio_at_tick_is_valid_max_tick_sub_one() {
    let value = MAX_TICK() - IntegerTrait::<i32>::new(1, false);
    assert(
        get_sqrt_ratio_at_tick(value) == 1461373636630004318706518188784493106690254656249,
        'incorrect ratio at MAX_TICK - 1'
    );
}

fn _matches_python_by_one_hundredth_of_a_bip(tick: i32, python_ratio: u256, err_msg: felt252) {
    let sqrt_ratio = get_sqrt_ratio_at_tick(tick);
    let diff = if (sqrt_ratio > python_ratio) {
        sqrt_ratio - python_ratio
    } else {
        python_ratio - sqrt_ratio
    };
    assert((diff * 100000) / python_ratio == 0, err_msg);
}

// python_ratio = int(math.sqrt((1.0001 ** tick)) * (2**96))
#[test]
fn test_get_sqrt_ratio_at_tick_matches_python_by_one_hundredth_of_a_bip() {
    _matches_python_by_one_hundredth_of_a_bip(
        IntegerTrait::<i32>::new(50, false), 79426470787362564183332749312, '50'
    );
    _matches_python_by_one_hundredth_of_a_bip(
        IntegerTrait::<i32>::new(50, true), 79030349367926623380336279552, '-50'
    );

    _matches_python_by_one_hundredth_of_a_bip(
        IntegerTrait::<i32>::new(100, false), 79625275426524698543654961152, '100'
    );
    _matches_python_by_one_hundredth_of_a_bip(
        IntegerTrait::<i32>::new(100, true), 78833030112140218996086538240, '-100'
    );

    _matches_python_by_one_hundredth_of_a_bip(
        IntegerTrait::<i32>::new(250, false), 80224679980005204522633789440, '250'
    );
    _matches_python_by_one_hundredth_of_a_bip(
        IntegerTrait::<i32>::new(250, true), 78244023372248473262413053952, '-250'
    );

    _matches_python_by_one_hundredth_of_a_bip(
        IntegerTrait::<i32>::new(500, false), 81233731461782943452224290816, '500'
    );
    _matches_python_by_one_hundredth_of_a_bip(
        IntegerTrait::<i32>::new(500, true), 77272108795590580476229713920, '-500'
    );

    _matches_python_by_one_hundredth_of_a_bip(
        IntegerTrait::<i32>::new(1000, false), 83290069058675764276559347712, '1000'
    );
    _matches_python_by_one_hundredth_of_a_bip(
        IntegerTrait::<i32>::new(1000, true), 75364347830767439984841457664, '-1000'
    );

    _matches_python_by_one_hundredth_of_a_bip(
        IntegerTrait::<i32>::new(2500, false), 89776708723585931833226821632, '2500'
    );
    _matches_python_by_one_hundredth_of_a_bip(
        IntegerTrait::<i32>::new(2500, true), 69919044979843140138347528192, '-2500'
    );

    _matches_python_by_one_hundredth_of_a_bip(
        IntegerTrait::<i32>::new(5000, false), 101729702841315830865122557952, '5000'
    );
    _matches_python_by_one_hundredth_of_a_bip(
        IntegerTrait::<i32>::new(5000, true), 61703726247761524449525891072, '-5000'
    );

    _matches_python_by_one_hundredth_of_a_bip(
        IntegerTrait::<i32>::new(10000, false), 130621891405334421671298203648, '10000'
    );
    _matches_python_by_one_hundredth_of_a_bip(
        IntegerTrait::<i32>::new(10000, true), 48055510970271650415741239296, '-10000'
    );

    _matches_python_by_one_hundredth_of_a_bip(
        IntegerTrait::<i32>::new(50000, false), 965075977352955512569221611520, '50000'
    );
    _matches_python_by_one_hundredth_of_a_bip(
        IntegerTrait::<i32>::new(50000, true), 6504256538022775632552787968, '-50000'
    );

    _matches_python_by_one_hundredth_of_a_bip(
        IntegerTrait::<i32>::new(250000, false), 21246587762904151822324099702587392, '250000'
    );
    _matches_python_by_one_hundredth_of_a_bip(
        IntegerTrait::<i32>::new(250000, true), 295440463449208326717440, '-250000'
    );

    _matches_python_by_one_hundredth_of_a_bip(
        IntegerTrait::<i32>::new(500000, false), 5697689776479602583788423076217614237696, '500000'
    );
    _matches_python_by_one_hundredth_of_a_bip(
        IntegerTrait::<i32>::new(500000, true), 1101692437046840448, '-500000'
    );

    _matches_python_by_one_hundredth_of_a_bip(
        IntegerTrait::<i32>::new(887272, false),
        1461446703478070281035530027706464741740609798144,
        '887272'
    );
    _matches_python_by_one_hundredth_of_a_bip(
        IntegerTrait::<i32>::new(887272, true), 4295128738, '-887272'
    );
}


#[test]
#[should_panic(expected: ('Invalid sqrt ratio',))]
fn test_get_tick_at_sqrt_ratio_fails_for_too_low() {
    let input = MIN_SQRT_RATIO - 1;
    get_tick_at_sqrt_ratio(input);
}

#[test]
#[should_panic(expected: ('Invalid sqrt ratio',))]
fn test_get_tick_at_sqrt_ratio_fails_for_too_high() {
    let input = MAX_SQRT_RATIO + 1;
    get_tick_at_sqrt_ratio(input);
}

#[test]
fn test_get_tick_at_sqrt_ratio_is_valid_min_sqrt_ratio() {
    let input = MIN_SQRT_RATIO;
    let tick = get_tick_at_sqrt_ratio(input);
    assert(tick == MIN_TICK(), 'incorrect tick MIN_SQRT_RATIO');
}

#[test]
fn test_get_tick_at_sqrt_ratio_is_valid_min_sqrt_ratio_plus_one() {
    let input = 4295343490;
    let tick = get_tick_at_sqrt_ratio(input);
    assert(
        tick == (MIN_TICK() + IntegerTrait::<i32>::new(1, false)), 'incorrect tick at MIN_TICK + 1'
    );
}

#[test]
fn test_get_tick_at_sqrt_ratio_is_valid_ratio_closest_to_max_tick() {
    let input = MAX_SQRT_RATIO - 1;
    let tick = get_tick_at_sqrt_ratio(input);
    assert(
        tick == MAX_TICK() - IntegerTrait::<i32>::new(1, false), 'incorrect tick MAX_SQRT_RATIO'
    );
}

#[test]
fn test_get_tick_at_sqrt_ratio_is_valid_max_sqrt_ratio_minus_one() {
    let input = 1461373636630004318706518188784493106690254656249;
    let tick = get_tick_at_sqrt_ratio(input);
    assert(
        tick == MAX_TICK() - IntegerTrait::<i32>::new(1, false), 'incorrect tick at MAX_TICK - 1'
    );
}

// python_tick = math.floor(math.log((sqrt_ratio_x96 / (2 ** 96)) ** 2, 1.0001))
fn _matches_python_within_1(sqrt_ratio_x96: u256, python_tick: i32, err_msg: felt252) {
    let tick = get_tick_at_sqrt_ratio(sqrt_ratio_x96);
    let diff = (tick - python_tick).mag;
    assert(diff <= 1, err_msg);
}

#[test]
fn test_get_tick_at_sqrt_ratio_matches_python_within_1() { // TODO Could not reach the end of the program. RunResources has no remaining steps. Why??
    _matches_python_within_1(
        MIN_SQRT_RATIO, IntegerTrait::<i32>::new(887272, true), 'MIN_SQRT_RATIO'
    );

    _matches_python_within_1(68722059824, IntegerTrait::<i32>::new(831818, true), '68722059824');

    // _matches_python_within_1(17592847314944, IntegerTrait::<i32>::new(720909, true), '17592847314944');

    // _matches_python_within_1(4503768912625664, IntegerTrait::<i32>::new(610000, true), '4503768912625664');

    // _matches_python_within_1(1152964841632169984, IntegerTrait::<i32>::new(499091, true), '1152964841632169984');

    // _matches_python_within_1(295158999457835515904, IntegerTrait::<i32>::new(388182, true), '295158999457835515904');

    // _matches_python_within_1(1208971261779294273142784, IntegerTrait::<i32>::new(221818, true), '1208971261779294273142784');

    // _matches_python_within_1(79231140611967829484685492224, IntegerTrait::<i32>::new(0, false), '79231140611967829484685492224');

    // _matches_python_within_1(5192492031145923673108348418392064, IntegerTrait::<i32>::new(221818, false), '519249...392064');

    // _matches_python_within_1(5444722524050868061453259551163876900864, IntegerTrait::<i32>::new(499091, false), '544472...900864');

    // _matches_python_within_1(1393848966157022223732034445097952486621184, IntegerTrait::<i32>::new(610000, false), '139384...621184');

    // _matches_python_within_1(5709205365379163028406413087121213385200369664, IntegerTrait::<i32>::new(776364, false), '570920...369664');

    _matches_python_within_1(
        91347285846066608454502609393939414163205914624,
        IntegerTrait::<i32>::new(831818, false),
        '913472...914624'
    );

    _matches_python_within_1(
        MAX_SQRT_RATIO - 1, IntegerTrait::<i32>::new(887272, false), 'MAX_SQRT_RATIO - 1'
    );
}
