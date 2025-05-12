## Foundry

**Foundry is a blazing fast, portable and modular toolkit for Ethereum application development written in Rust.**

Foundry consists of:

- **Forge**: Ethereum testing framework (like Truffle, Hardhat and DappTools).
- **Cast**: Swiss army knife for interacting with EVM smart contracts, sending transactions and getting chain data.
- **Anvil**: Local Ethereum node, akin to Ganache, Hardhat Network.
- **Chisel**: Fast, utilitarian, and verbose solidity REPL.

## Documentation

https://book.getfoundry.sh/

## Usage

### Build

```shell
$ forge build
```

### Test

```shell
$ forge test
```

### Format

```shell
$ forge fmt
```

### Gas Snapshots

```shell
$ forge snapshot
```

### Anvil

```shell
$ anvil
```

### Deploy

```shell
$ forge script script/Counter.s.sol:CounterScript --rpc-url <your_rpc_url> --private-key <your_private_key>
```

### Cast

```shell
$ cast <subcommand>
```

### Help

```shell
$ forge --help
$ anvil --help
$ cast --help
```

## License

AX11 AMM uses a dual licensing model:

1. **Business Source License 1.1 (BUSL-1.1)**

   - Files licensed under BUSL-1.1 will transition to GPLv3 on 2029-05-12
   - These files are currently restricted to evaluation and non-production use
   - See [BUSL_LICENSE](https://github.com/AX11-Labs/AX11-AMM/licenses/BUSL_LICENSE)

2. **GNU General Public License v3.0 (GPLv3)**
   - Some files are immediately licensed under GPLv3
   - See [GPL3_LICENSE](https://github.com/AX11-Labs/AX11-AMM/licenses/GPL3_LICENSE)

Each file in the codebase states its applicable license type in the header. For detailed information about the licensing terms and conditions, please refer to the respective license files.
