// @title Canonical JediSwap V2 factory
// @notice Deploys JediSwap V2 pools and manages ownership and control over pool protocol fees

use starknet::ContractAddress;
use yas_core::numbers::signed_integer::{i32::i32};

#[starknet::interface]
trait IJediSwapV2Factory<TContractState> {
    fn fee_amount_tick_spacing(self: @TContractState, fee: u32) -> u32;
    fn get_pool(
        self: @TContractState, token_a: ContractAddress, token_b: ContractAddress, fee: u32
    ) -> ContractAddress;
    fn get_fee_protocol(self: @TContractState) -> u8;

    fn create_pool(
        ref self: TContractState, token_a: ContractAddress, token_b: ContractAddress, fee: u32
    ) -> ContractAddress;
    fn enable_fee_amount(ref self: TContractState, fee: u32, tick_spacing: u32);
    fn set_fee_protocol(ref self: TContractState, fee_protocol: u8);
}


#[starknet::contract]
mod JediSwapV2Factory {
    use poseidon::poseidon_hash_span;
    use starknet::SyscallResultTrait;
    use starknet::syscalls::deploy_syscall;
    use starknet::{
        ContractAddress, ClassHash, get_caller_address, get_contract_address,
        contract_address_to_felt252
    };
    use integer::{u256_from_felt252};
    use yas_core::numbers::signed_integer::{i32::i32, integer_trait::IntegerTrait};
    use openzeppelin::access::ownable::OwnableComponent;

    component!(path: OwnableComponent, storage: ownable_storage, event: OwnableEvent);

    #[abi(embed_v0)]
    impl OwnableImpl = OwnableComponent::OwnableImpl<ContractState>;

    impl OwnableInternalImpl = OwnableComponent::InternalImpl<ContractState>;

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        PoolCreated: PoolCreated,
        FeeAmountEnabled: FeeAmountEnabled,
        SetFeeProtocol: SetFeeProtocol,
        #[flat]
        OwnableEvent: OwnableComponent::Event
    }

    // @notice Emitted when a pool is created
    // @param token0 The first token of the pool by address sort order
    // @param token1 The second token of the pool by address sort order
    // @param fee The fee collected upon every swap in the pool, denominated in hundredths of a bip
    // @param tick_spacing The minimum number of ticks between initialized ticks
    // @param pool The address of the created pool
    #[derive(Drop, starknet::Event)]
    struct PoolCreated {
        token0: ContractAddress,
        token1: ContractAddress,
        fee: u32,
        tick_spacing: u32,
        pool: ContractAddress
    }

    // @notice Emitted when a new fee amount is enabled for pool creation via the factory
    // @param fee The enabled fee, denominated in hundredths of a bip
    // @param tick_spacing The minimum number of ticks between initialized ticks for pools created with the given fee
    #[derive(Drop, starknet::Event)]
    struct FeeAmountEnabled {
        fee: u32,
        tick_spacing: u32
    }

    // @notice Emitted when the protocol fee is changed by the owner
    // @param old_fee_protocol The previous value of the protocol fee
    // @param new_fee_protocol The updated value of the protocol fee
    #[derive(Drop, starknet::Event)]
    struct SetFeeProtocol {
        old_fee_protocol: u8,
        new_fee_protocol: u8
    }

    #[storage]
    struct Storage {
        owner: ContractAddress,
        fee_amount_tick_spacing: LegacyMap::<u32, u32>,
        pool: LegacyMap<(ContractAddress, ContractAddress, u32), ContractAddress>,
        pool_class_hash: ClassHash,
        fee_protocol: u8,
        #[substorage(v0)]
        ownable_storage: OwnableComponent::Storage
    }

    #[constructor]
    fn constructor(ref self: ContractState, owner: ContractAddress, pool_class_hash: ClassHash) {
        self.ownable_storage.initializer(owner);

        assert(pool_class_hash.is_non_zero(), 'pool class hash can not be zero');
        self.pool_class_hash.write(pool_class_hash);

        self.fee_amount_tick_spacing.write(100, 2);
        self.emit(FeeAmountEnabled { fee: 100, tick_spacing: 2 });

        self.fee_amount_tick_spacing.write(500, 10);
        self.emit(FeeAmountEnabled { fee: 500, tick_spacing: 10 });

        self.fee_amount_tick_spacing.write(3000, 60);
        self.emit(FeeAmountEnabled { fee: 3000, tick_spacing: 60 });

        self.fee_amount_tick_spacing.write(10000, 200);
        self.emit(FeeAmountEnabled { fee: 10000, tick_spacing: 200 });

        self.fee_protocol.write(0);
    }

    #[external(v0)]
    impl JediSwapV2FactoryImpl of super::IJediSwapV2Factory<ContractState> {
        // @notice Returns the tick spacing for a given fee amount, if enabled, or 0 if not enabled
        // @dev A fee amount can never be removed, so this value should be hard coded or cached in the calling context
        // @param fee The enabled fee, denominated in hundredths of a bip. Returns 0 in case of unenabled fee
        // @return The tick spacing
        fn fee_amount_tick_spacing(self: @ContractState, fee: u32) -> u32 {
            self.fee_amount_tick_spacing.read(fee)
        }

        // @notice Returns the pool address for a given pair of tokens and a fee, or address 0 if it does not exist
        // @dev token_a and token_b may be passed in either token0/token1 or token1/token0 order
        // @param token_a The contract address of either token0 or token1
        // @param token_b The contract address of the other token
        // @param fee The fee collected upon every swap in the pool, denominated in hundredths of a bip
        // @return The pool address
        fn get_pool(
            self: @ContractState, token_a: ContractAddress, token_b: ContractAddress, fee: u32
        ) -> ContractAddress {
            self.pool.read((token_a, token_b, fee))
        }

        // @notice The current protocol fee as a percentage of the swap fee taken on withdrawal
        // represented as an integer denominator (1/x)%
        // @return The current protocol fee denominator
        fn get_fee_protocol(self: @ContractState) -> u8 {
            self.fee_protocol.read()
        }

        // @notice Creates a pool for the given two tokens and fee
        // @param token_a One of the two tokens in the desired pool
        // @param token_b The other of the two tokens in the desired pool
        // @param fee The desired fee for the pool
        // @dev token_a and token_b may be passed in either order: token0/token1 or token1/token0. tick_spacing is retrieved
        // from the fee. The call will revert if the pool already exists, the fee is invalid, or the token arguments
        // are invalid.
        // @return The address of the newly created pool
        fn create_pool(
            ref self: ContractState, token_a: ContractAddress, token_b: ContractAddress, fee: u32
        ) -> ContractAddress {
            assert(token_a != token_b, 'tokens must be different');
            assert(token_a.is_non_zero() && token_b.is_non_zero(), 'tokens must be non zero');

            let (token0, token1) = if (u256_from_felt252(
                contract_address_to_felt252(token_a)
            ) < u256_from_felt252(contract_address_to_felt252(token_b))) {
                (token_a, token_b)
            } else {
                (token_b, token_a)
            };

            let tick_spacing = self.fee_amount_tick_spacing(fee);
            assert(tick_spacing.is_non_zero(), 'tick spacing not initialized');

            assert(self.get_pool(token0, token1, fee).is_zero(), 'pool already created');

            let mut hash_data = array![];
            Serde::serialize(@token0, ref hash_data);
            Serde::serialize(@token1, ref hash_data);
            Serde::serialize(@fee, ref hash_data);
            let salt = poseidon_hash_span(hash_data.span());

            let mut constructor_calldata = array![];
            Serde::serialize(@token0, ref constructor_calldata);
            Serde::serialize(@token1, ref constructor_calldata);
            Serde::serialize(@fee, ref constructor_calldata);
            Serde::serialize(@tick_spacing, ref constructor_calldata);

            let (pool, _) = deploy_syscall(
                self.pool_class_hash.read(), salt, constructor_calldata.span(), false
            )
                .unwrap_syscall();

            self.pool.write((token0, token1, fee), pool);
            // populate mapping in the reverse direction, deliberate choice to avoid the cost of comparing addresses
            self.pool.write((token1, token0, fee), pool);

            self.emit(PoolCreated { token0, token1, fee, tick_spacing, pool });

            pool
        }

        // @notice Enables a fee amount with the given tick_spacing
        // @dev Fee amounts may never be removed once enabled
        // @param fee The fee amount to enable, denominated in hundredths of a bip (i.e. 1e-6)
        // @param tick_spacing The spacing between ticks to be enforced for all pools created with the given fee amount
        fn enable_fee_amount(ref self: ContractState, fee: u32, tick_spacing: u32) {
            self.ownable_storage.assert_only_owner();
            assert(fee <= 100000, 'fee cannot be above 100000');

            // tick spacing is capped at 16384 to prevent the situation where tick_spacing is so large that
            // TickBitmap#next_initialized_tick_within_one_word overflows container from a valid tick
            // 16384 ticks represents a >5x price change with ticks of 1 bips
            assert(tick_spacing > 0 && tick_spacing < 16384, 'invalid tick_spacing');
            assert(self.fee_amount_tick_spacing(fee).is_zero(), 'fee already enabled');

            self.fee_amount_tick_spacing.write(fee, tick_spacing);
            self.emit(FeeAmountEnabled { fee, tick_spacing });
        }

        // @notice Sets the denominator of the protocol's % share of the fees
        // @param fee_protocol new protocol fee
        fn set_fee_protocol(ref self: ContractState, fee_protocol: u8) {
            self.ownable_storage.assert_only_owner();
            assert(
                fee_protocol == 0 || (fee_protocol >= 4 && fee_protocol <= 10),
                'incorrect fee_protocol'
            );

            let old_fee_protocol = self.fee_protocol.read();
            self.fee_protocol.write(fee_protocol);
            self.emit(SetFeeProtocol { old_fee_protocol, new_fee_protocol: fee_protocol });
        }
    }
}
