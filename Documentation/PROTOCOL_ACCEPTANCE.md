# Protocol execution acceptance

Developer validation on 2026-11-11. These results describe specific executions;
they are not a security audit or a guarantee of future liquidity, RPC access,
message delivery or production-funds safety.

The ordinary regression run including asset grouping passed 152 Swift tests in 31 suites, with
public execution tests opt-in. The source-audit tooling's 14 tests also passed.
Privacy source checks, 1,667 matching localization keys and repository-relative
documentation checks passed. Bundled Tor smoke testing verified its exit route,
the default EVM chain identity and request blocking after Tor stopped.

## Verified execution scope

| Area | Environment | Evidence and limits |
|---|---|---|
| TRON SunSwap V2 | Public Nile testnet, bundled Tor | TRX → test USDT, separate approval, test USDT → TRX; three solidified successful receipts and token balance changes. Uses the official Nile router, factory, wrapped TRX and explicit Nile genesis identity. |
| ETH/BSC DEX | Isolated Anvil forks of real deployments | All 15 configured ETH/BSC venues executed swaps with successful receipts and input/output balance checks, including nonzero allowance reset, exact approvals and Permit2 where required. |
| Ethereum Sepolia DEX | Public testnet, bundled Tor | Uniswap V2, V3 and V4 native-to-test-USDC and return swaps; ten transactions canonically confirmed with exact approvals, Permit2 where required, and balance checks. A TLS failure and a read timeout were recovered by original hash without duplicate sends. |
| Classic native pools | Standalone local chains, genuine upstream contracts and verifiers | All eight denominations executed deposit, complete fixture-history synchronization, offline proof, withdrawal to a separate gas-paying account and duplicate-withdrawal rejection. Pool state is freshly initialized; this does not test existing mainnet history or anonymity. |
| Stargate ETH → BSC / BSC → ETH | Isolated forks | Real USDT acquisition, exact bridge approval, source send, source balance debit and OFTSent GUID extraction. Destination remains explicitly unverified. |
| Allbridge ETH → TRON | ETH isolated fork plus read-only TRON metadata over Tor | Real source USDT acquisition, approval, send, balance debit and OFTSent GUID extraction. TRON source execution and destination delivery remain unverified. |
| Stargate Sepolia → BSC Testnet | Public testnets, bundled Tor | Official EIDs, peers, asset mapping and quote checked; test-token mint, exact approval and source send canonically confirmed. Destination was not delivered within the observation window: source had 73 confirmations against the required 2, but the required DVN had not submitted its proof. This route has not passed end-to-end acceptance. |

The ETH/BSC venue set is Curve 3pool and ETH/stETH, Balancer V3 on ETH,
and Uniswap V2/V3/V4, PancakeSwap V2/V3 and Sushi V2 on both ETH and BSC.
Other catalog networks are covered by encoding/validation regressions and
read-only probes, not by this execution matrix.

The original Balancer EIGEN fixture returned `PoolPaused`; the execution fixture
uses the on-chain-unpaused PRL/WETH pool. Paused pools now fail before quote/signing.
See the [official error index](https://github.com/balancer/balancer-v3-monorepo/blob/main/docs/error-index.md).
stETH balance checks allow at most two wei of integer share-conversion rounding;
ordinary ERC20 debits remain exact.

## Isolation and local records

All fixture keys, passwords and notes are newly generated and disposable. They
never come from the installed wallet, its data directory or Keychain. Keys and
notes remain in temporary password-encrypted vaults or the explicitly ignored
test-only credentials file. No private key, note, password or signed payload is
included in source, reports or console output.

Development fixtures, dependencies, public receipts and reports live beneath
the Git-ignored `.build/ProtocolAcceptance/` directory. The source runners and
tests are versioned; generated data is not. Treat every wallet generated for
this directory as test-only and never fund it on mainnet.

The fork gateway forwards only explicitly allowed read RPC methods through the
bundled Tor SOCKS proxy with remote DNS. Public broadcast/debug/admin methods
are rejected. Signed EVM transactions go only to literal-loopback Anvil nodes.
Loopback transport exists only in the test target; production HTTPS/Tor gates
are unchanged. Nile broadcasts use the normal Tor transport and explicit
testnet genesis validation.

Bridge source success is not destination success. Cross-fork messages are not
silently delivered by a mock relayer. Public Sepolia/BSC testnet funding and
verified protocol testnet routes remain required for public end-to-end bridge
acceptance. No mainnet funds were used.

## Reproduce local DEX and bridge-source execution

Install Anvil from the [official Foundry distribution](https://getfoundry.sh/).
Prepare the regular pinned project runtimes first. From the repository root:

~~~bash
mkdir -p .build/ProtocolAcceptance
npm install --prefix .build/ProtocolAcceptance --no-save --no-package-lock \
  --ignore-scripts --no-audit --no-fund \
  ethers@6.15.0 tronweb@6.1.0 socks-proxy-agent@8.0.5
node Tools/ProtocolAcceptance/local-forks.cjs
~~~

Keep that process running. In another terminal, use the exact
`VEIL_PROTOCOL_PORTS` path it prints:

~~~bash
VEIL_PROTOCOL_PORTS=.build/ProtocolAcceptance/fork-run-REPLACE/ports.json \
  ./Scripts/swift.sh test --filter ProtocolExecutionTests
VEIL_PROTOCOL_PORTS=.build/ProtocolAcceptance/fork-run-REPLACE/ports.json \
  VEIL_BRIDGE_EXECUTION=1 ./Scripts/swift.sh test --filter BridgeExecutionTests
~~~

Run Swift build/test commands sequentially. RPC availability, current pool state
and liquidity can change. The script rejects public writes even when a test
fails. Ctrl-C stops its own Anvil and Tor children; no system proxy/DNS changes
are made. Successful cases write public-hash-only JSON reports beside ports.json.

## Reproduce genuine privacy-pool execution

`privacy-chains.cjs` starts two standalone chains without any public upstream.
`prepare-privacy.cjs` checks the upstream ETHTornado artifact SHA256, uses the
pinned circomlib generator (`mimcsponge`, 220 rounds), deploys genuine contracts,
and installs fresh local pool state at the catalog addresses. It does not modify
public chain state or change the app's pinned deployment catalog.

The artifact comes from the [pinned Tornado CLI revision](https://github.com/tornadocash/tornado-cli/blob/378ddf8b8b92a4924037d7b64a94dbfd5a7dd6e8/build/contracts/ETHTornado.json).
Verifier fixture files contain each chain's public on-chain verifier address,
runtime bytecode and its SHA256, obtained through the read-only fork with
`export-verifiers.cjs`, which checks all four catalog pools on each chain. Use each
chain's own verifier; do not assume their deployed bytecode is identical.

~~~bash
mkdir -p .build/ProtocolAcceptance/contracts
curl -fL --output .build/ProtocolAcceptance/contracts/ETHTornado.json \
  https://raw.githubusercontent.com/tornadocash/tornado-cli/378ddf8b8b92a4924037d7b64a94dbfd5a7dd6e8/build/contracts/ETHTornado.json
node Tools/ProtocolAcceptance/privacy-chains.cjs
~~~

In a second terminal, export public verifiers from the running fork pair, then
initialize the separate standalone privacy chains:

~~~bash
VEIL_PROTOCOL_PORTS=.build/ProtocolAcceptance/fork-run-REPLACE/ports.json \
  node Tools/ProtocolAcceptance/export-verifiers.cjs
VEIL_PROTOCOL_PORTS=.build/ProtocolAcceptance/privacy-run-REPLACE/ports.json \
  VEIL_PRIVACY_CHAINS=1 \
  VEIL_PRIVACY_VERIFIER_CODE_FILE=.build/ProtocolAcceptance/contracts/verifier-code.json \
  node Tools/ProtocolAcceptance/prepare-privacy.cjs
VEIL_PROTOCOL_PORTS=.build/ProtocolAcceptance/privacy-run-REPLACE/ports.json \
  VEIL_PRIVACY_CHAINS=56 \
  VEIL_PRIVACY_VERIFIER_CODE_FILE=.build/ProtocolAcceptance/contracts/verifier-code-56.json \
  node Tools/ProtocolAcceptance/prepare-privacy.cjs
VEIL_PROTOCOL_PORTS=.build/ProtocolAcceptance/privacy-run-REPLACE/ports.json \
  VEIL_PRIVACY_EXECUTION=1 ./Scripts/swift.sh test --filter PrivacyExecutionTests
~~~

Fixture history starts at the saved initialization anchor. No historical
mainnet commitments are substituted for this fresh local tree. Tests execute
the bundled sandboxed prover, real on-chain verifier, vault authorization,
signing, archive-before-broadcast, receipt checks and balance assertions.

## Public Nile test

`create-test-wallets.cjs` creates independent test-only credentials in ignored
storage and refuses replacement. Fund only the testnet addresses in its
funding.json. `NileExecutionTests` requires the separate opt-in below; ordinary
regression tests never broadcast public transactions:

~~~bash
node Tools/ProtocolAcceptance/create-test-wallets.cjs
VEIL_NILE_EXECUTION=1 ./Scripts/swift.sh test --filter NileExecutionTests
~~~

SUN smart routing, TRON bridge-source execution, public bridge delivery and full existing-pool history acceptance remain outside
these successful execution results. Nile V2 success is not a SUN smart-router test.

## Opt-in public Sepolia and Stargate tests

The public Sepolia harness verifies the supplied funding hash, exact receiving
account, successful receipt, canonical block and at least 12 confirmations before
using the separate test key. Read-only quotes and actual execution are separate:

~~~bash
VEIL_SEPOLIA_VERIFY=1 VEIL_SEPOLIA_FUNDING_HASH=REPLACE_PUBLIC_TRANSACTION_HASH \
  ./Scripts/swift.sh test --filter SepoliaExecutionTests
VEIL_SEPOLIA_VERIFY=1 VEIL_SEPOLIA_EXECUTE=1 \
  VEIL_SEPOLIA_FUNDING_HASH=REPLACE_PUBLIC_TRANSACTION_HASH \
  ./Scripts/swift.sh test --filter SepoliaExecutionTests
~~~

Swaps use 0.0001 test ETH per initial purchase, exact token/Permit2 grants and
half of the received test USDC for the return leg. Maximum outlay is capped at
0.008 test ETH. Every successful final report requires canonical confirmations
and balance checks. A saved journal is rechecked by hash, sender, target and
canonical receipt before resuming. Completed steps are not sent again; prior
V2 completion also checks token transfer logs and historical native balances.
If the RPC rejects historical state, the harness instead checks the exact
pinned-router recipient/path and canonical wrapped-native withdrawal event;
the final report states which evidence was available.
An unknown or failed saved receipt blocks resumption.
Optional developer timings record only RPC method, public four-byte selector,
completion state and time in ignored local storage, never request/response bodies,
addresses, signatures or credentials. They are not part of the shipped app.

The separate Stargate harness first verifies both testnet chain IDs, on-chain
Endpoint EIDs, bidirectional TokenMessaging peers and quote. Test USDT uses the
official pinned protocol deployment, not mainnet USDT. Execution is opt-in and
capped at 0.008 test ETH:

~~~bash
VEIL_STARGATE_TESTNET=1 \
  ./Scripts/swift.sh test --filter BridgeTestnetExecutionTests
VEIL_STARGATE_TESTNET=1 VEIL_STARGATE_TESTNET_EXECUTE=1 \
  ./Scripts/swift.sh test --filter BridgeTestnetExecutionTests
~~~

The source leg sends 0.1 test USDT from Sepolia to BSC Testnet. Destination
verification discovers the OFTReceived event by source GUID, validates the
canonical destination receipt through the normal BridgeClient and checks the
receiving balance increase. A saved pending source is monitored by its original
hash without a second send. Receiving does not require test BNB; BSC-initiated
swaps or reverse transfers require separate test BNB for gas.

Public testnet transaction hashes and execution journals remain beneath ignored
`.build/ProtocolAcceptance/`; never publish test credentials or signed archives.
