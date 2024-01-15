use starknet::ContractAddress;
use yas_core::numbers::signed_integer::{i32::i32};

#[starknet::interface]
trait IPoolMintTest<TContractState> {
    fn mint(
        ref self: TContractState,
        pool: ContractAddress,
        recipient: ContractAddress,
        tick_lower: i32,
        tick_upper: i32,
        amount: u128
    );
    fn jediswap_v2_mint_callback(
        ref self: TContractState,
        amount0_owed: u256,
        amount1_owed: u256,
        callback_data_span: Span<felt252>
    );
}

#[starknet::contract]
mod PoolMintTest {
    use starknet::{ContractAddress, get_caller_address, get_contract_address};
    use yas_core::numbers::signed_integer::{i32::i32};
    use jediswap_v2_core::jediswap_v2_pool::{
        IJediSwapV2PoolDispatcher, IJediSwapV2PoolDispatcherTrait
    };
    use openzeppelin::token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        MintCallback: MintCallback,
    }

    #[derive(Drop, starknet::Event)]
    struct MintCallback {
        amount0_owed: u256,
        amount1_owed: u256
    }

    #[storage]
    struct Storage {}

    // @notice Contract constructor
    #[constructor]
    fn constructor(ref self: ContractState) {}

    #[external(v0)]
    impl PoolMintTest of super::IPoolMintTest<ContractState> {
        fn mint(
            ref self: ContractState,
            pool: ContractAddress,
            recipient: ContractAddress,
            tick_lower: i32,
            tick_upper: i32,
            amount: u128
        ) {
            let caller = get_caller_address();
            let pool_dispatcher = IJediSwapV2PoolDispatcher { contract_address: pool };
            let mut callback_data: Array<felt252> = ArrayTrait::new();
            // callback_data.append(caller.into());    // TODO when possible
            callback_data
                .append(
                    pool.into()
                ); // We are sending pool address as callback get caller address will give us this caller due foundry cheat code
            pool_dispatcher.mint(recipient, tick_lower, tick_upper, amount, callback_data);
        }

        fn jediswap_v2_mint_callback(
            ref self: ContractState,
            amount0_owed: u256,
            amount1_owed: u256,
            mut callback_data_span: Span<felt252>
        ) {
            // let pool_address = get_caller_address(); // TODO when possible
            let sender = get_caller_address(); // Getting this due to cheatcode
            // callback validation in actual router
            // let sender = Serde::<ContractAddress>::deserialize(ref callback_data_span).unwrap(); // TODO when possible
            let pool_address = Serde::<ContractAddress>::deserialize(ref callback_data_span)
                .unwrap(); // Have to do this because of cheatcode
            self.emit(MintCallback { amount0_owed, amount1_owed });
            let pool_dispatcher = IJediSwapV2PoolDispatcher { contract_address: pool_address };
            if (amount0_owed > 0) {
                let token_dispatcher = IERC20Dispatcher {
                    contract_address: pool_dispatcher.get_token0()
                };
                token_dispatcher.transfer_from(sender, pool_address, amount0_owed);
            }
            if (amount1_owed > 0) {
                let token_dispatcher = IERC20Dispatcher {
                    contract_address: pool_dispatcher.get_token1()
                };
                token_dispatcher.transfer_from(sender, pool_address, amount1_owed);
            }
        }
    }
}
