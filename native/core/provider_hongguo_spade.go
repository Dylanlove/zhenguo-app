package core

import (
	"bytes"
	"crypto/aes"
	"crypto/cipher"
	"crypto/sha512"
	"errors"
	"strings"
)

var hongguoSpadeConstants = [...]byte{
	0x4d, 0xd4, 0xc2, 0xe6, 0xb8, 0x31, 0x62, 0x09, 0x0e, 0x52, 0xb3, 0xc7, 0xa6, 0x73, 0x3b, 0xa4,
	0x1c, 0xb2, 0x46, 0x2b, 0x82, 0x9a, 0xb5, 0x8a, 0x19, 0x6b, 0x39, 0xdb, 0x57, 0x17, 0x75, 0x24,
	0xf4, 0x9b, 0xaf, 0x7f, 0x08, 0xe8, 0xd6, 0x8d, 0x26, 0xa7, 0x2e, 0x37, 0xc1, 0xa9, 0x5a, 0x2f,
	0x1f, 0x05, 0xa5, 0x18, 0x92, 0xae, 0xf2, 0x94, 0x97, 0x32, 0xb6, 0x2a, 0x38, 0xaa, 0xdd, 0x58,
}

func decryptHongguoSpadeURL(encoded string, seed []byte) (string, error) {
	if len(encoded) > 16384 || len(seed) == 0 {
		return "", errors.New("红果加密播放地址或解密种子无效")
	}
	raw, err := decodeHongguoBase64(encoded)
	if err != nil || len(raw) < 4+aes.BlockSize || raw[0] != 0xa8 || raw[2] != 1 || raw[3] != 0 {
		return "", errors.New("红果加密播放地址格式无效")
	}
	first := sha512.Sum512(seed)
	material := append(first[:], hongguoSpadeConstants[:]...)
	second := sha512.Sum512(material)
	block, err := aes.NewCipher(second[:16])
	if err != nil {
		return "", err
	}
	ciphertext := raw[4 : 4+(len(raw)-4)/aes.BlockSize*aes.BlockSize]
	plain := make([]byte, len(ciphertext))
	cipher.NewCBCDecrypter(block, second[16:32]).CryptBlocks(plain, ciphertext)
	if padding := plain[len(plain)-1]; padding > 0 && padding <= aes.BlockSize {
		plain, err = pkcs7Unpad(plain, aes.BlockSize)
		if err != nil {
			return "", errors.New("红果播放地址解密失败")
		}
	}
	address := strings.TrimSpace(string(bytes.TrimRight(plain, "\x00")))
	if !isProviderHTTPMediaURL(address) {
		return "", errors.New("红果播放地址解密后不是有效媒体地址")
	}
	return address, nil
}
