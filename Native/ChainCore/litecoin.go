package main

import (
	"encoding/binary"
	"encoding/hex"
	"errors"
	"strings"

	"github.com/btcsuite/btcd/btcec/v2"
	b58 "github.com/btcsuite/btcd/btcutil/base58"
	"github.com/btcsuite/btcd/btcutil/bech32"
	"github.com/btcsuite/btcd/chaincfg"
	"lukechampine.com/blake3"
)

// Litecoin Core chainparams.cpp: mainnet P2PKH 48, P2SH 50 (old 5), WIF 176, HRP ltc.
func litecoinParams(compat bool) *chaincfg.Params {
	p := chaincfg.MainNetParams
	p.Name = "litecoin-mainnet"
	p.PubKeyHashAddrID = 0x30
	p.ScriptHashAddrID = 0x32
	p.PrivateKeyID = 0xb0
	p.Bech32HRPSegwit = "ltc"
	if compat {
		p.ScriptHashAddrID = 5
	}
	return &p
}

func litecoinInfo(input string) (response, error) {
	if len(input) < 8 || len(input) > 150 {
		return response{}, errors.New("LTC address length")
	}
	lower := strings.ToLower(input)
	if strings.HasPrefix(lower, "ltcmweb1") {
		hrp, words, err := bech32.DecodeNoLimit(input)
		if err != nil || hrp != "ltcmweb" || len(words) < 2 || words[0] != 0 {
			return response{}, errors.New("MWEB encoding")
		}
		raw, err := bech32.ConvertBits(words[1:], 5, 8, false)
		if err != nil || len(raw) != 66 {
			return response{}, errors.New("MWEB payload")
		}
		if _, err = btcec.ParsePubKey(raw[:33]); err != nil {
			return response{}, err
		}
		if _, err = btcec.ParsePubKey(raw[33:]); err != nil {
			return response{}, err
		}
		canonical, err := bech32.Encode("ltcmweb", words)
		if err != nil || canonical != lower {
			return response{}, errors.New("MWEB checksum type")
		}
		return response{Address: canonical, AddressType: "mweb", Valid: true}, nil
	}
	if strings.HasPrefix(lower, "ltc1") {
		hrp, words, checksum, err := bech32.DecodeGeneric(input)
		if err != nil || hrp != "ltc" || len(words) < 2 || words[0] > 16 {
			return response{}, errors.New("witness encoding")
		}
		program, err := bech32.ConvertBits(words[1:], 5, 8, false)
		if err != nil || len(program) < 2 || len(program) > 40 {
			return response{}, errors.New("witness size")
		}
		kind := "witness"
		if words[0] == 0 {
			if checksum != bech32.Version0 {
				return response{}, errors.New("v0 checksum")
			}
			switch len(program) {
			case 20:
				kind = "p2wpkh"
			case 32:
				kind = "p2wsh"
			default:
				return response{}, errors.New("v0 size")
			}
		} else {
			if checksum != bech32.VersionM {
				return response{}, errors.New("v1+ checksum")
			}
			if words[0] == 1 && len(program) == 32 {
				kind = "p2tr"
			}
		}
		return response{Address: lower, AddressType: kind, Valid: true}, nil
	}
	payload, version, err := b58.CheckDecode(input)
	if err != nil || len(payload) != 20 {
		return response{}, errors.New("base58 address")
	}
	switch version {
	case 0x30:
		return response{Address: input, AddressType: "p2pkh", Valid: true}, nil
	case 0x32:
		return response{Address: input, AddressType: "p2sh", Valid: true}, nil
	case 5:
		return response{Address: b58.CheckEncode(payload, 0x32), AddressType: "p2sh-legacy", Valid: true}, nil
	}
	return response{}, errors.New("not Litecoin mainnet")
}

func validateLitecoin(req request) bool {
	info, err := litecoinInfo(req.Address)
	if err != nil {
		return false
	}
	switch req.Variant {
	case "any":
		return true
	case "legacy":
		return info.AddressType == "p2pkh"
	case "nested", "nested-compat":
		return info.AddressType == "p2sh" || info.AddressType == "p2sh-legacy"
	case "segwit":
		return info.AddressType == "p2wpkh"
	case "taproot":
		return info.AddressType == "p2tr"
	case "mweb":
		return info.AddressType == "mweb"
	}
	return false
}

func mwebTweak(req request) (response, error) {
	if req.Family != "litecoin" || req.Variant != "mweb" {
		return response{}, errors.New("MWEB profile")
	}
	scan, err := hex.DecodeString(req.Key)
	if _, _, err = validSecp(scan, err); err != nil {
		return response{}, err
	}
	input := make([]byte, 37)
	input[0] = 'A'
	binary.LittleEndian.PutUint32(input[1:5], req.Index)
	copy(input[5:], scan)
	digest := blake3.Sum256(input)
	return response{Key: hex.EncodeToString(digest[:]), Valid: true}, nil
}
func mwebEncode(req request) (response, error) {
	if req.Family != "litecoin" || req.Variant != "mweb" {
		return response{}, errors.New("MWEB profile")
	}
	raw, err := hex.DecodeString(req.Key)
	if err != nil || len(raw) != 66 {
		return response{}, errors.New("MWEB public keys")
	}
	if _, err = btcec.ParsePubKey(raw[:33]); err != nil {
		return response{}, err
	}
	if _, err = btcec.ParsePubKey(raw[33:]); err != nil {
		return response{}, err
	}
	words, err := bech32.ConvertBits(raw, 8, 5, true)
	if err != nil {
		return response{}, err
	}
	address, err := bech32.Encode("ltcmweb", append([]byte{0}, words...))
	return response{Address: address, AddressType: "mweb", Valid: err == nil}, err
}
