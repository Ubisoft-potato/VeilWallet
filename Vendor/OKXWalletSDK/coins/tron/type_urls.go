package tron

// Tron protobuf type URLs for google.protobuf.Any
//
// These must match the original Tron protocol package name ("protocol")
// for wire-format compatibility with the Tron blockchain.
//
// Since we use protobuf-go-lite (reflection-free), these URLs must be
// explicitly provided when creating Any messages. The old implementation
// using github.com/golang/protobuf/ptypes derived these automatically
// via reflection.
//
// Source: Tron Protocol Buffers definitions
//   - Repository: https://github.com/tronprotocol/protocol
//   - Package declaration: "package protocol;" in .proto files
//   - TransferContract: core/contract/balance_contract.proto
//   - TransferAssetContract: core/contract/asset_issue_contract.proto
//   - TriggerSmartContract: core/contract/smart_contract.proto
const (
	TypeURLTransferContract      = "type.googleapis.com/protocol.TransferContract"
	TypeURLTransferAssetContract = "type.googleapis.com/protocol.TransferAssetContract"
	TypeURLTriggerSmartContract  = "type.googleapis.com/protocol.TriggerSmartContract"
)
