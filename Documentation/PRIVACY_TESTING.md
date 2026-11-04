# Privacy validation

## Automated and read-only checks

~~~bash
./Scripts/check-privacy.sh
python3 Scripts/check-monero-sandbox.py
./Scripts/swift.sh test
./Scripts/swift.sh run TorSmoke "$PWD/Vendor/Tor"
./Scripts/swift.sh run TorSmoke "$PWD/Vendor/Tor" --networks
./Scripts/swift.sh run TorSmoke "$PWD/Vendor/Tor" --litecoin
./Scripts/swift.sh run TorSmoke "$PWD/Vendor/Tor" --evm --evm-report "$PWD/.build/evm-report.json"
./Scripts/swift.sh run TorSmoke "$PWD/build/Veil Wallet.app/Contents/Helpers/TorRuntime.bundle" --contracts
~~~

Restricted environments may need explicit permission for loopback listeners/compiler plugins and SwiftPM's --disable-sandbox. SwiftPM operations remain sequential.

Default smoke connects to Tor Project's check API and Sepolia chain ID, then verifies blocked requests after Tor stops. No vault, signing or broadcast; exit IP is deliberately not logged.

--networks derives public BIP39 fixtures and reads configured native endpoints without logging keys/addresses/balances. --litecoin covers five transparent profiles, never MWEB public balance. --evm checks public burn-address chain identity/balance/fees/gas/additional fees on 56 prioritized mainnets. --contracts verifies nine Router02 deployments/factory/WETH. Read-only success is not funded acceptance.

The local fake SOCKS test uses an invalid domain and verifies the original domain in ATYP=3 even with NO_PROXY=*. It establishes no prior target DNS for that request, not system-wide leak freedom.

Monero tests verify full onion SOCKS4a forwarding, no direct fallback, closed-gate rejection and official offline address import under production sandbox rules. Kernel probes allow only the chosen proxy port and deny other local/external ports. See [MONERO.md](MONERO.md).

Privacy tests generate a complete public-test Groth16 proof offline. Kernel canaries verify denied user-content reads/writes/network. TorSmoke bridge/privacy probes only read public fixtures. See [BRIDGES_PRIVACY.md](BRIDGES_PRIVACY.md).

## Required system acceptance, not yet executed

Use a clean test account/machine with packet capture/process connection monitoring, without real seeds/funds/production API keys.

| Scenario | Expected observation |
|---|---|
| Locked | No Tor/RPC/pricing/icons/telemetry/update connection |
| Unlock with updates | Queries begin only after Tor bootstrap, within selected scope, without address-set index uploads |
| Asset and price updates disabled, no manual refresh | Tor bootstrap/directory traffic only |
| Asset refresh | Wallet connects only to loopback; external TCP belongs to Tor/bridge transport |
| DNS/TLS | No RPC-domain DNS/DoH/DoT or certificate AIA/OCSP/CRL fetch outside proxy |
| Tor exit/crash | Cancel current requests, block new ones, no direct retry |
| NO_PROXY/system proxy/PAC | Fixed local SOCKS routing unchanged |
| Redirect/invalid certificate | No 30x follow; invalid host/certificate fails without bypass |
| Account/network change | Validate supported identity, cancel stale scans |
| App switching | Session stays unlocked; displayed backup/note hides; idle clock continues |
| Sleep/idle expiry | Lock and terminate runtimes, close gate |
| Broadcast timeout | Retain hash/unverified state; no duplicate automatic payment |
| Prices | Fixed IDs/custom contracts via Tor, no wallet balances/addresses; disabling/lock stops new queries |
| Bridges | Only current Tor uses transport; reject config injection; do not log bridge text |

## Functional acceptance still needed

Complete dedicated small-value Sepolia native/ERC20 interactive flows, receipts, timeout/restart recovery, wrong-network/password/insufficient-funds cases, and equivalent funded protocol acceptance. Current vectors/mocks/read-only Tor tests are not live coin broadcasts. Full XMR restore, complete cross-version packet capture and independent security review remain outstanding.
