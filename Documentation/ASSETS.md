# Assets, prices and preferences

Wallet preferences are encrypted in local.sealed. Language is the exception: a non-sensitive app-local UserDefaults choice available before unlock and applied immediately. English is the default.

## Locking and updates

Idle lock defaults to 30 minutes, with 1/5/10/15/30/60/120-minute choices. Switching apps does not lock immediately. Sleep, manual lock and exit stop Tor/runtimes. ContinuousClock prevents wall-clock changes from extending a session. Background queries do not reset the timer; backup/note views hide secrets when focus leaves.

Automatic asset updates default to five minutes; choose 1/5/10/15 minutes or disable them. Requests require unlock and Tor bootstrap. Default scope: 16 popular EVM networks, compatible configured native networks and the selected network. Current-network/all-configured-network modes are available. Only the selected wallet is queried, at most three tasks concurrently.

Known positive balances show asset, network and address. Search asset/contract/address, filter network, include all assets, copy or open supported receive/send flows. Errors retain last known values and original times. Unknown, failed and zero balances differ. Changing wallet/network, signing or locking cancels old scans. Cache is not proof of current state.

Discovery covers native coins, 59 presets and manually added tokens, not arbitrary token indexing, NFTs or full history. XMR requires a manual scan; automatic updates never start full recovery. MWEB never submits scan keys. EOS/Starknet require bindings; networks without endpoints are skipped.

## USD prices

[DefiLlama](https://api-docs.defillama.com/llms-free.txt) supplies quotes from coins.llama.fi through Tor/HTTPS. Refresh every five minutes or manually; disable independently. Balance/price timestamps are separate.

The catalog contains 119 network identities, 115 native mappings, 82 distinct native price IDs and 59 token IDs: 141 fixed queries. Built-in requests do not vary by holdings or wallet. Manually added contracts extend the network query; the service sees identifiers/timing, not wallet addresses, IDs or balances. Serial batches contain at most 25 IDs.

Identity uses network namespace/full contract, never ticker matching. TRON case is preserved. Gas mappings avoid pricing ETH with OP/ARB governance assets. Response decimals must match. Unmapped/testnet/missing quotes display an em dash.

Decimal JSON becomes 18-decimal USD integers; BigUInt handles balances/multiplication/sums, without Double. Holdings display cents or <$0.01; unit prices retain more precision. Aggregate before cent rounding. Stablecoins use market prices, not assumed dollar pegs.

Totals follow wallet and all/current-network scope, independent of search/balance/error filters. Exclude testnets, retain unknown balances, count omitted unpriced holdings and deduplicate equivalent LTC/same-chain addresses. Known scanned XMR total balance can contribute.

Require positive bounded prices, confidence ≥0.9 and matching decimals. Reject source times over 24 hours old or 120 seconds ahead. Accepted/cache quotes over 15 minutes old are labeled historical. Failed refreshes retain original values/times. Historical data may contribute to clearly labeled reference totals; valuation is not an executable DEX quote and never changes signing, balance or fee checks.

The [historical report](market-live-report.json) recorded 137 usable quotes of 141, 129 within 15 minutes. Comdex/Fantom/Kujira and MegaETH USDT0 lacked accepted quotes then. Morph's identity discrepancy, unverified OKT mapping and unsupported Arc/Tempo native assets remain unmapped. Coverage changes.

## Presets and icons

59 presets across 32 networks pin chain ID, contract, decimals, identity, issuance/bridge/legacy labels and icon. Verify chain, code and decimals before displaying amounts. See [sources](TOKEN_SOURCES.json).

Presets include Ethereum USDT/USDC/WETH/DAI/WBTC, BSC Binance-Peg USDT/USDC/WBNB, verified native Circle USDC and USDT0 deployments. No guessed Base USDT. USDC.e and USDC stay distinct.

TRON includes USDT, current USDD, SUN, JST, WTRX and labeled USDDOLD/USDCOLD. Current USDD: TXDk8mbtRbXeYuMNS83CfKPaYYT8XWv9Hz. Legacy assets are not current issuance. Check [USDD deployments](https://docs.usdd.io/developers/deployment-addresses.md) and [Circle's discontinuation](https://www.circle.com/blog/circle-is-discontinuing-support-for-usdc-on-the-tron-blockchain) before moving them.

Presets do not expand signing scope: generic TRC20/SPL/non-EVM transfer forms remain unavailable. TRC20 DEX/bridge approvals are separate adapters.

Icons are PNGs fetched at development time from pinned commits, bundled locally and signed. Runtime downloads no artwork/fonts/lists. [ASSET_ARTWORK.json](ASSET_ARTWORK.json) records sources/hashes. Unknown assets use initials. Logos do not establish identity/endorsement.

The network picker searches name/symbol/chain ID and filters all/popular/with-assets/testnet. Ethereum mainnet is default. Research used [OKX asset management](https://www.okx.com/en-sg/help/how-do-i-manage-my-assets-in-my-okx-wallet-app) without claiming equivalence.
