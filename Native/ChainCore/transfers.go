package main

import (
	"bytes"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"github.com/aperturerobotics/protobuf-go-lite/types/known/anypb"
	"github.com/btcsuite/btcd/btcec/v2"
	"github.com/btcsuite/btcd/btcutil"
	"github.com/btcsuite/btcd/chaincfg"
	"github.com/btcsuite/btcd/txscript"
	"github.com/btcsuite/btcd/wire"
	"github.com/okx/go-wallet-sdk/coins/aptos"
	"github.com/okx/go-wallet-sdk/coins/aptos/aptos_types"
	"github.com/okx/go-wallet-sdk/coins/solana"
	"github.com/okx/go-wallet-sdk/coins/tron"
	"github.com/okx/go-wallet-sdk/coins/tron/pb"
	"github.com/okx/go-wallet-sdk/crypto/base58"
	"math/big"
	"strconv"
	"strings"
)

type transferInput struct {
	Txid     string `json:"txid"`
	Index    uint32 `json:"index"`
	Value    string `json:"value"`
	Previous string `json:"previous"`
}
type transferRequest struct {
	From            string          `json:"from"`
	To              string          `json:"to"`
	Amount          string          `json:"amount"`
	Fee             string          `json:"fee"`
	Change          string          `json:"change"`
	BlockHash       string          `json:"blockHash"`
	Nonce           string          `json:"nonce"`
	MaxGas          string          `json:"maxGas"`
	GasPrice        string          `json:"gasPrice"`
	Expiration      string          `json:"expiration"`
	RefBytes        string          `json:"refBytes"`
	RefHash         string          `json:"refHash"`
	Timestamp       string          `json:"timestamp"`
	PublicKey       string          `json:"publicKey"`
	Inputs          []transferInput `json:"inputs"`
	ChainIdentifier string          `json:"chainIdentifier"`
	Denomination    string          `json:"denomination"`
	AccountNumber   string          `json:"accountNumber"`
	Memo            string          `json:"memo"`
	ContractData    string          `json:"contractData"`
	FeeLimit        string          `json:"feeLimit"`
	Replaceable     bool            `json:"replaceable"`
}

func number(s string) (uint64, error) {
	if s == "" || strings.Trim(s, "0123456789") != "" {
		return 0, errors.New("integer")
	}
	return strconv.ParseUint(s, 10, 64)
}
func nativeTransfer(req request) (response, error) {
	p := req.Transfer
	if p == nil || !validate(request{Action: "validate", Family: req.Family, Variant: req.Variant, HRP: req.HRP, Address: p.From}) || !validate(request{Action: "validate", Family: req.Family, Variant: req.Variant, HRP: req.HRP, Address: p.To}) {
		return response{}, errors.New("transfer address")
	}
	amountValue, ok := new(big.Int).SetString(p.Amount, 10)
	if !ok || amountValue.Sign() < 0 || (amountValue.Sign() == 0 && !(req.Family == "tron" && p.ContractData != "")) || amountValue.BitLen() > 256 || strings.Trim(p.Amount, "0123456789") != "" {
		return response{}, errors.New("amount")
	}
	var err error
	var key []byte
	compressed := true
	if req.Action == "transferSign" {
		key, compressed, err = parseKey(req)
		if err != nil {
			return response{}, err
		}
		address, e := addressFor(req, key, compressed)
		if e != nil || address != p.From {
			return response{}, errors.New("signer mismatch")
		}
	}
	if req.Family == "cosmos" {
		return cosmosTransfer(req, key)
	}
	if !amountValue.IsUint64() {
		return response{}, errors.New("amount overflow")
	}
	amount := amountValue.Uint64()
	switch req.Family {
	case "bitcoin", "litecoin":
		return utxoTransfer(req, key, compressed)
	case "solana":
		if len(base58.Decode(p.BlockHash)) != 32 {
			return response{}, errors.New("blockhash")
		}
		tx := solana.NewRawTransaction(p.BlockHash, p.From)
		tx.AppendTransferInstruction(amount, p.From, p.To)
		unsigned, e := tx.UnsignedTx()
		if e != nil {
			return response{}, e
		}
		raw, e := hex.DecodeString(unsigned)
		if e != nil {
			return response{}, e
		}
		simulation := append(make([]byte, 65), raw...)
		simulation[0] = 1
		if key == nil {
			return response{Unsigned: unsigned, Simulation: base64.StdEncoding.EncodeToString(simulation), Valid: true}, nil
		}
		pair := ed25519.NewKeyFromSeed(key)
		tx.AppendSigner(hex.EncodeToString(pair))
		signed, e := tx.Sign(false)
		if e != nil {
			return response{}, e
		}
		serialized, e := base64.StdEncoding.DecodeString(signed)
		if e != nil || len(serialized) < 65 || serialized[0] != 1 || !bytes.Equal(serialized[65:], raw) || !ed25519.Verify(pair.Public().(ed25519.PublicKey), raw, serialized[1:65]) {
			return response{}, errors.New("signature verification")
		}
		return response{Unsigned: unsigned, Signed: signed, Hash: base58.Encode(serialized[1:65]), Valid: true}, nil
	case "aptos":
		nonce, e := number(p.Nonce)
		if e != nil {
			return response{}, e
		}
		gas, e := number(p.MaxGas)
		if e != nil || gas == 0 || gas > 2_000_000 {
			return response{}, errors.New("gas")
		}
		price, e := number(p.GasPrice)
		if e != nil || price == 0 {
			return response{}, errors.New("price")
		}
		expiry, e := number(p.Expiration)
		if e != nil {
			return response{}, e
		}
		payload, e := aptos.TransferPayload(p.To, amount)
		if e != nil {
			return response{}, e
		}
		tx, e := aptos.MakeRawTransaction(p.From, nonce, gas, price, expiry, 1, payload)
		if e != nil {
			return response{}, e
		}
		unsigned, e := tx.BcsSerialize()
		if e != nil {
			return response{}, e
		}
		if key == nil {
			public, e := hex.DecodeString(p.PublicKey)
			if e != nil || len(public) != 32 {
				return response{}, errors.New("public key")
			}
			auth := &aptos_types.TransactionAuthenticatorEd25519{PublicKey: aptos_types.Ed25519PublicKey(public), Signature: make([]byte, 64)}
			simulation, e := (&aptos_types.SignedTransaction{RawTxn: *tx, Authenticator: auth}).BcsSerialize()
			if e != nil {
				return response{}, e
			}
			return response{Unsigned: hex.EncodeToString(unsigned), Simulation: hex.EncodeToString(simulation), Valid: true}, nil
		}
		signed, e := aptos.SignRawTransaction(tx, hex.EncodeToString(key))
		if e != nil {
			return response{}, e
		}
		return response{Unsigned: hex.EncodeToString(unsigned), Signed: signed, Hash: aptos.GetTransactionHash(signed), Valid: true}, nil
	case "tron":
		ref, e := hex.DecodeString(p.RefBytes)
		if e != nil || len(ref) != 2 {
			return response{}, errors.New("ref bytes")
		}
		hash, e := hex.DecodeString(p.RefHash)
		if e != nil || len(hash) != 8 {
			return response{}, errors.New("ref hash")
		}
		timestamp, e := number(p.Timestamp)
		if e != nil {
			return response{}, e
		}
		expiry, e := number(p.Expiration)
		if e != nil || expiry <= timestamp || expiry-timestamp > 600_000 || expiry > 1<<63-1 || amount > 1<<63-1 {
			return response{}, errors.New("expiration")
		}
		tx, e := tron.GenTrxTransferTx(&tron.TxParamTron{FromAddress: p.From, ToAddress: p.To, Amount: new(big.Int).SetUint64(amount), RefBlockBytes: p.RefBytes, RefBlockHash: p.RefHash, Timestamp: int64(timestamp), Expiration: int64(expiry)})
		if e != nil {
			return response{}, e
		}
		if p.ContractData != "" {
			data, e := hex.DecodeString(p.ContractData)
			if e != nil || len(data) < 4 || len(data) > 128_000 {
				return response{}, errors.New("contract data")
			}
			limit, e := number(p.FeeLimit)
			if e != nil || limit == 0 || limit > 15_000_000_000 {
				return response{}, errors.New("fee limit")
			}
			owner, e := tron.GetAddressHash(p.From)
			if e != nil {
				return response{}, e
			}
			target, e := tron.GetAddressHash(p.To)
			if e != nil {
				return response{}, e
			}
			call := &pb.TriggerSmartContract{OwnerAddress: owner, ContractAddress: target, CallValue: int64(amount), Data: data}
			param, e := anypb.New(call, tron.TypeURLTriggerSmartContract)
			if e != nil {
				return response{}, e
			}
			tx.RawData.Contract = []*pb.Transaction_Contract{{Type: pb.Transaction_Contract_TriggerSmartContract, Parameter: param}}
			tx.RawData.FeeLimit = int64(limit)
		} else if p.FeeLimit != "" {
			return response{}, errors.New("unexpected fee limit")
		}
		raw, e := tx.GetRawData().MarshalVT()
		if e != nil {
			return response{}, e
		}
		if key == nil {
			return response{Unsigned: hex.EncodeToString(raw), Valid: true}, nil
		}
		signed, e := tron.SignTx(hex.EncodeToString(key), tx)
		if e != nil {
			return response{}, e
		}
		return response{Unsigned: hex.EncodeToString(raw), Signed: signed, Hash: hex.EncodeToString(tron.CalSigHash(raw)), Valid: true}, nil
	default:
		return response{}, errors.New("unsupported transfer")
	}
}
func utxoTransfer(req request, key []byte, compressed bool) (response, error) {
	p := req.Transfer
	params := &chaincfg.MainNetParams
	if req.Family == "litecoin" {
		params = litecoinParams(false)
	}
	if req.Variant != "legacy" && req.Variant != "segwit" && req.Variant != "nested" && req.Variant != "nested-compat" && req.Variant != "taproot" {
		return response{}, errors.New("unsupported script ownership")
	}
	fromAddress, toAddress := p.From, p.To
	if req.Family == "litecoin" {
		fromInfo, err := litecoinInfo(p.From)
		if err != nil {
			return response{}, err
		}
		toInfo, err := litecoinInfo(p.To)
		if err != nil {
			return response{}, err
		}
		if fromInfo.AddressType == "mweb" || toInfo.AddressType == "mweb" {
			return response{}, errors.New("MWEB requires a separate protocol")
		}
		fromAddress, toAddress = fromInfo.Address, toInfo.Address
	}
	from, e := btcutil.DecodeAddress(fromAddress, params)
	if e != nil {
		return response{}, e
	}
	fromScript, e := txscript.PayToAddrScript(from)
	if e != nil {
		return response{}, e
	}
	to, e := btcutil.DecodeAddress(toAddress, params)
	if e != nil || !to.IsForNet(params) {
		return response{}, errors.New("destination network")
	}
	toScript, e := txscript.PayToAddrScript(to)
	if e != nil {
		return response{}, e
	}
	if len(p.Inputs) == 0 || len(p.Inputs) > 20 {
		return response{}, errors.New("input count")
	}
	tx := wire.NewMsgTx(2)
	fetcher := txscript.NewMultiPrevOutFetcher(nil)
	total := uint64(0)
	seen := map[string]bool{}
	for _, input := range p.Inputs {
		raw, e := hex.DecodeString(input.Previous)
		if e != nil || len(raw) > 100_000 {
			return response{}, errors.New("previous transaction")
		}
		prev := wire.NewMsgTx(2)
		if prev.Deserialize(bytes.NewReader(raw)) != nil || prev.TxHash().String() != input.Txid || int(input.Index) >= len(prev.TxOut) {
			return response{}, errors.New("previous txid")
		}
		value, e := number(input.Value)
		if e != nil || value > 21_000_000_000_000_000 || total > 21_000_000_000_000_000-value {
			return response{}, errors.New("input value")
		}
		output := prev.TxOut[input.Index]
		if output.Value < 0 || uint64(output.Value) != value || !bytes.Equal(output.PkScript, fromScript) {
			return response{}, errors.New("input ownership")
		}
		point := wire.OutPoint{Hash: prev.TxHash(), Index: input.Index}
		if seen[point.String()] {
			return response{}, errors.New("duplicate input")
		}
		seen[point.String()] = true
		fetcher.AddPrevOut(point, output)
		txIn := wire.NewTxIn(&point, nil, nil)
		if p.Replaceable {
			txIn.Sequence = wire.MaxTxInSequenceNum - 2
		}
		tx.TxIn = append(tx.TxIn, txIn)
		total += value
	}
	amount, e := number(p.Amount)
	if e != nil || amount > total {
		return response{}, errors.New("amount")
	}
	change, e := number(p.Change)
	if e != nil || change > total-amount {
		return response{}, errors.New("change")
	}
	fee, e := number(p.Fee)
	if e != nil || total-amount-change != fee || fee == 0 {
		return response{}, errors.New("fee accounting")
	}
	tx.AddTxOut(wire.NewTxOut(int64(amount), toScript))
	if change > 0 {
		tx.AddTxOut(wire.NewTxOut(int64(change), fromScript))
	}
	var unsigned bytes.Buffer
	if e = tx.Serialize(&unsigned); e != nil {
		return response{}, e
	}
	unsignedHex := hex.EncodeToString(unsigned.Bytes())
	if key == nil {
		return response{Unsigned: unsignedHex, Valid: true}, nil
	}
	secret, _ := btcec.PrivKeyFromBytes(key)
	hashes := txscript.NewTxSigHashes(tx, fetcher)
	for i := range tx.TxIn {
		previous := fetcher.FetchPrevOutput(tx.TxIn[i].PreviousOutPoint)
		switch req.Variant {
		case "legacy":
			tx.TxIn[i].SignatureScript, e = txscript.SignatureScript(tx, i, previous.PkScript, txscript.SigHashAll, secret, compressed)
		case "segwit":
			tx.TxIn[i].Witness, e = txscript.WitnessSignature(tx, hashes, i, previous.Value, previous.PkScript, txscript.SigHashAll, secret, true)
		case "nested", "nested-compat":
			publicHash := btcutil.Hash160(secret.PubKey().SerializeCompressed())
			witness, e2 := btcutil.NewAddressWitnessPubKeyHash(publicHash, params)
			if e2 != nil {
				return response{}, e2
			}
			redeem, e2 := txscript.PayToAddrScript(witness)
			if e2 != nil {
				return response{}, e2
			}
			tx.TxIn[i].SignatureScript, e = txscript.NewScriptBuilder().AddData(redeem).Script()
			if e == nil {
				tx.TxIn[i].Witness, e = txscript.WitnessSignature(tx, hashes, i, previous.Value, redeem, txscript.SigHashAll, secret, true)
			}
		case "taproot":
			tx.TxIn[i].Witness, e = txscript.TaprootWitnessSignature(tx, hashes, i, previous.Value, previous.PkScript, txscript.SigHashDefault, secret)
		}
		if e != nil {
			return response{}, e
		}
		engine, e2 := txscript.NewEngine(previous.PkScript, tx, i, txscript.StandardVerifyFlags, nil, hashes, previous.Value, fetcher)
		if e2 != nil {
			return response{}, e2
		}
		if e2 = engine.Execute(); e2 != nil {
			return response{}, e2
		}
	}
	var signed bytes.Buffer
	if e = tx.Serialize(&signed); e != nil {
		return response{}, e
	}
	return response{Unsigned: unsignedHex, Signed: hex.EncodeToString(signed.Bytes()), Hash: tx.TxHash().String(), Valid: true}, nil
}
