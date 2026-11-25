package core

import (
    "net/http"
    "strings"
)

func applyHongguoRuntimeSignature(request *http.Request, body []byte) bool {
    if request == nil || request.URL == nil || !hongguoRuntimeAvailable() {
        return false
    }
    target := request.URL.Scheme + "://" + request.URL.Host + request.URL.RequestURI()
    payload := ""
    if len(body) > 0 && len(body) <= 4096 {
        payload = string(body)
    }
    fields := strings.Join([]string{"url", target, "data", payload}, "\r\n")
    signed := hongguoRuntimeSign(target, fields)
    if signed == "" {
        return false
    }
    pairs := strings.Split(signed, "\r\n")
    applied := 0
    for index := 0; index+1 < len(pairs); index += 2 {
        name := strings.TrimSpace(pairs[index])
        value := strings.TrimSpace(pairs[index+1])
        if name == "" || value == "" {
            continue
        }
        request.Header.Set(name, value)
        applied++
    }
    return applied > 0
}
