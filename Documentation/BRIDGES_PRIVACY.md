# Bridges and non-custodial privacy pools

Native forms use fixed deployments, local ABI encoding, on-chain quotes/simulation, separate exact approvals and password checks for every signature. This is an unaudited development build without funded deposit/withdrawal acceptance.

## Bridge routes

| Route | Protocol/asset | Scope |
|---|---|---|
| ETH ↔ TRON | Allbridge OFT / native USDT | Fixed wrapper; verify token/sharedDecimals/destination peer; no retired LP route |
| ETH ↔ BSC | Stargate V2 Taxi / USDT | quoteOFT/quoteSend/sendToken; explicit 6/18-decimal rounding to shared 6 decimals |
| TRON ↔ BSC | Two separate legs through ETH | Confirm delivery, then quote/approve/sign each next leg; no automatic chaining |

Open Bridge from Assets and enter recipient/amount. Insufficient nonzero allowance needs a separately confirmed zero reset, then exact approval. Requote after confirmation; watch-only accounts can quote only.

Quotes expire in 90 seconds. Recheck chain/code/route/rates/balance/allowance/message fee and simulate before signing. Chain/code validation is reused only within a single query, never across quotes/signatures. Message fees use native currency only; no compose, destination gas, bus or LZ-token mode. Stargate encodes an absolute minimum; Allbridge encodes proportional slippage, whose absolute result can change with administrator fees. Allbridge has no on-chain deadline.

Transactions are public. USDT freeze/pause, upgrades/administrators, message validation/execution and liquidity remain risks. Non-custodial does not mean free of protocol control; recipients need destination gas.

Save hash and approved route before broadcast. After the source receipt, extract OFTSent GUID. A supplied destination hash must match OFTReceived contract, GUID, source EID, recipient and minimum amount via destination RPC. ETH needs 12/BSC 15 canonical confirmations; TRON needs solidification. Source confirmation is not delivery. No hash upload to a bridge indexer or automatic rebroadcast.

## Privacy pools and notes

Eight fixed Tornado Cash Classic deployments: native ETH/BNB pools of 0.1, 1, 10 and 100 each. No Nova, ERC20 pools, RAILGUN, relayer withdrawals or TRON mixer adapter. No verified supported TRON native mixing protocol is configured; no custodial mixing address is supplied.

1. Re-authenticate to create a random note or import a standard tornado-eth/tornado-bnb note.
2. Save immediately in the primary password-encrypted AES-GCM vault; removing a wallet does not remove notes. Re-authenticate to display/back up the complete note, then acknowledge backup before deposit. **A mnemonic cannot restore a random note.**
3. Before deposit, generate a proof with a fixed public zero-value test note and check the on-chain verifier. Never use the private note for this self-test, which would expose a commitment/nullifierHash relationship.
4. Check unused commitment, fixed denomination and 20-level circuit parameters. Notes/nullifiers/secrets are never RPC fields or process arguments.
5. Download the entire pool's Deposit history, not a commitment-specific query. Verify source, contiguous indices and block anchors. Encrypt the public-tree cache with the separate local Keychain key. Limit each run to 64 batches; cancel/resume is supported. Reorgs require clearing/rescanning the public tree while retaining notes. Initial sync needs full-history RPC logs and may be rate-limited.
6. After re-authentication, build Merkle path/Groth16 proof offline. Swift checks public inputs, known root, unspent status and verifier acceptance before simulation/withdrawal preview. Expired roots require resync/reproof.
7. Direct withdrawal only: the selected separate signing account receives funds and pays gas, with no relay fee/refund. The recorded depositor cannot be the recipient. Gas funding, amount, timing and behavior can still link activity; anonymity is not guaranteed.

Notes control funds: disclosure can permit spending; loss can permanently lose the deposit. Clipboard clearing occurs after 30 seconds only if contents are unchanged; clipboard history/other software are outside that guarantee. Swift/Node memory copies cannot be reliably zeroized.

Save sending hashes before broadcast. Unknown responses block duplicate operations. Only a canonical reverted/cancelled result at the confirmation threshold, followed by re-authentication and verification, releases the corresponding sending record. Missing/unconfirmed receipts do not. Keep the note and verify original hashes.

## Offline proof boundary

Swift owns UI, business logic and signing. A bundled separate Node 24.22.2 process runs pinned upstream Tornado CLI dependencies. Users need not install Node. No WebView, external prover, online code download or network JS SDK is used.

macOS sandbox-exec denies all network, mach-lookup, extra processes and user-file content access/writes. It allows only runtime/system read-only resources, randomness and ancestor metadata; read-only root metadata does not grant child-directory contents. JSON uses inherited stdin/stdout, stderr is discarded, lock/cancel terminates the process. Native addons are disabled, at most two workers, 600-second timeout and bounded I/O.

Verify official signed Node SHASUMS256/fixed SHA256 and circuit/proving-key Git blobs/SHA256. Startup validates the complete resource inventory and rejects extras/symlinks. Sign the Node bundle first, then seal its final executable/resource hashes in the outer signed App's PrivacyRuntime manifest, avoiding circular hashes. Preserve GPL sources/licenses/versions/build scripts. This uses the upstream published trusted setup, not rewritten cryptography.

~~~bash
./Scripts/fetch-privacy-runtime.sh
./Scripts/swift.sh test
./Scripts/check-privacy.sh
./Scripts/swift.sh run TorSmoke "$PWD/Vendor/Tor" --bridge-probe --privacy-probe \
  --proof-runtime "$PWD/Vendor/PrivacyRuntime" \
  --bridge-privacy-report "$PWD/.build/bridge-privacy-live.json"
./Scripts/build-app.sh
~~~

Sources: [Allbridge OFT](https://github.com/allbridge-io/allbridge-core-evm-contracts/blob/main/contracts/OftBridge.sol), [route metadata](https://api.core.allbridge.io/token-info?filter=all), [Stargate](https://github.com/stargate-protocol/stargate-v2/tree/main/packages/stg-evm-v2/deployments), [pinned Tornado CLI](https://github.com/tornadocash/tornado-cli/tree/378ddf8b8b92a4924037d7b64a94dbfd5a7dd6e8), [circuits](https://github.com/tornadocash/tornado-core/tree/master/circuits).
