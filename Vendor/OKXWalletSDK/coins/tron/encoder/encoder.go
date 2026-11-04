package encoder

import (
	"bytes"
	"encoding/binary"
	"math/big"
)

var TypeSize = struct {
	Byte        int
	UInt16      int
	UInt32      int
	UInt64      int
	UInt128     int
	Float32     int
	Float64     int
	Checksum160 int
	Checksum256 int
	Checksum512 int
	Bool        int
}{
	Byte:        1,
	UInt16:      2,
	UInt32:      4,
	UInt64:      8,
	UInt128:     16,
	Float32:     4,
	Float64:     8,
	Checksum160: 20,
	Checksum256: 32,
	Checksum512: 64,
	Bool:        1,
}

const (
	// number of bits in a big.Word
	wordBits = 32 << (uint64(^big.Word(0)) >> 63)
	// number of bytes in a big.Word
	wordBytes = wordBits / 8
)

type Encoder struct {
	buf         *bytes.Buffer
	Order       binary.ByteOrder
	isBigEndian bool //Big endian / Little endian
}

func NewEncoder(isBigEndian bool) *Encoder {
	var order binary.ByteOrder
	if isBigEndian {
		order = binary.BigEndian
	} else {
		order = binary.LittleEndian
	}
	return &Encoder{buf: new(bytes.Buffer), Order: order, isBigEndian: isBigEndian}
}

func (e *Encoder) WriteString(v string) *Encoder {
	e.buf.Write([]byte(v))
	return e
}

func (e *Encoder) WriteInt16(v int16) *Encoder {
	e.WriteUint16(uint16(v))
	return e
}

func (e *Encoder) WriteUint16(v uint16) *Encoder {
	b := make([]byte, TypeSize.UInt16)
	e.Order.PutUint16(b, v)
	e.buf.Write(b)
	return e
}

func (e *Encoder) WriteInt32(v int32) *Encoder {
	e.WriteUint32(uint32(v))
	return e
}

func (e *Encoder) WriteUint32(v uint32) *Encoder {
	b := make([]byte, TypeSize.UInt32)
	e.Order.PutUint32(b, v)
	e.buf.Write(b)
	return e
}

func (e *Encoder) WriteInt64(v int64) *Encoder {
	e.WriteUint64(uint64(v))
	return e
}

func (e *Encoder) WriteUint64(v uint64) *Encoder {
	b := make([]byte, TypeSize.UInt64)
	e.Order.PutUint64(b, v)
	e.buf.Write(b)
	return e
}

func (e *Encoder) WriteBool(b bool) *Encoder {
	var out byte
	if b {
		out = 1
	}
	e.WriteByte(out)
	return e
}

func (e *Encoder) WriteBigInt(v *big.Int, n int) *Encoder {
	if v.BitLen()/8 >= n {
		e.buf.Write(v.Bytes())
		return e
	}

	b := make([]byte, n)
	if e.isBigEndian {
		i := len(b)
		for _, d := range v.Bits() {
			for j := 0; j < wordBytes && i > 0; j++ {
				i--
				b[i] = byte(d)
				d >>= 8
			}
		}
	} else {
		i := 0
		for _, d := range v.Bits() {
			for j := 0; j < wordBytes && i < len(b); j++ {
				b[i] = byte(d)
				d >>= 8
				i++
			}
		}
	}

	e.buf.Write(b)
	return e
}

func (e *Encoder) Padding(n int) *Encoder {
	e.buf.Write(make([]byte, n))
	return e
}

func (e *Encoder) WriteBytes(v []byte) *Encoder {
	e.buf.Write(v)
	return e
}

func (e *Encoder) WriteByte(b byte) *Encoder {
	e.buf.WriteByte(b)
	return e
}

func (e *Encoder) GetBytes() []byte {
	return e.buf.Bytes()
}

func reverse(s []byte) []byte {
	for i, j := 0, len(s)-1; i < j; i, j = i+1, j-1 {
		s[i], s[j] = s[j], s[i]
	}
	return s
}
