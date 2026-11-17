package core

import (
	"bytes"
	"context"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"strconv"
	"strings"
	"sync"
	"time"

	ohg "github.com/beilunyang/openhongguo/sdk"
	"github.com/beilunyang/openhongguo/sdk/model"
	fhttp "github.com/bogdanfinn/fhttp"
	tlsclient "github.com/bogdanfinn/tls-client"
	"github.com/bogdanfinn/tls-client/profiles"
)

const hongguoSdkRouteName = "红果SDK高清"

type hongguoDo func(context.Context, *ohg.Request) (*ohg.Response, error)

type hongguoSDKTransport struct{ do hongguoDo }

func (t *hongguoSDKTransport) Do(ctx context.Context, request *ohg.Request) (*ohg.Response, error) {
	return t.do(ctx, request)
}

type hongguoSDKMemoryStore struct {
	mu      sync.Mutex
	profile *ohg.DeviceProfile
}

func (s *hongguoSDKMemoryStore) Load(ctx context.Context) (*ohg.DeviceProfile, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.profile == nil {
		return nil, ohg.ErrProfileNotFound
	}
	copy := *s.profile
	return &copy, nil
}

func (s *hongguoSDKMemoryStore) Save(ctx context.Context, profile *ohg.DeviceProfile) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	if profile == nil {
		return ohg.ErrInvalidOptions
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	copy := *profile
	s.profile = &copy
	return nil
}

func (s *hongguoSDKMemoryStore) Reset(ctx context.Context) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.profile = nil
	return nil
}

type hongguoBrowserDoer interface {
	Do(*fhttp.Request) (*fhttp.Response, error)
}

func newHongguoBrowserDoer(insecure bool) (hongguoBrowserDoer, error) {
	options := []tlsclient.HttpClientOption{
		tlsclient.WithClientProfile(profiles.Chrome_150),
		tlsclient.WithRandomTLSExtensionOrder(),
		tlsclient.WithDisableHttp3(),
		tlsclient.WithNotFollowRedirects(),
		tlsclient.WithTimeoutSeconds(40),
		tlsclient.WithCookieJar(tlsclient.NewCookieJar()),
	}
	if insecure {
		options = append(options, tlsclient.WithInsecureSkipVerify())
	}
	return tlsclient.NewHttpClient(tlsclient.NewNoopLogger(), options...)
}

func hongguoBrowserTransportDo(client hongguoBrowserDoer) hongguoDo {
	return func(ctx context.Context, request *ohg.Request) (*ohg.Response, error) {
		upstream, err := fhttp.NewRequestWithContext(ctx, request.Method, request.URL, bytes.NewReader(request.Body))
		if err != nil {
			return nil, err
		}
		upstream.Header = fhttp.Header{}
		for name, value := range request.Headers {
			upstream.Header.Set(name, value)
		}
		response, err := client.Do(upstream)
		if err != nil {
			return nil, err
		}
		defer response.Body.Close()
		body, err := io.ReadAll(io.LimitReader(response.Body, 8<<20))
		if err != nil {
			return nil, err
		}
		headers := make(map[string]string, len(response.Header))
		for name, values := range response.Header {
			if strings.EqualFold(name, "Content-Encoding") || strings.EqualFold(name, "Content-Length") {
				continue
			}
			if len(values) > 0 {
				headers[name] = values[0]
			}
		}
		cookies := map[string]string{}
		for _, cookie := range response.Cookies() {
			if cookie.Name != "" {
				cookies[cookie.Name] = cookie.Value
			}
		}
		return &ohg.Response{StatusCode: response.StatusCode, Headers: headers, Body: body, Cookies: cookies}, nil
	}
}

func newHongguoSDKClient(do hongguoDo, overrides map[string]string) (*ohg.Client, error) {
	options := ohg.Options{
		Transport:     &hongguoSDKTransport{do: do},
		ProfileStore:  &hongguoSDKMemoryStore{},
		RetryAttempts: 1,
		DeviceResets:  ohg.Int(2),
	}
	if value := overrides["api"]; value != "" {
		options.APIOrigin = value
	}
	if value := overrides["register"]; value != "" {
		options.RegisterOrigin = value
	}
	return ohg.NewClient(options)
}

type hongguoPlaybackClient interface {
	ResolvePlayback(ctx context.Context, episodeID string, options ohg.PlaybackOptions) (*model.Playback, error)
}

func (d *Downloader) hongguoSdkPlayback(ctx context.Context, videoID string) (*model.Playback, error) {
	client, err := d.hongguoSdkClient()
	if err != nil {
		return nil, err
	}
	pb, err := client.ResolvePlayback(ctx, videoID, ohg.PlaybackOptions{})
	if errors.Is(err, ohg.ErrDRMProtected) && pb != nil {
		return pb, nil
	}
	return pb, err
}

func (d *Downloader) hongguoSdkClient() (hongguoPlaybackClient, error) {
	d.hongguoMu.Lock()
	defer d.hongguoMu.Unlock()
	if d.hongguoSdk != nil {
		return d.hongguoSdk, nil
	}
	doer, err := newHongguoBrowserDoer(d.cfg.InsecureTLS)
	if err != nil {
		return nil, err
	}
	client, err := newHongguoSDKClient(hongguoBrowserTransportDo(doer), nil)
	if err != nil {
		return nil, err
	}
	d.hongguoSdk = client
	return client, nil
}

func hongguoSdkMediaFromPlayback(pb *model.Playback) (providerMedia, error) {
	if pb == nil {
		return providerMedia{}, errors.New("红果 SDK 未返回播放模型")
	}
	var key []byte
	if pb.Protected {
		contentKey, err := ohg.ContentKey(pb)
		if err != nil {
			return providerMedia{}, fmt.Errorf("红果 SDK 内容密钥不可用：%w", err)
		}
		key, err = hex.DecodeString(contentKey.Hex)
		if err != nil || len(key) != 16 {
			return providerMedia{}, errors.New("红果 SDK 内容密钥格式无效")
		}
	}
	var variants []providerMedia
	best := -1
	selected := providerMedia{}
	for _, stream := range pb.Streams {
		address := strings.TrimSpace(stream.URL)
		if address == "" || len(address) > 8192 || !isProviderHTTPMediaURL(address) {
			continue
		}
		quality := stream.Height
		if quality <= 0 {
			quality, _ = strconv.Atoi(hongguoQualityNumber.FindString(stream.Definition))
		}
		media := providerMedia{
			URL:       address,
			Referer:   "https://novel.snssdk.com/",
			RouteName: hongguoSdkRouteName,
			CENCKey:   key,
			Quality:   quality,
		}
		if stream.HLS {
			media.Playlist = address
		}
		variants = append(variants, media)
		if selected.URL == "" || quality > best {
			selected, best = media, quality
		}
	}
	if selected.URL == "" {
		return providerMedia{}, errors.New("红果 SDK 播放模型没有可用的媒体地址")
	}
	selected.Variants = variants
	if pb.DurationSeconds > 0 {
		selected.Duration = time.Duration(pb.DurationSeconds) * time.Second
	}
	return selected, nil
}

func (d *Downloader) resolveHongguoSdkMedia(ctx context.Context, videoID string) (providerMedia, error) {
	pb, err := d.hongguoSdkPlayback(ctx, videoID)
	if err != nil {
		return providerMedia{}, err
	}
	return hongguoSdkMediaFromPlayback(pb)
}
