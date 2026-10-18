package core

import (
	"encoding/binary"
	"math/bits"
)

func hongguoMedusaMix(input []byte, key [32]byte) []byte {
	data := make([]byte, len(input))
	for i, value := range input {
		position := (i * 4) & 28
		a, b := key[position], key[position+1]
		x := (bits.RotateLeft8(value, 4) + a) ^ b
		x = bits.RotateLeft8(^x, 3)
		data[len(data)-i-1] = ^((x + b) ^ a)
	}
	last, first := data[len(data)-1]^data[len(data)-2], data[0]
	data[0] += ^last
	data[1] += data[0] ^ data[len(data)-1] ^ 254
	data[2] += (last - first) ^ bits.RotateLeft8(data[1], 3) ^ 2
	for i := 0; i < len(data)-4; i++ {
		temp := bits.RotateLeft8(data[i+2], 3) ^ data[i+1] ^ byte(i+3)
		data[i+3] += ^temp
	}
	data[len(data)-1] ^= data[len(data)-2]
	value := data[0] ^ data[1]
	for _, item := range data[1:] {
		value += item
	}
	data[0] = value
	return data
}

func hongguoMedusaCipher(data []byte, timestamp uint32) []byte {
	group := int(timestamp & 3)
	sbox := hongguoMedusaSBox[group*256 : (group+1)*256]
	key := [16]byte{0xf1, 0x59, 0x33, 0x76, 0x76, 0x6e, 0xa9, 0x8d, 0x34, 0xf3, 0x1b, 0x05, 0x7a, 0x9d, 0x5b, 0xe4}
	iv := [16]byte{0x1f, 0xe1, 0x09, 0xa4, 0x12, 0x52, 0x83, 0xf4, 0x18, 0xde, 0x9e, 0x05, 0x1a, 0x96, 0x9e, 0x12}
	initial := [4]uint32{0xca025ddc, 0x823dc546, 0xc9420583, 0xc298225f}[group]
	var expanded [48]byte
	for i := 0; i < 16; i++ {
		expanded[i] = byte(initial>>(8*(i%4))) ^ key[i]
	}
	for i, round := 4, uint(8); i < 12; i, round = i+1, round+2 {
		index := 4 * (i - 1)
		a, b, c, d := expanded[index], expanded[index+1], expanded[index+2], expanded[index+3]
		if i&3 == 0 {
			a, b, c, d = byte(initial>>(round&24))^sbox[b], sbox[c], sbox[d], sbox[a]
		}
		for j, value := range [4]byte{a, b, c, d} {
			expanded[index+4+j] = value ^ expanded[index-12+j]
		}
	}
	var sampled [32]byte
	for i := 0; i < 31; i++ {
		part := data[i*8:]
		sampled[i] = (part[0]>>4)&2 | part[1]&64 | (part[2]>>2)&1 | (part[3]<<3)&128 | (part[4]>>1)&4 | (part[5]<<3)&16 | (part[6]<<5)&32 | (part[7]>>4)&8
	}
	sampled[31] = 1
	var mixedKey [32]byte
	for offset := 0; offset < 32; offset += 16 {
		var block [16]byte
		for i := range block {
			block[i] = sampled[offset+i] ^ iv[i]
		}
		block = hongguoMedusaCipherBlock(block, expanded, sbox, group)
		copy(mixedKey[offset:], block[:])
		iv = block
	}
	output := append([]byte{mixedKey[31]}, data...)
	for i := 0; i < 31; i++ {
		part, value := output[1+i*8:], mixedKey[i]
		part[0] = (part[0] &^ 32) | (value<<4)&32
		part[1] = (part[1] &^ 64) | value&64
		part[2] = (part[2] &^ 4) | (value<<2)&4
		part[3] = (part[3] &^ 16) | (value>>3)&16
		part[4] = (part[4] &^ 8) | (value<<1)&8
		part[5] = (part[5] &^ 2) | (value>>3)&2
		part[6] = (part[6] &^ 1) | (value>>5)&1
		part[7] = (part[7] & 127) | (value<<4)&128
	}
	return output
}

func hongguoMedusaCipherBlock(state [16]byte, keys [48]byte, sbox []byte, group int) [16]byte {
	permutation := [4][4]int{{1, 0, 2, 3}, {2, 0, 3, 1}, {0, 1, 3, 2}, {1, 0, 2, 3}}[group]
	orders := [4][16]int{
		{0, 9, 14, 11, 4, 13, 2, 7, 8, 1, 6, 15, 12, 5, 10, 3},
		{0, 9, 14, 15, 4, 13, 2, 7, 8, 1, 6, 3, 12, 5, 10, 11},
		{0, 9, 14, 7, 4, 13, 2, 11, 8, 1, 6, 3, 12, 5, 10, 15},
		{0, 9, 14, 11, 4, 13, 2, 7, 8, 1, 6, 15, 12, 5, 10, 3},
	}[group]
	addKey := func(offset int) {
		for row := 0; row < 4; row++ {
			for column := 0; column < 4; column++ {
				state[row*4+column] ^= keys[offset+row*4+permutation[column]]
			}
		}
	}
	addKey(0)
	for round := 1; round <= 2; round++ {
		previous := state
		for row := 0; row < 4; row++ {
			for column := 0; column < 4; column++ {
				state[row*4+column] = sbox[previous[permutation[row]*4+column]]
			}
		}
		previous = state
		for i, position := range orders {
			state[i] = previous[position]
		}
		if round == 1 {
			previous = state
			for row := 0; row < 4; row++ {
				for column := 0; column < 4; column++ {
					state[row*4+column] = previous[row*4+permutation[column]]
				}
			}
			for i := 0; i < 4; i++ {
				a, b, c, d := state[i], state[4+i], state[8+i], state[12+i]
				total := a ^ b ^ c ^ d
				xtime := func(value byte) byte { return value<<1 ^ (0x1b * (value >> 7)) }
				state[i] ^= total ^ xtime(a^b)
				state[4+i] ^= total ^ xtime(b^c)
				state[8+i] ^= total ^ xtime(c^d)
				state[12+i] ^= total ^ xtime(d^a)
			}
		}
		addKey(round * 16)
	}
	for i := range state {
		state[i] ^= keys[16+i]
	}
	return state
}

func hongguoMedusaSignature(proto []byte, query [32]byte, bodyHash []byte, timestamp, hashRandom, mixRandom uint32) []byte {
	signKey := []byte{0x8e, 0xbd, 0xfa, 0x38, 0x06, 0xec, 0xc5, 0xce, 0xe7, 0x94, 0x23, 0xe6, 0x02, 0x9e, 0xd8, 0x25, 0x40, 0xbc, 0x22, 0x18, 0xbb, 0x7e, 0xae, 0xf7, 0x1c, 0xb6, 0x91, 0xf7, 0xaa, 0x8a, 0xa2, 0xf5}
	material := binary.LittleEndian.AppendUint32(append([]byte(nil), signKey...), hashRandom)
	key := hongguoSM3(append(material, signKey...))
	seedByte := (hashRandom >> 16) & 255
	seed := ^((seedByte << 11) | (hashRandom >> 24) ^ (seedByte >> 5) ^ seedByte)
	var seedBytes [4]byte
	binary.LittleEndian.PutUint32(seedBytes[:], seed)
	mixed := binary.LittleEndian.AppendUint64(nil, 320)
	mixed = append(mixed, hongguoMedusaMix(proto, key)...)
	for left, right := 0, len(mixed)-1; left < right; left, right = left+1, right-1 {
		mixed[left], mixed[right] = mixed[right], mixed[left]
	}
	for i := range mixed {
		mixed[i] ^= seedBytes[(^i)&3]
	}
	check := uint32(query[0]&63)<<14 | 0x18000001 | uint32(bodyHash[0]&63)<<8
	data := binary.LittleEndian.AppendUint32([]byte{0x35}, mixRandom)
	data = binary.LittleEndian.AppendUint32(data, check)
	data = append(data, mixed...)
	data = append(data, byte(hashRandom>>16), byte(hashRandom>>24))
	version := [5]uint32{3, 0xfa5fe8f7, 0x3bdcd7d7, 0x70c82ad6, 0x1861cf57}
	var output []byte
	for _, value := range version {
		output = binary.LittleEndian.AppendUint32(output, value^timestamp)
	}
	output = append(output, byte(hashRandom), byte(hashRandom>>8), 0, 1)
	return append(output, hongguoMedusaCipher(data, timestamp)...)
}
