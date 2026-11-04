package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"bytes"
	"crypto/ed25519"
	"encoding/hex"
	"encoding/json"
	"errors"
	"github.com/eoscanada/eos-go/ecc"
	"github.com/okx/go-wallet-sdk/coins/starknet"
	"github.com/okx/go-wallet-sdk/crypto/ss58"
	"golang.org/x/crypto/blake2b"
	"golang.org/x/crypto/ripemd160"
	"math/big"
	"strings"
	"sync"
	"unsafe"

	"github.com/btcsuite/btcd/btcec/v2"
	"github.com/btcsuite/btcd/btcec/v2/schnorr"
	"github.com/btcsuite/btcd/btcutil"
	"github.com/btcsuite/btcd/btcutil/bech32"
	"github.com/btcsuite/btcd/chaincfg"
	"github.com/okx/go-wallet-sdk/coins/aptos"
	"github.com/okx/go-wallet-sdk/coins/bitcoin"
	"github.com/okx/go-wallet-sdk/coins/cardano"
	cardanocrypto "github.com/okx/go-wallet-sdk/coins/cardano/crypto"
	"github.com/okx/go-wallet-sdk/coins/cosmos"
	"github.com/okx/go-wallet-sdk/coins/near"
	"github.com/okx/go-wallet-sdk/coins/nostrassets"
	"github.com/okx/go-wallet-sdk/coins/polkadot"
	"github.com/okx/go-wallet-sdk/coins/solana"
	"github.com/okx/go-wallet-sdk/coins/stacks"
	"github.com/okx/go-wallet-sdk/coins/sui"
	"github.com/okx/go-wallet-sdk/coins/ton"
	tonaddress "github.com/okx/go-wallet-sdk/coins/ton/address"
	tonwallet "github.com/okx/go-wallet-sdk/coins/ton/ton/wallet"
	"github.com/okx/go-wallet-sdk/coins/tron"
	"github.com/okx/go-wallet-sdk/crypto/base58"
	bip32 "github.com/okx/go-wallet-sdk/crypto/go-bip32"
	bip39 "github.com/okx/go-wallet-sdk/crypto/go-bip39"
)

func tronAddress(req request) (response, error) {
	if req.Family != "tron" {
		return response{}, errors.New("address family")
	}
	if strings.HasPrefix(req.Address, "0x") {
		raw, e := hex.DecodeString(req.Address[2:])
		if e != nil || len(raw) != 20 {
			return response{}, errors.New("address bytes")
		}
		address := base58.CheckEncode(raw, 0x41)
		return response{Address: address, Key: hex.EncodeToString(raw), Valid: true}, nil
	}
	if !tron.ValidateAddress(req.Address) {
		return response{}, errors.New("address")
	}
	raw, e := tron.GetAddressHash(req.Address)
	if e != nil || len(raw) != 21 || raw[0] != 0x41 {
		return response{}, errors.New("address version")
	}
	return response{Address: req.Address, Key: hex.EncodeToString(raw[1:]), Valid: true}, nil
}

type request struct {
	Action            string           `json:"action"`
	Family            string           `json:"family"`
	Variant           string           `json:"variant"`
	Key               string           `json:"key"`
	Address           string           `json:"address"`
	HRP               string           `json:"hrp"`
	Mnemonic          string           `json:"mnemonic"`
	Passphrase        string           `json:"passphrase"`
	Path              string           `json:"path"`
	Index             uint32           `json:"index"`
	Transfer          *transferRequest `json:"transfer,omitempty"`
	SignedTransaction string           `json:"signedTransaction,omitempty"`
}
type response struct {
	Address     string `json:"address,omitempty"`
	Key         string `json:"key,omitempty"`
	Valid       bool   `json:"valid"`
	Error       string `json:"error,omitempty"`
	StorageKey  string `json:"storageKey,omitempty"`
	AddressType string `json:"addressType,omitempty"`
	Unsigned    string `json:"unsigned,omitempty"`
	Signed      string `json:"signed,omitempty"`
	Hash        string `json:"hash,omitempty"`
	Simulation  string `json:"simulation,omitempty"`
	ViewKey     string `json:"viewKey,omitempty"`
	VirtualSize string `json:"virtualSize,omitempty"`
}

var cryptoLock sync.Mutex

//export veil_chain_execute
func veil_chain_execute(input *C.char) (output *C.char) {
	cryptoLock.Lock()
	defer cryptoLock.Unlock()
	defer func() {
		if recover() != nil {
			output = C.CString(`{"error":"Invalid chain input"}`)
		}
	}()
	if input == nil {
		return C.CString(`{"error":"Empty input"}`)
	}
	text := C.GoString(input)
	if len(text) > 2*1024*1024 {
		return C.CString(`{"error":"Input too large"}`)
	}
	var req request
	if json.Unmarshal([]byte(text), &req) != nil {
		return C.CString(`{"error":"Invalid input"}`)
	}
	result, err := execute(req)
	if err != nil {
		result = response{Error: "Invalid key, address or chain parameters"}
	}
	data, err := json.Marshal(result)
	if err != nil {
		return C.CString(`{"error":"Encoding failed"}`)
	}
	return C.CString(string(data))
}

//export veil_chain_free
func veil_chain_free(output *C.char) { C.free(unsafe.Pointer(output)) }

func execute(req request) (response, error) {
	if req.Action == "transferInspect" {
		return inspectUTXO(req)
	}
	if req.Action == "tronAddress" {
		return tronAddress(req)
	}
	if req.Action == "transferBuild" || req.Action == "transferSign" {
		return nativeTransfer(req)
	}
	if req.Family == "monero" {
		if req.Action == "validate" {
			return response{Valid: moneroValidate(req.Address)}, nil
		}
		if req.Action == "moneroDerive" {
			key, err := hex.DecodeString(req.Key)
			if err != nil || len(key) != 32 {
				return response{}, errors.New("node key")
			}
			scalar, err := moneroReduce(moneroHash(key))
			if err != nil {
				return response{}, err
			}
			return moneroAddress(scalar)
		}
		if req.Action == "address" {
			scalar, err := moneroKey(req.Key)
			if err != nil {
				return response{}, err
			}
			return moneroAddress(scalar)
		}
		return response{}, errors.New("unsupported Monero action")
	}
	if req.Action == "ltcInfo" {
		return litecoinInfo(req.Address)
	}
	if req.Action == "mwebTweak" {
		return mwebTweak(req)
	}
	if req.Action == "mwebEncode" {
		return mwebEncode(req)
	}
	if req.Action == "storageKey" {
		public, err := ss58.DecodeToPub(req.Address)
		if err != nil || len(public) != 32 {
			return response{}, errors.New("SS58")
		}
		hash, _ := blake2b.New(16, nil)
		hash.Write(public)
		return response{StorageKey: "0x26aa394eea5630e07c48ae0c9558cef7b99d880ec681799c0cf30e8886371da9" + hex.EncodeToString(hash.Sum(nil)) + hex.EncodeToString(public), Valid: true}, nil
	}
	if req.Action == "validate" {
		return response{Valid: validate(req)}, nil
	}
	if req.Action == "cardanoDerive" {
		entropy, err := bip39.EntropyFromMnemonic(req.Mnemonic)
		if err != nil {
			return response{}, err
		}
		path, err := bip32.ParseDerivationPath(req.Path)
		if err != nil || len(path) != 5 || path[0] != 0x8000073c || path[1] != 0x80000717 || path[2] < 0x80000000 || path[3] > 1 || path[4] >= 0x80000000 {
			return response{}, errors.New("path")
		}
		root := cardanocrypto.NewXPrvKeyFromEntropy(entropy, req.Passphrase)
		account := root.Derive(path[0]).Derive(path[1]).Derive(path[2])
		payment := account.Derive(path[3]).Derive(path[4])
		stake := account.Derive(2).Derive(0)
		key := payment.PrvKey().String() + stake.PrvKey().String()
		address, err := cardano.NewAddressFromPrvKey(key)
		return response{Key: key, Address: address, Valid: err == nil}, err
	}
	if req.Action != "address" {
		return response{}, errors.New("unsupported action")
	}
	key, compressed, err := parseKey(req)
	if err != nil {
		return response{}, err
	}
	address, err := addressFor(req, key, compressed)
	if err != nil {
		return response{}, err
	}
	return response{Address: address, Key: hex.EncodeToString(key), Valid: true}, nil
}

func parseKey(req request) ([]byte, bool, error) {
	text := strings.TrimSpace(req.Key)
	compressed := true
	if req.Family == "eos" && !isHex(text) {
		if strings.HasPrefix(text, "PVT_K1_") {
			decoded := base58.Decode(strings.TrimPrefix(text, "PVT_K1_"))
			if len(decoded) != 36 {
				return nil, false, errors.New("EOS key length")
			}
			digest := ripemd160.New()
			digest.Write(decoded[:32])
			digest.Write([]byte("K1"))
			if !bytes.Equal(decoded[32:], digest.Sum(nil)[:4]) {
				return nil, false, errors.New("EOS key checksum")
			}
			return validSecp(decoded[:32], nil)
		}
		wif, err := btcutil.DecodeWIF(text)
		if err != nil || !wif.IsForNet(&chaincfg.MainNetParams) {
			return nil, false, errors.New("EOS WIF")
		}
		return validSecp(wif.PrivKey.Serialize(), nil)
	}
	if req.Family == "litecoin" && !isHex(text) {
		wif, err := btcutil.DecodeWIF(text)
		if err != nil || !wif.IsForNet(litecoinParams(false)) {
			return nil, false, errors.New("Litecoin WIF")
		}
		if !wif.CompressPubKey && req.Variant != "legacy" {
			return nil, false, errors.New("uncompressed witness")
		}
		return wif.PrivKey.Serialize(), wif.CompressPubKey, nil
	}
	if req.Family == "bitcoin" && !isHex(text) {
		wif, err := btcutil.DecodeWIF(text)
		if err != nil || !wif.IsForNet(&chaincfg.MainNetParams) {
			return nil, false, errors.New("wif")
		}
		if !wif.CompressPubKey && req.Variant != "legacy" {
			return nil, false, errors.New("uncompressed segwit")
		}
		return wif.PrivKey.Serialize(), wif.CompressPubKey, nil
	}
	if req.Family == "aptos" {
		text = strings.TrimPrefix(text, "ed25519-priv-")
	}
	if req.Family == "near" {
		text = strings.TrimPrefix(text, "ed25519:")
	}
	if req.Family == "nostr" && strings.HasPrefix(text, "nsec1") {
		key, err := nostrassets.DecodeBech32("nsec", text)
		return validSecp(key, err)
	}
	if req.Family == "sui" && strings.HasPrefix(text, "suiprivkey1") {
		hrp, key, err := bech32.DecodeToBase256(text)
		if err != nil || hrp != "suiprivkey" || len(key) != 33 || key[0] != 0 {
			return nil, false, errors.New("sui key scheme")
		}
		return key[1:], true, nil
	}
	var key []byte
	var err error
	switch {
	case strings.HasPrefix(text, "[") && (req.Family == "solana" || req.Family == "near"):
		err = json.Unmarshal([]byte(text), &key)
	case isHex(text) && ((req.Family != "solana" && req.Family != "near") || len(strings.TrimPrefix(text, "0x")) == 64 || len(strings.TrimPrefix(text, "0x")) == 128):
		key, err = hex.DecodeString(strings.TrimPrefix(text, "0x"))
	case req.Family == "solana" || req.Family == "near":
		key = base58.Decode(text)
	default:
		return nil, false, errors.New("format")
	}
	if err != nil {
		return nil, false, err
	}
	switch req.Family {
	case "solana", "near", "sui", "aptos", "ton", "polkadot":
		if len(key) == 64 {
			seed := key[:32]
			pair := ed25519.NewKeyFromSeed(seed)
			if !bytes.Equal(key, pair) {
				return nil, false, errors.New("keypair mismatch")
			}
			key = append([]byte(nil), seed...)
		}
		if len(key) != 32 {
			return nil, false, errors.New("seed size")
		}
		return key, true, nil
	case "cardano":
		if len(key) != 128 {
			return nil, false, errors.New("cardano payment+stake key")
		}
		return key, true, nil
	case "starknet":
		if len(key) != 32 {
			return nil, false, errors.New("stark key length")
		}
		value := new(big.Int).SetBytes(key)
		curve := starknet.SC()
		if value.Sign() == 0 || value.Cmp(curve.N) >= 0 {
			return nil, false, errors.New("stark scalar")
		}
		return key, true, nil
	case "stacks":
		if len(key) == 33 && key[32] == 1 {
			key = key[:32]
		}
		return validSecp(key, nil)
	default:
		return validSecp(key, nil)
	}
	return key, compressed, nil
}
func isHex(value string) bool {
	value = strings.TrimPrefix(value, "0x")
	if len(value) == 0 || len(value)%2 != 0 {
		return false
	}
	_, err := hex.DecodeString(value)
	return err == nil
}
func validSecp(key []byte, err error) ([]byte, bool, error) {
	if err != nil || len(key) != 32 {
		return nil, false, errors.New("key size")
	}
	n := new(big.Int).SetBytes(key)
	if n.Sign() == 0 || n.Cmp(btcec.S256().Params().N) >= 0 {
		return nil, false, errors.New("scalar")
	}
	return key, true, nil
}
func addressFor(req request, key []byte, compressed bool) (string, error) {
	text := hex.EncodeToString(key)
	switch req.Family {
	case "starknet":
		return starknet.GetPubKey(starknet.SC(), "0x"+text)
	case "eos":
		priv, _ := btcec.PrivKeyFromBytes(key)
		wif, err := btcutil.NewWIF(priv, &chaincfg.MainNetParams, false)
		if err != nil {
			return "", err
		}
		parsed, err := ecc.NewPrivateKey(wif.String())
		if err != nil {
			return "", err
		}
		return parsed.PublicKey().String(), nil
	case "bitcoin", "litecoin":
		_, pub := btcec.PrivKeyFromBytes(key)
		data := pub.SerializeCompressed()
		if !compressed {
			data = pub.SerializeUncompressed()
		}
		kind := bitcoin.SEGWIT_NATIVE
		switch req.Variant {
		case "legacy":
			kind = bitcoin.LEGACY
		case "nested", "nested-compat":
			kind = bitcoin.SEGWIT_NESTED
		case "taproot":
			kind = bitcoin.TAPROOT
		}
		params := &chaincfg.MainNetParams
		if req.Family == "litecoin" {
			params = litecoinParams(req.Variant == "nested-compat")
		}
		if req.Variant != "legacy" && req.Variant != "segwit" && req.Variant != "nested" && req.Variant != "nested-compat" && req.Variant != "taproot" {
			return "", errors.New("address variant")
		}
		return bitcoin.PubKeyToAddr(data, kind, params)
	case "solana":
		return solana.NewAddress(hex.EncodeToString(ed25519.NewKeyFromSeed(key)))
	case "tron":
		_, pub := btcec.PrivKeyFromBytes(key)
		return tron.GetAddressByPublicKey(hex.EncodeToString(pub.SerializeUncompressed()))
	case "sui":
		return sui.NewAddress(text), nil
	case "aptos":
		return aptos.NewAddress(text, false), nil
	case "ton":
		version := tonwallet.V4R2
		if req.Variant == "v5r1" {
			version = tonwallet.V5R1Final
		}
		return ton.NewAddress(key, version)
	case "cosmos":
		return cosmos.NewAddress(text, req.HRP, req.Variant == "eth")
	case "near":
		return near.PrivateKeyToAddr(hex.EncodeToString(ed25519.NewKeyFromSeed(key)))
	case "stacks":
		return stacks.NewAddress(text + "01")
	case "cardano":
		return cardano.NewAddressFromPrvKey(text)
	case "nostr":
		return nostrassets.NpubEncode(hex.EncodeToString(publicKeyX(key)))
	case "polkadot":
		pub := ed25519.NewKeyFromSeed(key).Public().(ed25519.PublicKey)
		return polkadot.PubKeyToAddress(pub, polkadot.PolkadotPrefix)
	}
	return "", errors.New("unsupported family")
}
func publicKeyX(key []byte) []byte {
	_, pub := btcec.PrivKeyFromBytes(key)
	return pub.SerializeCompressed()[1:]
}
func validate(req request) bool {
	switch req.Family {
	case "litecoin":
		return validateLitecoin(req)
	case "starknet":
		text := strings.TrimPrefix(req.Address, "0x")
		value, ok := new(big.Int).SetString(text, 16)
		return strings.HasPrefix(req.Address, "0x") && len(text) <= 64 && ok && value.Sign() > 0 && value.Cmp(starknet.SC().P) < 0
	case "eos":
		if len(req.Address) < 1 || len(req.Address) > 12 {
			return false
		}
		for _, c := range req.Address {
			if !(c == '.' || c >= '1' && c <= '5' || c >= 'a' && c <= 'z') {
				return false
			}
		}
		return true
	case "bitcoin":
		return bitcoin.ValidateAddress(req.Address)
	case "solana":
		return solana.ValidateAddress(req.Address)
	case "tron":
		return tron.ValidateAddress(req.Address)
	case "sui":
		return sui.ValidateAddress(req.Address)
	case "aptos":
		return aptos.ValidateAddress(req.Address, false)
	case "ton":
		parsed, err := tonaddress.ParseAddr(req.Address)
		return err == nil && !parsed.IsTestnetOnly()
	case "cosmos":
		return cosmos.ValidateAddress(req.Address, req.HRP)
	case "near":
		return near.ValidateAddress(req.Address)
	case "stacks":
		return (strings.HasPrefix(req.Address, "SP") || strings.HasPrefix(req.Address, "SM")) && stacks.ValidAddress(req.Address)
	case "cardano":
		hrp, words, err := bech32.DecodeNoLimit(req.Address)
		if err != nil {
			return false
		}
		raw, err := bech32.ConvertBits(words, 5, 8, false)
		return err == nil && hrp == "addr" && len(raw) > 0 && raw[0]&15 == 1 && cardano.ValidateAddress(req.Address)
	case "nostr":
		key, err := nostrassets.DecodeBech32("npub", req.Address)
		if err != nil || len(key) != 32 {
			return false
		}
		_, err = schnorr.ParsePubKey(key)
		return err == nil
	case "polkadot":
		public, err := ss58.DecodeToPub(req.Address)
		if err != nil {
			return false
		}
		a, err := polkadot.PubKeyToAddress(public, polkadot.PolkadotPrefix)
		return err == nil && a == req.Address
	}
	return false
}
func main() {}
