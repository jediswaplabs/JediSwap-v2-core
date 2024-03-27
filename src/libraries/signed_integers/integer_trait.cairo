/// Trait
///
/// new - Constructs a new `signed_integer
/// abs - Computes the absolute value of the given `signed_integer`
trait IntegerTrait<T, U> {
    fn new(mag: U, sign: bool) -> T;
    fn abs(self: T) -> T;
}