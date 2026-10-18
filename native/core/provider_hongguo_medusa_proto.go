package core

import (
	"crypto/md5"
	"encoding/binary"
	"math"
	"time"
)

type hongguoProto []byte

func (data hongguoProto) integer(field int, value int64) hongguoProto {
	if value == 0 {
		return data
	}
	data = binary.AppendUvarint(data, uint64(field<<3))
	return binary.AppendUvarint(data, uint64(value<<1)^uint64(value>>63))
}

func (data hongguoProto) bytes(field int, value []byte) hongguoProto {
	if len(value) == 0 {
		return data
	}
	data = binary.AppendUvarint(data, uint64(field<<3|2))
	data = binary.AppendUvarint(data, uint64(len(value)))
	return append(data, value...)
}

func (data hongguoProto) text(field int, value string) hongguoProto {
	return data.bytes(field, []byte(value))
}

func (data hongguoProto) float(field int, value float32) hongguoProto {
	data = binary.AppendUvarint(data, uint64(field<<3|5))
	return binary.LittleEndian.AppendUint32(data, math.Float32bits(value))
}

func hongguoMedusaProto(query string, body []byte, deviceID string, now time.Time, entropy hongguoPlaybackEntropy) ([]byte, [32]byte, []byte) {
	timestamp := uint32(now.Unix())
	querySM3, bodyMD5 := hongguoSM3([]byte(query)), md5.Sum(body)
	hash := hongguoMedusaHash(querySM3, bodyMD5, timestamp)
	combined := append(append([]byte(query), bodyMD5[:]...), []byte("none")...)
	combinedSM3 := hongguoSM3(combined)
	device := hongguoProto(nil).
		integer(1, 1).integer(2, 2).text(3, "8662").text(4, deviceID).
		text(6, "!noperm!").integer(7, -888888).integer(8, -888888).
		integer(9, 3).integer(10, -888888).text(11, "!notset!").
		text(12, "Asia/Shanghai,8").text(13, "zh_CN").integer(14, 4).
		float(16, 255.24993896484375).float(17, 35.58599090576172).
		float(18, 3.467449188232422).float(19, 3.467449188232422).
		float(20, 255.1754913330078).float(21, 42.17544174194336).
		text(22, "16").integer(23, 41).integer(24, 36).
		integer(25, 1728388016635).integer(26, 1728388016635).
		integer(27, 1728388016635).integer(28, 1728388016637).
		integer(29, -1).text(30, "25053RT47C").text(31, "Redmi").
		text(32, "25053RT47C").text(33, "25053RT47C").text(34, "Xiaomi").
		text(35, "Redmi").text(36, "Redmi").integer(38, 31)
	report := hongguoProto(nil).integer(1, now.Unix()).integer(2, -2).integer(4, 200)
	environment := hongguoProto(nil).
		integer(1, int64(100+entropy.launch%21)).integer(2, 146331399).
		integer(3, 146331396).integer(5, 7).text(6, "v04.06.04.03-bugfix").
		integer(7, int64(10001+entropy.process%2000)).bytes(12, device).
		bytes(13, report).text(14, "7.1.3.32")
	request := hongguoProto(nil).integer(1, 111).integer(2, 10).integer(3, 694367).integer(5, 586952199)
	magic := []byte{0xf7, 0xe8, 0x5f, 0xfa, 0xd7, 0xd7, 0xdc, 0x3b, 0xd6, 0x2a, 0xc8, 0x70, 0x57, 0xcf, 0x61, 0x18}
	proto := hongguoProto(nil).
		bytes(1, magic).integer(2, 3).integer(3, int64(entropy.proto)).
		text(4, "8662").text(5, deviceID).text(6, "1588093228").
		text(7, "7.1.3.32").text(8, "v04.06.04-ml-android").integer(9, 67503104).
		bytes(10, binary.LittleEndian.AppendUint64(nil, 320)).integer(12, now.Unix()).
		bytes(13, hash).bytes(14, querySM3[:6]).bytes(15, request).
		integer(17, now.Unix()).bytes(19, combinedSM3[:]).text(20, "none").
		integer(21, 312).bytes(23, environment).
		text(24, `{"cmr":16777216,"cmr2":16777216,"un_h":1879194040,"vpn":0,"kd":0,"fkd":3672518972,"pd":-1872573247,"dyn":"","do":0,"tk":true}`)
	return proto, querySM3, hash
}
