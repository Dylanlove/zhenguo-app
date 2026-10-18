package core

import (
	"crypto/md5"
	"crypto/rand"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"math/bits"
	"net/http"
	"strconv"
	"strings"
	"time"
)

type hongguoPlaybackEntropy struct {
	gorgon, helios, proto, launch, process, hash, mix uint32
}

const hongguoPlaybackUserAgent = "com.phoenix.read/71332 (Linux; U; Android 16; zh_CN; 25053RT47C; Build/BP2A.250605.031.A3; Cronet/TTNetVersion:04657795 2026-01-23 QuicVersion:c67e9834 2025-09-08)"

func newHongguoPlaybackDeviceIDs() (string, string, error) {
	var data [16]byte
	if _, err := rand.Read(data[:]); err != nil {
		return "", "", err
	}
	device := uint64(100_000_000_000_000_000) + binary.LittleEndian.Uint64(data[:8])%900_000_000_000_000_000
	install := uint64(100_000_000_000_000_000) + binary.LittleEndian.Uint64(data[8:])%900_000_000_000_000_000
	return strconv.FormatUint(device, 10), strconv.FormatUint(install, 10), nil
}

func newHongguoPlaybackEntropy() (hongguoPlaybackEntropy, error) {
	var raw [28]byte
	if _, err := rand.Read(raw[:]); err != nil {
		return hongguoPlaybackEntropy{}, err
	}
	return hongguoPlaybackEntropy{
		gorgon: binary.LittleEndian.Uint32(raw[0:]), helios: binary.LittleEndian.Uint32(raw[4:]),
		proto: binary.LittleEndian.Uint32(raw[8:]), launch: binary.LittleEndian.Uint32(raw[12:]),
		process: binary.LittleEndian.Uint32(raw[16:]), hash: binary.LittleEndian.Uint32(raw[20:]),
		mix: binary.LittleEndian.Uint32(raw[24:]),
	}, nil
}

func signHongguoPlaybackRequest(request *http.Request, body []byte, deviceID string, now time.Time, entropy hongguoPlaybackEntropy) {
	timestamp := uint32(now.Unix())
	var little, big [4]byte
	binary.LittleEndian.PutUint32(little[:], timestamp)
	binary.BigEndian.PutUint32(big[:], timestamp)
	request.Header.Set("X-Ladon", base64.StdEncoding.EncodeToString(big[:]))
	request.Header.Set("X-Argus", base64.StdEncoding.EncodeToString(little[:]))
	request.Header.Set("X-Khronos", strconv.FormatUint(uint64(timestamp), 10))
	request.Header.Set("X-SS-Req-Ticket", strconv.FormatInt(now.UnixMilli(), 10))
	bodyMD5 := md5.Sum(body)
	request.Header.Set("X-SS-STUB", strings.ToUpper(hex.EncodeToString(bodyMD5[:])))
	request.Header.Set("X-Gorgon", hongguoPlaybackGorgon(request.URL.RawQuery, bodyMD5, timestamp, uint16(entropy.gorgon)))
	request.Header.Set("X-Helios", hongguoPlaybackHelios(timestamp, entropy.helios))
	proto, queryHash, hash := hongguoMedusaProto(request.URL.RawQuery, body, deviceID, now, entropy)
	medusa := hongguoMedusaSignature(proto, queryHash, hash, timestamp, entropy.hash, entropy.mix)
	request.Header.Set("X-Medusa", base64.StdEncoding.EncodeToString(medusa))
}

func hongguoPlaybackGorgon(query string, body [16]byte, timestamp uint32, random uint16) string {
	queryMD5 := md5.Sum([]byte(query))
	var payload [20]byte
	copy(payload[:4], queryMD5[:4])
	copy(payload[4:8], body[:4])
	binary.LittleEndian.PutUint32(payload[12:], 67503104)
	binary.BigEndian.PutUint32(payload[16:], timestamp)
	key := [8]byte{0x4a, 0x40, 0x16, byte(random >> 8), 0x47, 0x6c, 1, byte(random)}
	var table [256]byte
	for i := range table {
		table[i] = byte(i)
	}
	j := 0
	for i := range table {
		j = (j + int(table[i]) + int(key[i%len(key)])) & 255
		table[i], table[j] = table[j], table[i]
	}
	j = 0
	for offset, value := range payload {
		i := offset + 1
		j = (j + int(table[i])) & 255
		y := table[j]
		table[i] = y
		payload[offset] = value ^ table[byte(y+y)]
	}
	for i, value := range payload {
		following := payload[(i+1)%len(payload)]
		payload[i] = ^(bits.Reverse8(following^bits.RotateLeft8(value, 4)) ^ 20)
	}
	output := []byte{0x84, 0x04, byte(random), byte(random >> 8), 0x40, 0x01}
	return hex.EncodeToString(append(output, payload[:]...))
}

func hongguoPlaybackHelios(timestamp, random uint32) string {
	seed := append(binary.LittleEndian.AppendUint32(nil, random), []byte("8662")...)
	digest := md5.Sum(seed)
	encoded := []byte(hex.EncodeToString(digest[:]))
	var words [4]uint64
	for i := range words {
		words[i] = binary.LittleEndian.Uint64(encoded[i*8:])
	}
	var table [35]uint64
	table[0] = words[0]
	a, b, queue := words[0], words[1], append([]uint64(nil), words[2:]...)
	for i := 0; i < 34; i++ {
		value := (bits.RotateLeft64(b, -8) + a) ^ uint64(i)
		queue = append(queue, value)
		value ^= bits.RotateLeft64(a, -61)
		table[i+1] = value
		a, b, queue = value, queue[0], queue[1:]
	}
	data := []byte(strconv.FormatUint(uint64(timestamp), 10) + "-1588093228-8662")
	padding := 16 - len(data)%16
	for i := 0; i < padding; i++ {
		data = append(data, byte(padding))
	}
	output := binary.LittleEndian.AppendUint32(nil, random)
	for offset := 0; offset < len(data); offset += 16 {
		left, right := binary.LittleEndian.Uint64(data[offset:]), binary.LittleEndian.Uint64(data[offset+8:])
		for i := 0; i < 34; i++ {
			right = table[i] ^ (left + bits.RotateLeft64(right, -8))
			left = right ^ bits.RotateLeft64(left, -61)
		}
		output = binary.LittleEndian.AppendUint64(output, left)
		output = binary.LittleEndian.AppendUint64(output, right)
	}
	return base64.StdEncoding.EncodeToString(output)
}
