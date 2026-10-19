package ysp

import (
	"context"
	"crypto/cipher"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

type segment struct {
	sequence      int64
	duration      float64
	date          string
	address       string
	headers       map[string]string
	discontinuity bool
}
type playlistEntry struct {
	mu                           sync.Mutex
	channel                      Channel
	quality                      string
	start, end                   int64
	text                         string
	updated, lastUsed, firstUsed time.Time
	inflight                     chan struct{}
	lastError                    string
	plan                         Plan
	high                         Plan
	promoting                    bool
	promotion                    uint64
	promoteCancel                context.CancelFunc
	segments                     []segment
	seen                         map[string]bool
	seenOrder                    []string
	sequence                     int64
	discontinuities              int64
	engine                       string
}
type asset struct {
	address     string
	headers     map[string]string
	token       string
	lastUsed    time.Time
	data        []byte
	contentType string
}
type event struct {
	Time    string `json:"time"`
	Channel string `json:"channel"`
	Message string `json:"message"`
}

type Service struct {
	mu         sync.Mutex
	root       string
	channels   []Channel
	aliases    map[string]string
	settings   Settings
	server     *http.Server
	address    string
	started    time.Time
	ctx        context.Context
	cancel     context.CancelFunc
	client     *http.Client
	device     *deviceClient
	proxy      cipher.AEAD
	entries    map[string]*playlistEntry
	foreground *playlistEntry
	assets     map[string]*asset
	cacheBytes int
	log        []event
}

func New(root string) (*Service, error) {
	channels, aliases, err := catalog()
	if err != nil {
		return nil, err
	}
	proxy, err := newProxyCodec(root)
	if err != nil {
		return nil, err
	}
	service := &Service{root: root, channels: channels, aliases: aliases, client: directClient(), entries: map[string]*playlistEntry{}, assets: map[string]*asset{}, settings: Settings{Quality: "auto", Port: 8767}}
	if raw, err := os.ReadFile(filepath.Join(root, "settings.json")); err == nil && len(raw) < 4096 {
		json.Unmarshal(raw, &service.settings)
	}
	if service.settings.Port < 1024 || service.settings.Port > 65535 {
		service.settings.Port = 8767
	}
	if !validQuality(service.settings.Quality) {
		service.settings.Quality = "auto"
	}
	service.device = newDeviceClient(root)
	service.proxy = proxy
	return service, nil
}
func validQuality(value string) bool { return value == "auto" || value == "best" || value == "hd" }
func (s *Service) Start() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.server != nil {
		return nil
	}
	host := "127.0.0.1"
	if s.settings.Share {
		host = "0.0.0.0"
	}
	listener, err := net.Listen("tcp", net.JoinHostPort(host, strconv.Itoa(s.settings.Port)))
	if err != nil {
		return fmt.Errorf("央视频服务端口 %d 无法使用：%w", s.settings.Port, err)
	}
	s.ctx, s.cancel = context.WithCancel(context.Background())
	s.started = time.Now()
	s.address = "http://127.0.0.1:" + strconv.Itoa(s.settings.Port)
	s.server = &http.Server{Handler: s, ReadHeaderTimeout: 5 * time.Second, IdleTimeout: 30 * time.Second, WriteTimeout: 45 * time.Second}
	server := s.server
	ctx := s.ctx
	go func() { server.Serve(listener) }()
	go s.maintenance(ctx)
	return nil
}
func (s *Service) Close() {
	s.mu.Lock()
	server, cancel := s.server, s.cancel
	s.server = nil
	s.address = ""
	s.mu.Unlock()
	if cancel != nil {
		cancel()
	}
	if server != nil {
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer cancel()
		server.Shutdown(ctx)
	}
	s.client.CloseIdleConnections()
	s.device.client.CloseIdleConnections()
}
func (s *Service) maintenance(ctx context.Context) {
	timer := time.NewTicker(15 * time.Second)
	defer timer.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-timer.C:
			s.mu.Lock()
			for id, value := range s.assets {
				if time.Since(value.lastUsed) > 15*time.Minute {
					s.cacheBytes -= len(value.data)
					delete(s.assets, id)
				}
			}
			for key, entry := range s.entries {
				entry.mu.Lock()
				expired := time.Since(entry.lastUsed) > 5*time.Minute && entry.inflight == nil
				entry.mu.Unlock()
				if expired {
					delete(s.entries, key)
				}
			}
			active := len(s.entries) > 0
			s.mu.Unlock()
			if active {
				go s.device.heartbeat()
			}
		}
	}
}
func (s *Service) channel(id string) (Channel, error) {
	id = normalizeID(id, s.aliases)
	for _, channel := range s.channels {
		if channel.ID == id {
			return channel, nil
		}
	}
	return Channel{}, errors.New("央视频频道不存在")
}
func (s *Service) record(id string, err error) {
	message := safeError(err)
	if len(message) > 250 {
		message = message[:250]
	}
	s.mu.Lock()
	s.log = append(s.log, event{time.Now().In(time.FixedZone("CST", 8*3600)).Format("15:04:05"), id, message})
	if len(s.log) > 100 {
		s.log = append([]event(nil), s.log[len(s.log)-100:]...)
	}
	s.mu.Unlock()
}
func (s *Service) Configure(settings Settings) error {
	if !validQuality(settings.Quality) || settings.Port < 1024 || settings.Port > 65535 {
		return errors.New("央视频设置无效")
	}
	s.mu.Lock()
	old := s.settings
	s.mu.Unlock()
	restart := old.Share != settings.Share || old.Port != settings.Port
	if restart {
		s.Close()
	}
	s.mu.Lock()
	s.settings = settings
	s.mu.Unlock()
	if err := s.Start(); err != nil {
		s.mu.Lock()
		s.settings = old
		s.mu.Unlock()
		s.Start()
		return err
	}
	raw, err := json.Marshal(settings)
	if err != nil {
		return err
	}
	if err = os.MkdirAll(s.root, 0700); err != nil {
		return err
	}
	return os.WriteFile(filepath.Join(s.root, "settings.json"), raw, 0600)
}
func (s *Service) Status() map[string]any {
	s.mu.Lock()
	settings, address, started := s.settings, s.address, s.started
	entries := make([]*playlistEntry, 0, len(s.entries))
	for _, entry := range s.entries {
		entries = append(entries, entry)
	}
	log := append([]event(nil), s.log...)
	assets, cacheBytes := len(s.assets), s.cacheBytes
	s.mu.Unlock()
	playing := []map[string]any{}
	for _, entry := range entries {
		entry.mu.Lock()
		if time.Since(entry.lastUsed) < 2*time.Minute {
			playing = append(playing, map[string]any{"channel": entry.channel.ID, "name": entry.channel.Name, "engine": entry.plan.Engine, "quality": entry.plan.Quality, "refreshing": entry.inflight != nil, "upgrading": entry.promoting, "lastError": entry.lastError, "catchup": entry.start > 0})
		}
		entry.mu.Unlock()
	}
	d := s.device
	var sessionReady, heartbeats, links, rotations any
	deviceBusy := !d.mu.TryLock()
	if !deviceBusy {
		sessionReady = d.session != nil
		heartbeats = 0
		if d.session != nil {
			heartbeats = d.session.heartbeats
		}
		active := 0
		for _, last := range d.links {
			if time.Since(last) < 15*time.Second {
				active++
			}
		}
		links = active
		rotations = 0
		if d.state.RotationDay == time.Now().In(time.FixedZone("CST", 8*3600)).Format("2006-01-02") {
			rotations = d.state.Rotations
		}
		d.mu.Unlock()
	}
	addresses := []string{}
	if address != "" {
		addresses = append(addresses, address+"/all.m3u")
	}
	if settings.Share {
		if interfaces, err := net.InterfaceAddrs(); err == nil {
			for _, raw := range interfaces {
				network, ok := raw.(*net.IPNet)
				if !ok || network.IP.IsLoopback() || network.IP.To4() == nil {
					continue
				}
				addresses = append(addresses, "http://"+net.JoinHostPort(network.IP.String(), strconv.Itoa(settings.Port))+"/all.m3u")
			}
		}
	}
	uptime := int64(0)
	if !started.IsZero() && address != "" {
		uptime = int64(time.Since(started).Seconds())
	}
	return map[string]any{"ok": true, "version": Version, "running": address != "", "base": address, "settings": settings, "subscriptions": addresses, "uptimeSeconds": uptime, "channels": len(s.channels), "playing": playing, "events": log, "assets": assets, "segmentCacheBytes": cacheBytes, "deviceBusy": deviceBusy, "deviceSession": sessionReady, "deviceLinks": links, "heartbeatCount": heartbeats, "identityRotationsToday": rotations, "author": "Gary's Club", "community": "https://t.me/garysclub"}
}
func (s *Service) Command(command string, payload map[string]any) (any, error) {
	if command == "idle" {
		s.selectPlayback(nil)
		return map[string]bool{"released": true}, nil
	}
	if command == "stop" {
		s.Close()
		return map[string]bool{"stopped": true}, nil
	}
	if command == "configure" {
		raw, err := json.Marshal(payload)
		if err != nil {
			return nil, err
		}
		var settings Settings
		if err = json.Unmarshal(raw, &settings); err != nil {
			return nil, err
		}
		if err = s.Configure(settings); err != nil {
			return nil, err
		}
		return s.Status(), nil
	}
	switch command {
	case "status":
		return s.Status(), nil
	case "channels":
		return map[string]any{"items": s.channels}, nil
	case "rules":
		list, _ := bundled.ReadFile("assets/ysp.list")
		module, _ := bundled.ReadFile("assets/ysp.module")
		return map[string]string{"list": string(list), "module": string(module)}, nil
	case "playback":
		if err := s.Start(); err != nil {
			return nil, err
		}
		channel, err := s.channel(text(payload["channel"]))
		if err != nil {
			return nil, err
		}
		s.mu.Lock()
		base, quality := s.address, s.settings.Quality
		s.mu.Unlock()
		if choice := text(payload["quality"]); choice != "" {
			if !validQuality(choice) {
				return nil, errors.New("央视频画质设置无效")
			}
			quality = choice
		}
		query := url.Values{"quality": {quality}}
		start, end := int64(0), int64(0)
		if value := text(payload["start"]); value != "" {
			start, err = catchupTime(value)
			if err != nil {
				return nil, err
			}
			end, err = catchupTime(text(payload["end"]))
			if err != nil {
				return nil, err
			}
			if err = validateCatchup(channel, start, end); err != nil {
				return nil, err
			}
			query.Set("utc", strconv.FormatInt(start, 10))
			query.Set("lutc", strconv.FormatInt(end, 10))
		}
		s.selectPlayback(s.getEntry(channel, quality, start, end))
		return map[string]any{"url": base + "/live/" + channel.ID + ".m3u8?" + query.Encode(), "headers": map[string]string{}, "catchup": start > 0, "quality": quality}, nil
	}
	return nil, errors.New("央视频操作无效")
}
func validateCatchup(channel Channel, start, end int64) error {
	if !channel.Catchup {
		return errors.New("该频道未提供回看")
	}
	now := time.Now().Unix()
	if start < now-7*86400 || start >= now || end <= start || end > now+60 {
		return errors.New("请选择最近 7 天内有效的回看时间")
	}
	return nil
}
func catchupTime(value string) (int64, error) {
	value = strings.TrimSpace(value)
	if parsed, err := time.Parse(time.RFC3339Nano, value); err == nil {
		return parsed.Unix(), nil
	}
	zone := time.FixedZone("CST", 8*3600)
	for _, format := range []string{"2006-01-02T15:04:05", "2006-01-02 15:04:05", "2006-01-02T15:04", "2006-01-02 15:04"} {
		if parsed, err := time.ParseInLocation(format, value, zone); err == nil {
			return parsed.Unix(), nil
		}
	}
	digits := value
	if strings.HasSuffix(strings.ToUpper(digits), "Z") {
		digits = digits[:len(digits)-1]
		zone = time.UTC
	}
	if digits == "" || strings.IndexFunc(digits, func(r rune) bool { return r < '0' || r > '9' }) >= 0 {
		return 0, errors.New("回看时间格式无效")
	}
	if len(digits) == 10 || len(digits) == 13 {
		result, err := strconv.ParseInt(digits, 10, 64)
		if len(digits) == 13 {
			result /= 1000
		}
		return result, err
	}
	format := "20060102150405"
	if len(digits) == 12 {
		format = "200601021504"
	} else if len(digits) != 14 {
		return 0, errors.New("回看时间格式无效")
	}
	result, err := time.ParseInLocation(format, digits, zone)
	return result.Unix(), err
}
func catchupQuery(query url.Values) (int64, int64, error) {
	start, end := "", ""
	if seek := query.Get("playseek"); seek != "" {
		parts := strings.SplitN(seek, "-", 2)
		start = parts[0]
		if len(parts) > 1 {
			end = parts[1]
		}
	}
	for _, key := range []string{"utc", "start", "starttime"} {
		if start == "" {
			start = query.Get(key)
		}
	}
	for _, key := range []string{"lutc", "end", "endtime"} {
		if end == "" {
			end = query.Get(key)
		}
	}
	if start == "" {
		return 0, 0, nil
	}
	from, err := catchupTime(start)
	if err != nil {
		return 0, 0, err
	}
	to := time.Now().Unix()
	if to > from+7200 {
		to = from + 7200
	}
	if end != "" {
		to, err = catchupTime(end)
	}
	return from, to, err
}

func (s *Service) selectPlayback(entry *playlistEntry) {
	s.mu.Lock()
	previous := s.foreground
	s.foreground = entry
	if previous != nil && previous != entry {
		previous.mu.Lock()
		previous.promotion++
		if previous.promoteCancel != nil {
			previous.promoteCancel()
			previous.promoteCancel = nil
		}
		previous.promoting = false
		previous.firstUsed = time.Time{}
		previous.mu.Unlock()
	}
	s.mu.Unlock()
}

func (s *Service) getEntry(channel Channel, quality string, start, end int64) *playlistEntry {
	key := channel.ID + "\x00" + quality + "\x00" + strconv.FormatInt(start, 10) + "\x00" + strconv.FormatInt(end, 10)
	s.mu.Lock()
	defer s.mu.Unlock()
	if entry := s.entries[key]; entry != nil {
		return entry
	}
	if len(s.entries) >= 128 {
		var oldestKey string
		var oldest time.Time
		for id, entry := range s.entries {
			entry.mu.Lock()
			used := entry.lastUsed
			idle := entry.inflight == nil
			entry.mu.Unlock()
			if idle && (oldestKey == "" || used.Before(oldest)) {
				oldestKey, oldest = id, used
			}
		}
		if oldestKey != "" {
			delete(s.entries, oldestKey)
		}
	}
	entry := &playlistEntry{channel: channel, quality: quality, start: start, end: end, firstUsed: time.Now(), lastUsed: time.Now()}
	s.entries[key] = entry
	return entry
}
func (s *Service) Playlist(ctx context.Context, channel Channel, quality string, start, end int64) (string, error) {
	entry := s.getEntry(channel, quality, start, end)
	for attempt := 0; attempt < 2; attempt++ {
		entry.mu.Lock()
		if entry.firstUsed.IsZero() || time.Since(entry.lastUsed) > 15*time.Second {
			entry.firstUsed = time.Now()
		}
		entry.lastUsed = time.Now()
		cached, age := entry.text, time.Since(entry.updated)
		if start == 0 && quality == "auto" && channel.LiveID != "" && !channel.Ultra && !entry.promoting && (entry.high.URL == "" || int64(entry.high.Expires) < time.Now().Unix()+60) && time.Since(entry.firstUsed) >= 10*time.Second {
			entry.promoting = true
			entry.promotion++
			go s.promote(entry, entry.promotion)
		}
		if cached != "" && age < 2*time.Second {
			entry.mu.Unlock()
			s.device.touch(channel.ID)
			return cached, nil
		}
		if entry.inflight == nil {
			entry.inflight = make(chan struct{})
			go s.refresh(entry)
		}
		ready := entry.inflight
		if cached != "" && age < 30*time.Second {
			entry.mu.Unlock()
			return cached, nil
		}
		entry.mu.Unlock()
		select {
		case <-ctx.Done():
			return "", ctx.Err()
		case <-ready:
		}
		entry.mu.Lock()
		result, message := entry.text, entry.lastError
		usable := entry.start > 0 || time.Since(entry.updated) < 2*time.Minute
		entry.mu.Unlock()
		if result != "" && usable {
			return result, nil
		}
		if message != "" {
			return "", errors.New(message)
		}
	}
	return "", errors.New("央视频播放列表暂不可用")
}
func (s *Service) promote(entry *playlistEntry, generation uint64) {
	s.mu.Lock()
	parent := s.ctx
	s.mu.Unlock()
	ctx, cancel := context.WithTimeout(parent, 15*time.Second)
	defer cancel()
	entry.mu.Lock()
	if generation != entry.promotion || time.Since(entry.lastUsed) >= 15*time.Second {
		if generation == entry.promotion {
			entry.promoting = false
		}
		entry.mu.Unlock()
		return
	}
	entry.promoteCancel = cancel
	entry.mu.Unlock()
	plan, err := s.device.resolve(ctx, entry.channel)
	if err == nil {
		_, _, err = readPlaylist(ctx, s.client, plan)
	}
	entry.mu.Lock()
	if generation == entry.promotion {
		entry.promoting = false
		entry.promoteCancel = nil
		if err == nil && ctx.Err() == nil && time.Since(entry.lastUsed) < 15*time.Second {
			entry.high = plan
			entry.updated = time.Time{}
		}
	}
	entry.mu.Unlock()
	if err != nil && ctx.Err() == nil {
		s.record(entry.channel.ID, err)
	}
}
func (s *Service) refresh(entry *playlistEntry) {
	s.mu.Lock()
	parent := s.ctx
	s.mu.Unlock()
	ctx, cancel := context.WithTimeout(parent, 35*time.Second)
	defer cancel()
	entry.mu.Lock()
	high := entry.high
	entry.mu.Unlock()
	plan, body, address, err := s.resolvePlaylist(ctx, entry.channel, entry.quality, entry.start, entry.end, high)
	overrides := map[string]map[string]string{}
	if err == nil {
		entry.mu.Lock()
		if entry.start == 0 {
			body = entry.stitch(body, address, plan)
			for _, segment := range entry.segments {
				overrides[segment.address] = segment.headers
			}
		}
		entry.mu.Unlock()
		body = s.rewriteHeaders(body, address, plan.Headers, overrides)
	}
	entry.mu.Lock()
	if err == nil {
		entry.text = body
		entry.plan = plan
		if plan.Engine != "device" {
			entry.high = Plan{}
		}
		entry.updated = time.Now()
		entry.lastError = ""
	} else {
		entry.lastError = "央视频频道暂不可用：" + safeError(err)
	}
	ready := entry.inflight
	entry.inflight = nil
	if ready != nil {
		close(ready)
	}
	entry.mu.Unlock()
	if err != nil {
		s.record(entry.channel.ID, err)
	}
}
func (s *Service) resolvePlaylist(ctx context.Context, channel Channel, quality string, start, end int64, high Plan) (Plan, string, string, error) {
	var last error
	try := func(plan Plan, err error) (string, string, bool) {
		if err != nil {
			last = err
			return "", "", false
		}
		body, address, err := readPlaylist(ctx, s.client, plan)
		if err != nil {
			last = err
			return "", "", false
		}
		return body, address, true
	}
	if start > 0 {
		plan, err := jcePlan(ctx, s.client, channel, start, end)
		body, address, ok := try(plan, err)
		if ok {
			return plan, body, address, nil
		}
		return Plan{}, "", "", last
	}
	if high.URL == "" && quality != "hd" && channel.LiveID != "" {
		high = s.device.cached(channel.ID)
	}
	if high.URL != "" && int64(high.Expires) > time.Now().Unix() {
		if body, address, ok := try(high, nil); ok {
			return high, body, address, nil
		}
		s.device.invalidate(channel.ID)
	}
	if quality != "hd" && channel.LiveID != "" && (quality == "best" || channel.Ultra) {
		control, cancel := context.WithTimeout(ctx, 8*time.Second)
		plan, err := s.device.resolve(control, channel)
		cancel()
		if body, address, ok := try(plan, err); ok {
			return plan, body, address, nil
		}
		if err != nil {
			s.record(channel.ID, err)
		}
	}
	now := time.Now().Unix()
	plan, err := jcePlan(ctx, s.client, channel, now-300, now)
	if body, address, ok := try(plan, err); ok {
		return plan, body, address, nil
	}
	plans, err := backupPlans(ctx, s.client, channel)
	if err == nil {
		for _, plan := range plans {
			if body, address, ok := try(plan, nil); ok {
				return plan, body, address, nil
			}
		}
	} else {
		last = err
	}
	plan, err = webPlan(ctx, s.client, channel)
	if body, address, ok := try(plan, err); ok {
		return plan, body, address, nil
	}
	if last == nil {
		last = errors.New("所有取流引擎均暂不可用")
	}
	return Plan{}, "", "", last
}
