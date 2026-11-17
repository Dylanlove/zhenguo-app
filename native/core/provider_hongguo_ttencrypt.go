package core

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/sha512"
	"encoding/hex"
)

var hongguoTTConstant, _ = hex.DecodeString("4dd4c2e6b83162090e52b3c7a6733ba41cb2462b829ab58a196b39db57177524f49baf7f08e8d68d26a72e37c1a95a2f1f05a51892aef2949732b62a38aadd58")
var hongguoTTKeyIV = hongguoTTKeyIVBytes()

func hongguoTTKeyIVBytes() [64]byte {
	prefixHash := sha512.Sum512(hongguoTTPrefix)
	return sha512.Sum512(append(prefixHash[:], hongguoTTConstant...))
}

var hongguoTTPrefix, _ = hex.DecodeString("3176c9b6d71579d7e82179c9e7cbde787b54d541bad3b15f2e8fed92293fa25a")

func hongguoTTEncrypt(input []byte) []byte {
	digest := sha512.Sum512(input)
	plain := make([]byte, 0, len(digest)+len(input)+aes.BlockSize)
	plain = append(plain, digest[:]...)
	plain = append(plain, input...)
	padding := aes.BlockSize - len(plain)%aes.BlockSize
	for i := 0; i < padding; i++ {
		plain = append(plain, byte(padding))
	}
	block, err := aes.NewCipher(hongguoTTKeyIV[:16])
	if err != nil {
		return nil
	}
	encrypted := make([]byte, len(plain))
	cipher.NewCBCEncrypter(block, hongguoTTKeyIV[16:32]).CryptBlocks(encrypted, plain)
	out := make([]byte, 0, 6+len(hongguoTTPrefix)+len(encrypted))
	out = append(out, 0x74, 0x63, 0x05, 0x10, 0x00, 0x00)
	out = append(out, hongguoTTPrefix...)
	return append(out, encrypted...)
}
