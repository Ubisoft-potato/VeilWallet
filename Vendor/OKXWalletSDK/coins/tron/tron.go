package tron

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"math/big"
	"strconv"
	"strings"

	"github.com/aperturerobotics/protobuf-go-lite/types/known/anypb"
	"github.com/okx/go-wallet-sdk/coins/tron/pb"
	"github.com/okx/go-wallet-sdk/crypto/base58"
	"github.com/okx/go-wallet-sdk/crypto/btcd/btcec"
	"github.com/okx/go-wallet-sdk/util"
	"github.com/okx/go-wallet-sdk/coins/tron/encoder"
	"github.com/okx/go-wallet-sdk/crypto/vrf/utils"
	"golang.org/x/crypto/sha3"
)

func GetAddress(publicKey *btcec.PublicKey) string {
	pubKey := publicKey.SerializeUncompressed()
	h := sha3.NewLegacyKeccak256()
	h.Write(pubKey[1:])
	hash := h.Sum(nil)[12:]
	return base58.CheckEncode(hash, GetNetWork()[0])
}

// GetAddressByPublicKey generate address method based on public key
func GetAddressByPublicKey(pubKey string) (string, error) {
	pubKeyByte, err := hex.DecodeString(pubKey)
	if err != nil {
		return "", fmt.Errorf("failed to parse public key")
	}

	pk, err := btcec.ParsePubKey(pubKeyByte, btcec.S256())
	uncompressedPubKey := pk.SerializeUncompressed()
	if err != nil {
		return "", fmt.Errorf("pubKey encoding err ")
	}

	h := sha3.NewLegacyKeccak256()
	h.Write(uncompressedPubKey[1:])
	hash := h.Sum(nil)[12:]
	return base58.CheckEncode(hash, GetNetWork()[0]), nil
}

func ValidateAddress(address string) bool {
	_, v, err := base58.CheckDecode(address)
	return err == nil && v == GetNetWork()[0] && len(address) == 34
}

func ValidateContractAddress(address string) bool {
	if v, err := strconv.ParseInt(address, 10, 64); err == nil && v > 0 {
		return true
	}
	_, v, err := base58.CheckDecode(address)
	return err == nil && v == GetNetWork()[0] && len(address) == 34
}

func GetAddressHash(address string) ([]byte, error) {
	to, v, err := base58.CheckDecode(address)
	if err != nil {
		return nil, err
	}
	var bs []byte
	bs = append(bs, v)
	bs = append(bs, to...)
	return bs, nil
}

func GetNetWork() []byte {
	return []byte{0x41}
}

type TxParamTron struct {
	FromAddress     string   `json:"fromAddress"`
	ToAddress       string   `json:"toAddress"`
	Amount          *big.Int `json:"amount"`
	RefBlockBytes   string   `json:"refBlockBytes"`
	RefBlockHash    string   `json:"refBlockHash"`
	Expiration      int64    `json:"expiration"`
	Timestamp       int64    `json:"timestamp"`
	PermissionId    int32    `json:"permissionId"`
	AssetName       string   `json:"assetName"`
	ContractAddress string   `json:"contractAddress"`
	FeeLimit        int64    `json:"feeLimit"`
	Method          string   `json:"method"`
	Trc             string   `json:"trc"`
}

const errTxParamRequired = "txParam is required"

func GenTrxTransferTx(txParam *TxParamTron) (*pb.Transaction, error) {
	if txParam == nil {
		return nil, fmt.Errorf(errTxParamRequired)
	}
	if txParam.RefBlockBytes == "" || txParam.RefBlockHash == "" {
		return nil, fmt.Errorf("json error")
	}
	valid := ValidateAddress(txParam.FromAddress)
	if !valid {
		return nil, fmt.Errorf("invalid from address")
	}
	owner, err := GetAddressHash(txParam.FromAddress)
	if err != nil {
		return nil, err
	}
	valid = ValidateAddress(txParam.ToAddress)
	if !valid {
		return nil, fmt.Errorf("invalid to address")
	}
	to, err := GetAddressHash(txParam.ToAddress)
	if err != nil {
		return nil, err
	}
	transferContract := &pb.TransferContract{OwnerAddress: owner, ToAddress: to, Amount: txParam.Amount.Int64()}
	param, err := anypb.New(transferContract, TypeURLTransferContract)
	if err != nil {
		return nil, err
	}
	contract := &pb.Transaction_Contract{Type: pb.Transaction_Contract_TransferContract, Parameter: param, PermissionId: txParam.PermissionId}
	raw := new(pb.TransactionRaw)
	raw.RefBlockBytes, err = hex.DecodeString(txParam.RefBlockBytes)
	if err != nil {
		return nil, err
	}
	raw.RefBlockHash, err = hex.DecodeString(txParam.RefBlockHash)
	if err != nil {
		return nil, err
	}
	raw.Expiration = txParam.Expiration
	raw.Timestamp = txParam.Timestamp
	raw.Contract = []*pb.Transaction_Contract{contract}
	return &pb.Transaction{RawData: raw}, nil

}

func SignTx(privateKey string, trans *pb.Transaction) (string, error) {
	rawData, err := trans.GetRawData().MarshalVT()
	if err != nil {
		return "", err
	}
	hash := CalSigHash(rawData)
	contractList := trans.GetRawData().GetContract()

	prvBytes, err := hex.DecodeString(privateKey)
	if err != nil {
		return "", err
	}
	prvKey, _ := btcec.PrivKeyFromBytes(btcec.S256(), prvBytes)

	for range contractList {
		var sig []byte
		signature, err := btcec.SignCompact(btcec.S256(), prvKey, hash, false)
		if err != nil {
			return "", err
		}
		sig = append(sig, signature[1:33]...)
		sig = append(sig, signature[33:65]...)
		sig = append(sig, signature[0]-27)
		trans.Signature = append(trans.Signature, sig)
	}
	bytes, err := trans.MarshalVT()
	if err != nil {
		return "", err
	}
	return hex.EncodeToString(bytes), nil
}

func SignTransfer(privateKey string, txParam *TxParamTron) (string, error) {
	if txParam == nil {
		return "", fmt.Errorf(errTxParamRequired)
	}
	trans, err := GenTrxTransferTx(txParam)
	if err != nil {
		return "", err
	}
	return SignTx(privateKey, trans)
}

func GenTokenTransferTx(txParam *TxParamTron) (*pb.Transaction, error) {
	if txParam == nil {
		return nil, fmt.Errorf(errTxParamRequired)
	}
	if txParam.RefBlockBytes == "" || txParam.RefBlockHash == "" {
		return nil, fmt.Errorf("json error")
	}
	raw := new(pb.TransactionRaw)
	refBytes, err := hex.DecodeString(txParam.RefBlockBytes)
	if err != nil {
		return nil, err
	}
	raw.RefBlockBytes = refBytes
	refHash, err := hex.DecodeString(txParam.RefBlockHash)
	if err != nil {
		return nil, err
	}
	raw.RefBlockHash = refHash
	raw.Expiration = txParam.Expiration
	raw.Timestamp = txParam.Timestamp
	var contract *pb.Transaction_Contract
	valid := ValidateAddress(txParam.FromAddress)
	if !valid {
		return nil, fmt.Errorf("invalid from address")
	}
	owner, err := GetAddressHash(txParam.FromAddress)
	if err != nil {
		return nil, err
	}
	valid = ValidateAddress(txParam.ToAddress)
	if !valid {
		return nil, fmt.Errorf("invalid to address")
	}
	to, err := GetAddressHash(txParam.ToAddress)
	if err != nil {
		return nil, err
	}
	if txParam.Trc == "10" {
		// trc10
		transferContract := &pb.TransferAssetContract{OwnerAddress: owner, ToAddress: to, Amount: txParam.Amount.Int64(), AssetName: []byte(txParam.AssetName)}
		param, err := anypb.New(transferContract, TypeURLTransferAssetContract)
		if err != nil {
			return nil, err
		}
		contract = &pb.Transaction_Contract{Type: pb.Transaction_Contract_TransferAssetContract, Parameter: param, PermissionId: txParam.PermissionId}
	} else {
		// trc20
		var input []byte
		der := encoder.NewEncoder(true)
		der.Padding(32 - len(to))
		der.WriteBytes(to)

		amount := txParam.Amount.Bytes()
		der.Padding(32 - len(amount))
		der.WriteBytes(amount)
		args := der.GetBytes()

		transferMethod := "transfer(address,uint256)"

		h := sha3.NewLegacyKeccak256()
		h.Write([]byte(transferMethod))
		selector := h.Sum(nil)[0:4]
		input = append(input, selector...)
		input = append(input, args...)

		valid = ValidateContractAddress(txParam.ContractAddress)
		if !valid {
			return nil, fmt.Errorf("invalid contract address")
		}
		contractAddr, err := GetAddressHash(txParam.ContractAddress)
		if err != nil {
			return nil, err
		}
		transferContract := &pb.TriggerSmartContract{OwnerAddress: owner, ContractAddress: contractAddr, CallValue: 0, CallTokenValue: 0, Data: input}
		param, err := anypb.New(transferContract, TypeURLTriggerSmartContract)
		if err != nil {
			return nil, err
		}
		contract = &pb.Transaction_Contract{Type: pb.Transaction_Contract_TriggerSmartContract, Parameter: param, PermissionId: txParam.PermissionId}
		raw.FeeLimit = txParam.FeeLimit
	}

	raw.Contract = []*pb.Transaction_Contract{contract}
	return &pb.Transaction{RawData: raw}, nil
}

func SignTokenTransfer(privateKey string, txParam *TxParamTron) (string, error) {
	if txParam == nil {
		return "", fmt.Errorf(errTxParamRequired)
	}
	trans, err := GenTokenTransferTx(txParam)
	if err != nil {
		return "", err
	}
	return SignTx(privateKey, trans)
}

func GenContractTx(txParam *TxParamTron) (*pb.Transaction, error) {
	if txParam == nil {
		return nil, fmt.Errorf(errTxParamRequired)
	}
	if txParam.RefBlockBytes == "" || txParam.RefBlockHash == "" {
		return nil, fmt.Errorf("json error")
	}
	raw := new(pb.TransactionRaw)
	refBytes, err := hex.DecodeString(txParam.RefBlockBytes)
	if err != nil {
		return nil, err
	}
	raw.RefBlockBytes = refBytes
	refHash, err := hex.DecodeString(txParam.RefBlockHash)
	if err != nil {
		return nil, err
	}
	raw.RefBlockHash = refHash
	raw.Expiration = txParam.Expiration
	raw.Timestamp = txParam.Timestamp

	var contract *pb.Transaction_Contract
	valid := ValidateAddress(txParam.FromAddress)
	if !valid {
		return nil, fmt.Errorf("invalid from address")
	}
	owner, err := GetAddressHash(txParam.FromAddress)
	if err != nil {
		return nil, err
	}
	valid = ValidateAddress(txParam.ToAddress)
	if !valid {
		return nil, fmt.Errorf("invalid to address")
	}
	to, err := GetAddressHash(txParam.ToAddress)
	if err != nil {
		return nil, err
	}

	var input []byte
	der := encoder.NewEncoder(true)
	der.Padding(32 - len(to))
	der.WriteBytes(to)

	amount := txParam.Amount.Bytes()
	der.Padding(32 - len(amount))
	der.WriteBytes(amount)
	args := der.GetBytes()

	transferMethod := txParam.Method
	h := sha3.NewLegacyKeccak256()
	h.Write([]byte(transferMethod))
	selector := h.Sum(nil)[0:4]
	input = append(input, selector...)
	input = append(input, args...)

	valid = ValidateContractAddress(txParam.ContractAddress)
	if !valid {
		return nil, fmt.Errorf("invalid contract address")
	}
	contractAddr, err := GetAddressHash(txParam.ContractAddress)
	if err != nil {
		return nil, err
	}
	transferContract := &pb.TriggerSmartContract{OwnerAddress: owner, ContractAddress: contractAddr, CallValue: 0, CallTokenValue: 0, Data: input}
	param, err := anypb.New(transferContract, TypeURLTriggerSmartContract)
	if err != nil {
		return nil, err
	}
	contract = &pb.Transaction_Contract{Type: pb.Transaction_Contract_TriggerSmartContract, Parameter: param, PermissionId: txParam.PermissionId}
	raw.FeeLimit = txParam.FeeLimit

	raw.Contract = []*pb.Transaction_Contract{contract}
	return &pb.Transaction{RawData: raw}, nil
}

func SignContractTx(privateKey string, txParam *TxParamTron) (string, error) {
	if txParam == nil {
		return "", fmt.Errorf(errTxParamRequired)
	}
	trans, err := GenContractTx(txParam)
	if err != nil {
		return "", err
	}
	return SignTx(privateKey, trans)
}

func CalSigHash(rawData []byte) []byte {
	s256 := sha256.New()
	s256.Write(rawData)
	return s256.Sum(nil)
}

func CalTxHash(rawTx string) string {
	rawTxBytes, err := hex.DecodeString(rawTx)
	if err != nil {
		return ""
	}
	var tx pb.Transaction
	err = tx.UnmarshalVT(rawTxBytes)
	if err != nil {
		return ""
	}
	rawData, err := tx.GetRawData().MarshalVT()
	if err != nil {
		return ""
	}
	s256 := sha256.New()
	s256.Write(rawData)
	hash := s256.Sum(nil)
	return hex.EncodeToString(hash)
}

func DecodeTx(rawTx string) (string, error) {
	bytes, err := hex.DecodeString(rawTx)
	if err != nil {
		return "", err
	}
	var tx pb.Transaction

	err = tx.UnmarshalVT(bytes)
	if err != nil {
		return "", err
	}

	txData := make(map[string]interface{})
	rawData := make(map[string]interface{})
	rawData["ref_block_bytes"] = hex.EncodeToString(tx.RawData.RefBlockBytes)
	rawData["ref_block_hash"] = hex.EncodeToString(tx.RawData.RefBlockHash)
	rawData["ref_block_number"] = tx.RawData.RefBlockNum
	rawData["timestamp"] = tx.RawData.Timestamp
	rawData["expiration"] = tx.RawData.Expiration
	txData["raw_data"] = rawData
	var contracts []interface{}
	for _, value := range tx.RawData.Contract {
		contract := make(map[string]interface{})
		contract["type"] = value.Type
		parameter := make(map[string]interface{})
		parameter["type_url"] = value.Parameter.TypeUrl
		parameter["value"] = hex.EncodeToString(value.Parameter.Value)
		contract["parameter"] = parameter
		contract["permission_id"] = value.PermissionId
		contracts = append(contracts, contract)
	}
	txData["contract"] = contracts
	var signature []string
	for _, v := range tx.Signature {
		signature = append(signature, hex.EncodeToString(v))
	}
	txData["signature"] = signature

	b, err := json.Marshal(&txData)
	if err != nil {
		return "", err
	}

	return string(b), nil
}

func GetMessageHash(data []byte, addPrefix bool) []byte {
	if addPrefix {
		msg := fmt.Sprintf("\x19TRON Signed Message:\n%d%s", len(data), data)
		s := sha3.NewLegacyKeccak256()
		s.Write([]byte(msg))
		return s.Sum(nil)
	}
	return data
}

func GetMessageHashV1(data []byte, useTronHeader bool) []byte {
	header := "\x19TRON Signed Message:\n32"
	if !useTronHeader {
		header = "\x19Ethereum Signed Message:\n32"
	}
	msg := append([]byte(header), data...)
	s := sha3.NewLegacyKeccak256()
	s.Write(msg)
	return s.Sum(nil)
}

func TypedMessageHash(message string, addPrefix bool, version int) []byte {
	if version == 2 {
		return GetMessageHash([]byte(message), addPrefix)
	}
	return GetMessageHashV1(util.RemoveZeroHex(message), addPrefix)
}

func SignMessage(message string, privateKey string) (string, error) {
	return SignTypedMessage(message, privateKey, true, 2)
}

func SignTypedMessage(message string, privateKey string, addPrefix bool, version int) (string, error) {
	hash := TypedMessageHash(message, true, 2)
	prvBytes, err := hex.DecodeString(privateKey)
	if err != nil {
		return "", err
	}
	prvKey, _ := btcec.PrivKeyFromBytes(btcec.S256(), prvBytes)

	var sig []byte
	signature, err := btcec.SignCompact(btcec.S256(), prvKey, hash, false)
	if err != nil {
		return "", err
	}

	sig = append(sig, signature[1:33]...)
	sig = append(sig, signature[33:65]...)
	sig = append(sig, signature[0])

	return hex.EncodeToString(sig), nil
}

func VerifyMessage(message string, publicKey string, signature string) error {
	msg := []byte(fmt.Sprintf("\x19TRON Signed Message:\n%d%s", len(message), message))
	hash, err := utils.Keccak256(msg)
	if err != nil {
		return err
	}
	sigTemp, err := hex.DecodeString(strings.TrimPrefix(signature, "0x"))
	if err != nil {
		return err
	}

	var sig []byte
	sig = append(sig, sigTemp[64])
	sig = append(sig, sigTemp[:32]...)
	sig = append(sig, sigTemp[32:64]...)
	pubKey, _, err := btcec.RecoverCompact(btcec.S256(), sig, hash)
	if err != nil {
		return err
	}

	compressedPubKey := hex.EncodeToString(pubKey.SerializeCompressed())
	uncompressedPubKey := hex.EncodeToString(pubKey.SerializeUncompressed())

	if compressedPubKey != publicKey && uncompressedPubKey != publicKey {
		return errors.New("invalid signature")
	}
	return nil
}

func VerifyMessageWithAddress(message, address, signature string) error {
	msg := []byte(fmt.Sprintf("\x19TRON Signed Message:\n%d%s", len(message), message))
	hash, err := utils.Keccak256(msg)
	if err != nil {
		return err
	}
	sigTemp, err := hex.DecodeString(strings.TrimPrefix(signature, "0x"))
	if err != nil {
		return err
	}

	sig := append([]byte{sigTemp[64]}, sigTemp[:64]...)
	pubKey, _, err := btcec.RecoverCompact(btcec.S256(), sig, hash)
	if err != nil {
		return err
	}

	signer, err := GetAddressByPublicKey(hex.EncodeToString(pubKey.SerializeUncompressed()))
	if err != nil {
		return err
	}

	if signer != address {
		return errors.New("invalid signature")
	}
	return nil
}

func VerifyMessageV1(message, address, signature string, useTronHeader bool) error {
	msg, err := hex.DecodeString(strings.TrimPrefix(message, "0x"))
	if err != nil {
		return err
	}
	header := "\x19Ethereum Signed Message:\n32"
	if useTronHeader {
		header = "\x19TRON Signed Message:\n32"
	}
	msg = append([]byte(header), msg...)

	hash, err := utils.Keccak256(msg)
	if err != nil {
		return err
	}
	sigTemp, err := hex.DecodeString(strings.TrimPrefix(signature, "0x"))
	if err != nil {
		return err
	}

	sig := append([]byte{sigTemp[64]}, sigTemp[:64]...)
	pubKey, _, err := btcec.RecoverCompact(btcec.S256(), sig, hash)
	if err != nil {
		return err
	}

	signer, err := GetAddressByPublicKey(hex.EncodeToString(pubKey.SerializeUncompressed()))
	if err != nil {
		return err
	}

	if signer != address {
		return errors.New("invalid signature")
	}
	return nil
}
