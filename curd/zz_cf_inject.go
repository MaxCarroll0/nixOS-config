package internal

import (
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// cf_clearance + matching UA seeded by an external solver (FlareSolverr),
// injected on allanime/animepahe requests so curd's plain client passes Cloudflare.
type cfSession struct {
	UserAgent string            `json:"userAgent"`
	Hosts     map[string]string `json:"hosts"`
}

type cfRoundTripper struct {
	base  http.RoundTripper
	mu    sync.Mutex
	sess  cfSession
	mtime time.Time
}

func (rt *cfRoundTripper) reload() {
	path := filepath.Join(GetStoragePath(), "cf_session.json")
	fi, err := os.Stat(path)
	if err != nil {
		return
	}
	rt.mu.Lock()
	defer rt.mu.Unlock()
	if fi.ModTime().Equal(rt.mtime) {
		return
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return
	}
	var s cfSession
	if json.Unmarshal(b, &s) == nil {
		rt.sess = s
		rt.mtime = fi.ModTime()
	}
}

func (rt *cfRoundTripper) RoundTrip(req *http.Request) (*http.Response, error) {
	rt.reload()
	host := req.URL.Hostname()
	rt.mu.Lock()
	ua := rt.sess.UserAgent
	cookie := ""
	for h, c := range rt.sess.Hosts {
		if host == h || strings.HasSuffix(host, "."+h) {
			cookie = c
			break
		}
	}
	rt.mu.Unlock()
	if cookie != "" {
		req.Header.Set("Cookie", cookie)
		if ua != "" {
			req.Header.Set("User-Agent", ua)
		}
	}
	return rt.base.RoundTrip(req)
}

func init() {
	if sharedHTTPClient != nil {
		sharedHTTPClient.Transport = &cfRoundTripper{base: sharedHTTPClient.Transport}
	}
}
