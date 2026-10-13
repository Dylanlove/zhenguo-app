package ysp

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
)

type assetToken struct {
	URL     string            `json:"url"`
	Headers map[string]string `json:"headers"`
}

func newProxyCodec(root string) (cipher.AEAD, error) {
	name := filepath.Join(root, "proxy.key")
	key, err := os.ReadFile(name)
	if err != nil || len(key) != 32 {
		key = make([]byte, 32)
		if _, err = rand.Read(key); err != nil {
			return nil, err
		}
		if err = os.MkdirAll(root, 0700); err != nil {
			return nil, err
		}
		if err = os.WriteFile(name, key, 0600); err != nil {
			return nil, err
		}
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	return cipher.NewGCM(block)
}
func (s *Service) encodeAsset(address string, headers map[string]string) string {
	raw, _ := json.Marshal(assetToken{address, headers})
	nonce := make([]byte, s.proxy.NonceSize())
	if _, err := rand.Read(nonce); err != nil {
		panic(err)
	}
	return base64.RawURLEncoding.EncodeToString(s.proxy.Seal(nonce, nonce, raw, nil))
}
func (s *Service) decodeAsset(value string) (assetToken, error) {
	if len(value) > 16384 {
		return assetToken{}, errors.New("央视频分片令牌过长")
	}
	raw, err := base64.RawURLEncoding.DecodeString(value)
	if err != nil || len(raw) < s.proxy.NonceSize()+s.proxy.Overhead() {
		return assetToken{}, errors.New("央视频分片令牌无效")
	}
	raw, err = s.proxy.Open(nil, raw[:s.proxy.NonceSize()], raw[s.proxy.NonceSize():], nil)
	if err != nil {
		return assetToken{}, errors.New("央视频分片令牌验证失败")
	}
	var token assetToken
	if err = json.Unmarshal(raw, &token); err != nil || absoluteURL(token.URL, token.URL) == "" {
		return assetToken{}, errors.New("央视频分片地址无效")
	}
	return token, nil
}
