# Transfers and typed contract calls

[Transaction management](TRANSACTIONS.md) describes queues, archives, same-payload rebroadcast, EVM replacement/cancellation and BTC/LTC RBF/CPFP. [Bridge/privacy adapters](BRIDGES_PRIVACY.md) are separate flows. Every write needs local approval; no automatic resend or cross-Mac sync.

Implemented encoding, preview, password checks, signing and Tor broadcast/receipts do not constitute funded end-to-end acceptance.

| Protocol | Checks | Limits |
|---|---|---|
| BTC/LTC | Confirmed selected-address UTXOs, previous raw transaction proofs, change/fee budget, post-sign script verification | At most 20 largest-first inputs; no other-address scan; minimum 1,000 sat/litoshi payment; dust change becomes explicitly shown fee |
| SOL | Mainnet genesis, confirmed blockhash, getFeeForMessage, simulation, Ed25519 verification and returned signature match | System Program SOL only; no SPL/priority fee/durable nonce |
| TRX | Genesis, TAPOS, 180-second expiry, bandwidth/new-account budget and single-key owner; adapted TriggerSmartContract local encoding/Energy/solidified receipts | TRX plus supported DEX/bridge/approvals; no generic TRC20 form/multisig/changed permissions; bandwidth is additional to fee_limit |
| APT | chain_id=1, authentication key, sequence, gas price, zero-signature BCS simulation and pre-sign recheck | Ordinary Ed25519/APT; rotated authentication keys rejected |
| Cosmos | Fixed mainnet ID, latest block time, signer key, account_number/sequence, two simulations, timeout_height/memo | 21 Bank MsgSend networks; matching REST endpoint; user must supply gas price when missing; no IBC/feegrant/multisig/staking/contracts/chain-specific tax |
| XMR | Official local scan, actual fee, signed preview and separate relay | See [Monero](MONERO.md); full initial live restore/funded acceptance outstanding |

Save hash/encrypted record before broadcasting. Timeout remains unverified. Changed network, lock or a preview older than 90 seconds blocks sending. Independent vectors check UTXO messages/hashes and Schnorr signatures, Solana/Aptos/Cosmos/Injective bytes.

TON, Sui, NEAR, Stacks, Cardano, Polkadot, Starknet, EOS/WAX sending is unavailable, as are LTC MWEB/arbitrary scripts and ordinary non-EVM token forms. Existing import/balance features remain. Stargaze/Comdex are marked stopped upstream; Terra Classic tax is unadapted; these three Cosmos send flows are disabled.

## Typed EVM contracts

The form accepts canonical function signatures and a JSON string-array of arguments: address, bool, uint8…uint256, int8…int256, bytes1…bytes32, bytes, string, tuple and bounded dynamic arrays, including tuple[]/bytes[]/nested arrays. Compound values are nested JSON string arrays. Generic input rejects fixed arrays, aliases, raw calldata and deployment; fixed arrays used by internal verified adapters are separate. Integers use decimal base units without guessing token decimals. Depth/count/bytes are bounded.

Read-only calls verify chain ID and target code before eth_call. Writes simulate, estimate gas/L2 fees/nonce/balance and show complete target, function, arguments, native value and budget. Re-simulate before every signature; explicit false approval results block signing. Simulation neither audits a contract nor guarantees future state.

## DEX scope

See [DEX.md](DEX.md) for all protocol/version/pool/approval limits. The original nine Router02 networks are Ethereum, Sepolia, Unichain, Arbitrum, Avalanche C, BNB Chain, Base, Optimism and Polygon, from [Uniswap deployments](https://github.com/Uniswap/docs/blob/main/content/protocols/v2/deployments.mdx).

Exact-input quotes show decimals, path, expected/minimum output and 1–1000 bps slippage (default 50). Quotes last 90 seconds; supported on-chain deadlines are five minutes. Recipient is the current account. EVM has no remote aggregator; SUN uses an official candidate-route service with local validation.

Insufficient allowance requires separate exact approval or nonzero reset, confirmed receipt and requote. No automatic signatures or infinite approvals. The generic contract form can explicitly encode a larger approve; maximum values receive a risk notice.

No generic fee-on-transfer/rebase support, independent market-price validation or MEV protection. Node/pool manipulation and protocol risk remain.

Sources: [Esplora](https://github.com/Blockstream/esplora/blob/master/API.md), [Solana fees](https://solana.com/docs/rpc/http/getfeeformessage), [Aptos simulation](https://aptos.dev/rest-api/operations/simulate_transaction), [Cosmos transactions](https://github.com/cosmos/cosmos-sdk/blob/main/docs/docs/user/run-node/03-txs.md), [Cosmos provenance](COSMOS_SOURCES.json), [Injective signer](https://github.com/InjectiveLabs/sdk-go/blob/master/chain/crypto/ethsecp256k1/ethsecp256k1.go), [Router02](https://docs.uniswap.org/contracts/v2/reference/smart-contracts/router-02). TRON genesis was checked via its official getblockbynum endpoint; the pinned public hash remains in protocol source.
