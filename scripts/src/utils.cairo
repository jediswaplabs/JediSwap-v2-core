use option::OptionTrait;
use starknet::{ContractAddress, ClassHash, contract_address_try_from_felt252};

fn owner() -> ContractAddress { // TODO based on environment (rpc ?)
    contract_address_try_from_felt252(
        0x05c86BAD2F55d0b3af0D79bC3407a9D0aDa7449b64C69B0FF52A6631eB9d152E
    )
        .unwrap() // JediSwap Mainnet/Goerli Treasury Multisig from Argent
    // contract_address_try_from_felt252(
    //     0x0640e83E96Ea6aE55f90b2BE15f15717B8203e680b25ff979Ee1E81B58b6147a
    // )
    //     .unwrap() // Sepolia Argent Personal
}

