package main

import (
	"bytes"
	"encoding/hex"
	"errors"
	"github.com/btcsuite/btcd/txscript"
	"github.com/btcsuite/btcd/wire"
	"strconv"
)

// Parse and validate an already signed local transaction with the same pinned
// btcd engine used for signing. No new crypto and no network / filesystem I/O.
func inspectUTXO(req request) (response, error) {
	if req.Family != "bitcoin" && req.Family != "litecoin" || req.Transfer == nil {
		return response{}, errors.New("UTXO archive type")
	}
	raw, err := hex.DecodeString(req.SignedTransaction)
	if err != nil || len(raw) > 1_000_000 {
		return response{}, errors.New("signed encoding")
	}
	signed := wire.NewMsgTx(2)
	reader := bytes.NewReader(raw)
	if signed.Deserialize(reader) != nil || reader.Len() != 0 {
		return response{}, errors.New("signed structure")
	}
	buildRequest := req
	buildRequest.Action = "transferBuild"
	buildRequest.Key = ""
	expected, err := nativeTransfer(buildRequest)
	if err != nil {
		return response{}, err
	}
	stripped := signed.Copy()
	for _, input := range stripped.TxIn {
		input.SignatureScript = nil
		input.Witness = nil
	}
	var unsigned bytes.Buffer
	if stripped.Serialize(&unsigned) != nil || hex.EncodeToString(unsigned.Bytes()) != expected.Unsigned {
		return response{}, errors.New("signed intent mismatch")
	}
	if len(signed.TxIn) != len(req.Transfer.Inputs) {
		return response{}, errors.New("input mismatch")
	}
	fetcher := txscript.NewMultiPrevOutFetcher(nil)
	for i, input := range req.Transfer.Inputs {
		previousRaw, err := hex.DecodeString(input.Previous)
		previous := wire.NewMsgTx(2)
		if err != nil || previous.Deserialize(bytes.NewReader(previousRaw)) != nil || int(input.Index) >= len(previous.TxOut) {
			return response{}, errors.New("previous output")
		}
		fetcher.AddPrevOut(signed.TxIn[i].PreviousOutPoint, previous.TxOut[input.Index])
	}
	hashes := txscript.NewTxSigHashes(signed, fetcher)
	for i, input := range signed.TxIn {
		output := fetcher.FetchPrevOutput(input.PreviousOutPoint)
		engine, err := txscript.NewEngine(output.PkScript, signed, i, txscript.StandardVerifyFlags, nil, hashes, output.Value, fetcher)
		if err != nil {
			return response{}, err
		}
		if err = engine.Execute(); err != nil {
			return response{}, err
		}
	}
	weight := signed.SerializeSizeStripped()*3 + signed.SerializeSize()
	return response{Valid: true, Hash: signed.TxHash().String(), Unsigned: expected.Unsigned, VirtualSize: strconv.Itoa((weight + 3) / 4)}, nil
}
