package tron

import (
	"encoding/hex"
	"math/big"
	"testing"

	"github.com/stretchr/testify/assert"

	"github.com/okx/go-wallet-sdk/crypto/btcd/btcec"
)

// prvKeyHex2PubKeyHex inlines bitcoin.PrvKeyHex2PubKeyHex to avoid a
// transitive dependency on coins/bitcoin from this test.
func prvKeyHex2PubKeyHex(priKey string) (string, error) {
	p, err := hex.DecodeString(priKey)
	if err != nil {
		return "", err
	}
	_, publicKey := btcec.PrivKeyFromBytes(btcec.S256(), p)
	return hex.EncodeToString(publicKey.SerializeCompressed()), nil
}

func TestTron_Address(t *testing.T) {
	trxAddress := "TNrEPvnnX7Hwj1z6tb1aTXpMad7z4BxoNW"
	ret := ValidateAddress(trxAddress)
	assert.True(t, ret)

	ah, err := GetAddressHash("TGpKmWjRRQLuMn2G2PX5yCWJ9HfVsawJjY")
	assert.NoError(t, err)
	assert.Equal(t, "414b1ac901c1e39c904d5f4eaca40e6362357abcdb", hex.EncodeToString(ah))

	_, err = GetAddressHash("")
	assert.Error(t, err)
}

func TestTron_NewAddr(t *testing.T) {
	pub := "0350b3a55428393c092908fa6cdbfdfe0a10645f5940f94380358afb649d0a18fa"
	ret, err := GetAddressByPublicKey(pub)
	if err != nil {
		t.Fatal(err)
	}
	assert.Equal(t, "TQhLxrmHdV1VdeqP8LXD9A1FuiWeYkbMgD", ret)
}

func TestSignTransfer(t *testing.T) {
	prvKey := "8185ae198672f631cf1d2c9447404353ff4597eff0603134d73918594f7424b4"
	fromAddress := "TBfuSMyuVWQpfLQaGM7KpzTDHiHaLqrNCo"
	toAddress := "TVxeeiqU1KbQK84vA9qyhdSpDsf7K4m51X"
	amount := big.NewInt(100000)

	refBlockHash := "05dddb27424fd260"
	refBlockBytes := "d08f"
	timestamp := int64(1545112908947)
	expiration := int64(1545116409000)
	permissionId := int32(0)

	signedTx, _ := SignTransfer(prvKey, &TxParamTron{FromAddress: fromAddress, ToAddress: toAddress, Amount: amount, RefBlockBytes: refBlockBytes, RefBlockHash: refBlockHash, Expiration: expiration, Timestamp: timestamp, PermissionId: permissionId})
	expected := `0a85010a02d08f220805dddb27424fd26040a8b9f580fc2c5a67080112630a2d747970652e676f6f676c65617069732e636f6d2f70726f746f636f6c2e5472616e73666572436f6e747261637412320a154112aa84ccf290f271c1528f3fd7be15f95069a56a121541db4782bedabefc077234797ee55f644d4e185acd18a08d067093e99ffffb2c124134dd392afa3a2daad1662e19559653a624f682da763b6204100df902d763d54b3bc27669148142755867f88b663aa0ee2349b617617867e1f61ab01ac11aee2200`
	assert.Equal(t, expected, signedTx)
}

func TestSignTransfer2(t *testing.T) {
	prvKey := "8185ae198672f631cf1d2c9447404353ff4597eff0603134d73918594f7424b4"
	fromAddress := "TBfuSMyuVWQpfLQaGM7KpzTDHiHaLqrNCo"
	toAddress := "TVxeeiqU1KbQK84vA9qyhdSpDsf7K4m51X"
	amount := big.NewInt(100000)

	//"0000000002ee165a7e35c0cac02612ac1a16068a35198d229faedf4443bb4cf6"
	//"05dddb27424fd260"
	refBlockHash := "0000000002ee165a"
	refBlockBytes := "49157722"

	timestamp := int64(1738649852)
	expiration := timestamp + 20
	permissionId := int32(0)

	signedTx, _ := SignTransfer(prvKey, &TxParamTron{FromAddress: fromAddress, ToAddress: toAddress, Amount: amount, RefBlockBytes: refBlockBytes, RefBlockHash: refBlockHash, Expiration: expiration, Timestamp: timestamp, PermissionId: permissionId})

	expected := `0a85010a044915772222080000000002ee165a4090e286bd065a67080112630a2d747970652e676f6f676c65617069732e636f6d2f70726f746f636f6c2e5472616e73666572436f6e747261637412320a154112aa84ccf290f271c1528f3fd7be15f95069a56a121541db4782bedabefc077234797ee55f644d4e185acd18a08d0670fce186bd0612419846466ddefe9c3cdede78a152a314fd8631487aaf19b235f900fd9cc7bd5b2765083767e3671c75e429f12adea158ca81cd3dc84dfdd23573ef88616448860200`
	assert.Equal(t, expected, signedTx)
}

func TestSignTokenTransfer(t *testing.T) {
	prvKey := "8185ae198672f631cf1d2c9447404353ff4597eff0603134d73918594f7424b4"
	fromAddress := "TBfuSMyuVWQpfLQaGM7KpzTDHiHaLqrNCo"
	toAddress := "TKFBEJ4ghdVCb9ixLAqwSqW2PPk5vFk8kS"
	amount := big.NewInt(100)

	refBlockHash := "f91672e92171eaf9"
	refBlockBytes := "655c"
	timestamp := int64(1555588207533)
	expiration := int64(1555591866000)
	permissionId := int32(0)
	trc := "20"
	assetName := "USDT"
	contractAddress := "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t"
	feeLimit := int64(1000000000)
	signedTx, _ := SignTokenTransfer(prvKey, &TxParamTron{fromAddress, toAddress, amount, refBlockBytes, refBlockHash, expiration, timestamp, permissionId, assetName, contractAddress, feeLimit, "", trc})
	expected := `0ad4010a02655c2208f91672e92171eaf94090cd8084a32d5aae01081f12a9010a31747970652e676f6f676c65617069732e636f6d2f70726f746f636f6c2e54726967676572536d617274436f6e747261637412740a154112aa84ccf290f271c1528f3fd7be15f95069a56a121541a614f803b6fd780986a42c78ec9c7f77e6ded13c2244a9059cbb00000000000000000000004165be4ef4e7bbf540b90ade7b11a0342f35fa9b01000000000000000000000000000000000000000000000000000000000000006470ada7a182a32d90018094ebdc0312414f8a5589807ee13be1d7f97eed26a1c4bc3734e21183d0225f2983be6f77922e4e842442af2b111149ae4b37370bb45f76f2509abd22bdcb97703eb25c278a6400`
	assert.Equal(t, expected, signedTx)
}
func TestCalcTxHash(t *testing.T) {
	rawTx := "0ad3010a02e60e220817a154e738ccf87040f8f7d88cfd315aae01081f12a9010a31747970652e676f6f676c65617069732e636f6d2f70726f746f636f6c2e54726967676572536d617274436f6e747261637412740a15413f17f1962b36e491b30a40b2405849e597ba5fb5121541a614f803b6fd780986a42c78ec9c7f77e6ded13c2244a9059cbb000000000000000000000041f0aa501fa48083e8497def7ea5f055d02e30ed1f000000000000000000000000000000000000000000000000000000004a817c8070fad9818bfd319001b891ff191241a214ec091d214e86e7adeb2e4dd6ddde582b40a1389efefbf8c5f46d4b8df13d0660eae5d789d52eec714fd51de8b8012950b7140ab0f652098f0cd8a1f08ad200"
	res := CalTxHash(rawTx)
	expected := `645c735e5ee329d38b8a28df19ce5513f1e0fa808856207bf12cb3b9501361f7`
	assert.Equal(t, expected, res)
}
func TestDecodeTx(t *testing.T) {
	rawTx := "0ad3010a02e60e220817a154e738ccf87040f8f7d88cfd315aae01081f12a9010a31747970652e676f6f676c65617069732e636f6d2f70726f746f636f6c2e54726967676572536d617274436f6e747261637412740a15413f17f1962b36e491b30a40b2405849e597ba5fb5121541a614f803b6fd780986a42c78ec9c7f77e6ded13c2244a9059cbb000000000000000000000041f0aa501fa48083e8497def7ea5f055d02e30ed1f000000000000000000000000000000000000000000000000000000004a817c8070fad9818bfd319001b891ff191241a214ec091d214e86e7adeb2e4dd6ddde582b40a1389efefbf8c5f46d4b8df13d0660eae5d789d52eec714fd51de8b8012950b7140ab0f652098f0cd8a1f08ad200"
	res, _ := DecodeTx(rawTx)
	expected := `{"contract":[{"parameter":{"type_url":"type.googleapis.com/protocol.TriggerSmartContract","value":"0a15413f17f1962b36e491b30a40b2405849e597ba5fb5121541a614f803b6fd780986a42c78ec9c7f77e6ded13c2244a9059cbb000000000000000000000041f0aa501fa48083e8497def7ea5f055d02e30ed1f000000000000000000000000000000000000000000000000000000004a817c80"},"permission_id":0,"type":31}],"raw_data":{"expiration":1717208235000,"ref_block_bytes":"e60e","ref_block_hash":"17a154e738ccf870","ref_block_number":0,"timestamp":1717204708602},"signature":["a214ec091d214e86e7adeb2e4dd6ddde582b40a1389efefbf8c5f46d4b8df13d0660eae5d789d52eec714fd51de8b8012950b7140ab0f652098f0cd8a1f08ad200"]}`
	assert.Equal(t, expected, res)
}

func TestSignMessage(t *testing.T) {
	message := "hello world"
	priKey := "0000000000000000000000000000000000000000000000000000000000000001"
	signature, err := SignMessage(message, priKey)
	assert.NoError(t, err)
	expected := `0dc0b53d525e0103a6013061cf18e60cf158809149f2b8994a545af65a7004cb1eeaff560e801ab51b28df5d42549aa024c2aa7e9d34de1e01294b9afb5e6c7e1c`
	assert.Equal(t, expected, signature)

	publicKey, err := prvKeyHex2PubKeyHex(priKey)
	assert.Equal(t, "0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798", publicKey)

	assert.NoError(t, err)

	err = VerifyMessage(message, publicKey, signature)
	assert.NoError(t, err)
}

func TestSignMessagev1(t *testing.T) {
	//      address: 'TYpnxNvu8QoGJa3RjCKjLGbkD7tMnoncKZ',
	//      publicKey: '04a43f34ca1ab7feec5717172bc918288d0751952c95239f1ccdbf69f40a1b1148f099f9deedc8635b6055af891949aacb2caa0c4773d4b64cad82e3a42171e3ac'
	message := "0x879a053d4800c6354e76c7985a865d2922c82fb5b3f4577b2fe08b998954f2e0"
	address := "TYpnxNvu8QoGJa3RjCKjLGbkD7tMnoncKZ"

	signature := `0x2def53b5dda3cabbf9d681a00bb9ea61b3441d4e5e9812cfce86675b1a68262628aff86a157f6655fcdf8a7fe68eba143eaeb3f188a507933d066767b793754c1c`

	err := VerifyMessageV1(message, address, signature, true)
	assert.NoError(t, err)
}

func TestValidateContractAddress(t *testing.T) {
	assert.True(t, ValidateContractAddress("TXGtp7qXazWXvVSBDWb6D1e4mpsVdKPe1M"))
}
