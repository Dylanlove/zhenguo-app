package ysp

import (
	"bytes"
	"compress/gzip"
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

type jceWriter struct{ bytes.Buffer }

func (w *jceWriter) head(kind, tag byte) {
	if tag < 15 {
		w.WriteByte(tag<<4 | kind)
	} else {
		w.WriteByte(240 | kind)
		w.WriteByte(tag)
	}
}
func (w *jceWriter) integer(value int64, tag byte) {
	if value == 0 {
		w.head(12, tag)
		return
	}
	if value >= -128 && value <= 127 {
		w.head(0, tag)
		w.WriteByte(byte(value))
		return
	}
	if value >= -32768 && value <= 32767 {
		w.head(1, tag)
		binary.Write(&w.Buffer, binary.BigEndian, int16(value))
		return
	}
	if value >= -2147483648 && value <= 2147483647 {
		w.head(2, tag)
		binary.Write(&w.Buffer, binary.BigEndian, int32(value))
		return
	}
	w.head(3, tag)
	binary.Write(&w.Buffer, binary.BigEndian, value)
}
func (w *jceWriter) string(value string, tag byte) {
	if len(value) > 255 {
		w.head(7, tag)
		binary.Write(&w.Buffer, binary.BigEndian, int32(len(value)))
	} else {
		w.head(6, tag)
		w.WriteByte(byte(len(value)))
	}
	w.WriteString(value)
}
func (w *jceWriter) blob(value []byte, tag byte) {
	w.head(13, tag)
	w.head(0, 0)
	w.integer(int64(len(value)), 0)
	w.Write(value)
}
func (w *jceWriter) structure(tag byte, write func()) { w.head(10, tag); write(); w.head(11, 0) }
func (w *jceWriter) emptyList(tag byte)               { w.head(9, tag); w.integer(0, 0) }

type jceReader struct {
	raw    []byte
	offset int
	depth  int
}

func (r *jceReader) take(count int) ([]byte, error) {
	if count < 0 || count > len(r.raw)-r.offset {
		return nil, io.ErrUnexpectedEOF
	}
	value := r.raw[r.offset : r.offset+count]
	r.offset += count
	return value, nil
}
func (r *jceReader) head() (byte, byte, error) {
	raw, err := r.take(1)
	if err != nil {
		return 0, 0, err
	}
	kind, tag := raw[0]&15, raw[0]>>4
	if tag == 15 {
		value, err := r.take(1)
		if err != nil {
			return 0, 0, err
		}
		tag = value[0]
	}
	return kind, tag, nil
}
func (r *jceReader) field() (any, error) {
	kind, _, err := r.head()
	if err != nil {
		return nil, err
	}
	return r.value(kind)
}
func (r *jceReader) count() (int, error) {
	value, err := r.field()
	if err != nil {
		return 0, err
	}
	count, ok := value.(int64)
	if !ok || count < 0 || count > 100000 {
		return 0, errors.New("JCE 长度无效")
	}
	return int(count), nil
}
func (r *jceReader) value(kind byte) (any, error) {
	switch kind {
	case 12:
		return int64(0), nil
	case 0:
		raw, err := r.take(1)
		if err != nil {
			return nil, err
		}
		return int64(int8(raw[0])), nil
	case 1:
		raw, err := r.take(2)
		if err != nil {
			return nil, err
		}
		return int64(int16(binary.BigEndian.Uint16(raw))), nil
	case 2:
		raw, err := r.take(4)
		if err != nil {
			return nil, err
		}
		return int64(int32(binary.BigEndian.Uint32(raw))), nil
	case 3:
		raw, err := r.take(8)
		if err != nil {
			return nil, err
		}
		return int64(binary.BigEndian.Uint64(raw)), nil
	case 4:
		return r.take(4)
	case 5:
		return r.take(8)
	case 6, 7:
		size := 0
		if kind == 6 {
			raw, err := r.take(1)
			if err != nil {
				return nil, err
			}
			size = int(raw[0])
		} else {
			raw, err := r.take(4)
			if err != nil {
				return nil, err
			}
			size = int(binary.BigEndian.Uint32(raw))
		}
		raw, err := r.take(size)
		return string(raw), err
	case 13:
		kind, _, err := r.head()
		if err != nil || kind != 0 {
			return nil, errors.New("JCE 字节数组无效")
		}
		count, err := r.count()
		if err != nil {
			return nil, err
		}
		return r.take(count)
	case 10:
		return r.structure()
	case 9:
		count, err := r.count()
		if err != nil {
			return nil, err
		}
		values := make([]any, 0, count)
		for index := 0; index < count; index++ {
			value, err := r.field()
			if err != nil {
				return nil, err
			}
			values = append(values, value)
		}
		return values, nil
	case 8:
		count, err := r.count()
		if err != nil {
			return nil, err
		}
		values := make([]any, 0, count*2)
		for index := 0; index < count*2; index++ {
			value, err := r.field()
			if err != nil {
				return nil, err
			}
			values = append(values, value)
		}
		return values, nil
	}
	return nil, errors.New("JCE 字段类型无效")
}
func (r *jceReader) structure() (map[byte]any, error) {
	if r.depth >= 16 {
		return nil, errors.New("JCE 嵌套过深")
	}
	r.depth++
	defer func() { r.depth-- }()
	values := map[byte]any{}
	for r.offset < len(r.raw) {
		kind, tag, err := r.head()
		if err != nil {
			return nil, err
		}
		if kind == 11 {
			break
		}
		value, err := r.value(kind)
		if err != nil {
			return nil, err
		}
		values[tag] = value
	}
	return values, nil
}

func jcePacket(body []byte, command int16, requestID int64, guid string) []byte {
	var writer jceWriter
	writer.structure(0, func() {
		writer.integer(requestID, 0)
		writer.integer(int64(command), 1)
		writer.structure(2, func() {
			writer.string("3.2.7.26212", 0)
			writer.string("302070", 1)
			writer.integer(1080, 2)
			writer.integer(2400, 3)
			writer.integer(3, 4)
			writer.string("12", 5)
			writer.integer(1, 6)
			writer.integer(1, 7)
			writer.integer(420, 8)
			writer.string("10070", 9)
			for tag := byte(10); tag < 15; tag++ {
				writer.string("", tag)
			}
			writer.structure(15, func() { writer.integer(0, 0); writer.integer(0, 1); writer.string("", 2) })
			for tag := byte(16); tag <= 18; tag++ {
				writer.string("", tag)
			}
			writer.structure(19, func() {
				writer.integer(0, 0)
				writer.head(4, 1)
				writer.Write(make([]byte, 4))
				writer.head(4, 2)
				writer.Write(make([]byte, 4))
				writer.head(5, 3)
				writer.Write(make([]byte, 8))
			})
			writer.string(guid[:16], 20)
			writer.string("Pixel 6", 21)
			writer.integer(1, 22)
			for tag := byte(23); tag < 27; tag++ {
				writer.integer(0, tag)
			}
			writer.string("", 27)
			writer.string("", 28)
			writer.string(guid, 29)
		})
		writer.string("1200013", 3)
		writer.string(guid, 4)
		writer.emptyList(5)
		writer.structure(6, func() {})
		writer.emptyList(7)
		for tag := byte(8); tag <= 10; tag++ {
			writer.integer(0, tag)
		}
	})
	writer.blob(body, 1)
	var inner bytes.Buffer
	inner.WriteByte(38)
	binary.Write(&inner, binary.BigEndian, int32(writer.Len()+17))
	inner.WriteByte(1)
	inner.Write(make([]byte, 10))
	inner.Write(writer.Bytes())
	inner.WriteByte(40)
	var compressed bytes.Buffer
	zip := gzip.NewWriter(&compressed)
	zip.Write(inner.Bytes())
	zip.Close()
	var packet bytes.Buffer
	packet.WriteByte(19)
	binary.Write(&packet, binary.BigEndian, int32(0))
	binary.Write(&packet, binary.BigEndian, uint16(2))
	binary.Write(&packet, binary.BigEndian, uint16(65281))
	binary.Write(&packet, binary.BigEndian, command)
	binary.Write(&packet, binary.BigEndian, int16(0))
	binary.Write(&packet, binary.BigEndian, requestID)
	binary.Write(&packet, binary.BigEndian, int32(531))
	binary.Write(&packet, binary.BigEndian, int32(10012))
	binary.Write(&packet, binary.BigEndian, int64(0))
	packet.WriteString(guid)
	packet.WriteByte(1)
	binary.Write(&packet, binary.BigEndian, int32(302070))
	packet.Write(make([]byte, 6))
	packet.WriteByte(0)
	binary.Write(&packet, binary.BigEndian, int16(0))
	binary.Write(&packet, binary.BigEndian, int16(0))
	binary.Write(&packet, binary.BigEndian, int32(inner.Len()))
	packet.Write(compressed.Bytes())
	packet.WriteByte(3)
	raw := packet.Bytes()
	binary.BigEndian.PutUint32(raw[1:5], uint32(len(raw)))
	return raw
}

func jceUnwrap(raw []byte) (map[byte]any, error) {
	if len(raw) < 90 || raw[0] != 19 {
		return nil, errors.New("央视频 JCE 响应无效")
	}
	body := raw[89 : len(raw)-1]
	if binary.BigEndian.Uint32(raw[21:25])&2 != 0 {
		reader, err := gzip.NewReader(bytes.NewReader(body))
		if err != nil {
			return nil, err
		}
		defer reader.Close()
		body, err = io.ReadAll(io.LimitReader(reader, 4<<20))
		if err != nil {
			return nil, err
		}
	}
	if len(body) < 18 || body[0] != 38 || body[len(body)-1] != 40 {
		return nil, errors.New("央视频 JCE 数据包无效")
	}
	fields, err := (&jceReader{raw: body[16 : len(body)-1]}).structure()
	if err != nil {
		return nil, err
	}
	payload, ok := fields[1].([]byte)
	if !ok {
		return nil, errors.New("央视频 JCE 返回为空")
	}
	return (&jceReader{raw: payload}).structure()
}

func jcePlan(ctx context.Context, client *http.Client, channel Channel, start, end int64) (Plan, error) {
	var writer jceWriter
	writer.string(channel.PID, 0)
	writer.string(channel.CnlID, 1)
	writer.integer(start, 2)
	writer.integer(end, 3)
	writer.string(channel.Definition, 4)
	packet := jcePacket(writer.Bytes(), 25312, time.Now().UnixMilli()&2147483647, randomHex(16))
	raw, _, _, err := fetch(ctx, client, "POST", "https://jacc.ysp.cctv.cn", packet, map[string]string{"Content-Type": "application/octet-stream"}, 4<<20)
	if err != nil {
		return Plan{}, err
	}
	fields, err := jceUnwrap(raw)
	if err != nil {
		return Plan{}, err
	}
	if code, ok := fields[0].(int64); ok && code != 0 {
		return Plan{}, fmt.Errorf("央视频回看接口：%s", text(fields[1]))
	}
	address := text(fields[2])
	if address == "" || strings.Contains(address, "liverecord.video.cloud.cctv.com") {
		return Plan{}, errors.New("央视频回看线路暂不可用")
	}
	return Plan{URL: address, Headers: map[string]string{"User-Agent": browserUA}, Engine: "jce", Quality: "1080p", Expires: time.Now().Add(30 * time.Second).Unix()}, nil
}
