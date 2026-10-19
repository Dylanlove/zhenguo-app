package ysp

import (
	"embed"
	"encoding/json"
	"errors"
	"strings"
)

//go:embed assets/*
var bundled embed.FS

const Version = "9.5.0"

type Channel struct {
	ID         string `json:"id"`
	Name       string `json:"name"`
	CnlID      string `json:"cnlid"`
	PID        string `json:"pid"`
	Definition string `json:"definition"`
	LiveID     string `json:"liveId"`
	Group      string `json:"group"`
	TvgID      string `json:"tvgId"`
	Catchup    bool   `json:"catchup"`
	Ultra      bool   `json:"ultra"`
}

type Settings struct {
	Quality string `json:"quality"`
	Share   bool   `json:"share"`
	Port    int    `json:"port"`
}

type Plan struct {
	URL     string            `json:"url"`
	Headers map[string]string `json:"headers,omitempty"`
	Engine  string            `json:"engine"`
	Quality string            `json:"quality"`
	Expires int64             `json:"expires"`
}

func catalog() ([]Channel, map[string]string, error) {
	raw, err := bundled.ReadFile("assets/channels.json")
	if err != nil {
		return nil, nil, err
	}
	var channels []Channel
	if err = json.Unmarshal(raw, &channels); err != nil {
		return nil, nil, err
	}
	raw, err = bundled.ReadFile("assets/aliases.json")
	if err != nil {
		return nil, nil, err
	}
	aliases := map[string]string{}
	if err = json.Unmarshal(raw, &aliases); err != nil {
		return nil, nil, err
	}
	if len(channels) != 64 {
		return nil, nil, errors.New("央视频频道数据不完整")
	}
	return channels, aliases, nil
}

func normalizeID(value string, aliases map[string]string) string {
	value = strings.ToLower(strings.TrimSuffix(strings.TrimSpace(value), ".m3u8"))
	if canonical := aliases[value]; canonical != "" {
		return canonical
	}
	return value
}
