use starknet::ContractAddress;
use yas_core::numbers::signed_integer::{i32::i32, i256::i256};

#[starknet::interface]
trait IPoolSwapTest<TContractState> {
    fn swap_exact_0_for_1(ref self: TContractState, pool: ContractAddress, amount0_in: u256, recipient: ContractAddress, sqrt_price_limit_X96: u256);
    fn swap_0_for_exact_1(ref self: TContractState, pool: ContractAddress, amount1_out: u256, recipient: ContractAddress, sqrt_price_limit_X96: u256);
    fn swap_exact_1_for_0(ref self: TContractState, pool: ContractAddress, amount1_in: u256, recipient: ContractAddress, sqrt_price_limit_X96: u256);
    fn swap_1_for_exact_0(ref self: TContractState, pool: ContractAddress, amount0_out: u256, recipient: ContractAddress, sqrt_price_limit_X96: u256);
    fn swap_to_lower_sqrt_price(ref self: TContractState, pool: ContractAddress, sqrt_price_X96: u256, recipient: ContractAddress);
    fn swap_to_higher_sqrt_price(ref self: TContractState, pool: ContractAddress, sqrt_price_X96: u256, recipient: ContractAddress);
    fn swap_for_exact_0_multi(ref self: TContractState, recipient: ContractAddress, pool_input: ContractAddress, pool_output: ContractAddress, amount0_out: u256);
    fn swap_for_exact_1_multi(ref self: TContractState, recipient: ContractAddress, pool_input: ContractAddress, pool_output: ContractAddress, amount1_out: u256);
    fn jediswap_v2_swap_callback(ref self: TContractState, amount0_delta: i256, amount1_delta: i256, callback_data_span: Span<felt252>);
}

#[starknet::contract]
mod PoolSwapTest {

    use integer::BoundedInt;
    use starknet::{ContractAddress, get_caller_address, get_contract_address};
    use yas_core::numbers::signed_integer::{i32::i32, i256::i256, integer_trait::IntegerTrait};
    use jediswap_v2_core::jediswap_v2_pool::{IJediSwapV2PoolDispatcher, IJediSwapV2PoolDispatcherTrait};
    use openzeppelin::token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
    use jediswap_v2_core::libraries::tick_math::TickMath::{MAX_SQRT_RATIO, MIN_SQRT_RATIO};

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        SwapCallback: SwapCallback, 
    }

    #[derive(Drop, starknet::Event)]
    struct SwapCallback {
        amount0_delta: i256,
        amount1_delta: i256
    }

    #[storage]
    struct Storage {
    }

    // @notice Contract constructor
    #[constructor]
    fn constructor(ref self: ContractState) {
    }

    #[external(v0)]
    impl PoolSwapTest of super::IPoolSwapTest<ContractState> {
        fn swap_exact_0_for_1(ref self: ContractState, pool: ContractAddress, amount0_in: u256, recipient: ContractAddress, sqrt_price_limit_X96: u256) {
            let caller = get_caller_address();
            let pool_dispatcher = IJediSwapV2PoolDispatcher { contract_address: pool };
            let mut callback_data: Array<felt252> = ArrayTrait::new();
            // callback_data.append(caller.into());    // TODO when possible
            callback_data.append(pool.into()); // We are sending pool address as callback get caller address will give us this caller due foundry cheat code
            pool_dispatcher.swap(recipient, true, IntegerTrait::<i256>::new(amount0_in, false), sqrt_price_limit_X96, callback_data);
        }

        fn swap_0_for_exact_1(ref self: ContractState, pool: ContractAddress, amount1_out: u256, recipient: ContractAddress, sqrt_price_limit_X96: u256) {
            let caller = get_caller_address();
            let pool_dispatcher = IJediSwapV2PoolDispatcher { contract_address: pool };
            let mut callback_data: Array<felt252> = ArrayTrait::new();
            // callback_data.append(caller.into());    // TODO when possible
            callback_data.append(pool.into()); // We are sending pool address as callback get caller address will give us this caller due foundry cheat code
            pool_dispatcher.swap(recipient, true, IntegerTrait::<i256>::new(amount1_out, true), sqrt_price_limit_X96, callback_data);
        }

        fn swap_exact_1_for_0(ref self: ContractState, pool: ContractAddress, amount1_in: u256, recipient: ContractAddress, sqrt_price_limit_X96: u256) {
            let caller = get_caller_address();
            let pool_dispatcher = IJediSwapV2PoolDispatcher { contract_address: pool };
            let mut callback_data: Array<felt252> = ArrayTrait::new();
            // callback_data.append(caller.into());    // TODO when possible
            callback_data.append(pool.into()); // We are sending pool address as callback get caller address will give us this caller due foundry cheat code
            pool_dispatcher.swap(recipient, false, IntegerTrait::<i256>::new(amount1_in, false), sqrt_price_limit_X96, callback_data);
        }

        fn swap_1_for_exact_0(ref self: ContractState, pool: ContractAddress, amount0_out: u256, recipient: ContractAddress, sqrt_price_limit_X96: u256) {
            let caller = get_caller_address();
            let pool_dispatcher = IJediSwapV2PoolDispatcher { contract_address: pool };
            let mut callback_data: Array<felt252> = ArrayTrait::new();
            // callback_data.append(caller.into());    // TODO when possible
            callback_data.append(pool.into()); // We are sending pool address as callback get caller address will give us this caller due foundry cheat code
            pool_dispatcher.swap(recipient, false, IntegerTrait::<i256>::new(amount0_out, true), sqrt_price_limit_X96, callback_data);
        }

        fn swap_to_lower_sqrt_price(ref self: ContractState, pool: ContractAddress, sqrt_price_X96: u256, recipient: ContractAddress) {
            let caller = get_caller_address();
            let pool_dispatcher = IJediSwapV2PoolDispatcher { contract_address: pool };
            let mut callback_data: Array<felt252> = ArrayTrait::new();
            // callback_data.append(caller.into());    // TODO when possible
            callback_data.append(pool.into()); // We are sending pool address as callback get caller address will give us this caller due foundry cheat code
            pool_dispatcher.swap(recipient, true, IntegerTrait::<i256>::new(BoundedInt::max() / 2 - 1, false), sqrt_price_X96, callback_data);
        }

        fn swap_to_higher_sqrt_price(ref self: ContractState, pool: ContractAddress, sqrt_price_X96: u256, recipient: ContractAddress) {
            let caller = get_caller_address();
            let pool_dispatcher = IJediSwapV2PoolDispatcher { contract_address: pool };
            let mut callback_data: Array<felt252> = ArrayTrait::new();
            // callback_data.append(caller.into());    // TODO when possible
            callback_data.append(pool.into()); // We are sending pool address as callback get caller address will give us this caller due foundry cheat code
            pool_dispatcher.swap(recipient, false, IntegerTrait::<i256>::new(BoundedInt::max() / 2 - 1, false), sqrt_price_X96, callback_data);
        }

        fn swap_for_exact_0_multi(ref self: ContractState, recipient: ContractAddress, pool_input: ContractAddress, pool_output: ContractAddress, amount0_out: u256) {
            let caller = get_caller_address();
            let pool_dispatcher = IJediSwapV2PoolDispatcher { contract_address: pool_output };
            let mut callback_data: Array<felt252> = ArrayTrait::new();
            // callback_data.append(caller.into());    // TODO when possible
            callback_data.append(pool_output.into()); // We are sending pool address as callback get caller address will give us this caller due foundry cheat code
            callback_data.append(pool_input.into());
            pool_dispatcher.swap(recipient, false, IntegerTrait::<i256>::new(amount0_out, true), MAX_SQRT_RATIO - 1, callback_data);
        }

        fn swap_for_exact_1_multi(ref self: ContractState, recipient: ContractAddress, pool_input: ContractAddress, pool_output: ContractAddress, amount1_out: u256) {
            let caller = get_caller_address();
            let pool_dispatcher = IJediSwapV2PoolDispatcher { contract_address: pool_output };
            let mut callback_data: Array<felt252> = ArrayTrait::new();
            // callback_data.append(caller.into());    // TODO when possible
            callback_data.append(pool_output.into()); // We are sending pool address as callback get caller address will give us this caller due foundry cheat code
            callback_data.append(pool_input.into());
            pool_dispatcher.swap(recipient, true, IntegerTrait::<i256>::new(amount1_out, true), MIN_SQRT_RATIO + 1, callback_data);
        }

        fn jediswap_v2_swap_callback(ref self: ContractState, amount0_delta: i256, amount1_delta: i256, mut callback_data_span: Span<felt252>) {

            self.emit(SwapCallback { amount0_delta, amount1_delta });
            // let pool_address = get_caller_address(); // TODO when possible
            let payer = get_caller_address();      // Getting this due to cheatcode
            // callback validation in actual router
            // let payer = Serde::<ContractAddress>::deserialize(ref callback_data_span).unwrap(); // TODO when possible
            if (callback_data_span.len() == 2) {
                let pool_address = Serde::<ContractAddress>::deserialize(ref callback_data_span).unwrap();  // Have to do this because of cheatcode
                let pool_dispatcher = IJediSwapV2PoolDispatcher { contract_address: pool_address };

                let (token_to_be_paid, amount_to_be_paid) = if (amount0_delta > IntegerTrait::<i256>::new(0, false)) {
                    (pool_dispatcher.get_token0(), amount0_delta)
                } else {
                    (pool_dispatcher.get_token1(), amount1_delta)
                };

                let second_pool_address = Serde::<ContractAddress>::deserialize(ref callback_data_span).unwrap();
                let second_pool_dispatcher = IJediSwapV2PoolDispatcher { contract_address: second_pool_address };
                
                let zero_for_one = (token_to_be_paid == second_pool_dispatcher.get_token1());
                let mut callback_data: Array<felt252> = ArrayTrait::new();
                // callback_data.append(payer.into());    // TODO when possible
                callback_data.append(second_pool_address.into()); // We are sending pool address as callback get caller address will give us this caller due foundry cheat code
                second_pool_dispatcher.swap(pool_address, zero_for_one, -amount_to_be_paid, if (zero_for_one) { MIN_SQRT_RATIO + 1 } else { MAX_SQRT_RATIO - 1 }, callback_data);
            } else {
                let pool_address = Serde::<ContractAddress>::deserialize(ref callback_data_span).unwrap();  // Have to do this because of cheatcode
                let pool_dispatcher = IJediSwapV2PoolDispatcher { contract_address: pool_address};
                if (amount0_delta > IntegerTrait::<i256>::new(0, false)) {
                    let token_dispatcher = IERC20Dispatcher { contract_address: pool_dispatcher.get_token0() };
                    token_dispatcher.transfer_from(payer, pool_address, amount0_delta.mag);
                }
                if (amount1_delta > IntegerTrait::<i256>::new(0, false)) {
                    let token_dispatcher = IERC20Dispatcher { contract_address: pool_dispatcher.get_token1() };
                    token_dispatcher.transfer_from(payer, pool_address, amount1_delta.mag);
                }
            }
        }
    }
}