
# Change Log

All notable changes to this project will be documented in this file.

# [0.0.3](https://github.com/okx/go-wallet-sdk) (2026-05-21)

### Breaking changes

- **tron-sdk:** consolidate protobuf into a single `tron_minimal.pb.go`; most `pb` types not used for offline signing are no longer exported (Account/Block/Asset/Exchange/Resource/SmartContract/Networking variants). Use upstream `github.com/tronprotocol/grpc-gateway` if you need them.
- **tron-sdk:** rewrite signing API. Removed: `Sign`, `SignStart`, `SignEnd`, `ParseTxStr`, `NewTransfer`, `NewTRC20TokenTransfer`; struct types `Transaction`, `TronTransaction`, `TronTokenTransaction` (file `types.go` deleted).
- **tron-sdk:** remove RefBlock validations (offline SDK has no access to chain state).

### New features

- **tron-sdk:** new offline-signing API — `SignTx`, `SignTransfer`, `SignContractTx`, `SignTokenTransfer`, `SignMessage`, `SignTypedMessage`, `VerifyMessage`/`V1`/`WithAddress`, `GetMessageHash`/`V1`, `TypedMessageHash`, `CalSigHash`, `CalTxHash`, `DecodeTx`, `GenTrxTransferTx`, `GenTokenTransferTx`, `GenContractTx`, `ValidateContractAddress`.
- **tron-sdk:** add `proto/tron_minimal.proto` source schema and inline `coins/tron/encoder` subpackage.

# [0.0.2](https://github.com/okx/go-wallet-sdk) (2023-11-20)

### updates

- **tron-sdk:** change some files name and remove some unused libs ([21](https://github.com/okx/go-wallet-sdk/pull/21))
