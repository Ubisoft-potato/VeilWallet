# tron-sdk

Tron SDK is used to interact with the Tron blockchain, it contains various functions that can be used for web3 wallet.

## Installation

### go get

To obtain the latest version, simply require the project using :

```shell
go get -u github.com/okx/go-wallet-sdk/coins/tron
```

## Usage

### New Address

```golang
    publicKey := "0350b3a55428393c092908fa6cdbfdfe0a10645f5940f94380358afb649d0a18fa"
    address, err := tron.GetAddressByPublicKey(publicKey)
    if err != nil {
        // todo
        fmt.Println(err)
    }
    fmt.Println(address)
```

### Validate Address

```golang
    ok := tron.ValidateAddress("TQhLxrmHdV1VdeqP8LXD9A1FuiWeYkbMgD")
    fmt.Println(ok)
```

### TRX Transfer

```golang
    prvKey := "8185ae198672f631cf1d2c9447404353ff4597eff0603134d73918594f7424b4"
    param := &tron.TxParamTron{
        FromAddress:   "TBfuSMyuVWQpfLQaGM7KpzTDHiHaLqrNCo",
        ToAddress:     "TVxeeiqU1KbQK84vA9qyhdSpDsf7K4m51X",
        Amount:        big.NewInt(100000),
        RefBlockBytes: "d08f",
        RefBlockHash:  "05dddb27424fd260",
        Expiration:    1545116409000,
        Timestamp:     1545112908947,
    }
    signedTx, err := tron.SignTransfer(prvKey, param)
    if err != nil {
        // todo
    }
    fmt.Println(signedTx)
```

### TRC-20 Transfer

```golang
    prvKey := "..."
    param := &tron.TxParamTron{
        FromAddress:     "TBfuSMyuVWQpfLQaGM7KpzTDHiHaLqrNCo",
        ToAddress:       "TVxeeiqU1KbQK84vA9qyhdSpDsf7K4m51X",
        Amount:          big.NewInt(1000000), // smallest unit
        ContractAddress: "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t",
        FeeLimit:        100000000,
        RefBlockBytes:   "d08f",
        RefBlockHash:    "05dddb27424fd260",
        Expiration:      1545116409000,
        Timestamp:       1545112908947,
    }
    signedTx, err := tron.SignTokenTransfer(prvKey, param)
    if err != nil {
        // todo
    }
    fmt.Println(signedTx)
```

### Sign Message

```golang
    prvKey := "..."
    sig, err := tron.SignMessage("hello world", prvKey)
    if err != nil {
        // todo
    }
    fmt.Println(sig)
```

### Verify Message

```golang
    err := tron.VerifyMessage("hello world", publicKey, signature)
    if err != nil {
        // bad signature
    }
```

## Notes

- The SDK is offline-only. `RefBlockBytes`, `RefBlockHash`, `Expiration`,
  `Timestamp` and `FeeLimit` must be supplied by the caller using values from
  a Tron node it intends to broadcast against.
