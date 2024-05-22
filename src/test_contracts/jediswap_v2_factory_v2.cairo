// @title Canonical JediSwap V2 factory
// @notice Deploys JediSwap V2 pools and manages ownership and control over pool protocol fees

use starknet::{ContractAddress, ClassHash};
use jediswap_v2_core::libraries::signed_integers::i32::i32;

#[starknet::interface]
trait IJediSwapV2FactoryV2<TContractState> {
    fn fee_amount_tick_spacing(self: @TContractState, fee: u32) -> u32;
    fn get_pool(
        self: @TContractState, token_a: ContractAddress, token_b: ContractAddress, fee: u32
    ) -> ContractAddress;
    fn get_fee_protocol_v2(self: @TContractState) -> u8;
    fn get_pool_class_hash(self: @TContractState) -> ClassHash;

    fn create_pool(
        ref self: TContractState, token_a: ContractAddress, token_b: ContractAddress, fee: u32
    ) -> ContractAddress;
    fn enable_fee_amount(ref self: TContractState, fee: u32, tick_spacing: u32);
    fn set_fee_protocol(ref self: TContractState, fee_protocol: u8);
    fn upgrade(ref self: TContractState, new_class_hash: ClassHash, new_pool_class_hash: ClassHash);
    fn pause(ref self: TContractState);
    fn unpause(ref self: TContractState);
}


#[starknet::contract]
mod JediSwapV2FactoryV2 {
    use poseidon::poseidon_hash_span;
    use starknet::SyscallResultTrait;
    use starknet::syscalls::deploy_syscall;
    use starknet::{
        ContractAddress, ClassHash, get_caller_address, get_contract_address,
        contract_address_to_felt252
    };
    use integer::{u256_from_felt252};
    use jediswap_v2_core::libraries::signed_integers::{i32::i32, integer_trait::IntegerTrait};
    use openzeppelin::access::ownable::OwnableComponent;
    use openzeppelin::upgrades::upgradeable::UpgradeableComponent;
    use openzeppelin::security::pausable::PausableComponent;

    component!(path: OwnableComponent, storage: ownable_storage, event: OwnableEvent);
    component!(path: UpgradeableComponent, storage: upgradeable_storage, event: UpgradeableEvent);
    component!(path: PausableComponent, storage: pausable_storage, event: PausableEvent);

    #[abi(embed_v0)]
    impl OwnableImpl = OwnableComponent::OwnableImpl<ContractState>;

    #[abi(embed_v0)]
    impl PausableImpl = PausableComponent::PausableImpl<ContractState>;

    impl OwnableInternalImpl = OwnableComponent::InternalImpl<ContractState>;
    impl UpgradeableInternalImpl = UpgradeableComponent::InternalImpl<ContractState>;
    impl PausableInternalImpl = PausableComponent::InternalImpl<ContractState>;

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        PoolCreated: PoolCreated,
        FeeAmountEnabled: FeeAmountEnabled,
        SetFeeProtocol: SetFeeProtocol,
        UpgradedPoolClassHash: UpgradedPoolClassHash,
        #[flat]
        OwnableEvent: OwnableComponent::Event,
        #[flat]
        UpgradeableEvent: UpgradeableComponent::Event,
        #[flat]
        PausableEvent: PausableComponent::Event
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

    // @notice Emitted when pool class hash is upgraded
    // @param class_hash The new pool class hash which will be used to deploy new pools
    #[derive(Drop, starknet::Event)]
    struct UpgradedPoolClassHash {
        class_hash: ClassHash,
    }

    #[storage]
    struct Storage {
        owner: ContractAddress,
        fee_amount_tick_spacing: LegacyMap::<u32, u32>,
        pool: LegacyMap<(ContractAddress, ContractAddress, u32), ContractAddress>,
        pool_class_hash: ClassHash,
        fee_protocol: u8,
        #[substorage(v0)]
        ownable_storage: OwnableComponent::Storage,
        #[substorage(v0)]
        upgradeable_storage: UpgradeableComponent::Storage,
        #[substorage(v0)]
        pausable_storage: PausableComponent::Storage
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

    #[abi(embed_v0)]
    impl JediSwapV2FactoryV2Impl of super::IJediSwapV2FactoryV2<ContractState> {
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
        fn get_fee_protocol_v2(self: @ContractState) -> u8 {
            self.fee_protocol.read()
        }

        // @notice The current pool class hash used to deploy new pools
        // @return The current pool class hash
        fn get_pool_class_hash(self: @ContractState) -> ClassHash {
            self.pool_class_hash.read()
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
            self.pausable_storage.assert_not_paused();
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

        // @notice Upgrades factory class hash and pool class hash
        // @dev Only owner can call. new_pool_class_hash can be zero if upgrading only factory class hash
        // @param new_class_hash New class hash for factory
        // @param new_pool_class_hash New class hash for pools
        fn upgrade(
            ref self: ContractState, new_class_hash: ClassHash, new_pool_class_hash: ClassHash
        ) {
            self.ownable_storage.assert_only_owner();
            if (!new_pool_class_hash.is_zero()
                && self.pool_class_hash.read() != new_pool_class_hash) {
                self.pool_class_hash.write(new_pool_class_hash);
                self.emit(UpgradedPoolClassHash { class_hash: new_pool_class_hash });
            }
            self.upgradeable_storage._upgrade(new_class_hash);
        }

        fn pause(ref self: ContractState) {
            self.ownable_storage.assert_only_owner();
            self.pausable_storage._pause();
        }

        fn unpause(ref self: ContractState) {
            self.ownable_storage.assert_only_owner();
            self.pausable_storage._unpause();
        }
    }
}
