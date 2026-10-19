package core

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"strings"
	"testing"
)

func TestNativeCapabilitiesRespectEditionAndSearchImplementation(t *testing.T) {
	items := nativeCapabilities("test")
	seen := map[string]bool{}
	for _, item := range items {
		if seen[item.ID] || !nativeSourceAvailable(item.ID) || len(item.Fingerprint) != 16 {
			t.Fatalf("invalid source descriptor: %+v", item)
		}
		seen[item.ID] = true
		if item.SearchPaging && !item.OnlineSearch {
			t.Fatal("search paging advertised without online search")
		}
		if spec, found := duanjuSourceSpecFor(item.ID); found {
			if item.OnlineSearch != spec.Searcher || item.SearchPaging != (item.ID == sourceChaoguo && spec.Searcher) {
				t.Fatalf("descriptor disagrees with search implementation: %+v", item)
			}
		}
	}
	if !seen[sourceHongguo] || buildAllSources != "true" && len(items) != 1 {
		t.Fatalf("wrong edition sources: %+v", items)
	}
	encoded, err := json.Marshal(items)
	if err != nil || strings.Contains(string(encoded), "http:") || strings.Contains(string(encoded), "https:") {
		t.Fatal("source capabilities must not contain endpoint or credential data")
	}
}

func TestDiagnosticFailurePreservesWrappedNetworkCauses(t *testing.T) {
	for _, item := range []struct {
		err    error
		status int
		code   string
	}{
		{fmt.Errorf("request: %w", &net.DNSError{Err: "no such host", Name: "example.test"}), 0, "DNS"},
		{fmt.Errorf("request: %w", context.DeadlineExceeded), 0, "TIMEOUT"},
		{context.Canceled, 0, "CANCELLED"},
		{errors.New("handshake interrupted"), 0, "TLS"},
		{errors.New("access rejected"), 403, "HTTP_403"},
		{&legacyAPIError{code: "1001", message: "refused"}, 200, "BUSINESS"},
	} {
		if got := diagnosticFailureCode(publicError(item.err), item.status); got != item.code {
			t.Fatalf("classification = %s, want %s", got, item.code)
		}
	}
}
