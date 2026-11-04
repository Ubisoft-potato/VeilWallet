# Transaction management

The Transactions sidebar shows locally initiated and previously saved records. Filter pending/history, search hash/recipient/nonce, inspect groups and refresh the selected network. Optional 30-second polling runs only while this page is visible and stops on lock. No complete address-history index or archive upload is used.

## Capabilities

| Network | Verification | Actions |
|---|---|---|
| Supported EVM | Chain ID, hash, sender, nonce, canonical block, execution, confirmations | Nonce queue/reservations, fee editing, same-nonce speed-up or zero-value self-cancel, nonce-gap preview, same-payload rebroadcast, revoke never-broadcast entries, requote failures |
| BTC/LTC transparent single-key | Mainnet genesis, canonical block, six confirmations, confirmed-input conflicts | RBF speed-up preserving payment, cancel using all original inputs, single-level CPFP from local change, same-payload rebroadcast |
| Solana | Mainnet genesis, signature status, finalized state, blockhash validity | Same-payload rebroadcast, expiry verification, explicit rebuild; no simulated same-nonce cancellation |
| TRON, including adapted DEX/bridges | Mainnet identity, solidified execution receipt, expiry | Same-payload rebroadcast, expiry verification, return to protocol for requote; no replacement/cancellation |
| Aptos | chain_id=1, hash, sender, sequence, version, execution fee | Same-payload rebroadcast, sequence/expiry checks, rebuild |
| Supported Cosmos Bank | Fixed chain ID, height/code, timeout_height | Same-payload rebroadcast, expiry checks, rebuild; no borrowed EVM replacement rules |
| XMR | Official local scan, original txid, ten confirmations | Relay identical metadata; new preview after verified failure; no fee replacement/cancellation |

Confirmation thresholds are display policies: usually EVM 12, BSC 15, BTC/LTC 6, XMR 10. Execution-chain confirmation does not establish L2 L1 settlement/dispute completion. Queries depend on configured nodes, not light-client proofs.

## Queue and replacement rules

EVM combines node latest/pending with all unconsumed local signatures. Same-nonce attempts reserve the maximum cost/spend, not their sum; different nonces add. Not-seen signatures retain reservations. A local gap blocks new payments until verified and separately previewed as a zero-value self-transfer. The queue spans at most 64 nonces. Later entries broadcast only when predecessors are in the node; otherwise they stay local, without automatic submission.

Speed-up preserves recipient, amount, calldata, minimum output and protocol deadline. Default price bump is at least 25%; EIP-1559 raises both maxFee and priorityFee. Nodes may require more. Recheck chain, sequence, balance, simulation and extra fees before signing. Cancellation uses the same nonce and a zero-value self-transfer; delegated/contract-code accounts cannot use this flow. Original and cancel compete: **requesting cancellation does not establish cancellation**, and executed transfers cannot be reversed.

BTC/LTC RBF keeps all original inputs and adds none. Speed-up does not reduce payment; fees use change. Include node-provided unconfirmed descendant fees, at most 25 transactions, with conservative size/incremental fee bounds. Incomplete data blocks action. Old transactions without RBF do not assume Full RBF support. CPFP spends verified local change/self-output only, requires confirmed parent inputs, and supports neither multi-level children nor child RBF. Local change reservations block duplicate CPFP. Node package/replacement policy can still reject.

## Persistence and recovery

Before sending, encrypt the approved intent, signed payload/XMR metadata, hash and initial queue record. Before calling broadcast, persist the attempt count and unverified status, then update the activity index. Crash recovery restores missing entries and retains the higher attempt count, never treating possibly sent data as a never-broadcast draft. Nothing automatically rebroadcasts. A single-writer process lock protects one data directory.

Manual rebroadcast rechecks password, account, latest attempt, protocol expiry and state. It sends identical signed bytes/hash only. Expired bytes are blocked. Only entries with no broadcast attempt can be revoked; replayable signatures are removed while intent/history remain. Ordinary nonce queues are revoked from the tail.

Not-seen, timeout and consumed nonce do not mean success/failure/cancellation. Missing known receipts or canonical mismatch trigger reorg checks. A group chooses a winning hash only after matching canonical receipts meet thresholds. Conflicting same-nonce confirmed results are rejected. Bridge verification uses the winning source hash and separately checks destination delivery.

Privacy-pool replacement attempts are also stored with the note. Confirmed cancellation/revert permits re-authenticated release of the matching sending record, never deletion of the note. If a crash separates archive writing from note linkage, original archive/password can restore that exact binding, without substituting a different note.

## Local files and limits

Under the user's **Application Support → VeilWallet** directory:

~~~text
vault.json                  Password-encrypted wallet and random privacy notes
local.sealed                Encrypted activity index, settings and caches
Transactions/<UUID>.sealed  Encrypted intent and signed transaction archive
~~~

Archives use AES-GCM with a local non-syncing Keychain key and UUID-bound AAD, directory 0700/file 0600. No cross-Mac recovery, sync, upload or migration is added. Removing the App normally retains these files; deleting the directory or Keychain can lose data. A mnemonic does not recover random privacy notes.

Records from 0.6 and earlier lack signed archives but can query receipts. A legacy EVM type-0/type-2 ordinary native transfer can be adopted only after reconstructing its signature, recovering sender and matching hash. Old contracts without local typed intent, access-list transactions and old non-EVM entries remain query-only; remote calldata is never adopted blindly.

This is not an address-history scanner. Unknown replacements sent by another wallet do not become local success. Beyond node retention, expiry proves bytes are no longer valid, not that they never executed. Rebuild creates a new hash: verify the original payment/recipient first. Contract/DEX/bridge/privacy actions return to their protocol for requoting. Unsupported send networks have no write actions.

No funded-transfer acceptance, independent audit or production security claim. Local Anvil/mocks do not establish mainnet mempool policy acceptance.

## Reproduction and sources

~~~bash
VEIL_ANVIL="$(command -v anvil)" VEIL_VERIFY_NODE=1 ./Scripts/swift.sh test
~~~

Anvil is optional; when absent its integration test skips. Tested version 1.5.1 uses literal loopback, a random port, no-mining and no fork/upstream, with public disposable keys and temporary balances. Neither Anvil nor its loopback test transport ships in the App. A temporary test directory is deleted after the run.

Sources: [Ethereum RPC](https://ethereum.org/en/developers/docs/apis/json-rpc/), [Geth txpool](https://geth.ethereum.org/docs/interacting-with-geth/rpc/ns-txpool), [replacement settings](https://geth.ethereum.org/docs/fundamentals/command-line-options), [BIP125](https://github.com/bitcoin/bips/blob/master/bip-0125.mediawiki), [Esplora](https://github.com/Blockstream/esplora/blob/master/API.md), [Monero lookup](https://github.com/monero-project/monero/blob/v0.18.5.0/src/wallet/wallet_rpc_server.cpp), [Anvil](https://www.getfoundry.sh/anvil/index.html).

TorSmoke --transactions only reads ETH/BSC public historical receipts/nonces through Tor, without a user vault, address/signature logging or broadcasting.
