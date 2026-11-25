//go:build !android || !cgo

package core

func hongguoRuntimeAvailable() bool {
    return false
}

func hongguoRuntimeSign(identity, fields string) string {
    return ""
}
