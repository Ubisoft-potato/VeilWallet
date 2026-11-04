# EVM support

The fixed catalog contains 81 mainnets plus Sepolia; 56 mainnets are prioritized in the picker. It includes Ethereum, BNB Chain, Polygon, Arbitrum/Nova, Optimism, Base, Avalanche, Sonic, Gnosis, Cronos, Celo, Kaia, Sei, Berachain, HyperEVM, Monad, Linea, Scroll, zkSync, Mantle, Abstract, World Chain, Soneium, Lisk, Morph, Hemi, Zircuit, Fraxtal, Immutable zkEVM, Astar, IoTeX and Telos. See the exact [catalog](../Sources/WalletCore/Resources/evm-networks.json).

An imported EVM mnemonic/32-byte key uses the same address/key on networks sharing that derivation path. Cross-chain activity can therefore be linked. Account indices, custom paths and watch-only imports are supported.

## Operations

- Exact native/ERC20 balances, receive addresses and QR codes.
- Native/ERC20 transfer previews with nonce, gas, fees, full recipient and contract.
- Local EIP-1559 or Legacy EIP-155 signing; recheck chain ID, balance, nonce and expiry, with password verification per signature.
- Tor-only requests/remote DNS, no direct fallback; configurable asset scans/prices are described in [ASSETS.md](ASSETS.md).
- Hash/archive persistence before broadcast, receipt checking and manual same-payload rebroadcast; no automatic retry.

Unavailable/rate-limited/API-key-only nodes fail explicitly, never as zero balance. Users may replace HTTPS RPC endpoints in Settings; addresses are not automatically spread across providers. Only known old default strings migrate, preserving custom endpoints.

Addresses use 0x hex/EIP55. XDC's legacy xdc prefix and Rootstock-specific EIP1191 mixed-case checks are not supported; verify the same 20-byte address before using lowercase 0x. ENS, smart-account signing and arbitrary DApp requests are unavailable.

## Fee models

| Model | Estimation |
|---|---|
| Standard | eth_estimateGas +20% gas buffer; latest block distinguishes Legacy/EIP-1559; node fee prices |
| Arbitrum/Nova | RPC gas estimate already includes parent-chain data cost; no added OP oracle fee |
| zkSync Era/Abstract | EraVM has no priority-fee market; node gasPrice and Legacy EIP-155; no paymasters/custom EIP712 account transactions |
| OP Stack | getL1FeeUpperBound(unsignedSize), older supported versions use getL1Fee(unsignedRLP); verified getOperatorFee interfaces |
| Mantle | Before Arsia, gas estimate includes old fees; after Arsia, add L1 data/operator fees |
| Scroll | getL1Fee with serialized signed-length bytes; estimator bytes are never signed/broadcast |
| Execution only | Manta, Metis, Boba, BitLayer, Merlin, zkFair, Taiko, Morph, Hemi: additional DA/protocol fees incomplete; explicit UI warning |
| Sending disabled | Tempo/Arc: native asset/fee model unsupported |

OP/Mantle/Scroll additional fees get a 20% budget included in balance requirements and are reread before signing. Exceeding the approved budget requires a new preview. This local budget is not an on-chain cap: data prices/compression/signature bytes may change actual fees. RPC/rate-limit/ABI failures never become zero fees.

ETHW's earlier erroneous smartBCH testnet endpoint was corrected. Both share chain ID 10001, so ETHW additionally checks Ethereum's genesis hash. This remains node-dependent validation, not light-client proof.

## Validation and sources

Tests cover network isolation, ERC20 encoding, oracle ABI/versions, fee increases, Mantle upgrade branches, Scroll lengths and wrong ETHW genesis. Historical Tor checks are in [VALIDATION.md](VALIDATION.md) and [EVM_RPC_REPORT.md](EVM_RPC_REPORT.md), not funded-transfer acceptance.

~~~bash
./Scripts/swift.sh test
.build/out/Products/Debug/TorSmoke "$PWD/Vendor/Tor" --evm --evm-report "$PWD/.build/evm-report.json"
~~~

The tool queries public burn-address fixtures without opening the vault, logging addresses/balances or signing/broadcasting. --evm-all selects all mainnets; --evm-ids selects IDs; --evm-rpc ID=https://… temporarily overrides an endpoint under the same Tor rules.

Sources: [Viem chain definitions](https://github.com/wevm/viem/tree/main/src/chains/definitions), [ethereum-lists](https://github.com/ethereum-lists/chains), [PublicNode](https://publicnode.com), [Lisk](https://docs.lisk.com/lisk-chain/lisk-tools/node-providers/), [Moonbeam](https://docs.moonbeam.network/builders/get-started/endpoints/), [Filecoin](https://docs.filecoin.io/networks-and-tools/networks/mainnet/rpcs.md), [OP oracle](https://github.com/ethereum-optimism/optimism/blob/develop/packages/contracts-bedrock/src/L2/GasPriceOracle.sol), [Mantle oracle](https://github.com/mantle-xyz/mantle-v2/blob/main/packages/contracts-bedrock/src/L2/GasPriceOracle.sol), [Mantle RPC](https://github.com/mantle-xyz/op-geth/blob/main/internal/ethapi/api.go), [Arbitrum fees](https://developer.arbitrum.io/arbitrum-essentials/how-to-estimate-gas), [Scroll fees](https://docs.scroll.io/en/developers/transaction-fees-on-scroll/), [EraVM lifecycle](https://docs.zksync.io/zksync-protocol/era-vm/transactions/transaction-lifecycle). No Viem runtime dependency is introduced. Chain upgrades/provider policy may change.
