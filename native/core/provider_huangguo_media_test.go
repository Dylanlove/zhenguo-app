package core

import (
	"context"
	"io"
	"net/http"
	"net/url"
	"reflect"
	"strings"
	"testing"
)

const huangguoQualityFixtureMaster = `#EXTM3U
#EXT-X-VERSION:3
#EXT-X-SESSION-KEY:METHOD=AES-128,URI="keys/session.key?auth=k%2Fv"
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="low",NAME="Main",DEFAULT=YES,URI="audio/low.m3u8?auth=low%2Fmain"
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="high",NAME="Main",DEFAULT=YES,URI="audio/high.m3u8?auth=high%2Fmain"
#EXT-X-STREAM-INF:BANDWIDTH=200000,RESOLUTION=270x480,AUDIO="low"
480p/index.m3u8?token=low%2Fvideo
#EXT-X-STREAM-INF:BANDWIDTH=400000,RESOLUTION=404x720,AUDIO="high"
720p/lower.m3u8?token=lower%2Fvideo
#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=404x720,AUDIO="high"
720p/index.m3u8?token=high%2Fvideo
`

func TestHuangguoHLSQualityChoicesPreserveSignedMasterAndAudio(t *testing.T) {
	credentials := &providerMediaCredentials{referer: "https://huangguo.video/video/fixture"}
	original := providerMedia{
		URL: "https://media.test/nested/master.m3u8?signature=a%2Fb", Referer: credentials.referer,
		Playlist: huangguoQualityFixtureMaster, HLSKey: []byte("0123456789abcdef"), credentials: credentials,
	}
	media := huangguoMediaQualities(original)
	choice := nativePlaybackChoices(media, 0)
	if len(choice.media) != 2 || !reflect.DeepEqual(choice.qualities, []int{720, 480}) {
		t.Fatalf("master qualities were lost or duplicated: %+v", choice)
	}
	for _, option := range choice.media {
		if option.URL != original.URL || option.Referer != original.Referer || option.credentials != credentials || !reflect.DeepEqual(option.HLSKey, original.HLSKey) {
			t.Fatalf("quality selection lost source credentials: %+v", option)
		}
		if strings.Count(option.Playlist, "#EXT-X-STREAM-INF:") != 1 || strings.Count(option.Playlist, "#EXT-X-MEDIA:") != 1 {
			t.Fatalf("quality selection did not retain exactly one video and its audio: %s", option.Playlist)
		}
	}
	high := choice.media[0]
	if high.Quality != 720 || !strings.Contains(high.Playlist, "720p/index.m3u8?token=high%2Fvideo") ||
		!strings.Contains(high.Playlist, "audio/high.m3u8?auth=high%2Fmain") || strings.Contains(high.Playlist, "720p/lower") {
		t.Fatalf("automatic selection did not prefer the highest resolution and bitrate: %s", high.Playlist)
	}
	manual := nativePlaybackChoices(media, 480)
	if len(manual.media) != 1 || manual.media[0].Quality != 480 ||
		!strings.Contains(manual.media[0].Playlist, "480p/index.m3u8?token=low%2Fvideo") ||
		!strings.Contains(manual.media[0].Playlist, "audio/low.m3u8?auth=low%2Fmain") {
		t.Fatalf("manual quality did not select its own playlist and audio: %+v", manual)
	}
	if fallback := nativePlaybackChoices(media, 1080); len(fallback.media) != 2 || fallback.media[0].Quality != 720 ||
		!reflect.DeepEqual(fallback.qualities, []int{720, 480}) {
		t.Fatalf("an unavailable preference invented or selected a missing quality: %+v", fallback)
	}
	stream, err := newNativeStreamServer(sourceFixtureDownloader(t, nil))
	if err != nil {
		t.Fatal(err)
	}
	defer stream.server.Close()
	address, token := stream.nativeOpen(high)
	defer stream.nativeRelease(token)
	response, err := http.Get(address)
	if err != nil {
		t.Fatal(err)
	}
	body, err := io.ReadAll(response.Body)
	response.Body.Close()
	if err != nil || response.StatusCode != http.StatusOK || strings.Count(string(body), "#EXT-X-STREAM-INF:") != 1 {
		t.Fatalf("selected master was not served: %s, %v", body, err)
	}
	stream.mu.Lock()
	session := stream.sessions[token]
	stream.mu.Unlock()
	session.mu.Lock()
	defer session.mu.Unlock()
	want := map[string]bool{
		original.URL: true,
		"https://media.test/nested/keys/session.key?auth=k%2Fv":        true,
		"https://media.test/nested/audio/high.m3u8?auth=high%2Fmain":   true,
		"https://media.test/nested/720p/index.m3u8?token=high%2Fvideo": true,
	}
	for _, asset := range session.assets {
		if !want[asset.address] {
			t.Fatalf("quality proxy changed the signed URI or resolved from the wrong base: %s", asset.address)
		}
		delete(want, asset.address)
	}
	if len(want) != 0 {
		t.Fatalf("quality proxy dropped associated resources: %v", want)
	}
}

func TestHuangguoHLSQualityWithoutResolutionRemainsUnknown(t *testing.T) {
	single := providerMedia{URL: "https://media.test/720p/index.m3u8", Playlist: "#EXTM3U\n#EXTINF:4,\nsegment.ts\n#EXT-X-ENDLIST\n"}
	if actual := huangguoMediaQualities(single); !reflect.DeepEqual(actual, single) {
		t.Fatalf("a single rendition was relabelled from its path: %+v", actual)
	}
	master := providerMedia{URL: "https://media.test/master.m3u8", Playlist: "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=100000\nlow.m3u8\n#EXT-X-STREAM-INF:BANDWIDTH=500000\nhigh.m3u8\n"}
	choice := nativePlaybackChoices(huangguoMediaQualities(master), 1080)
	if len(choice.media) != 1 || len(choice.qualities) != 0 || choice.media[0].Quality != 0 ||
		!strings.Contains(choice.media[0].Playlist, "high.m3u8") || strings.Contains(choice.media[0].Playlist, "low.m3u8") {
		t.Fatalf("unknown dimensions should prefer bandwidth without inventing a quality: %+v", choice)
	}
}

func TestHuangguoResolveExposesHLSQualitiesAfterRedirect(t *testing.T) {
	for _, source := range []string{sourceHuangguoAI, sourceHuangguoVideo} {
		t.Run(source, func(t *testing.T) {
			base := "https://huangguo.video"
			if source == sourceHuangguoAI {
				base = "https://fixture.rurhvbhx.cc"
			}
			page := base + "/video/123/"
			var requested []string
			d := sourceFixtureDownloader(t, func(request *http.Request) (*http.Response, error) {
				requested = append(requested, request.URL.String())
				if request.URL.String() == page {
					return sourceFixtureResponse(request, http.StatusOK, `<script id="videoInitialData" type="application/json">{"id":"123","ep":1,"videoSrc":"https://media.test/redirect.m3u8"}</script><div data-hls="https://media.test/redirect.m3u8"></div>`), nil
				}
				if request.URL.String() != "https://media.test/redirect.m3u8" || request.Header.Get("Referer") != page {
					t.Fatalf("unexpected or eager media request: %s", request.URL)
				}
				response := sourceFixtureResponse(request, http.StatusOK, huangguoQualityFixtureMaster)
				final := request.Clone(request.Context())
				final.URL, _ = url.Parse("https://cdn.test/nested/master.m3u8?signature=a%2Fb")
				response.Request = final
				return response, nil
			})
			if source == sourceHuangguoAI {
				d.cfg.HuangguoAIURL = base
			}
			media, err := d.resolveProviderMedia(context.Background(), Task{
				DramaID: source + ":123", Chapter: Chapter{Source: source, PageURL: page}, Index: 1,
			})
			if err != nil {
				t.Fatal(err)
			}
			choice := nativePlaybackChoices(media, 480)
			if len(requested) != 2 || len(choice.media) != 1 || choice.media[0].Quality != 480 ||
				choice.media[0].URL != "https://cdn.test/nested/master.m3u8?signature=a%2Fb" ||
				choice.media[0].Referer != page || !reflect.DeepEqual(choice.qualities, []int{720, 480}) {
				t.Fatalf("resolved HLS qualities or final URL were lost: %+v, requests=%v", choice, requested)
			}
		})
	}
}
