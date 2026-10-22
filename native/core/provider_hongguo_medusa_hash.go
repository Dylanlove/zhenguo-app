package core

import (
	_ "embed"
	"encoding/binary"
	"math/bits"
)

//go:embed assets/hongguo_medusa.bin
var hongguoMedusaBranchTable []byte

func hongguoSM3(input []byte) [32]byte {
	data := append([]byte(nil), input...)
	length := uint64(len(data)) * 8
	data = append(data, 0x80)
	for len(data)%64 != 56 {
		data = append(data, 0)
	}
	data = binary.BigEndian.AppendUint64(data, length)
	state := [8]uint32{0x7380166f, 0x4914b2b9, 0x172442d7, 0xda8a0600, 0xa96f30bc, 0x163138aa, 0xe38dee4d, 0xb0fb0e4e}
	for offset := 0; offset < len(data); offset += 64 {
		var words [68]uint32
		for i := 0; i < 16; i++ {
			words[i] = binary.BigEndian.Uint32(data[offset+i*4:])
		}
		for i := 16; i < len(words); i++ {
			x := words[i-16] ^ words[i-9] ^ bits.RotateLeft32(words[i-3], 15)
			words[i] = x ^ bits.RotateLeft32(x, 15) ^ bits.RotateLeft32(x, 23) ^ bits.RotateLeft32(words[i-13], 7) ^ words[i-6]
		}
		a, b, c, d, e, f, g, h := state[0], state[1], state[2], state[3], state[4], state[5], state[6], state[7]
		for i := 0; i < 64; i++ {
			t, ff, gg := uint32(0x79cc4519), a^b^c, e^f^g
			if i >= 16 {
				t, ff, gg = 0x7a879d8a, (a&b)|(a&c)|(b&c), (e&f)|(^e&g)
			}
			ss1 := bits.RotateLeft32(bits.RotateLeft32(a, 12)+e+bits.RotateLeft32(t, i), 7)
			tt1 := ff + d + (ss1 ^ bits.RotateLeft32(a, 12)) + (words[i] ^ words[i+4])
			tt2 := gg + h + ss1 + words[i]
			a, b, c, d = tt1, a, bits.RotateLeft32(b, 9), c
			e, f, g, h = tt2^bits.RotateLeft32(tt2, 9)^bits.RotateLeft32(tt2, 17), e, bits.RotateLeft32(f, 19), g
		}
		for i, value := range [8]uint32{a, b, c, d, e, f, g, h} {
			state[i] ^= value
		}
	}
	var digest [32]byte
	for i, value := range state {
		binary.BigEndian.PutUint32(digest[i*4:], value)
	}
	return digest
}

func hongguoMedusaChecksum(data []byte) uint32 {
	value := uint32(0x20220420)
	for i := 0; i < 12; i++ {
		if i%2 == 0 {
			value = uint32(data[i]) ^ (value << 7) ^ (value >> 3) ^ value
		} else {
			value = ^(uint32(data[i]) | (value << 11)) ^ (value >> 5) ^ value
		}
	}
	return (value | 4) ^ 0x1000000
}

func hongguoMedusaHash(query [32]byte, body [16]byte, timestamp uint32) []byte {
	input := append(append([]byte(nil), query[:]...), body[:]...)
	input = binary.LittleEndian.AppendUint32(input, timestamp)
	iv := uint32(0x20230928)
	for _, part := range [][]byte{query[:], body[:], input[48:]} {
		for i, value := range part {
			if i%2 == 0 {
				iv = (iv >> 4) ^ iv ^ (iv << 6) ^ uint32(value)
			} else {
				iv = ^((iv >> 7) ^ iv ^ (uint32(value) | iv<<12))
			}
		}
	}
	group := int((iv & 15) * 171 >> 9)
	switch int(iv&15) - group*3 {
	case 0:
		return hongguoMedusaSHA(input, group, timestamp)
	case 1:
		return hongguoMedusaWhirlpool(input, group, timestamp)
	default:
		return hongguoMedusaMD5(input, iv, timestamp)
	}
}

func hongguoMedusaSHA(input []byte, group int, timestamp uint32) []byte {
	base := hongguoMedusaSHASeeds[group]
	count := base + timestamp
	var constants [64]uint32
	for i, value := range hongguoMedusaSHAConstants {
		constants[i] = bits.RotateLeft32(value, -int(byte(count+1)))
	}
	for _, value := range []byte{0xfa, 0x45, 0x61, 0xd7} {
		input = append(input, byte(uint16(value)*257>>((count+2)&7)))
	}
	input = append(input, 0, 0, 0, 0, 0, 0, 1, 0xa0)
	var words [128]uint32
	for i := 0; i < 16; i++ {
		words[i] = binary.BigEndian.Uint32(input[i*4:])
	}
	for i := 0; i < 112; i++ {
		a, b := words[i+1], words[i+14]
		words[i+16] = words[i] + words[i+9] + (bits.RotateLeft32(a, 14) ^ bits.RotateLeft32(a, 25) ^ a>>3) + (bits.RotateLeft32(b, 13) ^ bits.RotateLeft32(b, 15) ^ b>>10)
	}
	state := [8]uint32{0x7aba4fc8, 0x67166507, 0x6403fa00, 0x340f512f, 984304912, 3005047866, 2874125293, 2152413264}
	for i, value := range state {
		state[i] = bits.RotateLeft32(value, -int(byte(count)))
	}
	configs := [6][11]int{
		{101, 5, 7, 6, 3, 2, 1, 0, 5, 4, 3},
		{96, 0, 6, 7, 5, 3, 2, 1, 5, 4, 4},
		{96, 7, 6, 2, 1, 4, 0, 5, 4, 3, 5},
		{99, 3, 6, 2, 4, 5, 1, 0, 0, 7, 6},
		{96, 0, 5, 6, 7, 3, 1, 2, 5, 4, 4},
		{100, 2, 0, 3, 5, 4, 6, 7, 2, 1, 5},
	}
	config, current := configs[group], state
	x := config[1:]
	for i := 0; i < config[0]; i++ {
		offset := base + uint32(i)
		a, b := current[x[0]], current[x[1]]
		n1 := ((current[x[2]] ^ current[x[3]]) & a) ^ current[x[2]]
		n2 := bits.RotateLeft32(a, 26) ^ bits.RotateLeft32(a, 21) ^ bits.RotateLeft32(a, 7)
		n4 := words[offset&127] + n1 + n2 + constants[offset&63] + current[x[4]]
		n5 := bits.RotateLeft32(b, 30) ^ bits.RotateLeft32(b, 19) ^ bits.RotateLeft32(b, 10)
		n6 := (b & current[x[5]]) | ((b | current[x[5]]) & current[x[6]])
		o := current[x[8]]
		current = [8]uint32{current[7], current[0], current[1], current[2], current[3], current[4], current[5], current[6]}
		current[x[9]], current[x[7]] = n5+n6+n4, o+n4
	}
	var output [32]byte
	for i := range state {
		binary.BigEndian.PutUint32(output[i*4:], current[i]+state[i])
	}
	return hongguoMedusaFold(output)
}

func hongguoMedusaFold(data [32]byte) []byte {
	for i := 0; i < 16; i++ {
		data[i] ^= data[i+16]
	}
	return binary.LittleEndian.AppendUint32(data[:16], hongguoMedusaChecksum(data[:16]))
}

func hongguoMedusaWhirlpool(input []byte, group int, timestamp uint32) []byte {
	seeds := [5]uint32{0x808a9c79, 0xf079807e, 0xbadf79c5, 0xa785d3ff, 0x82d8438c}
	count := seeds[group] + timestamp
	value := bits.RotateLeft64(uint64(timestamp), -int(byte(count)))
	orders := [5][8]int{{5, 7, 1, 2, 4, 0, 6, 3}, {0, 5, 2, 4, 1, 3, 7, 6}, {5, 7, 2, 4, 1, 6, 3, 0}, {3, 0, 2, 4, 6, 7, 1, 5}, {4, 5, 0, 3, 6, 2, 1, 7}}
	constants := [11]uint64{0x87aeea5dab37cd6b, 0x7ff48becb4f54087, 0xb0724c06706bbd5d, 0x1fe5dfb1143e328d, 0x1a2331d00af4f1f2, 0xcaff7131bb1e71ba, 0x33385e1042752218, 0xff01ed65d4a441fb, 0xadb1ec8828c80e8, 0x62475d12f4e06fe7, 0xbd0b238da4fe72}
	for i, constant := range constants {
		constants[i] = bits.RotateLeft64(constant, -int((count+1)&63))
	}
	input = append(input, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	var source, mask [8]uint64
	for i := range source {
		source[i] = binary.BigEndian.Uint64(input[i*8:])
		mask[i] = value
	}
	first := hongguoMedusaWhirlpoolSwap(source, mask, constants, orders[group], group, nil)
	mask = [8]uint64{first[4], first[3], first[2], first[1], first[0], first[7], first[6], first[5]}
	second := hongguoMedusaWhirlpoolSwap([8]uint64{0, 0, 0, 0, 0, 0, 0, 416}, mask, constants, orders[group], group, &first)
	var output [32]byte
	for i := 0; i < 8; i++ {
		var encoded [8]byte
		binary.LittleEndian.PutUint64(encoded[:], second[7-i])
		for j, position := range [4]int{1, 3, 5, 6} {
			output[i*4+j] = encoded[position]
		}
	}
	return hongguoMedusaFold(output)
}

func hongguoMedusaWhirlpoolRound(words [8]uint64, offset, group int) uint64 {
	var result uint64
	for i := 0; i < 8; i++ {
		value := words[(offset+i)%8]
		position := int(byte(value >> (56 - i*8)))
		index := group*16384 + i*2048 + position*8
		result ^= binary.LittleEndian.Uint64(hongguoMedusaBranchTable[index:])
	}
	return result
}

func hongguoMedusaWhirlpoolSwap(source, mask [8]uint64, constants [11]uint64, order [8]int, group int, previous *[8]uint64) [8]uint64 {
	var data [8]uint64
	for i := range data {
		data[i] = source[order[i]] ^ mask[i]
	}
	key := mask
	for round := 0; round < 10; round++ {
		var nextKey, nextData [8]uint64
		for i := range nextKey {
			nextKey[i] = hongguoMedusaWhirlpoolRound(key, i, group)
		}
		nextKey[7] ^= constants[round+1]
		for i := range nextData {
			nextData[i] = hongguoMedusaWhirlpoolRound(data, i, group) ^ nextKey[i]
		}
		data, key = nextData, nextKey
	}
	if previous == nil {
		for i := range source {
			source[i] ^= mask[i] ^ data[(8-i)%8]
		}
	} else {
		for i := range source {
			source[i] = data[7-i] ^ previous[(i+1)%8]
		}
		source[6] ^= uint64(416)
	}
	return source
}

func hongguoMedusaMD5(input []byte, iv, timestamp uint32) []byte {
	n := (iv & 13) * 86
	group := int(((n >> 15) & 255) + ((n >> 8) & 255))
	seeds := [5]uint32{0x8980f29b, 0xeb549c7f, 0xb08726db, 0xd40cb5e6, 0xe8f559e4}
	count := seeds[group] + timestamp
	for _, value := range []byte{0x84, 0x96, 0x77, 0x9d, 0xd4, 0x15, 0x0b, 0xf8} {
		input = append(input, byte(uint16(value)*257>>((count+5)&7)))
	}
	input = append(input, 0xa0, 1, 0, 0)
	state := [4]uint32{0x79e0f2fb, 0xc8b52570, 0xebc2f8cd, 0x7c104d93}
	end := [4]uint32{0x19be4866, 0xe85986b4, 0xe19b326e, 0x71d1d7d4}
	for i := range state {
		state[i] = bits.RotateLeft32(state[i], -int(byte(count)))
		end[i] = bits.RotateLeft32(end[i], -int(byte(count+6)))
	}
	var words [16]uint32
	for i := range words {
		words[i] = binary.LittleEndian.Uint32(input[i*4:])
	}
	shifts := [4][4]int{{7, 12, 17, 22}, {5, 9, 14, 20}, {4, 11, 16, 23}, {6, 10, 15, 21}}
	a, b, c, d := state[0], state[1], state[2], state[3]
	for i := 0; i < 64; i++ {
		var f uint32
		switch i / 16 {
		case 0:
			f = (b & c) | (^b & d)
		case 1:
			f = (b & d) | (c & ^d)
		case 2:
			f = b ^ c ^ d
		default:
			f = c ^ (b | ^d)
		}
		constant := bits.RotateLeft32(hongguoMedusaMD5Constants[i], -int(byte(count+1)))
		word := words[hongguoMedusaMD5Orders[group*64+i]]
		a, b, c, d = d, b+bits.RotateLeft32(a+f+word+constant, shifts[i/16][i%4]), b, c
	}
	var output []byte
	for i, value := range [4]uint32{a, b, c, d} {
		output = binary.LittleEndian.AppendUint32(output, (state[i]+value)^end[i])
	}
	return binary.LittleEndian.AppendUint32(output, hongguoMedusaChecksum(output))
}
