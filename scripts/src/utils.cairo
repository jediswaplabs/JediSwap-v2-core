use option::OptionTrait;
use starknet:: { ContractAddress, ClassHash, contract_address_try_from_felt252};

fn user1() -> ContractAddress {
    contract_address_try_from_felt252('user1').unwrap()
}

fn owner() -> ContractAddress { // TODO based on environment (rpc ?)
    // contract_address_try_from_felt252('owner').unwrap()
    contract_address_try_from_felt252(0x05c86BAD2F55d0b3af0D79bC3407a9D0aDa7449b64C69B0FF52A6631eB9d152E).unwrap() // JediSwap Testnet Treasury Multisig from Argent
}

fn new_owner() -> ContractAddress {
    contract_address_try_from_felt252('new_owner').unwrap()
}