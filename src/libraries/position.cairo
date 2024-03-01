// @title PositionComponent
// @notice Positions represent an owner address' liquidity between a lower and upper tick boundary
// @dev Positions store additional state for tracking fees owed to the position

use starknet::ContractAddress;
use yas_core::numbers::signed_integer::{i32::i32, i128::i128, integer_trait::IntegerTrait};


#[derive(Copy, Drop, Serde, starknet::Store)]
struct PositionInfo {
    // @notice The amount of liquidity owned by this position
    liquidity: u128,
    // @notice Fee growth of token0 per unit of liquidity as of the last update to liquidity or fees owned
    fee_growth_inside_0_last_X128: u256,
    // @notice Fee growth of token1 per unit of liquidity as of the last update to liquidity or fees owned
    fee_growth_inside_1_last_X128: u256,
    // @notice The fees owed to the position owner in token0
    tokens_owed_0: u128,
    // @notice The fees owed to the position owner in token1
    tokens_owed_1: u128,
}

#[derive(Copy, Drop, Serde)]
struct PositionKey {
    // @notice The owner of the position
    owner: ContractAddress,
    // @notice The lower tick of the position's tick range
    tick_lower: i32,
    // @notice The upper tick of the position's tick range
    tick_upper: i32,
}

#[starknet::interface]
trait IPosition<TState> {
    fn get(self: @TState, position_key: PositionKey) -> PositionInfo;
    fn update(
        ref self: TState,
        position_key: PositionKey,
        liquidity_delta: i128,
        fee_growth_inside_0_X128: u256,
        fee_growth_inside_1_X128: u256
    );
}

#[starknet::component]
mod PositionComponent {
    use super::{PositionInfo, PositionKey};

    use integer::BoundedInt;
    use poseidon::poseidon_hash_span;
    use yas_core::numbers::signed_integer::{i128::i128, integer_trait::IntegerTrait};
    use yas_core::utils::math_utils::FullMath::mul_div;
    use yas_core::utils::math_utils::mod_subtraction;
    use jediswap_v2_core::libraries::sqrt_price_math::SqrtPriceMath::Q128;

    #[storage]
    struct Storage {
        positions: LegacyMap::<
            felt252, PositionInfo
        >, // @dev Represents all the positions in a pool
    }

    #[embeddable_as(Position)]
    impl PositionImpl<
        TContractState, +HasComponent<TContractState>
    > of super::IPosition<ComponentState<TContractState>> {
        // @notice Returns the PositionInfo struct of a position, given an owner and position boundaries
        // @param position_key Key variables defining the position
        // @return position info
        fn get(self: @ComponentState<TContractState>, position_key: PositionKey) -> PositionInfo {
            let position_hash = _get_position_hash(position_key);
            self.positions.read(position_hash)
        }

        // @notice Credits accumulated fees to a user's position
        // @param position_key Key variables defining the position
        // @param liquidity_delta The change in pool liquidity as a result of the position update
        // @param fee_growth_inside_0_X128 The all-time fee growth in token0, per unit of liquidity, inside the position's tick boundaries
        // @param fee_growth_inside_1_X128 The all-time fee growth in token1, per unit of liquidity, inside the position's tick boundaries
        fn update(
            ref self: ComponentState<TContractState>,
            position_key: PositionKey,
            liquidity_delta: i128,
            fee_growth_inside_0_X128: u256,
            fee_growth_inside_1_X128: u256
        ) {
            let position_hash = _get_position_hash(position_key);
            let mut position_info: PositionInfo = self.positions.read(position_hash);

            let liquidity_next = if (liquidity_delta == IntegerTrait::<i128>::new(0, false)) {
                // disallows pokes for 0 liquidity positions
                assert(position_info.liquidity > 0, 'NP');
                position_info.liquidity
            } else {
                if (liquidity_delta < IntegerTrait::<i128>::new(0, false)) {
                    position_info.liquidity - liquidity_delta.mag
                } else {
                    position_info.liquidity + liquidity_delta.mag
                }
            };

            // calculate accumulated fees
            let tokens_owed_0 = mul_div(
                mod_subtraction(
                    fee_growth_inside_0_X128, position_info.fee_growth_inside_0_last_X128
                ),
                position_info.liquidity.into(),
                Q128
            )
                .try_into()
                .unwrap();
            let tokens_owed_1 = mul_div(
                mod_subtraction(
                    fee_growth_inside_1_X128, position_info.fee_growth_inside_1_last_X128
                ),
                position_info.liquidity.into(),
                Q128
            )
                .try_into()
                .unwrap();

            // update the position
            if (liquidity_delta != IntegerTrait::<i128>::new(0, false)) {
                position_info.liquidity = liquidity_next;
            }

            position_info.fee_growth_inside_0_last_X128 = fee_growth_inside_0_X128;
            position_info.fee_growth_inside_1_last_X128 = fee_growth_inside_1_X128;

            if (tokens_owed_0 > 0 || tokens_owed_1 > 0) {
                // overflow is acceptable, have to withdraw before you hit Q128 fees
                position_info.tokens_owed_0 += tokens_owed_0;
                position_info.tokens_owed_1 += tokens_owed_1;
            }
            self.positions.write(position_hash, position_info);
        }
    }

    #[generate_trait]
    impl InternalImpl<
        TContractState, +HasComponent<TContractState>
    > of InternalTrait<TContractState> {
        fn set(
            ref self: ComponentState<TContractState>,
            position_key: PositionKey,
            position_info: PositionInfo
        ) {
            let position_hash = _get_position_hash(position_key);
            self.positions.write(position_hash, position_info);
        }
    }

    fn _get_position_hash(position_key: PositionKey) -> felt252 {
        let mut serialized: Array<felt252> = ArrayTrait::new();
        Serde::<PositionKey>::serialize(@position_key, ref serialized);
        poseidon_hash_span(serialized.span())
    }
}
