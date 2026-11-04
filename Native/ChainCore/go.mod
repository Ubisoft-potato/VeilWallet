module app.veilwallet.chaincore

go 1.26.8

require (
	filippo.io/edwards25519 v1.2.0
	github.com/aperturerobotics/protobuf-go-lite v0.13.0
	github.com/btcsuite/btcd v0.24.2
	github.com/btcsuite/btcd/btcec/v2 v2.3.4
	github.com/btcsuite/btcd/btcutil v1.1.5
	github.com/eoscanada/eos-go v0.10.2
	github.com/okx/go-wallet-sdk/coins/aptos v0.0.0
	github.com/okx/go-wallet-sdk/coins/bitcoin v0.0.0
	github.com/okx/go-wallet-sdk/coins/cardano v0.0.0
	github.com/okx/go-wallet-sdk/coins/cosmos v0.0.0
	github.com/okx/go-wallet-sdk/coins/near v0.0.0
	github.com/okx/go-wallet-sdk/coins/nostrassets v0.0.0
	github.com/okx/go-wallet-sdk/coins/polkadot v0.0.0
	github.com/okx/go-wallet-sdk/coins/solana v0.0.0
	github.com/okx/go-wallet-sdk/coins/stacks v0.0.0
	github.com/okx/go-wallet-sdk/coins/starknet v0.0.0
	github.com/okx/go-wallet-sdk/coins/sui v0.0.0
	github.com/okx/go-wallet-sdk/coins/ton v0.0.0
	github.com/okx/go-wallet-sdk/coins/tron v0.0.0
	github.com/okx/go-wallet-sdk/crypto v0.0.3
	golang.org/x/crypto v0.58.1-0.20261009181718-2f1f834330b2
	lukechampine.com/blake3 v1.2.1
)

require (
	github.com/ProjectZKM/Ziren/crates/go-runtime/zkvm_runtime v0.0.0-20251001021608-1fe7b43fc4d6 // indirect
	github.com/aperturerobotics/json-iterator-lite v1.0.0 // indirect
	github.com/bits-and-blooms/bitset v1.25.0 // indirect
	github.com/blocto/solana-go-sdk v1.27.0 // indirect
	github.com/btcsuite/btcd/btcutil/psbt v1.1.8 // indirect
	github.com/btcsuite/btcd/chaincfg/chainhash v1.1.0 // indirect
	github.com/btcsuite/btclog v0.0.0-20170628155309-84c8d2346e9f // indirect
	github.com/btcsuite/btcutil v1.0.3-0.20201208143702-a53e38424cce // indirect
	github.com/consensys/gnark-crypto v0.22.0 // indirect
	github.com/crate-crypto/go-eth-kzg v1.5.0 // indirect
	github.com/dchest/blake2b v1.0.0 // indirect
	github.com/decred/dcrd/crypto/blake256 v1.0.1 // indirect
	github.com/decred/dcrd/dcrec/secp256k1/v4 v4.3.0 // indirect
	github.com/ethereum/c-kzg-4844/v2 v2.1.8 // indirect
	github.com/ethereum/go-ethereum v1.17.10 // indirect
	github.com/fxamacker/cbor/v2 v2.5.0 // indirect
	github.com/holiman/uint256 v1.3.2 // indirect
	github.com/klauspost/cpuid/v2 v2.3.0 // indirect
	github.com/mr-tron/base58 v1.2.0 // indirect
	github.com/okx/go-wallet-sdk/util v0.0.6 // indirect
	github.com/shopspring/decimal v1.4.0 // indirect
	github.com/supranational/blst v0.3.16 // indirect
	github.com/veraison/go-cose v1.3.0 // indirect
	github.com/x448/float16 v0.8.4 // indirect
	golang.org/x/sync v0.23.0 // indirect
	golang.org/x/sys v0.49.0 // indirect
)

replace (
	github.com/okx/go-wallet-sdk/coins/aptos => ../../Vendor/OKXWalletSDK/coins/aptos
	github.com/okx/go-wallet-sdk/coins/bitcoin => ../../Vendor/OKXWalletSDK/coins/bitcoin
	github.com/okx/go-wallet-sdk/coins/cardano => ../../Vendor/OKXWalletSDK/coins/cardano
	github.com/okx/go-wallet-sdk/coins/cosmos => ../../Vendor/OKXWalletSDK/coins/cosmos
	github.com/okx/go-wallet-sdk/coins/eos => ../../Vendor/OKXWalletSDK/coins/eos
	github.com/okx/go-wallet-sdk/coins/near => ../../Vendor/OKXWalletSDK/coins/near
	github.com/okx/go-wallet-sdk/coins/nostrassets => ../../Vendor/OKXWalletSDK/coins/nostrassets
	github.com/okx/go-wallet-sdk/coins/polkadot => ../../Vendor/OKXWalletSDK/coins/polkadot
	github.com/okx/go-wallet-sdk/coins/solana => ../../Vendor/OKXWalletSDK/coins/solana
	github.com/okx/go-wallet-sdk/coins/stacks => ../../Vendor/OKXWalletSDK/coins/stacks
	github.com/okx/go-wallet-sdk/coins/starknet => ../../Vendor/OKXWalletSDK/coins/starknet
	github.com/okx/go-wallet-sdk/coins/sui => ../../Vendor/OKXWalletSDK/coins/sui
	github.com/okx/go-wallet-sdk/coins/ton => ../../Vendor/OKXWalletSDK/coins/ton
	github.com/okx/go-wallet-sdk/coins/tron => ../../Vendor/OKXWalletSDK/coins/tron
	github.com/okx/go-wallet-sdk/crypto => ../../Vendor/OKXWalletSDK/crypto
	github.com/okx/go-wallet-sdk/util => ../../Vendor/OKXWalletSDK/util
)
