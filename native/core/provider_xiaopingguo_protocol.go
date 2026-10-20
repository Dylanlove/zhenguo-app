package core

import (
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strconv"
	"strings"
	"time"
)

const (
	sourceXiaopingguo          = "xiaopingguo"
	xiaopingguoBaseURL         = "http://122.228.193.211:18008"
	xiaopingguoDetailPath      = "/api/proto/v5/drama/getDetail"
	xiaopingguoPublicKey       = "MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQCduNEnfxGaLuQRk5ABzXHhPV43zi00sCHjLo8BYc+Wi6xXm2b4v0i28Sq4WlNCKhseft9fz8kO/qLr6/022o1RcuOU7e4GFL3U9WnNODwRBYSYWd+K8nqpI/tAUDmZEBGRWqjrc7x6aMl3A+xpnWkLbPCLsuhbuuUE3tv09oeOpwIDAQAB"
	xiaopingguoHeaderKey       = "ed5fdsgucxumegqa"
	xiaopingguoSignatureKey    = "OC1A06E197EF10CF3F6058CA7A803B5E"
	xiaopingguoBodyKey         = "S0VNDTJHOFHHCNMRAW5IV2TOS2PBPQ=="
	xiaopingguoUserAgent       = "okhttp/3.12.1"
	xiaopingguoRRSPBaseURL     = "https://api.rrmj.plus"
	xiaopingguoRRSPReferer     = "https://mh.yichengwlkj.com/"
	xiaopingguoRRSPSignKey     = "ES513W0B1CsdUrR13Qk5EgDAKPeeKZY"
	xiaopingguoRRSPResponseKey = "3b744389882a4067"
	xiaopingguoRRSPPlayIV      = "b1da7878016e4e2b"
	xiaopingguoRRSPAgent       = "Mozilla/5.0 (Linux; Android 16; PJX110) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Mobile Safari/537.36"
)

type xiaopingguoParam struct {
	key   string
	value string
}

type xiaopingguoField struct {
	number int
	wire   byte
	value  uint64
	data   []byte
}

func xiaopingguoRandom(size int, alphabet string) (string, error) {
	result := make([]byte, size)
	if _, err := rand.Read(result); err != nil {
		return "", err
	}
	for index := range result {
		result[index] = alphabet[int(result[index])%len(alphabet)]
	}
	return string(result), nil
}

func xiaopingguoEncrypt(plain, key, iv []byte) ([]byte, error) {
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	padded := pkcs7Pad(append([]byte(nil), plain...), aes.BlockSize)
	result := make([]byte, len(padded))
	if len(iv) > 0 {
		if len(iv) != aes.BlockSize {
			return nil, errors.New("小苹果加密参数无效")
		}
		cipher.NewCBCEncrypter(block, iv).CryptBlocks(result, padded)
	} else {
		for offset := 0; offset < len(padded); offset += aes.BlockSize {
			block.Encrypt(result[offset:], padded[offset:])
		}
	}
	return result, nil
}

func xiaopingguoDecrypt(encoded, key, iv string) ([]byte, error) {
	encrypted, err := base64.StdEncoding.DecodeString(strings.TrimSpace(encoded))
	if err != nil {
		return nil, err
	}
	block, err := aes.NewCipher([]byte(key))
	if err != nil || len(encrypted) == 0 || len(encrypted)%aes.BlockSize != 0 {
		return nil, errors.New("小苹果返回的加密数据无效")
	}
	plain := make([]byte, len(encrypted))
	if iv != "" {
		if len(iv) != aes.BlockSize {
			return nil, errors.New("小苹果解密参数无效")
		}
		cipher.NewCBCDecrypter(block, []byte(iv)).CryptBlocks(plain, encrypted)
	} else {
		for offset := 0; offset < len(encrypted); offset += aes.BlockSize {
			block.Decrypt(plain[offset:], encrypted[offset:])
		}
	}
	return pkcs7Unpad(plain, aes.BlockSize)
}

func xiaopingguoProtoField(out []byte, number int, data []byte) []byte {
	out = binary.AppendUvarint(out, uint64(number<<3|2))
	out = binary.AppendUvarint(out, uint64(len(data)))
	return append(out, data...)
}

func xiaopingguoProto(data []byte) ([]xiaopingguoField, error) {
	var fields []xiaopingguoField
	for len(data) > 0 {
		tag, size := binary.Uvarint(data)
		if size <= 0 || tag>>3 == 0 || tag>>3 > (1<<29)-1 {
			return nil, errors.New("小苹果 Protobuf 字段无效")
		}
		data = data[size:]
		field := xiaopingguoField{number: int(tag >> 3), wire: byte(tag & 7)}
		if field.wire == 0 {
			field.value, size = binary.Uvarint(data)
			if size <= 0 {
				return nil, errors.New("小苹果 Protobuf 整数无效")
			}
			data = data[size:]
		} else {
			var length uint64
			switch field.wire {
			case 2:
				length, size = binary.Uvarint(data)
				if size <= 0 {
					return nil, errors.New("小苹果 Protobuf 长度无效")
				}
				data = data[size:]
			case 1:
				length = 8
			case 5:
				length = 4
			default:
				return nil, errors.New("小苹果 Protobuf 类型无效")
			}
			if length > uint64(len(data)) {
				return nil, errors.New("小苹果 Protobuf 数据不完整")
			}
			field.data, data = data[:int(length)], data[int(length):]
		}
		fields = append(fields, field)
	}
	return fields, nil
}

func xiaopingguoFlat(fields []xiaopingguoField) map[int]string {
	result := map[int]string{}
	for _, field := range fields {
		switch field.wire {
		case 0:
			result[field.number] = strconv.FormatUint(field.value, 10)
		case 2:
			result[field.number] = string(field.data)
		}
	}
	return result
}

func xiaopingguoResponse(payload []byte) ([]byte, error) {
	fields, err := xiaopingguoProto(payload)
	if err != nil {
		return nil, err
	}
	flat := xiaopingguoFlat(fields)
	if code := flat[1]; code != "" && code != "200" {
		return nil, fmt.Errorf("小苹果接口 %s：%s", code, truncate(flat[2], 200))
	}
	for _, field := range fields {
		if field.number == 3 && field.wire == 2 {
			return field.data, nil
		}
	}
	return nil, errors.New("小苹果接口未返回数据")
}

func xiaopingguoBody(params []xiaopingguoParam, timestamp int64) ([]byte, error) {
	random, err := xiaopingguoRandom(8, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
	if err != nil {
		return nil, err
	}
	var entries []string
	for _, param := range params {
		if param.value != "" {
			entries = append(entries, param.key+"="+param.value)
		}
	}
	encrypted, err := xiaopingguoEncrypt([]byte(strings.Join(entries, "&")+strconv.FormatInt(timestamp, 10)), []byte(xiaopingguoBodyKey), nil)
	if err != nil {
		return nil, err
	}
	text := random + base64.StdEncoding.EncodeToString(encrypted)
	noise, err := xiaopingguoRandom(20, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
	if err != nil {
		return nil, err
	}
	body := xiaopingguoProtoField(nil, 1, []byte(text[:20]))
	body = xiaopingguoProtoField(body, 2, []byte(text[20:]))
	body = xiaopingguoProtoField(body, 3, []byte(noise))
	body = binary.AppendUvarint(body, 4<<3)
	body = binary.AppendUvarint(body, uint64(timestamp))
	return xiaopingguoProtoField(body, 5, []byte(random)), nil
}

func (d *Downloader) xiaopingguoHeaders(timestamp int64) (map[string]string, error) {
	d.xiaopingguoOnce.Do(func() {
		d.xiaopingguoDevice, d.xiaopingguoDeviceError = xiaopingguoRandom(32, "0123456789ABCDEF")
	})
	if d.xiaopingguoDeviceError != nil {
		return nil, d.xiaopingguoDeviceError
	}
	random, err := xiaopingguoRandom(12, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
	if err != nil {
		return nil, err
	}
	random = base64.StdEncoding.EncodeToString([]byte(random))
	stamp := strconv.FormatInt(timestamp, 10)
	der, err := base64.StdEncoding.DecodeString(xiaopingguoPublicKey)
	if err != nil {
		return nil, err
	}
	parsed, err := x509.ParsePKIXPublicKey(der)
	if err != nil {
		return nil, err
	}
	public, valid := parsed.(*rsa.PublicKey)
	if !valid {
		return nil, errors.New("小苹果内置公钥无效")
	}
	signature, err := rsa.EncryptPKCS1v15(rand.Reader, public, []byte(stamp+random+"1003"))
	if err != nil {
		return nil, err
	}
	sig2, err := xiaopingguoEncrypt([]byte(stamp+random), []byte(xiaopingguoSignatureKey), nil)
	if err != nil {
		return nil, err
	}
	encodedSignature := base64.StdEncoding.EncodeToString(sig2)
	device := d.xiaopingguoDevice
	params := map[string]any{
		"country": "CN", "vName": "1.0.0.3", "cpuId": "", "young": 0, "facturer": "OnePlus",
		"pkg": "com.juechufsh.android.xpg1", "uuid": device, "resolution": "1080x2256",
		"mac": "02%3A00%3A00%3A00%3A00%3A00", "sig": base64.StdEncoding.EncodeToString(signature),
		"abid": "2557", "model": "PJX110", "plat": "android", "udid": device, "dpi": "480",
		"net": "1", "lang": "zh", "random_str": random, "brand": "OnePlus", "timestamp": timestamp,
		"density": "3.0", "appName": "%E5%B0%8F%E8%8B%B9%E6%9E%9C%E5%BD%B1%E8%A7%86",
		"cpu": "arm64-v8a", "chid": "10000", "carrier": "%E8%81%94%E9%80%9A",
		"sig2": encodedSignature[:8], "v": 1, "sig3": encodedSignature[8:], "tenantId": "xpg",
		"_vOsCode": "36", "vOs": "16", "vApp": "1003", "device": 0, "androidID": strings.ToLower(device[:16]),
	}
	plain, err := json.Marshal(params)
	if err != nil {
		return nil, err
	}
	encrypted, err := xiaopingguoEncrypt(plain, []byte(xiaopingguoHeaderKey), []byte(xiaopingguoHeaderKey))
	if err != nil {
		return nil, err
	}
	publicParams, err := json.Marshal(map[string]string{"paramsData": hex.EncodeToString(encrypted)})
	if err != nil {
		return nil, err
	}
	return map[string]string{"Cache-Control": "no-cache", "Accept": "application/x-protobuf",
		"Content-Type": "application/x-protobuf", "publicParams": string(publicParams)}, nil
}

func (d *Downloader) xiaopingguoRequest(ctx context.Context, path string, params []xiaopingguoParam) ([]byte, error) {
	timestamp := time.Now().UnixMilli()
	headers, err := d.xiaopingguoHeaders(timestamp)
	if err != nil {
		return nil, err
	}
	request := duanjuRequest{Source: sourceXiaopingguo, Address: d.providerBaseURL(sourceXiaopingguo) + path,
		Agent: xiaopingguoUserAgent, Headers: headers}
	if params != nil {
		request.Method = http.MethodPost
		request.Body, err = xiaopingguoBody(params, timestamp)
		if err != nil {
			return nil, err
		}
	}
	payload, err := d.duanjuDo(ctx, request)
	if err != nil {
		return nil, err
	}
	return xiaopingguoResponse(payload)
}
