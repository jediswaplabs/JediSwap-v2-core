use integer::BoundedInt;

// Raise a number to a power.
fn pow(base: u256, exp: u256) -> u256 {
    if exp == 0 {
        1
    } else if exp == 1 {
        base
    } else if (exp & 1) == 1 {
        base * pow(base * base, exp / 2)
    } else {
        pow(base * base, exp / 2)
    }
}

// @notice Performs modular subtraction of two unsigned 256-bit integers, a and b.
// @param a The first operand for subtraction.
// @param b The second operand for subtraction.
// @return The result of (a - b) modulo 2^256.
fn mod_subtraction(a: u256, b: u256) -> u256 {
    if b > a {
        (BoundedInt::max() - b) + a + 1
    } else {
        a - b
    }
}