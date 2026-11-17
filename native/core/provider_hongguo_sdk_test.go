package core

import (
	"context"
	"encoding/hex"
	"errors"
	"testing"
	"time"

	ohg "github.com/beilunyang/openhongguo/sdk"
	"github.com/beilunyang/openhongguo/sdk/model"
)

type hongguoSDKStub struct {
	playback *model.Playback
	err      error
	calls    int
	lastID   string
}

func (s *hongguoSDKStub) ResolvePlayback(_ context.Context, episodeID string, _ ohg.PlaybackOptions) (*model.Playback, error) {
	s.calls++
	s.lastID = episodeID
	return s.playback, s.err
}

func TestHongguoSdkMediaFromPlaybackSelectsBestAndKeepsVariants(t *testing.T) {
	pb := &model.Playback{
		EpisodeID:       "1",
		DurationSeconds: 75,
		Streams: []model.Stream{
			{URL: "https://video.example.com/a/720.mp4", Definition: "720p", Width: 1280, Height: 720, Bitrate: 2_000_000},
			{URL: "https://video.example.com/a/1080.mp4", Definition: "1080p", Width: 1920, Height: 1080, Bitrate: 4_000_000},
			{URL: "https://video.example.com/a/480.mp4", Definition: "480p", Width: 854, Height: 480, Bitrate: 800_000},
		},
	}
	media, err := hongguoSdkMediaFromPlayback(pb)
	if err != nil {
		t.Fatal(err)
	}
	if media.URL != "https://video.example.com/a/1080.mp4" || media.Quality != 1080 {
		t.Fatalf("selected wrong stream: url=%s quality=%d", media.URL, media.Quality)
	}
	if len(media.Variants) != 3 {
		t.Fatalf("variants = %d, want 3", len(media.Variants))
	}
	if media.Duration != 75*time.Second {
		t.Fatalf("duration = %v", media.Duration)
	}
	if media.RouteName != hongguoSdkRouteName {
		t.Fatalf("route = %q", media.RouteName)
	}
}

func TestHongguoSdkMediaDerivesCENCKey(t *testing.T) {
	pb := &model.Playback{
		EpisodeID:   "1",
		Protected:   true,
		KeyMaterial: "nLwSxG6JI85zhT//c7AK4HauO+lzrg7TdZwO0XWrP+J0pDypqQ==",
		Streams: []model.Stream{
			{URL: "https://video.example.com/a/720.mp4", Height: 720, Protected: true, Encryption: "cenc-aes-ctr"},
		},
	}
	media, err := hongguoSdkMediaFromPlayback(pb)
	if err != nil {
		t.Fatal(err)
	}
	want, _ := hex.DecodeString("1be760855c48a8c86000eeb8c5bb1010")
	if hex.EncodeToString(media.CENCKey) != hex.EncodeToString(want) {
		t.Fatalf("cenc key = %x, want %x", media.CENCKey, want)
	}
}

func TestHongguoSdkMediaRejectsBadModels(t *testing.T) {
	if _, err := hongguoSdkMediaFromPlayback(nil); err == nil {
		t.Fatal("nil playback must fail")
	}
	if _, err := hongguoSdkMediaFromPlayback(&model.Playback{}); err == nil {
		t.Fatal("playback without stream URL must fail")
	}
	bad := &model.Playback{
		Protected:   true,
		KeyMaterial: "not-a-real-key",
		Streams:     []model.Stream{{URL: "https://video.example.com/a.mp4"}},
	}
	if _, err := hongguoSdkMediaFromPlayback(bad); err == nil {
		t.Fatal("protected playback with invalid key material must fail")
	}
}

func TestResolveHongguoSdkMediaUsesInjectedClient(t *testing.T) {
	stub := &hongguoSDKStub{playback: &model.Playback{
		EpisodeID: "7697465535398677529",
		Streams:   []model.Stream{{URL: "https://video.example.com/a.mp4", Height: 720}},
	}}
	d := &Downloader{hongguoSdk: stub}
	media, err := d.resolveHongguoSdkMedia(context.Background(), "7697465535398677529")
	if err != nil {
		t.Fatal(err)
	}
	if stub.calls != 1 || stub.lastID != "7697465535398677529" {
		t.Fatalf("client calls=%d lastID=%s", stub.calls, stub.lastID)
	}
	if media.URL != "https://video.example.com/a.mp4" {
		t.Fatalf("url=%s", media.URL)
	}
}

func TestHongguoSdkPlaybackKeepsDRMProtectedModel(t *testing.T) {
	pb := &model.Playback{
		Protected:   true,
		KeyMaterial: "nLwSxG6JI85zhT//c7AK4HauO+lzrg7TdZwO0XWrP+J0pDypqQ==",
		Streams:     []model.Stream{{URL: "https://video.example.com/a.mp4", Height: 720}},
	}
	stub := &hongguoSDKStub{playback: pb, err: ohg.ErrDRMProtected}
	d := &Downloader{hongguoSdk: stub}
	got, err := d.hongguoSdkPlayback(context.Background(), "1")
	if err != nil {
		t.Fatalf("DRM-protected model must be retained: %v", err)
	}
	if got != pb {
		t.Fatal("expected the protected playback model")
	}
	media, err := hongguoSdkMediaFromPlayback(got)
	if err != nil || len(media.CENCKey) != 16 {
		t.Fatalf("protected media lost its key: key=%x err=%v", media.CENCKey, err)
	}
}

func TestResolveHongguoSdkMediaPropagatesError(t *testing.T) {
	stub := &hongguoSDKStub{err: errors.New("empty")}
	d := &Downloader{hongguoSdk: stub}
	if _, err := d.resolveHongguoSdkMedia(context.Background(), "1"); err == nil {
		t.Fatal("client error must propagate")
	}
}
