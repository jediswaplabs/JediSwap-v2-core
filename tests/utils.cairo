use option::OptionTrait;
use starknet:: { ContractAddress, ClassHash, contract_address_try_from_felt252, contract_address_to_felt252 };
use integer::{u256_from_felt252};
use snforge_std::{ declare, ContractClass, ContractClassTrait, PrintTrait };
use yas_core::utils::math_utils::{pow};

fn user1() -> ContractAddress {
    contract_address_try_from_felt252('user1').unwrap()
}

fn owner() -> ContractAddress {
    contract_address_try_from_felt252('owner').unwrap()
}

fn new_owner() -> ContractAddress {
    contract_address_try_from_felt252('new_owner').unwrap()
}

fn token0_1() -> (ContractAddress, ContractAddress) {
    let erc20_class = declare('ERC20');
    let token0_name = 'token0';
    let token0_symbol = 'TOK0';
    let initial_supply: u256 = 100 * pow(10, 18);

    let mut token0_constructor_calldata = Default::default();
    Serde::serialize(@token0_name, ref token0_constructor_calldata);
    Serde::serialize(@token0_symbol, ref token0_constructor_calldata);
    Serde::serialize(@initial_supply, ref token0_constructor_calldata);
    Serde::serialize(@user1(), ref token0_constructor_calldata);
    // let token0_address = contract_address_try_from_felt252('token0').unwrap();
    // erc20_class.deploy_at(@token0_constructor_calldata, token0_address).unwrap();
    let token0_address = erc20_class.deploy(@token0_constructor_calldata).unwrap();
    'token0 address'.print();
    token0_address.print();

    let token1_name = 'token1';
    let token1_symbol = 'TOK1';
    let initial_supply: u256 = 100 * pow(10, 18);

    let mut token1_constructor_calldata = Default::default();
    Serde::serialize(@token1_name, ref token1_constructor_calldata);
    Serde::serialize(@token1_symbol, ref token1_constructor_calldata);
    Serde::serialize(@initial_supply, ref token1_constructor_calldata);
    Serde::serialize(@user1(), ref token1_constructor_calldata);
    // let token1_address = contract_address_try_from_felt252('token1').unwrap();
    // erc20_class.deploy_at(@token1_constructor_calldata, token1_address).unwrap();
    let token1_address = erc20_class.deploy(@token1_constructor_calldata).unwrap();
    'token1 address'.print();
    token1_address.print();

    // (token0_address, token1_address)

    if (u256_from_felt252(contract_address_to_felt252(token0_address)) < u256_from_felt252(contract_address_to_felt252(token1_address))) {
        return (token0_address, token1_address);
    } else {
        return (token1_address, token0_address);
    }
}