use starknet::ContractAddress;
use yas_core::numbers::signed_integer::{i32::i32, i256::i256};

#[starknet::interface]
trait IPoolSwapTest<TContractState> {
    fn swap_exact_0_for_1(ref self: TContractState, pool: ContractAddress, amount0_in: u256, recipient: ContractAddress, sqrt_price_limit_X96: u256);
    fn swap_0_for_exact_1(ref self: TContractState, pool: ContractAddress, amount1_out: u256, recipient: ContractAddress, sqrt_price_limit_X96: u256);
    fn swap_exact_1_for_0(ref self: TContractState, pool: ContractAddress, amount1_in: u256, recipient: ContractAddress, sqrt_price_limit_X96: u256);
    fn swap_1_for_exact_0(ref self: TContractState, pool: ContractAddress, amount0_out: u256, recipient: ContractAddress, sqrt_price_limit_X96: u256);
    fn jediswap_v2_swap_callback(ref self: TContractState, amount0_delta: i256, amount1_delta: i256, callback_data_span: Span<felt252>);
}

#[starknet::contract]
mod PoolSwapTest {

    use starknet::{ContractAddress, get_caller_address, get_contract_address};
    use yas_core::numbers::signed_integer::{i32::i32, i256::i256, integer_trait::IntegerTrait};
    use jediswap_v2_core::jediswap_v2_pool::{IJediSwapV2PoolDispatcher, IJediSwapV2PoolDispatcherTrait};
    use openzeppelin::token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};

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

        fn jediswap_v2_swap_callback(ref self: ContractState, amount0_delta: i256, amount1_delta: i256, mut callback_data_span: Span<felt252>) {
            // let pool_address = get_caller_address(); // TODO when possible
            let sender = get_caller_address();      // Getting this due to cheatcode
            // callback validation in actual router
            // let sender = Serde::<ContractAddress>::deserialize(ref callback_data_span).unwrap(); // TODO when possible
            let pool_address = Serde::<ContractAddress>::deserialize(ref callback_data_span).unwrap(); // Have to do this because of cheatcode
            self.emit(SwapCallback { amount0_delta, amount1_delta });
            let pool_dispatcher = IJediSwapV2PoolDispatcher { contract_address: pool_address};
            if (amount0_delta > IntegerTrait::<i256>::new(0, false)) {
                let token_dispatcher = IERC20Dispatcher { contract_address: pool_dispatcher.get_token0() };
                token_dispatcher.transfer_from(sender, pool_address, amount0_delta.mag);
            }
            if (amount1_delta > IntegerTrait::<i256>::new(0, false)) {
                let token_dispatcher = IERC20Dispatcher { contract_address: pool_dispatcher.get_token1() };
                token_dispatcher.transfer_from(sender, pool_address, amount1_delta.mag);
            }
        }
    }
}