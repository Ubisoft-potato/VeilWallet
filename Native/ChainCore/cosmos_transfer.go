package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"github.com/btcsuite/btcd/btcec/v2"
	"github.com/btcsuite/btcd/btcec/v2/ecdsa"
	"github.com/btcsuite/btcd/btcutil/bech32"
	"github.com/okx/go-wallet-sdk/coins/cosmos"
	"github.com/okx/go-wallet-sdk/coins/cosmos/tx"
	"github.com/okx/go-wallet-sdk/coins/cosmos/types"
	"github.com/okx/go-wallet-sdk/coins/cosmos/types/ethsecp256k1"
	"math/big"
	"strings"
)

func cosmosTransfer(req request, key []byte) (response, error) {
	p := req.Transfer
	for _, address := range []string{p.From, p.To} {
		hrp, raw, err := bech32.DecodeToBase256(address)
		if err != nil || hrp != req.HRP || len(raw) != 20 {
			return response{}, errors.New("account address")
		}
	}
	if len(p.ChainIdentifier) == 0 || len(p.ChainIdentifier) > 80 || len(p.Memo) > 256 || len(p.Denomination) < 3 || len(p.Denomination) > 128 || strings.ContainsAny(p.Denomination, " \n\r\t") {
		return response{}, errors.New("chain parameters")
	}
	sequence, e := number(p.Nonce)
	if e != nil {
		return response{}, e
	}
	account, e := number(p.AccountNumber)
	if e != nil {
		return response{}, e
	}
	gas, e := number(p.MaxGas)
	if e != nil || gas == 0 || gas > 5_000_000 {
		return response{}, errors.New("gas")
	}
	timeout, e := number(p.Expiration)
	if e != nil || timeout == 0 {
		return response{}, errors.New("timeout height")
	}
	fee, ok := new(big.Int).SetString(p.Fee, 10)
	if !ok || fee.Sign() < 0 || fee.BitLen() > 128 || strings.Trim(p.Fee, "0123456789") != "" {
		return response{}, errors.New("fee")
	}
	public, e := hex.DecodeString(p.PublicKey)
	if e != nil || len(public) != 33 {
		return response{}, errors.New("public key")
	}
	parsed, e := btcec.ParsePubKey(public)
	if e != nil {
		return response{}, e
	}
	var owner string
	if req.Variant == "eth" {
		digest := cosmos.HashMessage(parsed.SerializeUncompressed()[1:])
		owner, e = bech32.EncodeFromBase256(req.HRP, digest[12:])
	} else {
		owner, e = cosmos.GetAddressByPublicKey(hex.EncodeToString(public), req.HRP)
	}
	if e != nil || owner != p.From {
		return response{}, errors.New("public key owner")
	}
	if key != nil {
		_, pk := btcec.PrivKeyFromBytes(key)
		if !bytes.Equal(pk.SerializeCompressed(), public) {
			return response{}, errors.New("key mismatch")
		}
	}
	var pub *types.Any
	if req.Variant == "eth" {
		pub, e = types.NewAnyWithValue(&ethsecp256k1.PubKey{Key: public})
	} else {
		pub, e = types.NewAnyWithValue(&types.PubKey{Key: public})
	}
	if e != nil {
		return response{}, e
	}
	// Injective uses its own type URL, distinct from the SDK's Ethermint default.
	if req.Variant == "eth" {
		pub.TypeUrl = "/injective.crypto.v1beta1.ethsecp256k1.PubKey"
	}
	amount, ok := types.NewIntFromString(p.Amount)
	if !ok {
		return response{}, errors.New("amount")
	}
	message, e := types.NewAnyWithValue(&types.MsgSend{FromAddress: p.From, ToAddress: p.To, Amount: types.NewCoins(types.NewCoin(p.Denomination, amount))})
	if e != nil {
		return response{}, e
	}
	body, e := (&tx.TxBody{Messages: []*types.Any{message}, Memo: p.Memo, TimeoutHeight: timeout}).Marshal()
	if e != nil {
		return response{}, e
	}
	feeAmount, ok := types.NewIntFromString(p.Fee)
	if !ok {
		return response{}, errors.New("fee")
	}
	auth, e := (&tx.AuthInfo{SignerInfos: []*tx.SignerInfo{{PublicKey: pub, ModeInfo: &tx.ModeInfo{Sum: &tx.ModeInfo_Single_{Single: &tx.ModeInfo_Single{Mode: types.SignMode_SIGN_MODE_DIRECT}}}, Sequence: sequence}}, Fee: &tx.Fee{Amount: types.NewCoins(types.NewCoin(p.Denomination, feeAmount)), GasLimit: gas}}).Marshal()
	if e != nil {
		return response{}, e
	}
	doc, e := (&tx.SignDoc{BodyBytes: body, AuthInfoBytes: auth, ChainId: p.ChainIdentifier, AccountNumber: account}).Marshal()
	if e != nil {
		return response{}, e
	}
	signatureSize := 64
	if req.Variant == "eth" {
		signatureSize = 65
	}
	simulation, e := (&tx.TxRaw{BodyBytes: body, AuthInfoBytes: auth, Signatures: [][]byte{make([]byte, signatureSize)}}).Marshal()
	if e != nil {
		return response{}, e
	}
	if key == nil {
		return response{Unsigned: hex.EncodeToString(doc), Simulation: base64.StdEncoding.EncodeToString(simulation), Valid: true}, nil
	}
	// Upstream btcec performs deterministic low-S ECDSA; no curve arithmetic here.
	digest := sha256.Sum256(doc)
	signHash := digest[:]
	if req.Variant == "eth" {
		signHash = cosmos.HashMessage(doc)
	}
	private, _ := btcec.PrivKeyFromBytes(key)
	compact := ecdsa.SignCompact(private, signHash, false)
	recovered, _, e := ecdsa.RecoverCompact(compact, signHash)
	if e != nil || !bytes.Equal(recovered.SerializeCompressed(), public) {
		return response{}, errors.New("signature verification")
	}
	signature := append([]byte{}, compact[1:]...)
	if req.Variant == "eth" {
		signature = append(signature, compact[0]-27)
	}
	raw, e := (&tx.TxRaw{BodyBytes: body, AuthInfoBytes: auth, Signatures: [][]byte{signature}}).Marshal()
	if e != nil {
		return response{}, e
	}
	signed := base64.StdEncoding.EncodeToString(raw)
	hash := sha256.Sum256(raw)
	return response{Unsigned: hex.EncodeToString(doc), Signed: signed, Hash: strings.ToUpper(hex.EncodeToString(hash[:])), Valid: true}, nil
}
