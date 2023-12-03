use option::OptionTrait;
use starknet:: { ContractAddress, ClassHash, contract_address_try_from_felt252};

fn user1() -> ContractAddress {
    contract_address_try_from_felt252('user1').unwrap()
}

fn owner() -> ContractAddress {
    contract_address_try_from_felt252('owner').unwrap()
}

fn new_owner() -> ContractAddress {
    contract_address_try_from_felt252('new_owner').unwrap()
}