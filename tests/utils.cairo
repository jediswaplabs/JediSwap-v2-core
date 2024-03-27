use option::OptionTrait;
use starknet::{
    ContractAddress, ClassHash, contract_address_try_from_felt252, contract_address_to_felt252
};
use integer::{u256_from_felt252};
use snforge_std::{declare, start_prank, stop_prank, ContractClass, ContractClassTrait, CheatTarget};
use jediswap_v2_core::libraries::math_utils::pow;
use openzeppelin::token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};

fn user1() -> ContractAddress {
    contract_address_try_from_felt252('user1').unwrap()
}

fn user2() -> ContractAddress {
    contract_address_try_from_felt252('user2').unwrap()
}

fn owner() -> ContractAddress {
    contract_address_try_from_felt252('owner').unwrap()
}

fn new_owner() -> ContractAddress {
    contract_address_try_from_felt252('new_owner').unwrap()
}

fn token0() -> ContractAddress {
    contract_address_try_from_felt252('token0').unwrap()
}

fn token1() -> ContractAddress {
    contract_address_try_from_felt252('token1').unwrap()
}

fn token0_1() -> (ContractAddress, ContractAddress) {
    let erc20_class = declare('ERC20');
    let token0_name = 'token0';
    let token0_symbol = 'TOK0';
    let initial_supply: u256 = 200 * pow(10, 18) * pow(10, 18);

    let mut token0_constructor_calldata = Default::default();
    Serde::serialize(@token0_name, ref token0_constructor_calldata);
    Serde::serialize(@token0_symbol, ref token0_constructor_calldata);
    Serde::serialize(@initial_supply, ref token0_constructor_calldata);
    Serde::serialize(@user1(), ref token0_constructor_calldata);
    let token0_address = erc20_class.deploy(@token0_constructor_calldata).unwrap();

    let token1_name = 'token1';
    let token1_symbol = 'TOK1';
    let initial_supply: u256 = 200 * pow(10, 18) * pow(10, 18);

    let mut token1_constructor_calldata = Default::default();
    Serde::serialize(@token1_name, ref token1_constructor_calldata);
    Serde::serialize(@token1_symbol, ref token1_constructor_calldata);
    Serde::serialize(@initial_supply, ref token1_constructor_calldata);
    Serde::serialize(@user1(), ref token1_constructor_calldata);
    let token1_address = erc20_class.deploy(@token1_constructor_calldata).unwrap();

    start_prank(CheatTarget::One(token0_address), user1());
    let token_dispatcher = IERC20Dispatcher { contract_address: token0_address };
    token_dispatcher.transfer(user2(), 100 * pow(10, 18) * pow(10, 18));
    stop_prank(CheatTarget::One(token0_address));

    start_prank(CheatTarget::One(token1_address), user1());
    let token_dispatcher = IERC20Dispatcher { contract_address: token1_address };
    token_dispatcher.transfer(user2(), 100 * pow(10, 18) * pow(10, 18));
    stop_prank(CheatTarget::One(token1_address));

    // (token0_address, token1_address)

    if (u256_from_felt252(
        contract_address_to_felt252(token0_address)
    ) < u256_from_felt252(contract_address_to_felt252(token1_address))) {
        return (token0_address, token1_address);
    } else {
        return (token1_address, token0_address);
    }
}

fn token0_1_2() -> (ContractAddress, ContractAddress, ContractAddress) {
    let erc20_class = declare('ERC20');
    let token0_name = 'token0';
    let token0_symbol = 'TOK0';
    let initial_supply: u256 = 200 * pow(10, 18) * pow(10, 18);

    let mut token0_constructor_calldata = Default::default();
    Serde::serialize(@token0_name, ref token0_constructor_calldata);
    Serde::serialize(@token0_symbol, ref token0_constructor_calldata);
    Serde::serialize(@initial_supply, ref token0_constructor_calldata);
    Serde::serialize(@user1(), ref token0_constructor_calldata);
    let token0_address = erc20_class.deploy(@token0_constructor_calldata).unwrap();

    let token1_name = 'token1';
    let token1_symbol = 'TOK1';
    let initial_supply: u256 = 200 * pow(10, 18) * pow(10, 18);

    let mut token1_constructor_calldata = Default::default();
    Serde::serialize(@token1_name, ref token1_constructor_calldata);
    Serde::serialize(@token1_symbol, ref token1_constructor_calldata);
    Serde::serialize(@initial_supply, ref token1_constructor_calldata);
    Serde::serialize(@user1(), ref token1_constructor_calldata);
    let token1_address = erc20_class.deploy(@token1_constructor_calldata).unwrap();

    let token2_name = 'token2';
    let token2_symbol = 'TOK2';
    let initial_supply: u256 = 200 * pow(10, 18) * pow(10, 18);

    let mut token2_constructor_calldata = Default::default();
    Serde::serialize(@token2_name, ref token2_constructor_calldata);
    Serde::serialize(@token2_symbol, ref token2_constructor_calldata);
    Serde::serialize(@initial_supply, ref token2_constructor_calldata);
    Serde::serialize(@user1(), ref token2_constructor_calldata);
    let token2_address = erc20_class.deploy(@token2_constructor_calldata).unwrap();

    start_prank(CheatTarget::One(token0_address), user1());
    let token_dispatcher = IERC20Dispatcher { contract_address: token0_address };
    token_dispatcher.transfer(user2(), 100 * pow(10, 18) * pow(10, 18));
    stop_prank(CheatTarget::One(token0_address));

    start_prank(CheatTarget::One(token1_address), user1());
    let token_dispatcher = IERC20Dispatcher { contract_address: token1_address };
    token_dispatcher.transfer(user2(), 100 * pow(10, 18) * pow(10, 18));
    stop_prank(CheatTarget::One(token1_address));

    start_prank(CheatTarget::One(token2_address), user1());
    let token_dispatcher = IERC20Dispatcher { contract_address: token2_address };
    token_dispatcher.transfer(user2(), 100 * pow(10, 18) * pow(10, 18));
    stop_prank(CheatTarget::One(token2_address));

    if (u256_from_felt252(
        contract_address_to_felt252(token0_address)
    ) < u256_from_felt252(contract_address_to_felt252(token1_address))) {
        if (u256_from_felt252(
            contract_address_to_felt252(token1_address)
        ) < u256_from_felt252(contract_address_to_felt252(token2_address))) {
            return (token0_address, token1_address, token2_address);
        } else if (u256_from_felt252(
            contract_address_to_felt252(token2_address)
        ) < u256_from_felt252(contract_address_to_felt252(token0_address))) {
            return (token2_address, token0_address, token1_address);
        }
        return (token0_address, token2_address, token1_address);
    } else {
        if (u256_from_felt252(
            contract_address_to_felt252(token0_address)
        ) < u256_from_felt252(contract_address_to_felt252(token2_address))) {
            return (token1_address, token0_address, token2_address);
        } else if (u256_from_felt252(
            contract_address_to_felt252(token2_address)
        ) < u256_from_felt252(contract_address_to_felt252(token1_address))) {
            return (token2_address, token1_address, token0_address);
        }
        return (token1_address, token2_address, token0_address);
    }
}
