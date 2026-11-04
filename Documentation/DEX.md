# DEX swaps

Native Swift forms encode bounded, typed ABI locally, sign locally and quote/simulate/broadcast through bundled Tor. There is no embedded webpage. Protocol implementation, deployment verification, quote verification and full simulation are distinct from funded on-chain acceptance. No real funds were sent during this development validation.

## EVM matrix

82 deployments: nine original Uniswap V2 entries and 73 additional network/protocol versions. Exact deployments and official sources are in [dex-venues.json](../Sources/WalletCore/Resources/dex-venues.json). A catalog does not imply every protocol exists on every network.

| Protocol | Implemented path | Limits |
|---|---|---|
| Uniswap V2 | Router02 exact input on nine networks | Direct pair or two hops via wrapped native asset |
| Uniswap V3 | SwapRouter and SwapRouter02 | Common fee tiers, direct/two hops; Router02 deadline in outer multicall |
| Uniswap V4 | Ethereum, Base, Arbitrum, BNB Chain, Sepolia; Universal Router 2.1.2 | Single standard pool without hooks; known fee/tick spacing; native currency uses zero address |
| PancakeSwap | Eight V2/V3 deployments | V3 tiers 100/500/2500/10000; no Infinity |
| SushiSwap | V2 | No V3/RouteProcessor |
| QuickSwap | Polygon/Base V2; Polygon Algebra V1 | Fee-less packed Algebra path; no other Algebra versions |
| Aerodrome/Velodrome | V2 stable/volatile and Slipstream | Version-specific V1/V2/V3 factories/routers; bounded tick-spacing search |
| LFJ/Trader Joe | Avalanche V1; Liquidity Book V2.2 | LB single pool, discovered bin step; partial input fill rejected |
| Curve | Ethereum 3pool and ETH/stETH fixed pools | Direct pool coins only; no underlying/LP; these pools have no on-chain deadline |
| Balancer V3 | Fixed Router/Vault on six networks | User supplies/checks pool and hooks; registration/initialization/coins verified, hooks not audited; single-pool exact input, Permit2; no Boosted/Batch/V2 |

EVM quotes read contracts through RPC, without a remote aggregator. Fee parameter zero compares a finite set of known tiers; it does not search every pool, tick spacing or intermediary. Two-hop routes use the same fee/curve parameter. A 90-second local signing limit cannot add a missing protocol deadline to Curve.

## TRON matrix

- SunSwap V2 verifies Router factory/WETH and reads getAmountsOut for direct TRX/TRC20 paths. ABI names retain ETH/WETH despite using TRX.
- SUN smart routing queries the official open.sun.io routerUniversal endpoint through Tor with pair, amount and slippage, without wallet identity. The service still learns trading intent.
- Accepted paths: adapted V1/V2/V3/V4, WTRX wrapping, eight fixed SunCurve flags and USDT 2.0 PSM, at most four hops. V4 requires standard concentrated liquidity without hooks. Unknown protocols/hooks, referral fees and inconsistent amounts/outputs are rejected.
- Candidate JSON is validated and Universal Router commands are built locally. Remote arbitrary calldata is never signed. Every step forbids allow-revert; final sweep fixes recipient and minimum output, and remaining route assets are refunded.
- Router/Permit2/PoolManager versions are pinned to matching official sun-kit/universal-router-sdk releases. Old documentation router addresses/PSM opcodes cannot be mixed with current SDK values.
- TRX/USDT/WTRX/USDD/SUN use fixed local identities and checked on-chain decimals; other TRC20 may be added. Generic TRC20 transfer forms remain unavailable.

TriggerSmartContract protobuf is built locally, not supplied by the node: TAPOS, 180-second expiry and fee_limit. Recheck mainnet genesis, ordinary single-signature owner permissions, Energy simulation, Energy/bandwidth prices and balance. fee_limit includes 50% Energy buffer; worst-case bandwidth is additional and is not part of fee_limit. Available resources may reduce actual cost.

Current preset TRON RPC is https://api.tronstack.io; the prior TronGrid default returned 403 through the tested Tor exit. Ethereum uses https://eth.drpc.org after the old PublicNode disconnected during Balancer quoting. dRPC documents its [Tor endpoint](https://drpc.org/docs/tor). Only exact old defaults migrate; custom endpoints remain. There is no automatic provider rotation or direct fallback.

## Approval, confirmation and signing

Default slippage is 50 bps; range 1–1000. Show expected/minimum output, complete route/router and current recipient. Quotes last 90 seconds; supported protocol deadlines are at most five minutes. If a sufficient Permit2 allowance has at least 90 seconds remaining, new quote deadlines stay within that existing expiry. Short/expired allowances require approval. TRON also has its outer three-minute expiry.

ERC20/TRC20 approval requests only the current input amount. An existing insufficient nonzero allowance requires a separately confirmed reset to zero. Permit2 requires an additional exact-amount, current-router, short-lived approval. Every step has its own preview/password check. Requote after confirmation. There is no automatic next signature, password reuse or unlimited approval; existing larger allowances are not automatically revoked.

### Continue after approval

1. The action distinguishes reset, token approval, short router approval and swap simulation/preview. Approval alone never means a swap completed.
2. The approval screen shows the saved hash and actual queue/broadcast status, with a return/verify/continue action. Closing preserves form inputs and flow.
3. Verify the canonical approval group before continuing. EVM requires 15 confirmations on BSC or 12 elsewhere; this is an execution-chain policy, not L1 settlement. Only the original approval or a matching successful speed-up can continue. Cancellation/failure stops; unknown/reorged/consumed-nonce/queued/not-seen states wait.
4. Requote, check actual allowance and open the next approval/swap preview. Recheck output/fees and enter the password again.
5. Reopening the same account/token/spender restores unfinished approval context from encrypted archives, including resets and Permit2. Missing broadcast responses recover the exact archived hash; they do not permit duplicate signing.

Both TRON modes follow the same staged flow, requiring solidified execution success and matching archived owner, target contract, calldata and call_value. A transaction body or accepted broadcast alone is insufficient. Unknown/failed/expired/queued states cannot continue. New SUN quotes reuse adequate Permit2 expiry instead of moving it forward indefinitely. Account/network/profile changes cancel stale requests and prevent old responses updating a new form.

Confirmed sufficient allowance can be reused for the same account/token/spender. Changing protocol or spender requires another query.

## Validation and limits

[Catalog regression](DEX_REGRESSION_0.9.1.json) covers all 82 EVM deployments, deployment/quote constraints and 6/18-decimal approval sequences through reset, exact approval, required Permit2 approval, requote and final swap preview. Every configured EVM network has confirmation-threshold checks. TRON covers both modes, 13 SUN route variants, recipient/minimum-output constraints, solidified receipt binding and unknown-state blocking.

These are mocks/public vectors; they are not a guarantee of liquidity or funded execution for every token/pool. Separate [live results](dex-0.9.1-live-report.json) distinguish deployment, quote and simulation checks.

Before signing, re-simulate, verify network/balance/allowance/expiry/deployments and compare rebuilt calldata against recipient/path/amount. Save hash before broadcast; timeout means unverified, with no automatic retry. Cancelable requests run blocking libcurl off Swift's cooperative pool. V3/native and V4 unsettled native inputs are explicitly refunded.

Quotes/simulations depend on nodes and do not remove MEV, manipulation or contract risk. No generic fee-on-transfer/rebase support, arbitrary V4 hooks, 1inch/0x aggregation, LP management, limit orders, DApp/WalletConnect or MEV protection is implemented. Bridges use a separate adapter.

## Primary implementation sources

- [Uniswap](https://docs.uniswap.org/contracts/overview), [Universal Router](https://github.com/Uniswap/universal-router), [V4 Periphery](https://github.com/Uniswap/v4-periphery), [Permit2](https://developers.uniswap.org/docs/protocols/permit2/concepts/allowance-transfer)
- [PancakeSwap](https://developer.pancakeswap.finance/contracts/v3/addresses), [Sushi](https://github.com/sushi-labs/sushi), [QuickSwap](https://docs.quickswap.exchange/technical-reference/smart-contracts)
- [Aerodrome](https://github.com/aerodrome-finance/slipstream), [Velodrome](https://github.com/velodrome-finance/slipstream), [LFJ](https://github.com/lfj-gg/joe-v2)
- [Balancer deployments](https://github.com/balancer/balancer-deployments), [Curve](https://docs.curve.finance/)
- [SUN SDK](https://github.com/sun-protocol/sun-kit), [Universal Router SDK](https://github.com/sun-protocol/universal-router-sdk), [routing service](https://docs.sun.io/protocols/universal-router/reference/calculation-service/)
- [TRON simulation](https://developers.tron.network/reference/triggerconstantcontract), [solidified receipts](https://developers.tron.network/reference/gettransactioninfobyid-1)
