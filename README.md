# JediSwap-v2-core

This repository consists of the core contracts of JediSwap V2 protocol, a cairo fork of Uniswap V3. CLAMM for Starknet.

## Testing and Development

Prerequisites:

- [Scarb] (https://github.com/software-mansion/scarb) for managing the project.
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

```
python -m venv ./venv
source ./venv/bin/activate
```

#### Install dependencies
```
pip install -r requirements.txt
```

Find more info about the installed dependencies here:
* [starknet-devnet](https://github.com/Shard-Labs/starknet-devnet)
* [starknet.py](https://github.com/software-mansion/starknet.py)


#### Run Scripts

All scripts are placed in ```scripts``` folder. testnet config is not committed, please create your own in ```scripts/config```

To run scripts on local system, you first need to run a devnet server:
```
starknet-devnet
```

Run script by specifying the path to the script file. Example:
```
python scripts/deploy.py local
```