package core

import (
	"context"
	"crypto/x509"
	"errors"
	"net"
	"strconv"
	"strings"
)

func diagnosticFailureCode(err error, status int) string {
	if err == nil {
		return ""
	}
	if errors.Is(err, context.Canceled) {
		return "CANCELLED"
	}
	var network net.Error
	if errors.Is(err, context.DeadlineExceeded) || errors.As(err, &network) && network.Timeout() {
		return "TIMEOUT"
	}
	var dns *net.DNSError
	if errors.As(err, &dns) {
		return "DNS"
	}
	var authority x509.UnknownAuthorityError
	var certificate x509.CertificateInvalidError
	message := strings.ToLower(err.Error())
	if errors.As(err, &authority) || errors.As(err, &certificate) || strings.Contains(message, "tls") || strings.Contains(message, "handshake") {
		return "TLS"
	}
	if status > 0 && (status < 200 || status >= 300) {
		return "HTTP_" + strconv.Itoa(status)
	}
	var legacy *legacyAPIError
	var huangdou *huangdouAPIError
	if errors.As(err, &legacy) || errors.As(err, &huangdou) {
		return "BUSINESS"
	}
	if errors.As(err, &network) {
		return "CONNECTION"
	}
	if strings.Contains(message, "json") || strings.Contains(message, "解析") || strings.Contains(message, "格式") {
		return "DATA"
	}
	return "SOURCE"
}
