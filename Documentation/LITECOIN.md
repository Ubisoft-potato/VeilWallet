# Litecoin address support

Mainnet Core address encodings support validation, watch import and receiving. Ordinary single-key types also derive/import keys and support transparent sending. Format validation does not prove script ownership.

| Encoding | Type | Key derivation/import | Balance/send |
|---|---|---|---|
| L… | P2PKH | m/44'/2'/0'/0/i; compressed/uncompressed WIF, hex | Tor Esplora; single-key send |
| M… | P2SH | Nested SegWit m/49'/2'/0'/0/i; compressed key | Arbitrary P2SH watch; only supported nested single-key send |
| 3… | Legacy P2SH | Same nested path, old network byte | Labeled legacy; query equivalent M… |
| ltc1q…, 20-byte | P2WPKH | m/84'/2'/0'/0/i; compressed key | Tor Esplora; single-key send |
| ltc1q…, 32-byte | P2WSH | No arbitrary script inferred from one key | Watch/receive; no send |
| ltc1p…, 32-byte | P2TR | m/86'/2'/0'/0/i; compressed key | BIP86 single-key send |
| ltcmweb1… | MWEB stealth | Core root m/0'/100'; scan/primary spend pair | Local scanning/send unavailable; balance unknown |
| Other valid witness v1–v16 | WitnessUnknown | Undefined spend rules not generated | Validate/watch; node-dependent queries only |

Sending uses confirmed UTXOs at the selected address, verifies previous transaction IDs/amounts/locking scripts and executes btcd script verification after signing. It does not scan other derived addresses. Arbitrary scripts/P2WSH/MWEB remain watch/receive-only.

Old 3… encoding shares Bitcoin's prefix; formatting cannot determine intended chain. The UI identifies Litecoin, retains input display and queries the equivalent M… script hash. Bitcoin 1…, bc1… and WIF and LTC testnet addresses are not accepted as LTC mainnet.

## MWEB keys

Use the BIP39 seed as BIP32 root, derive m/0'/100', then hardened 0' for scan key a and 1' for primary spend key b. For subaddress index i:

~~~text
m_i = BLAKE3('A' || uint32_little_endian(i) || a)
b_i = b + m_i mod n
B_i = b_i * G
A_i = (a * b_i mod n) * G
address = Bech32("ltcmweb", version=0, compressed(A_i) || compressed(B_i))
~~~

Pinned upstream BLAKE3 and libsecp256k1 scalar tweaks/public-key creation implement these operations. No custom hash/curve primitive. Reject zero/out-of-range scalars, invalid points/version/padding, mixed case and incorrect Bech32m.

Import accepts scanHex:spendHex[:index], or combined 64-byte hex with index zero. These are primary scan/spend keys, not an individual output key or LTC WIF. Index is encrypted and displayed. Passphrase, seed convention, root and index affect the address; compare with the original wallet.

A public MWEB address cannot supply a balance. The UI disables refresh and the data layer rejects the request before networking; scan keys are never submitted or unknown values replaced with zero. This is not a complete MWEB wallet.

## Balances and migration

Default endpoint: https://litecoinspace.org/api. Check block-height/0 against mainnet genesis before querying the selected transparent address. Use integer litoshis/eight decimals through Tor; errors, negatives and inconsistent funded/spent values never mean zero.

Unlocking older mnemonic vaults adds only missing LTC profiles while preserving wallet IDs, existing addresses, custom paths, account bindings and index. Separate private-key/watch wallets are not reinterpreted as LTC keys.

## Sources and vectors

References read on 2026-11-02. Core's actual mainnet MWEB HRP is ltcmweb, not ltc1mweb.

- [Core parameters](https://github.com/litecoin-project/litecoin/blob/master/src/chainparams.cpp): P2PKH 48, P2SH 50/old 5, WIF 176 and genesis.
- [Core encoding](https://github.com/litecoin-project/litecoin/blob/master/src/key_io.cpp): v0 Bech32, v1+ Bech32m and MWEB public keys.
- [Account root](https://github.com/litecoin-project/litecoin/blob/master/src/wallet/scriptpubkeyman.cpp), [subaddresses](https://github.com/litecoin-project/litecoin/blob/master/src/libmw/src/wallet/Keychain.cpp), [hash domains](https://github.com/litecoin-project/litecoin/blob/master/src/libmw/include/mw/crypto/Hasher.h).
- [Valid](https://github.com/litecoin-project/litecoin/blob/master/src/test/data/key_io_valid.json)/[invalid](https://github.com/litecoin-project/litecoin/blob/master/src/test/data/key_io_invalid.json) Core fixtures retained locally.
- [ltcd vectors](https://github.com/ltcsuite/ltcd/blob/master/ltcutil/mweb/keychain_test.go), [ltcwallet compatibility](https://github.com/ltcsuite/ltcwallet/blob/master/waddrmgr/mweb_compat_test.go): public scan/spend keys at indices 0/1/10.
- [Light-client privacy](https://github.com/litecoin-project/litecoin/blob/master/doc/mweb/light-clients.md): uploading scan keys reveals outputs/amounts.

[verify-multichain.cjs](../Scripts/verify-multichain.cjs) independently computes addresses using bitcoinjs/noble/scure. Tests cover network/WIF bytes, uncompressed-key limits, script watching, legacy conversion, wrong genesis, blocked MWEB queries and vault migration. See [validation](VALIDATION.md).
