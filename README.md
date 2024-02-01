# JediSwap-v2-core

This repository consists of the core contracts of JediSwap V2 protocol, a cairo fork of Uniswap V3. CLAMM for Starknet.

## Testing and Development

Prerequisites:

- [Scarb](https://github.com/software-mansion/scarb) for managing the project.
- [starknet-foundry](https://github.com/foundry-rs/starknet-foundry) for testing and writing scripts. 

### Compile Contracts
```
scarb build
```

### Run Tests
```
snforge test
```

### Run Scripts


#### Run a local devnet

We use [starknet-devnet-rs](https://github.com/0xSpaceShard/starknet-devnet-rs)

Run the devnet and add one of the predeployed accounts with your preferred name <test_account_local>. See the instructions [here](https://foundry-rs.github.io/starknet-foundry/starknet/account.html#importing-an-account).

#### Run Scripts

Run sncast in the parent folder by specifying the path to the script file. Example:

```
sncast --url http://127.0.0.1:5050 --account <test_account_local> --path-to-scarb-toml scripts/Scarb.toml script deploy_factory_and_pool
```