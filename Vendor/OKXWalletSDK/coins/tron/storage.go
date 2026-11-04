package tron

import "math/big"

type Transaction struct {
	Nonce        *big.Int `json:"nonce"`
	GasLimit     *big.Int `json:"gasLimit"`
	GasPrice     *big.Int `json:"gasPrice"`
	From         string   `json:"from"`
	To           string   `json:"to"`
	Value        *big.Int `json:"value"`
	Data         []byte   `json:"data"`
	Fee          *big.Int `json:"fee"`
	PermissionId string   `json:"permission_id"`
}

type TronTransaction struct {
	Transaction
	RefBlockBytes string   `json:"ref_block_bytes"`
	RefBlockHash  string   `json:"ref_block_hash"`
	RefBlockNum   *big.Int `json:"ref_block_number"`
	Timestamp     *big.Int `json:"timestamp"`
	Expiration    *big.Int `json:"expiration"`
}

type TronTokenTransaction struct {
	TronTransaction
	AssetName       string `json:"asset"`
	ContractAddress string `json:"contractAddress"`
	FeeLimit        int64  `json:"feelimit"`
	Trc             string `json:"trc"`
}
