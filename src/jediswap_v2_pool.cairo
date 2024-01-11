use starknet::ContractAddress;

use yas_core::numbers::signed_integer::{i32::i32, i128::i128, i256::i256};
use jediswap_v2_core::libraries::position::{PositionInfo, PositionKey};
use jediswap_v2_core::libraries::tick::TickInfo;

#[derive(Copy, Drop, Serde, starknet::Store)]
struct ProtocolFees {
    // @notice Accumulated protocol fees in token0
    token0: u128,
    // @notice Accumulated protocol fees in token1
    token1: u128
}

#[derive(Copy, Drop, Serde)]
struct ModifyPositionParams {
    // @notice The owner of the position
    owner: ContractAddress,
    // @notice lower tick of the position
    tick_lower: i32,
    // @notice upper tick of the position
    tick_upper: i32,
    // @notice how to modify the liquidity
    liquidity_delta: i128
}

// the top level state of the swap, the results of which are recorded in storage at the end
#[derive(Copy, Drop)]
struct SwapState {
    // @notice the amount remaining to be swapped in/out of the input/output asset
    amount_specified_remaining: i256,
    // @notice the amount already swapped out/in of the output/input asset
    amount_calculated: i256,
    // @notice current sqrt(price)
    sqrt_price_X96: u256,
    // @notice the tick associated with the current price
    tick: i32,
    // @notice the global fee growth of the input token
    fee_growth_global_X128: u256,
    // @notice amount of input token paid as protocol fee
    protocol_fee: u128,
    // @notice the current liquidity in range
    liquidity: u128
}

#[derive(Copy, Drop)]
struct SwapSteps {
    // @notice the price at the beginning of the step
    sqrt_price_start_X96: u256,
    // @notice the next tick to swap to from the current tick in the swap direction
    tick_next: i32,
    // @notice whether tickNext is initialized or not
    initialized: bool,
    // @notice sqrt(price) for the next tick (1/0)
    sqrt_price_next_X96: u256,
    // @notice how much is being swapped in in this step
    amount_in: u256,
    // @notice how much is being swapped out
    amount_out: u256,
    // @notice how much fee is being paid in
    fee_amount: u256
}

#[starknet::interface]
trait IJediSwapV2MintCallback<T> {
    fn jediswap_v2_mint_callback(ref self: T, amount0_owed: u256, amount1_owed: u256, callback_data_span: Span<felt252>);
}

#[starknet::interface]
trait IJediSwapV2SwapCallback<T> {
    fn jediswap_v2_swap_callback(ref self: T,  amount0_delta: i256, amount1_delta: i256, callback_data_span: Span<felt252>);
}

#[starknet::interface]
trait IJediSwapV2Pool<TContractState> {
    fn get_factory(self: @TContractState) -> ContractAddress;
    fn get_token0(self: @TContractState) -> ContractAddress;
    fn get_token1(self: @TContractState) -> ContractAddress;
    fn get_fee(self: @TContractState) -> u32;
    fn get_tick_spacing(self: @TContractState) -> u32;
    fn get_max_liquidity_per_tick(self: @TContractState) -> u128;
    fn get_sqrt_price_X96(self: @TContractState) -> u256;
    fn get_tick(self: @TContractState) -> i32;
    fn get_fee_protocol(self: @TContractState) -> u8;
    fn get_fee_growth_global_0_X128(self: @TContractState) -> u256;
    fn get_fee_growth_global_1_X128(self: @TContractState) -> u256;
    fn get_protocol_fees(self: @TContractState) -> ProtocolFees;
    fn get_liquidity(self: @TContractState) -> u128;
    fn get_tick_info(self: @TContractState, tick: i32) -> TickInfo;
    fn get_position_info(self: @TContractState, position_key: PositionKey) -> PositionInfo;
    fn static_collect(self: @TContractState, owner: ContractAddress, tick_lower: i32, tick_upper: i32, amount0_requested: u128, amount1_requested: u128) -> (u128, u128);
    
    fn initialize(ref self: TContractState, sqrt_price_X96: u256);
    fn mint(ref self: TContractState, recipient: ContractAddress, tick_lower: i32, tick_upper: i32, amount: u128, data: Array<felt252>) -> (u256, u256);
    fn collect(ref self: TContractState, recipient: ContractAddress, tick_lower: i32, tick_upper: i32, amount0_requested: u128, amount1_requested: u128) -> (u128, u128);
    fn burn(ref self: TContractState, tick_lower: i32, tick_upper: i32, amount: u128) -> (u256, u256);
    fn swap(ref self: TContractState, recipient: ContractAddress, zero_for_one: bool, amount_specified: i256, sqrt_price_limit_X96: u256, data: Array<felt252>) -> (i256, i256);
    fn collect_protocol(ref self: TContractState, recipient: ContractAddress, amount0_requested: u128, amount1_requested: u128) -> (u128, u128);
}

#[starknet::contract]
mod JediSwapV2Pool {
    use jediswap_v2_core::jediswap_v2_pool::IJediSwapV2Pool;
    use super::{ProtocolFees, ModifyPositionParams, SwapState, SwapSteps, IJediSwapV2MintCallbackDispatcher, IJediSwapV2MintCallbackDispatcherTrait, IJediSwapV2SwapCallbackDispatcher, IJediSwapV2SwapCallbackDispatcherTrait};

    use starknet::{ContractAddress, get_block_timestamp, get_caller_address, get_contract_address};

    use openzeppelin::token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait, IERC20CamelDispatcher, IERC20CamelDispatcherTrait};
    use openzeppelin::access::ownable::interface::{IOwnableDispatcher, IOwnableDispatcherTrait};
    use jediswap_v2_core::libraries::position::{PositionComponent, PositionKey, PositionInfo};
    use jediswap_v2_core::libraries::sqrt_price_math::SqrtPriceMath::{Q128, get_amount0_delta, get_amount1_delta};
    use jediswap_v2_core::libraries::swap_math::SwapMath::compute_swap_step;
    use jediswap_v2_core::libraries::tick::{TickComponent, TickInfo};
    use jediswap_v2_core::libraries::tick_bitmap::TickBitmapComponent;
    use jediswap_v2_core::libraries::tick_math::TickMath::{get_tick_at_sqrt_ratio, get_sqrt_ratio_at_tick, MIN_TICK, MAX_TICK};
    use jediswap_v2_core::jediswap_v2_factory::{IJediSwapV2FactoryDispatcher, IJediSwapV2FactoryDispatcherTrait};
    use yas_core::numbers::signed_integer::{i32::i32, i64::i64, i128::{i128, u128Intoi128}, i256::{i256, i256TryIntou256}, integer_trait::IntegerTrait};
    use yas_core::utils::math_utils::FullMath::mul_div;
    use yas_core::utils::math_utils::BitShift::BitShiftTrait;

    component!(path: PositionComponent, storage: position_storage, event: PositionEvent);
    component!(path: TickComponent, storage: tick_storage, event: TickEvent);
    component!(path: TickBitmapComponent, storage: tick_bitmap_storage, event: TickBitmapEvent);

    #[abi(embed_v0)]
    impl PositionImpl = PositionComponent::Position<ContractState>;
    impl TickImpl = TickComponent::Tick<ContractState>;
    impl TickBitmapImpl = TickBitmapComponent::TickBitmap<ContractState>;

    impl PositionInternalImpl = PositionComponent::InternalImpl<ContractState>;

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        Initialize: Initialize,
        Mint: Mint,
        Collect: Collect,
        Burn: Burn,
        Swap: Swap,
        CollectProtocol: CollectProtocol,
        #[flat]
        PositionEvent: PositionComponent::Event,
        #[flat]
        TickEvent: TickComponent::Event,
        #[flat]
        TickBitmapEvent: TickBitmapComponent::Event
    }

    // @notice Emitted exactly once by a pool when #initialize is first called on the pool
    // @dev Mint/Burn/Swap cannot be emitted by the pool before Initialize
    // @param sqrt_price_X96 The initial sqrt price of the pool, as a Q64.96
    // @param tick The initial tick of the pool, i.e. log base 1.0001 of the starting price of the pool
    #[derive(Drop, starknet::Event)]
    struct Initialize {
        sqrt_price_X96: u256,
        tick: i32
    }

    // @notice Emitted when liquidity is minted for a given position
    // @param sender The address that minted the liquidity
    // @param owner The owner of the position and recipient of any minted liquidity
    // @param tick_lower The lower tick of the position
    // @param tick_upper The upper tick of the position
    // @param amount The amount of liquidity minted to the position range
    // @param amount0 How much token0 was required for the minted liquidity
    // @param amount1 How much token1 was required for the minted liquidity
    #[derive(Drop, starknet::Event)]
    struct Mint {
        sender: ContractAddress,
        owner: ContractAddress,
        tick_lower: i32,
        tick_upper: i32,
        amount: u128,
        amount0: u256,
        amount1: u256
    }

    // @notice Emitted when fees are collected by the owner of a position
    // @dev Collect events may be emitted with zero amount0 and amount1 when the caller chooses not to collect fees
    // @param owner The owner of the position for which fees are collected
    // @param recipient The address which should receive the fees collected
    // @param tick_lower The lower tick of the position
    // @param tick_upper The upper tick of the position
    // @param amount0 The amount of token0 fees collected
    // @param amount1 The amount of token1 fees collected
    #[derive(Drop, starknet::Event)]
    struct Collect {
        owner: ContractAddress,
        recipient: ContractAddress,
        tick_lower: i32,
        tick_upper: i32,
        amount0: u128,
        amount1: u128
    }

    // @notice Emitted when a position's liquidity is removed
    // @dev Does not withdraw any fees earned by the liquidity position, which must be withdrawn via #collect
    // @param owner The owner of the position for which liquidity is removed
    // @param tick_lower The lower tick of the position
    // @param tick_upper The upper tick of the position
    // @param amount The amount of liquidity to remove
    // @param amount0 The amount of token0 withdrawn
    // @param amount1 The amount of token1 withdrawn
    #[derive(Drop, starknet::Event)]
    struct Burn {
        owner: ContractAddress,
        tick_lower: i32,
        tick_upper: i32,
        amount: u128,
        amount0: u256,
        amount1: u256
    }

    // @notice Emitted by the pool for any swaps between token0 and token1
    // @param sender The address that initiated the swap call, and that received the callback
    // @param recipient The address that received the output of the swap
    // @param amount0 The delta of the token0 balance of the pool
    // @param amount1 The delta of the token1 balance of the pool
    // @param sqrt_price_X96 The sqrt(price) of the pool after the swap, as a Q64.96
    // @param liquidity The liquidity of the pool after the swap
    // @param tick The log base 1.0001 of price of the pool after the swap
    #[derive(Drop, starknet::Event)]
    struct Swap {
        sender: ContractAddress,
        recipient: ContractAddress,
        amount0: i256,
        amount1: i256,
        sqrt_price_X96: u256,
        liquidity: u128,
        tick: i32
    }

    // @notice Emitted when the collected protocol fees are withdrawn by the factory owner
    // @param sender The address that collects the protocol fees
    // @param recipient The address that receives the collected protocol fees
    // @param amount0 The amount of token0 protocol fees that is withdrawn
    // @param amount1 The amount of token1 protocol fees that is withdrawn
    #[derive(Drop, starknet::Event)]
    struct CollectProtocol {
        sender: ContractAddress,
        recipient: ContractAddress,
        amount0: u128,
        amount1: u128
    }

    #[storage]
    struct Storage {
        factory: ContractAddress,   // @notice The contract that deployed the pool, which must adhere to the IJediSwapV2Factory interface
        token0: ContractAddress,    // @notice The first of the two tokens of the pool, sorted by address
        token1: ContractAddress,    // @notice The second of the two tokens of the pool, sorted by address
        fee: u32,                   // @notice The pool's fee in hundredths of a bip, i.e. 1e-6
        tick_spacing: u32,          // @notice The pool tick spacing
        max_liquidity_per_tick: u128,   // @notice The maximum amount of position liquidity that can use any tick in the range
        sqrt_price_X96: u256,       // @notice The current price of the pool as a sqrt(token1/token0) Q64.96 value
        tick: i32,                  // @notice The current tick of the pool, i.e. according to the last tick transition that was run.
                                    // This value may not always be equal to SqrtTickMath.getTickAtSqrtRatio(sqrtPriceX96) if the price is on a tick
                                    // boundary.
        unlocked: bool,             // @notice Whether the pool is currently locked to reentrancy
        fee_growth_global_0_X128: u256, // @notice The fee growth as a Q128.128 fees of token0 collected per unit of liquidity for the entire life of the pool
        fee_growth_global_1_X128: u256, // @notice The fee growth as a Q128.128 fees of token1 collected per unit of liquidity for the entire life of the pool
        protocol_fees: ProtocolFees,    // @notice The amounts of token0 and token1 that are owed to the protocol
        liquidity: u128,            // @notice The currently in range liquidity available to the pool

        #[substorage(v0)]
        position_storage: PositionComponent::Storage,
        #[substorage(v0)]
        tick_storage: TickComponent::Storage,
        #[substorage(v0)]
        tick_bitmap_storage: TickBitmapComponent::Storage
    }

    #[constructor]
    fn constructor(ref self: ContractState, token0: ContractAddress, token1: ContractAddress, fee: u32, tick_spacing: u32) {
        let factory = get_caller_address();
        self.factory.write(factory);
        self.token0.write(token0);
        self.token1.write(token1);
        self.fee.write(fee);
        self.tick_spacing.write(tick_spacing);
        self.max_liquidity_per_tick.write(self.tick_storage.tick_spacing_to_max_liquidity_per_tick(tick_spacing));
    }

    #[external(v0)]
    impl JediSwapV2PoolImpl of super::IJediSwapV2Pool<ContractState> {

        fn get_factory(self: @ContractState) -> ContractAddress {
            self.factory.read()
        }

        fn get_token0(self: @ContractState) -> ContractAddress {
            self.token0.read()
        }

        fn get_token1(self: @ContractState) -> ContractAddress {
            self.token1.read()
        }

        fn get_fee(self: @ContractState) -> u32 {
            self.fee.read()
        }

        fn get_tick_spacing(self: @ContractState) -> u32 {
            self.tick_spacing.read()
        }

        fn get_max_liquidity_per_tick(self: @ContractState) -> u128 {
            self.max_liquidity_per_tick.read()
        }

        fn get_sqrt_price_X96(self: @ContractState) -> u256 {
            self.sqrt_price_X96.read()
        }
        
        fn get_tick(self: @ContractState) -> i32 {
            self.tick.read()
        }
        
        fn get_fee_protocol(self: @ContractState) -> u8 {
            let factory_dispatcher = IJediSwapV2FactoryDispatcher {contract_address: self.factory.read()};
            factory_dispatcher.get_fee_protocol()
        }

        fn get_fee_growth_global_0_X128(self: @ContractState) -> u256 {
            self.fee_growth_global_0_X128.read()
        }

        fn get_fee_growth_global_1_X128(self: @ContractState) -> u256 {
            self.fee_growth_global_1_X128.read()
        }

        fn get_protocol_fees(self: @ContractState) -> ProtocolFees {
            self.protocol_fees.read()
        }

        fn get_liquidity(self: @ContractState) -> u128 {
            self.liquidity.read()
        }

        fn get_tick_info(self: @ContractState, tick: i32) -> TickInfo {
            self.tick_storage.ticks.read(tick)
        }

        fn get_position_info(self: @ContractState, position_key: PositionKey) -> PositionInfo {
            self.position_storage.get(position_key)
        }

        // @notice Read method for collect
        // @return The amount of fees to collect in token0
        // @return The amount of fees to collect in token1
        fn static_collect(self: @ContractState, owner: ContractAddress, tick_lower: i32, tick_upper: i32, amount0_requested: u128, amount1_requested: u128) -> (u128, u128) {
            let position_key = PositionKey {owner, tick_lower, tick_upper};
            let mut position = self.position_storage.get(position_key);
            
            let amount0 = if (amount0_requested > position.tokens_owed_0) {
                position.tokens_owed_0
            } else {
                amount0_requested
            };
            let amount1 = if (amount1_requested > position.tokens_owed_1) {
                position.tokens_owed_1
            } else {
                amount1_requested
            };
            (amount0, amount1)
        }

        // @notice Sets the initial price for the pool
        // @dev price is represented as a sqrt(amount_token1/amount_token0) Q64.96 value
        // @param sqrt_price_X96 the initial sqrt price of the pool as a Q64.96
        fn initialize(ref self: ContractState, sqrt_price_X96: u256) {
            // The initialize function should only be called once. To ensure this,
            // we verify that the price is not initialized.
            assert(self.sqrt_price_X96.read().is_zero(), 'already initialized');

            self.sqrt_price_X96.write(sqrt_price_X96);
            let tick = get_tick_at_sqrt_ratio(sqrt_price_X96);
            self.tick.write(tick);

            self.unlocked.write(true);

            self.emit(Initialize { sqrt_price_X96, tick });
        }

        // @notice Adds liquidity for the given recipient/tick_lower/tick_upper position
        // @dev The caller of this method receives a callback in the form of IJediSwapV2MintCallback#jediswapV2MintCallback
        // in which they must pay any token0 or token1 owed for the liquidity. The amount of token0/token1 due depends
        // on tick_lower, tick_upper, the amount of liquidity, and the current price.
        // @param recipient The address for which the liquidity will be created
        // @param tick_lower The lower tick of the position in which to add liquidity
        // @param tick_upper The upper tick of the position in which to add liquidity
        // @param amount The amount of liquidity to mint
        // @param data Any data that should be passed through to the callback
        // @return The amount of token0 that was paid to mint the given amount of liquidity. Matches the value in the callback
        // @return The amount of token1 that was paid to mint the given amount of liquidity. Matches the value in the callback
        fn mint(ref self: ContractState, recipient: ContractAddress, tick_lower: i32, tick_upper: i32, amount: u128, data: Array<felt252>) -> (u256, u256) {
            self._check_and_lock();

            assert(amount > 0, 'amount must be greater than 0');
            let (_, amount0, amount1) = self._modify_position(ModifyPositionParams {owner: recipient, tick_lower, tick_upper, liquidity_delta: amount.into()});

            let amount0: u256 = amount0.try_into().unwrap();
            let amount1: u256 = amount1.try_into().unwrap();

            let mut balance0_before = 0;
            let mut balance1_before = 0;
            if (amount0 > 0) {
                balance0_before = self.balance0();
            }
            if (amount1 > 0) {
                balance1_before = self.balance1();
            }

            let callback_contract = get_caller_address();
            
            let callback_dispatcher = IJediSwapV2MintCallbackDispatcher { contract_address: callback_contract }; // TODO
            callback_dispatcher.jediswap_v2_mint_callback(amount0, amount1, data.span());

            if (amount0 > 0) {
                assert(balance0_before + amount0 <= self.balance0(), 'M0');
            }

            if (amount1 > 0) {
                assert(balance1_before + amount1 <= self.balance1(), 'M1');
            }

            self.emit(Mint {sender: get_caller_address(), owner: recipient, tick_lower, tick_upper, amount, amount0, amount1});
            self._unlock();
            (amount0, amount1)
        }

        // @notice Collects tokens owed to a position
        // @dev Does not recompute fees earned, which must be done either via mint or burn of any amount of liquidity.
        // Collect must be called by the position owner. To withdraw only token0 or only token1, amount0_requested or
        // amount1_requested may be set to zero. To withdraw all tokens owed, caller may pass any value greater than the
        // actual tokens owed, e.g. BoundedInt::<u128>::max(). Tokens owed may be from accumulated swap fees or burned liquidity.
        // @param recipient The address which should receive the fees collected
        // @param tick_lower The lower tick of the position for which to collect fees
        // @param tick_upper The upper tick of the position for which to collect fees
        // @param amount0_requested How much token0 should be withdrawn from the fees owed
        // @param amount1_requested How much token1 should be withdrawn from the fees owed
        // @return The amount of fees collected in token0
        // @return The amount of fees collected in token1
        fn collect(ref self: ContractState, recipient: ContractAddress, tick_lower: i32, tick_upper: i32, amount0_requested: u128, amount1_requested: u128) -> (u128, u128) {
            self._check_and_lock();
            // we don't need to _check_ticks here, because invalid positions will never have non-zero tokens_owed_{0,1}
            let caller = get_caller_address();
            let position_key = PositionKey {owner: caller, tick_lower, tick_upper};
            let mut position = self.position_storage.get(position_key);
            
            let amount0 = if (amount0_requested > position.tokens_owed_0) {
                position.tokens_owed_0
            } else {
                amount0_requested
            };
            let amount1 = if (amount1_requested > position.tokens_owed_1) {
                position.tokens_owed_1
            } else {
                amount1_requested
            };

            if (amount0 > 0) {
                position.tokens_owed_0 -= amount0;
                self.position_storage.set(position_key, position);
                let token_dispatcher = IERC20Dispatcher { contract_address: self.token0.read() };
                token_dispatcher.transfer(recipient, amount0.into());
            }
            if (amount1 > 0) {
                position.tokens_owed_1 -= amount1;
                self.position_storage.set(position_key, position);
                let token_dispatcher = IERC20Dispatcher { contract_address: self.token1.read() };
                token_dispatcher.transfer(recipient, amount1.into());
            }
            self.emit(Collect {owner: caller, recipient, tick_lower, tick_upper, amount0, amount1});
            self._unlock();
            (amount0, amount1)
        }

        // @notice Burn liquidity from the sender and account tokens owed for the liquidity to the position
        // @dev Can be used to trigger a recalculation of fees owed to a position by calling with an amount of 0
        // @dev Fees must be collected separately via a call to #collect
        // @param tick_lower The lower tick of the position for which to burn liquidity
        // @param tick_upper The upper tick of the position for which to burn liquidity
        // @param amount How much liquidity to burn
        // @return The amount of token0 sent to the recipient
        // @return The amount of token1 sent to the recipient
        fn burn(ref self: ContractState, tick_lower: i32, tick_upper: i32, amount: u128) -> (u256, u256) {
            self._check_and_lock();
            let caller = get_caller_address();
            let (mut position, amount0_i, amount1_i) = self._modify_position(ModifyPositionParams {owner: caller, tick_lower, tick_upper, liquidity_delta: -amount.into()});
            
            let amount0 = amount0_i.mag;
            let amount1 = amount1_i.mag;
            
            if (amount0 > 0 || amount1 > 0 ) {
                position.tokens_owed_0 += amount0.try_into().unwrap();
                position.tokens_owed_1 += amount1.try_into().unwrap();
                let position_key = PositionKey {owner: caller, tick_lower, tick_upper};
                self.position_storage.set(position_key, position);
            }
            
            self.emit(Burn {owner: caller, tick_lower, tick_upper, amount, amount0, amount1});
            self._unlock();
            (amount0, amount1)
        }

        /// @notice Swap token0 for token1, or token1 for token0
        /// @dev The caller of this method receives a callback in the form of IJediSwapV2SwapCallback#jediswapV2SwapCallback
        /// @param recipient The address to receive the output of the swap
        /// @param zero_for_one The direction of the swap, true for token0 to token1, false for token1 to token0
        /// @param amount_specified The amount of the swap, which implicitly configures the swap as exact input (positive), or exact output (negative)
        /// @param sqrt_price_limit_X96 The Q64.96 sqrt price limit. If zero for one, the price cannot be less than this
        /// value after the swap. If one for zero, the price cannot be greater than this value after the swap
        /// @param data Any data to be passed through to the callback
        /// @return The delta of the balance of token0 of the pool, exact when negative, minimum when positive
        /// @return The delta of the balance of token1 of the pool, exact when negative, minimum when positive
        fn swap(ref self: ContractState, recipient: ContractAddress, zero_for_one: bool, amount_specified: i256, sqrt_price_limit_X96: u256, data: Array<felt252>) -> (i256, i256) {
            self._check_and_lock();
            assert(amount_specified.is_non_zero(), 'AS');

            let sqrt_price_X96_start = self.sqrt_price_X96.read();
            let fee_protocol = self.get_fee_protocol();
            let tick_start = self.tick.read();

            assert(
                if (zero_for_one) {
                    sqrt_price_limit_X96 < sqrt_price_X96_start
                        && sqrt_price_limit_X96 > get_sqrt_ratio_at_tick(MIN_TICK())
                } else {
                    sqrt_price_limit_X96 > sqrt_price_X96_start
                        && sqrt_price_limit_X96 < get_sqrt_ratio_at_tick(MAX_TICK())
                },
                'SPL'
            );

            let liquidity_start = self.liquidity.read();

            let exact_input = amount_specified > Zeroable::zero();

            let mut state = SwapState {
                amount_specified_remaining: amount_specified,
                amount_calculated: Zeroable::zero(),
                sqrt_price_X96: sqrt_price_X96_start,
                tick: tick_start,
                fee_growth_global_X128: if (zero_for_one) {
                    self.fee_growth_global_0_X128.read()
                } else {
                    self.fee_growth_global_1_X128.read()
                },
                protocol_fee: 0,
                liquidity: liquidity_start
            };

            let mut step = SwapSteps{sqrt_price_start_X96: 0, tick_next: Zeroable::zero(), initialized: false, sqrt_price_next_X96: 0, amount_in: 0, amount_out: 0, fee_amount: 0};

            loop {
                // continue as long as we haven't used the entire input/output and haven't reached the price limit
                if (state.amount_specified_remaining.is_zero() || state.sqrt_price_X96 == sqrt_price_limit_X96) {
                    break true;
                }

                step.sqrt_price_start_X96 = state.sqrt_price_X96;
                let (step_tick_next, step_initialized) = self.tick_bitmap_storage.next_initialized_tick_within_one_word(state.tick, self.tick_spacing.read(), zero_for_one);
                step.tick_next = step_tick_next;
                step.initialized = step_initialized;

                // ensure that we do not overshoot the min/max tick, as the tick bitmap is not aware of these bounds
                if (step.tick_next < MIN_TICK()) {
                    step.tick_next = MIN_TICK();
                } else if (step.tick_next > MAX_TICK()) {
                    step.tick_next = MAX_TICK();
                }

                // get the price for the next tick
                step.sqrt_price_next_X96 = get_sqrt_ratio_at_tick(step.tick_next);

                let (state_sqrt_price_X96, step_amount_in, step_amount_out, step_fee_amount) = compute_swap_step(state.sqrt_price_X96, 
                                                                                            if (zero_for_one) { if (step.sqrt_price_next_X96 < sqrt_price_limit_X96) {
                                                                                                sqrt_price_limit_X96
                                                                                            } else { step.sqrt_price_next_X96}} else {
                                                                                               if (step.sqrt_price_next_X96 > sqrt_price_limit_X96) {
                                                                                                sqrt_price_limit_X96
                                                                                               } else { step.sqrt_price_next_X96}
                                                                                            }, state.liquidity, state.amount_specified_remaining, self.fee.read());
                state.sqrt_price_X96 = state_sqrt_price_X96;
                step.amount_in = step_amount_in;
                step.amount_out = step_amount_out;
                step.fee_amount = step_fee_amount;

                if (exact_input) {
                    state.amount_specified_remaining -= (step.amount_in + step.fee_amount).into();
                    state.amount_calculated -= step.amount_out.into();
                } else {
                    state.amount_specified_remaining += step.amount_out.into();
                    state.amount_calculated += (step.amount_in + step.fee_amount).into();
                }

                // if the protocol fee is on, calculate how much is owed, decrement feeAmount, and increment protocolFee
                if (fee_protocol > 0) {
                    let delta = step.fee_amount / fee_protocol.into();
                    step.fee_amount -= delta;
                    state.protocol_fee += delta.try_into().unwrap();
                }

                // update global fee tracker
                if (state.liquidity > 0) {
                    state.fee_growth_global_X128 += mul_div(step.fee_amount, Q128, state.liquidity.into());
                }

                // shift tick if we reached the next price
                if (state.sqrt_price_X96 == step.sqrt_price_next_X96) {
                    // if the tick is initialized, run the tick transition
                    if (step.initialized) {
                        let mut liquidity_net = self.tick_storage.cross(step.tick_next, if (zero_for_one) { state.fee_growth_global_X128} else {self.fee_growth_global_0_X128.read()}, if (zero_for_one) { self.fee_growth_global_1_X128.read()} else {state.fee_growth_global_X128});

                        // if we're moving leftward, we interpret liquidityNet as the opposite sign
                        if (zero_for_one) {
                            liquidity_net = -liquidity_net;
                        }

                        state.liquidity = if (liquidity_net < IntegerTrait::<i128>::new(0, false)) {
                            state.liquidity - liquidity_net.mag
                        } else {
                            state.liquidity + liquidity_net.mag
                        };
                    }
                    state.tick = if (zero_for_one) { step.tick_next - IntegerTrait::<i32>::new(1, false) } else { step.tick_next };
                } else if (state.sqrt_price_X96 != step.sqrt_price_start_X96) {
                    // recompute unless we're on a lower tick boundary (i.e. already transitioned ticks), and haven't moved
                    state.tick = get_tick_at_sqrt_ratio(state.sqrt_price_X96);
                };
            };

            // update tick if the tick change
            if (state.tick != tick_start) {
                self.tick.write(state.tick);
            }
            self.sqrt_price_X96.write(state.sqrt_price_X96);

            // update liquidity if it changed
            if (liquidity_start != state.liquidity) {
                self.liquidity.write(state.liquidity);
            }

            // update fee growth global and, if necessary, protocol fees
            // overflow is acceptable, protocol has to withdraw before it hits type(uint128).max fees
            if (zero_for_one) {
                self.fee_growth_global_0_X128.write(state.fee_growth_global_X128);
                if (state.protocol_fee > 0) {
                    let mut protocol_fees = self.protocol_fees.read();
                    protocol_fees.token0 += state.protocol_fee;
                    self.protocol_fees.write(protocol_fees);
                }
            } else {
                self.fee_growth_global_1_X128.write(state.fee_growth_global_X128);
                if (state.protocol_fee > 0) {
                    let mut protocol_fees = self.protocol_fees.read();
                    protocol_fees.token1 += state.protocol_fee;
                    self.protocol_fees.write(protocol_fees);
                }
            }

            let (amount0, amount1) = if (zero_for_one == exact_input) {
                (amount_specified - state.amount_specified_remaining, state.amount_calculated)
            } else {
                (state.amount_calculated, amount_specified - state.amount_specified_remaining)
            };

            // do the transfers and collect payment
            if (zero_for_one) {
                if (amount1 < Zeroable::zero()) {
                    let token_dispatcher = IERC20Dispatcher { contract_address: self.token1.read() };
                    token_dispatcher.transfer(recipient, amount1.mag);
                };

                let balance0_before: u256 = self.balance0();

                let callback_contract = get_caller_address();
                let callback_dispatcher = IJediSwapV2SwapCallbackDispatcher { contract_address: callback_contract };
                callback_dispatcher.jediswap_v2_swap_callback(amount0, amount1, data.span());

                assert(balance0_before + amount0.mag <= self.balance0(), 'IIA');
            } else {
                if (amount0 < Zeroable::zero()) {
                    let token_dispatcher = IERC20Dispatcher { contract_address: self.token0.read() };
                    token_dispatcher.transfer(recipient, amount0.mag);
                }

                let balance1_before: u256 = self.balance1();

                let callback_contract = get_caller_address();
                let callback_dispatcher = IJediSwapV2SwapCallbackDispatcher { contract_address: callback_contract };
                callback_dispatcher.jediswap_v2_swap_callback(amount0, amount1, data.span());

                assert(balance1_before + amount1.mag <= self.balance1(), 'IIA');
            }

            self.emit(Swap {sender: get_caller_address(), recipient, amount0, amount1, sqrt_price_X96: state.sqrt_price_X96, liquidity: state.liquidity, tick: state.tick});
            self._unlock();
            (amount0, amount1)
        }

        // @notice Collect the protocol fee accrued to the pool
        // @param recipient The address to which collected protocol fees should be sent
        // @param amount0_requested The maximum amount of token0 to send, can be 0 to collect fees in only token1
        // @param amount1_requested The maximum amount of token1 to send, can be 0 to collect fees in only token0
        // @return The protocol fee collected in token0
        // @return The protocol fee collected in token1
        fn collect_protocol(ref self: ContractState, recipient: ContractAddress, amount0_requested: u128, amount1_requested: u128) -> (u128, u128) {
            self._check_and_lock();
            let caller = get_caller_address();
            let ownable_dispatcher = IOwnableDispatcher { contract_address: self.factory.read() };
            assert(ownable_dispatcher.owner() == caller, 'Invalid caller');

            let mut protocol_fees = self.protocol_fees.read();

            let mut amount0 = if(amount0_requested > protocol_fees.token0) {
                protocol_fees.token0
            } else {
                amount0_requested
            };

            let mut amount1 = if(amount1_requested > protocol_fees.token1) {
                protocol_fees.token1
            } else {
                amount1_requested
            };

            if (amount0 > 0) {
                protocol_fees.token0 = protocol_fees.token0 - amount0;
                let token_dispatcher = IERC20Dispatcher { contract_address: self.token0.read() };
                token_dispatcher.transfer(recipient, amount0.into());
            }

            if (amount1 > 0) {
                protocol_fees.token1 = protocol_fees.token1 - amount1;
                let token_dispatcher = IERC20Dispatcher { contract_address: self.token1.read() };
                token_dispatcher.transfer(recipient, amount1.into());
            }
            self.protocol_fees.write(protocol_fees);
            self.emit(CollectProtocol { sender: caller, recipient, amount0, amount1 });
            
            (amount0, amount1)
        }
    }

    #[generate_trait]
    impl InternalImpl of InternalTrait {

        // @dev Effect some changes to a position
        // @param params the position details and the change to the position's liquidity to effect
        // @return referencing the position with the given owner and tick range
        // @return the amount of token0 owed to the pool, negative if the pool should pay the recipient
        // @return the amount of token1 owed to the pool, negative if the pool should pay the recipient
        fn _modify_position(ref self: ContractState, params: ModifyPositionParams) -> (PositionInfo, i256, i256) { // How to nodelegatecall TODO
            _check_ticks(params.tick_lower, params.tick_upper);

            let tick = self.tick.read();
            let sqrt_price_X96 = self.sqrt_price_X96.read();
            let position = self._update_position(params.owner, params.tick_lower, params.tick_upper, params.liquidity_delta, tick);

            let mut amount0 = Zeroable::zero();
            let mut amount1 = Zeroable::zero();
            if (params.liquidity_delta != Zeroable::zero()) {
                if (tick < params.tick_lower) {
                    // current tick is below the passed range; liquidity can only become in range by crossing from left to
                    // right, when we'll need _more_ token0 (it's becoming more valuable) so user must provide it
                    amount0 = get_amount0_delta(get_sqrt_ratio_at_tick(params.tick_lower), get_sqrt_ratio_at_tick(params.tick_upper), params.liquidity_delta);
                } else if (tick < params.tick_upper) {
                    // current tick is inside the passed range
                    amount0 = get_amount0_delta(sqrt_price_X96, get_sqrt_ratio_at_tick(params.tick_upper), params.liquidity_delta);

                    amount1 = get_amount1_delta(get_sqrt_ratio_at_tick(params.tick_lower), sqrt_price_X96, params.liquidity_delta);

                    let mut liquidity = self.liquidity.read();
                    if (params.liquidity_delta < Zeroable::zero()) {
                        liquidity = liquidity - params.liquidity_delta.mag;
                    }
                    else {
                        liquidity = liquidity + params.liquidity_delta.mag;
                    }
                    self.liquidity.write(liquidity);
                } else {
                    // current tick is above the passed range; liquidity can only become in range by crossing from right to
                    // left, when we'll need _more_ token1 (it's becoming more valuable) so user must provide it
                    amount1 = get_amount1_delta(get_sqrt_ratio_at_tick(params.tick_lower), get_sqrt_ratio_at_tick(params.tick_upper), params.liquidity_delta);
                }
            }
            (position, amount0, amount1)
        }

        // @dev Gets and updates a position with the given liquidity delta
        // @param owner the owner of the position
        // @param tick_lower the lower tick of the position's tick range
        // @param tick_upper the upper tick of the position's tick range
        // @param liquidity_delta Change in liquidity
        // @param tick the current tick, passed to avoid sloads
        // @return referencing the position with the given owner and tick range
        fn _update_position(ref self: ContractState, owner: ContractAddress, tick_lower: i32, tick_upper: i32, liquidity_delta: i128, tick: i32) -> PositionInfo {
            let fee_growth_global_0_X128 = self.fee_growth_global_0_X128.read();
            let fee_growth_global_1_X128 = self.fee_growth_global_1_X128.read();

            let max_liquidity_per_tick = self.max_liquidity_per_tick.read();

            // if we need to update the ticks, do it
            let mut flipped_lower = false;
            let mut flipped_upper = false;

            if (liquidity_delta != Zeroable::zero()) {
                
                flipped_lower = self.tick_storage.update(tick_lower, tick, liquidity_delta, fee_growth_global_0_X128, fee_growth_global_1_X128, false, max_liquidity_per_tick);
                
                flipped_upper = self.tick_storage.update(tick_upper, tick, liquidity_delta, fee_growth_global_0_X128, fee_growth_global_1_X128, true, max_liquidity_per_tick);                
            }
            
            if (flipped_lower) {
                self.tick_bitmap_storage.flip_tick(tick_lower, self.tick_spacing.read());
            }

            if flipped_upper {
                self.tick_bitmap_storage.flip_tick(tick_upper, self.tick_spacing.read());
            }

            let (fee_growth_inside_0_X128, fee_growth_inside_1_X128) =
                self.tick_storage.get_fee_growth_inside(tick_lower, tick_upper, tick, fee_growth_global_0_X128, fee_growth_global_1_X128);

            let position_key = PositionKey {owner, tick_lower, tick_upper};
            
            self.position_storage.update(position_key, liquidity_delta, fee_growth_inside_0_X128, fee_growth_inside_1_X128);

            // clear any tick data that is no longer needed
            if (liquidity_delta < Zeroable::zero()) {
                if (flipped_lower) {
                    self.tick_storage.clear(tick_lower);
                }

                if (flipped_upper) {
                    self.tick_storage.clear(tick_upper);
                }
            }
            
            self.position_storage.get(position_key)
        }

        fn _check_and_lock(ref self: ContractState) {
            let unlocked = self.unlocked.read();
            assert(unlocked, 'LOK');
            self.unlocked.write(false);
        }

        fn _unlock(ref self: ContractState) {
            let locked = self.unlocked.read();
            self.unlocked.write(true);
        }

        fn balance0(self: @ContractState) -> u256 { //TODO fallback balance_of/balanceOf
            // let token_dispatcher = IERC20Dispatcher { contract_address: self.token0.read() };
            // token_dispatcher.balance_of(get_contract_address())
            let token_camel_dispatcher = IERC20CamelDispatcher { contract_address: self.token0.read() };
            token_camel_dispatcher.balanceOf(get_contract_address())
        }

        fn balance1(self: @ContractState) -> u256 { //TODO fallback balance_of/balanceOf
            // let token_dispatcher = IERC20Dispatcher { contract_address: self.token1.read() };
            // token_dispatcher.balance_of(get_contract_address())
            let token_camel_dispatcher = IERC20CamelDispatcher { contract_address: self.token1.read() };
            token_camel_dispatcher.balanceOf(get_contract_address())
        }
    }

    fn _check_ticks(tick_lower: i32, tick_upper: i32) {
        assert(tick_lower < tick_upper, 'TLU');
        assert(tick_lower >= MIN_TICK(), 'TLM');
        assert(tick_upper <= MAX_TICK(), 'TUM');
    }
}