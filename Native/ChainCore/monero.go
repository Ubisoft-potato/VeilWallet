package main

import (
	"bytes"
	_ "embed"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"filippo.io/edwards25519"
	"github.com/okx/go-wallet-sdk/crypto/base58"
	"golang.org/x/crypto/sha3"
	"hash/crc32"
	"math/big"
	"strings"
)

//go:embed monero-english.txt
var moneroEnglish string

func moneroHash(b []byte) []byte { h := sha3.NewLegacyKeccak256(); h.Write(b); return h.Sum(nil) }
func moneroReduce(b []byte) (*edwards25519.Scalar, error) {
	if len(b) != 32 {
		return nil, errors.New("key size")
	}
	uniform := make([]byte, 64)
	copy(uniform, b)
	return new(edwards25519.Scalar).SetUniformBytes(uniform)
}
func moneroKey(text string) (*edwards25519.Scalar, error) {
	if len(strings.Fields(text)) == 25 {
		words := strings.Fields(strings.ToLower(text))
		list := strings.Fields(moneroEnglish)
		indices := map[string]uint32{}
		for i, w := range list {
			indices[w] = uint32(i)
		}
		prefixes := ""
		for _, w := range words[:24] {
			if _, ok := indices[w]; !ok {
				return nil, errors.New("seed word")
			}
			prefixes += w[:3]
		}
		if words[crc32.ChecksumIEEE([]byte(prefixes))%24] != words[24] {
			return nil, errors.New("seed checksum")
		}
		key := make([]byte, 32)
		const n uint64 = 1626
		for i := 0; i < 8; i++ {
			a := uint64(indices[words[i*3]])
			b := uint64(indices[words[i*3+1]])
			c := uint64(indices[words[i*3+2]])
			v := a + n*((b+n-a)%n) + n*n*((c+n-b)%n)
			if v > 0xffffffff || v%n != a {
				return nil, errors.New("seed range")
			}
			binary.LittleEndian.PutUint32(key[i*4:], uint32(v))
		}
		return new(edwards25519.Scalar).SetCanonicalBytes(key)
	}
	key, err := hex.DecodeString(strings.TrimPrefix(text, "0x"))
	if err != nil || len(key) != 32 {
		return nil, errors.New("key encoding")
	}
	return new(edwards25519.Scalar).SetCanonicalBytes(key)
}
func moneroAddress(key *edwards25519.Scalar) (response, error) {
	if bytes.Equal(key.Bytes(), make([]byte, 32)) {
		return response{}, errors.New("zero key")
	}
	view, err := moneroReduce(moneroHash(key.Bytes()))
	if err != nil {
		return response{}, err
	}
	spendPub := new(edwards25519.Point).ScalarBaseMult(key).Bytes()
	viewPub := new(edwards25519.Point).ScalarBaseMult(view).Bytes()
	raw := append([]byte{18}, spendPub...)
	raw = append(raw, viewPub...)
	raw = append(raw, moneroHash(raw)[:4]...)
	return response{Address: moneroEncode(raw), Key: hex.EncodeToString(key.Bytes()), ViewKey: hex.EncodeToString(view.Bytes()), Valid: true}, nil
}

var moneroBlockSizes = []int{0, 2, 3, 5, 6, 7, 9, 10, 11}

func moneroEncode(raw []byte) string {
	var output strings.Builder
	for len(raw) > 0 {
		size := 8
		if len(raw) < size {
			size = len(raw)
		}
		part := raw[:size]
		encoded := base58.Encode(part)
		output.WriteString(strings.Repeat("1", max(0, moneroBlockSizes[size]-len(encoded))))
		output.WriteString(encoded)
		raw = raw[size:]
	}
	return output.String()
}
func moneroDecode(text string) ([]byte, error) {
	if len(text) != 95 && len(text) != 106 {
		return nil, errors.New("address size")
	}
	var out []byte
	for len(text) > 0 {
		size := 11
		if len(text) < size {
			size = len(text)
		}
		decodedSize := -1
		for i, n := range moneroBlockSizes {
			if n == size {
				decodedSize = i
			}
		}
		if decodedSize < 1 {
			return nil, errors.New("base58 size")
		}
		block := text[:size]
		value := new(big.Int)
		const alphabet = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
		for _, c := range block {
			digit := strings.IndexRune(alphabet, c)
			if digit < 0 {
				return nil, errors.New("base58 digit")
			}
			value.Mul(value, big.NewInt(58))
			value.Add(value, big.NewInt(int64(digit)))
		}
		raw := value.Bytes()
		if len(raw) > decodedSize {
			return nil, errors.New("base58 overflow")
		}
		padded := make([]byte, decodedSize)
		copy(padded[decodedSize-len(raw):], raw)
		out = append(out, padded...)
		text = text[size:]
	}
	return out, nil
}
func moneroValidate(text string) bool {
	raw, err := moneroDecode(text)
	if err != nil || len(raw) != 69 && len(raw) != 77 || moneroEncode(raw) != text {
		return false
	}
	if !((len(raw) == 69 && (raw[0] == 18 || raw[0] == 42)) || (len(raw) == 77 && raw[0] == 19)) || !bytes.Equal(moneroHash(raw[:len(raw)-4])[:4], raw[len(raw)-4:]) {
		return false
	}
	for _, b := range [][]byte{raw[1:33], raw[33:65]} {
		p, err := new(edwards25519.Point).SetBytes(b)
		if err != nil || !bytes.Equal(p.Bytes(), b) || new(edwards25519.Point).MultByCofactor(p).Equal(edwards25519.NewIdentityPoint()) == 1 {
			return false
		}
	}
	return true
}
