package core

import (
	"bytes"
	"encoding/binary"

	"github.com/bluenviron/mediacommon/v2/pkg/codecs/h264"
	"github.com/bluenviron/mediacommon/v2/pkg/codecs/h265"
)

func mediaNALResolution(nalu []byte) (int, int) {
	if len(nalu) < 4 {
		return 0, 0
	}
	width, height := 0, 0
	if nalu[0]&0x1f == 7 {
		var sps h264.SPS
		if sps.Unmarshal(nalu) == nil {
			width, height = sps.Width(), sps.Height()
		}
	} else if nalu[0]>>1&0x3f == 33 {
		var sps h265.SPS
		if sps.Unmarshal(nalu) == nil {
			width, height = sps.Width(), sps.Height()
		}
	}
	if width < 16 || height < 16 || width > 16384 || height > 16384 {
		return 0, 0
	}
	return width, height
}

func mediaAnnexBResolution(data []byte) (int, int) {
	for _, nalu := range bytes.Split(data, []byte{0, 0, 1})[1:] {
		if width, height := mediaNALResolution(bytes.TrimRight(nalu, "\x00")); width > 0 {
			return width, height
		}
	}
	return 0, 0
}

func mediaMP4Resolution(data []byte) (int, int) {
	for _, kind := range []string{"avcC", "hvcC"} {
		for offset := 4; offset+4 <= len(data); {
			found := bytes.Index(data[offset:], []byte(kind))
			if found < 0 {
				break
			}
			start := offset + found
			offset = start + 4
			size := uint64(binary.BigEndian.Uint32(data[start-4:]))
			if size < 8 || size > uint64(len(data)-start+4) {
				continue
			}
			config := data[start+4 : start-4+int(size)]
			if len(config) == 0 || config[0] != 1 {
				continue
			}
			var nalus [][]byte
			if kind == "avcC" && len(config) >= 6 {
				count, remaining := int(config[5]&31), config[6:]
				for index := 0; index < count && len(remaining) >= 2; index++ {
					size := int(binary.BigEndian.Uint16(remaining))
					remaining = remaining[2:]
					if size > len(remaining) {
						break
					}
					nalus = append(nalus, remaining[:size])
					remaining = remaining[size:]
				}
			} else if kind == "hvcC" && len(config) >= 23 {
				remaining := config[23:]
				for index := 0; index < int(config[22]) && len(remaining) >= 3; index++ {
					count := int(binary.BigEndian.Uint16(remaining[1:]))
					remaining = remaining[3:]
					for entry := 0; entry < count && len(remaining) >= 2; entry++ {
						size := int(binary.BigEndian.Uint16(remaining))
						remaining = remaining[2:]
						if size > len(remaining) {
							remaining = nil
							break
						}
						nalus = append(nalus, remaining[:size])
						remaining = remaining[size:]
					}
				}
			}
			for _, nalu := range nalus {
				if width, height := mediaNALResolution(nalu); width > 0 {
					return width, height
				}
			}
		}
	}
	return 0, 0
}

func mediaMP4MetadataOffset(data []byte) int64 {
	if len(data) < 16 || string(data[4:8]) != "ftyp" {
		return 0
	}
	for offset := 0; offset+8 <= len(data); {
		size := uint64(binary.BigEndian.Uint32(data[offset:]))
		header := 8
		if size == 1 {
			if offset+16 > len(data) {
				return 0
			}
			size, header = binary.BigEndian.Uint64(data[offset+8:]), 16
		}
		if size < uint64(header) || size > 1<<62-uint64(offset) {
			return 0
		}
		if size > uint64(len(data)-offset) {
			if string(data[offset+4:offset+8]) == "mdat" {
				return int64(uint64(offset) + size)
			}
			return 0
		}
		offset += int(size)
	}
	return 0
}

func mediaTSResolution(data []byte) (int, int) {
	start := -1
	for index := 0; index+376 < len(data); index++ {
		if data[index] == 0x47 && data[index+188] == 0x47 && data[index+376] == 0x47 {
			start = index
			break
		}
	}
	if start < 0 {
		return 0, 0
	}
	streams := map[int][]byte{}
	for index := start; index+188 <= len(data); index += 188 {
		packet := data[index : index+188]
		if packet[0] != 0x47 || packet[1]&0x80 != 0 || packet[3]&0x10 == 0 {
			continue
		}
		pid := int(packet[1]&31)<<8 | int(packet[2])
		offset := 4
		if packet[3]&0x20 != 0 {
			offset += 1 + int(packet[4])
		}
		if offset >= len(packet) {
			continue
		}
		payload := packet[offset:]
		if packet[1]&0x40 != 0 {
			if len(payload) < 9 || !bytes.HasPrefix(payload, []byte{0, 0, 1}) || payload[3] < 0xe0 || payload[3] > 0xef {
				delete(streams, pid)
				continue
			}
			header := 9 + int(payload[8])
			if header > len(payload) {
				continue
			}
			payload = payload[header:]
			if _, exists := streams[pid]; !exists {
				streams[pid] = nil
			}
		}
		if previous, exists := streams[pid]; exists {
			streams[pid] = append(previous, payload...)
		}
	}
	for _, elementary := range streams {
		if width, height := mediaAnnexBResolution(elementary); width > 0 {
			return width, height
		}
	}
	return 0, 0
}

func mediaResolution(data []byte) (int, int) {
	if width, height := mediaMP4Resolution(data); width > 0 {
		return width, height
	}
	return mediaTSResolution(data)
}
