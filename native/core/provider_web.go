package core

import (
	"context"
	"errors"
	"fmt"
	htmltext "html"
	"net/http/cookiejar"
	"net/url"
	"regexp"
	"strconv"
	"strings"

	"golang.org/x/net/html"
	"golang.org/x/net/publicsuffix"
)

type providerTextUserAgentKey struct{}
type providerTextNoCacheKey struct{}

func isFilmProviderSource(source string) bool {
	return source == sourceIkanbot || source == sourceA123 || source == sourceXiaopingguo || source == sourceMiguoHoney
}

func validFilmCategory(categories []nativeCategory, category string) bool {
	if category == "" {
		return true
	}
	for _, item := range categories {
		if item.ID == category {
			return true
		}
	}
	return false
}

func (d *Downloader) filmDownloader() *Downloader {
	d.filmSessionOnce.Do(func() {
		client := *d.client
		client.Jar, _ = cookiejar.New(&cookiejar.Options{PublicSuffixList: publicsuffix.List})
		d.filmSession = &Downloader{cfg: d.cfg, client: &client, limiter: d.limiter,
			proxyRouter: d.proxyRouter, diagnostics: d.diagnostics, providerHosts: map[string]string{}}
	})
	return d.filmSession
}

func (d *Downloader) fetchFilmText(ctx context.Context, source, path, referer string) (string, string, error) {
	site := d.providerBaseURL(source)
	address := filmResolveURL(site+"/", path)
	base, baseErr := url.Parse(site)
	parsed, err := url.Parse(address)
	if baseErr != nil || err != nil || !isProviderHTTPMediaURL(address) || providerMediaOrigin(parsed) != providerMediaOrigin(base) {
		return "", "", errors.New("影视站源请求地址无效")
	}
	if referer == "" {
		referer = site + "/"
	}
	agent := a123UserAgent
	if source == sourceIkanbot {
		agent = ikanbotUserAgent
	}
	responses := &playbackResponseURLs{}
	ctx = context.WithValue(ctx, playbackResponseURLsKey{}, responses)
	ctx = context.WithValue(ctx, providerTextExactURLKey{}, true)
	ctx = context.WithValue(ctx, providerTextUserAgentKey{}, agent)
	body, err := d.filmDownloader().fetchProviderText(ctx, address, referer)
	if err != nil {
		return "", "", err
	}
	if actual, found := responses.values.Load(address); found {
		address = actual.(string)
	}
	parsed, err = url.Parse(address)
	if err != nil || providerMediaOrigin(parsed) != providerMediaOrigin(base) {
		return "", "", errors.New("影视站源已重定向至其他站点，请稍后重试")
	}
	return body, address, nil
}

func filmDocument(body string) (*html.Node, error) {
	if len(body) > 4<<20 {
		return nil, errors.New("影视站源页面过大")
	}
	return html.Parse(strings.NewReader(body))
}

func filmMeta(document *html.Node, names ...string) string {
	for _, name := range names {
		for _, node := range providerHTMLNodes(document, func(node *html.Node) bool { return node.Data == "meta" }) {
			if firstNonEmpty(providerHTMLAttr(node, "property"), providerHTMLAttr(node, "name")) == name {
				if value := strings.TrimSpace(providerHTMLAttr(node, "content")); value != "" {
					return value
				}
			}
		}
	}
	return ""
}

func filmMediaURL(raw, pageURL string) string {
	if strings.TrimSpace(raw) == "" {
		return ""
	}
	address := filmResolveURL(pageURL, raw)
	parsed, err := url.Parse(address)
	if err != nil || !isProviderHTTPMediaURL(address) {
		return ""
	}
	path := strings.ToLower(parsed.Path)
	if !strings.HasSuffix(path, ".m3u8") && !strings.HasSuffix(path, ".mp4") {
		return ""
	}
	return address
}

func filmResolveURL(pageURL, reference string) string {
	base, err := url.Parse(pageURL)
	if err != nil {
		return ""
	}
	reference = strings.TrimSpace(htmltext.UnescapeString(strings.ReplaceAll(reference, `\/`, `/`)))
	if reference == "" {
		return ""
	}
	address, err := url.Parse(reference)
	if err != nil {
		return ""
	}
	return base.ResolveReference(address).String()
}

func (d *Downloader) filmMedia(source, address, referer string) providerMedia {
	parsed, _ := url.Parse(address)
	agent := a123UserAgent
	if source == sourceIkanbot {
		agent = ikanbotUserAgent
	}
	cookies := []string{}
	for _, cookie := range d.filmDownloader().client.Jar.Cookies(parsed) {
		cookies = append(cookies, cookie.Name+"="+cookie.Value)
	}
	return providerMedia{URL: address, Referer: referer, credentials: &providerMediaCredentials{
		origin: providerMediaOrigin(parsed), userAgent: agent, referer: referer, cookie: strings.Join(cookies, "; ")}}
}

var webProviderNumericID = regexp.MustCompile(`^[1-9][0-9]{0,17}$`)

func webProviderInteger(value any, maximum int) (int, bool) {
	number, err := strconv.Atoi(nativeText(value))
	return number, err == nil && number >= 0 && number <= maximum
}

func providerHTMLAttr(node *html.Node, name string) string {
	if node != nil {
		for _, attribute := range node.Attr {
			if attribute.Key == name {
				return attribute.Val
			}
		}
	}
	return ""
}

func providerHTMLClass(node *html.Node, name string) bool {
	for _, value := range strings.Fields(providerHTMLAttr(node, "class")) {
		if value == name {
			return true
		}
	}
	return false
}

func providerHTMLNodes(root *html.Node, match func(*html.Node) bool) []*html.Node {
	var found []*html.Node
	if root == nil {
		return found
	}
	pending := []*html.Node{root}
	for len(pending) > 0 {
		node := pending[len(pending)-1]
		pending = pending[:len(pending)-1]
		if match(node) {
			found = append(found, node)
		}
		for child := node.LastChild; child != nil; child = child.PrevSibling {
			pending = append(pending, child)
		}
	}
	return found
}

func providerHTMLFirstClass(root *html.Node, names ...string) *html.Node {
	for _, name := range names {
		matches := providerHTMLNodes(root, func(node *html.Node) bool {
			return providerHTMLClass(node, name)
		})
		if len(matches) > 0 {
			return matches[0]
		}
	}
	return nil
}

func providerHTMLText(root *html.Node) string {
	var text strings.Builder
	for _, node := range providerHTMLNodes(root, func(node *html.Node) bool {
		return node.Type == html.TextNode
	}) {
		if node.Parent != nil && (node.Parent.Data == "script" || node.Parent.Data == "style") {
			continue
		}
		text.WriteString(node.Data)
		text.WriteByte(' ')
	}
	return strings.Join(strings.Fields(text.String()), " ")
}

func (d *Downloader) fetchProviderPage(ctx context.Context, address, referer, agent string) (*html.Node, string, error) {
	responses := &playbackResponseURLs{}
	ctx = context.WithValue(ctx, playbackResponseURLsKey{}, responses)
	if agent != "" {
		ctx = context.WithValue(ctx, providerTextUserAgentKey{}, agent)
	}
	body, err := d.fetchProviderText(ctx, address, referer)
	if err != nil {
		return nil, "", err
	}
	if len(body) > 4<<20 {
		return nil, "", errors.New("站源页面过大")
	}
	if actual, found := responses.values.Load(address); found {
		address = actual.(string)
	}
	document, err := html.Parse(strings.NewReader(body))
	return document, address, err
}

func (d *Downloader) prepareWebProviderMedia(ctx context.Context, media providerMedia, sourceName string) (providerMedia, error) {
	address, err := url.Parse(media.URL)
	if err != nil || !isProviderHTTPMediaURL(media.URL) || address.User != nil {
		return providerMedia{}, fmt.Errorf("%s未返回有效播放地址，请刷新详情后重试", sourceName)
	}
	if providerMediaHLSURL(media.URL) {
		if media.credentials != nil {
			ctx = providerMediaContext(ctx, media.credentials)
		}
		media.Playlist, media.URL, err = d.fetchMediaPlaylist(ctx, media.URL, media.Referer)
		if err != nil {
			return providerMedia{}, fmt.Errorf("获取%s播放列表失败：%w", sourceName, err)
		}
		if !strings.HasPrefix(strings.TrimSpace(strings.TrimPrefix(media.Playlist, "\ufeff")), "#EXTM3U") {
			return providerMedia{}, fmt.Errorf("%s播放列表无效，请重新解析播放", sourceName)
		}
		if duration := m3u8Duration(media.Playlist); duration > 0 {
			media.Duration = duration
		}
	}
	return media, nil
}
