// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// One of the two reference implementations behind the vector tables in
// `src/*/\*_vectors_wbtest.mbt`. It reads the cases the generator picked on stdin and
// answers with what independent Go libraries make of them, both directions, so the
// generator can hold the MoonBit implementation and Python's libraries against these.
//
//   - encoding/binary writes the fixed widths and protobuf's varints, and reads them back;
//   - github.com/quic-go/quic-go/quicvarint writes and parses RFC 9000 §16 integers;
//   - github.com/go-mysql-org/go-mysql/mysql writes and reads MySQL's length-encoded
//     integers;
//   - golang.org/x/net/http2/hpack reads header blocks. RFC 7541 §5.1's 7-bit-prefix
//     integer is only reachable there, as the length in front of a name, so the exchange
//     is a whole block and the name that comes back out of it.
//
// Run through scripts/gen_vectors.py; it is not meant to be run by hand.
package main

import (
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"

	"github.com/go-mysql-org/go-mysql/mysql"
	"github.com/quic-go/quic-go/quicvarint"
	"golang.org/x/net/http2/hpack"
)

// widthCase is a value and the width it is written in.
type widthCase struct {
	Value uint64 `json:"value"`
	Width int    `json:"width"`
}

// octetCase is a run of octets, given as hex, and the width to read it in.
type octetCase struct {
	Hex   string `json:"hex"`
	Width int    `json:"width"`
	Big   bool   `json:"big"`
}

type request struct {
	Fixed       []widthCase  `json:"fixed"`
	FixedRead   []octetCase  `json:"fixed_read"`
	LebUnsigned []uint64     `json:"leb128_unsigned"`
	LebRead     []string     `json:"leb128_read"`
	Quic        []uint64     `json:"quic"`
	QuicRead    []string     `json:"quic_read"`
	Lenenc      []uint64     `json:"lenenc"`
	LenencRead  []string `json:"lenenc_read"`
	Blocks      []string `json:"header_blocks"`
}

type fixedAnswer struct {
	Big    string `json:"big"`
	Little string `json:"little"`
}

type answer struct {
	Fixed       []fixedAnswer `json:"fixed"`
	FixedRead   []uint64      `json:"fixed_read"`
	LebUnsigned []string      `json:"leb128_unsigned"`
	LebRead     []uint64      `json:"leb128_read"`
	Quic        []string      `json:"quic"`
	QuicRead    []uint64      `json:"quic_read"`
	Lenenc      []string      `json:"lenenc"`
	LenencRead  []uint64 `json:"lenenc_read"`
	Blocks      []int    `json:"header_blocks"`
}

// fixedWidth writes v in w octets, either way round, through the standard library's
// per-width functions. Only the widths a machine has are here: those are the ones the
// formats name, and every other width the library also carries is the same arithmetic.
func fixedWidth(v uint64, w int, big bool) []byte {
	b := make([]byte, w)
	switch w {
	case 1:
		b[0] = byte(v)
	case 2:
		if big {
			binary.BigEndian.PutUint16(b, uint16(v))
		} else {
			binary.LittleEndian.PutUint16(b, uint16(v))
		}
	case 4:
		if big {
			binary.BigEndian.PutUint32(b, uint32(v))
		} else {
			binary.LittleEndian.PutUint32(b, uint32(v))
		}
	case 8:
		if big {
			binary.BigEndian.PutUint64(b, v)
		} else {
			binary.LittleEndian.PutUint64(b, v)
		}
	default:
		panic("no standard width of " + fmt.Sprint(w))
	}
	return b
}

// fixedRead reads w octets back through the same per-width functions.
func fixedRead(b []byte, big bool) uint64 {
	switch len(b) {
	case 1:
		return uint64(b[0])
	case 2:
		if big {
			return uint64(binary.BigEndian.Uint16(b))
		}
		return uint64(binary.LittleEndian.Uint16(b))
	case 4:
		if big {
			return uint64(binary.BigEndian.Uint32(b))
		}
		return uint64(binary.LittleEndian.Uint32(b))
	case 8:
		if big {
			return binary.BigEndian.Uint64(b)
		}
		return binary.LittleEndian.Uint64(b)
	}
	panic("no standard width of " + fmt.Sprint(len(b)))
}

// headerNameLength is the name length of the one field in a header block, as this
// implementation's decoder reads it. A reader that got the integer encoding wrong comes
// back with a different length, or with nothing at all.
func headerNameLength(block []byte) int {
	var fields []hpack.HeaderField
	dec := hpack.NewDecoder(4096, func(f hpack.HeaderField) { fields = append(fields, f) })
	if _, err := dec.Write(block); err != nil {
		panic(err)
	}
	if len(fields) != 1 {
		panic("expected one field in the block, got " + fmt.Sprint(len(fields)))
	}
	return len(fields[0].Name)
}

func octets(s string) []byte {
	b, err := hex.DecodeString(s)
	if err != nil {
		panic(err)
	}
	return b
}

func main() {
	var req request
	if err := json.NewDecoder(os.Stdin).Decode(&req); err != nil {
		fmt.Fprintln(os.Stderr, "vectors: reading the request:", err)
		os.Exit(1)
	}
	var ans answer
	for _, c := range req.Fixed {
		ans.Fixed = append(ans.Fixed, fixedAnswer{
			Big:    hex.EncodeToString(fixedWidth(c.Value, c.Width, true)),
			Little: hex.EncodeToString(fixedWidth(c.Value, c.Width, false)),
		})
	}
	for _, c := range req.FixedRead {
		ans.FixedRead = append(ans.FixedRead, fixedRead(octets(c.Hex)[:c.Width], c.Big))
	}
	for _, v := range req.LebUnsigned {
		buf := make([]byte, binary.MaxVarintLen64)
		n := binary.PutUvarint(buf, v)
		ans.LebUnsigned = append(ans.LebUnsigned, hex.EncodeToString(buf[:n]))
	}
	for _, s := range req.LebRead {
		v, _ := binary.Uvarint(octets(s))
		ans.LebRead = append(ans.LebRead, v)
	}
	for _, v := range req.Quic {
		ans.Quic = append(ans.Quic, hex.EncodeToString(quicvarint.Append(nil, v)))
	}
	for _, s := range req.QuicRead {
		v, _, _ := quicvarint.Parse(octets(s))
		ans.QuicRead = append(ans.QuicRead, v)
	}
	for _, v := range req.Lenenc {
		ans.Lenenc = append(ans.Lenenc, hex.EncodeToString(mysql.PutLengthEncodedInt(v)))
	}
	for _, s := range req.LenencRead {
		v, _, _ := mysql.LengthEncodedInt(octets(s))
		ans.LenencRead = append(ans.LenencRead, v)
	}
	for _, b := range req.Blocks {
		ans.Blocks = append(ans.Blocks, headerNameLength(octets(b)))
	}
	if err := json.NewEncoder(os.Stdout).Encode(&ans); err != nil {
		fmt.Fprintln(os.Stderr, "vectors: writing the answer:", err)
		os.Exit(1)
	}
}
