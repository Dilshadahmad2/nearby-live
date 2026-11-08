package delay

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"math"
	"net/http"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/dilshadahmad2/nearby-live/backend/internal/geo"
)

// HTTPProvider fetches live status from any JSON HTTP API. The request URL,
// headers and the JSON paths of the fields are configuration, so the same
// code works with RapidAPI's IRCTC APIs, RailRadar, or your own feed —
// without baking in a response schema that providers change.
//
// URL placeholders: {number}, {date} (YYYY-MM-DD), {date_compact}
// (YYYYMMDD), {date_dmy} (DD-MM-YYYY), {start_day} (0 = journey started
// today IST, 1 = yesterday, …).
//
// Paths are dot-separated, with numeric segments for arrays, e.g.
// "data.delay" or "data.current_location.lat".
type HTTPProvider struct {
	ProviderName string
	URLTemplate  string
	Headers      map[string]string
	DelayPath    string // minutes; numbers, "15", "15 min", "1h 5m", "01:05" are accepted
	StationPath  string // optional: last / current station code
	LatPath      string // optional: live latitude
	LonPath      string // optional: live longitude
	OKPath       string // optional: boolean that must be true (e.g. "status")
	MessagePath  string // optional: error message when OKPath is false
	Client       *http.Client
	Now          func() time.Time
}

// Name implements [Provider].
func (p *HTTPProvider) Name() string {
	if p.ProviderName != "" {
		return p.ProviderName
	}
	return "http"
}

// Fetch implements [Provider].
func (p *HTTPProvider) Fetch(ctx context.Context, number string, journey time.Time) (Status, error) {
	now := time.Now
	if p.Now != nil {
		now = p.Now
	}
	u := p.buildURL(number, journey, now())
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return Status{}, err
	}
	req.Header.Set("Accept", "application/json")
	for k, v := range p.Headers {
		req.Header.Set(k, v)
	}
	client := p.Client
	if client == nil {
		client = &http.Client{Timeout: 15 * time.Second}
	}
	res, err := client.Do(req)
	if err != nil {
		return Status{}, err
	}
	defer res.Body.Close()
	body, err := io.ReadAll(io.LimitReader(res.Body, 2<<20))
	if err != nil {
		return Status{}, err
	}
	if res.StatusCode == http.StatusNotFound {
		return Status{}, ErrNotFound
	}
	if res.StatusCode/100 != 2 {
		return Status{}, fmt.Errorf("%s: HTTP %d", p.Name(), res.StatusCode)
	}
	st, err := p.Parse(body)
	if err != nil {
		return Status{}, err
	}
	st.TrainNumber = number
	st.JourneyDate = DateKey(journey)
	st.Source = p.Name()
	st.ReportedAt = now()
	return st, nil
}

func (p *HTTPProvider) buildURL(number string, journey, now time.Time) string {
	j := journey.In(IST)
	jd := time.Date(j.Year(), j.Month(), j.Day(), 0, 0, 0, 0, IST)
	n := now.In(IST)
	nd := time.Date(n.Year(), n.Month(), n.Day(), 0, 0, 0, 0, IST)
	startDay := int(math.Round(nd.Sub(jd).Hours() / 24))
	if startDay < 0 {
		startDay = 0
	}
	r := strings.NewReplacer(
		"{number}", url.PathEscape(number),
		"{date}", j.Format("2006-01-02"),
		"{date_compact}", j.Format("20060102"),
		"{date_dmy}", j.Format("02-01-2006"),
		"{start_day}", strconv.Itoa(startDay),
	)
	return r.Replace(p.URLTemplate)
}

// Parse extracts a status from a provider response body.
func (p *HTTPProvider) Parse(body []byte) (Status, error) {
	var doc any
	if err := json.Unmarshal(body, &doc); err != nil {
		return Status{}, fmt.Errorf("%s: invalid JSON: %w", p.Name(), err)
	}
	if p.OKPath != "" {
		if ok, _ := lookup(doc, p.OKPath).(bool); !ok {
			msg, _ := lookup(doc, p.MessagePath).(string)
			if msg == "" {
				msg = "provider reported failure"
			}
			return Status{}, fmt.Errorf("%s: %s", p.Name(), msg)
		}
	}
	d, ok := parseMinutes(lookup(doc, p.DelayPath))
	if !ok {
		return Status{}, fmt.Errorf("%s: no delay at %q", p.Name(), p.DelayPath)
	}
	st := Status{DelayMin: d}
	if p.StationPath != "" {
		if v := lookup(doc, p.StationPath); v != nil {
			st.LastStationCode = strings.ToUpper(strings.TrimSpace(fmt.Sprint(v)))
		}
	}
	if p.LatPath != "" && p.LonPath != "" {
		lat, ok1 := toFloat(lookup(doc, p.LatPath))
		lon, ok2 := toFloat(lookup(doc, p.LonPath))
		if ok1 && ok2 && lat >= -90 && lat <= 90 && lon >= -180 && lon <= 180 && (lat != 0 || lon != 0) {
			st.Point = &geo.Point{Lat: lat, Lon: lon}
		}
	}
	return st, nil
}

// lookup walks a dot path through decoded JSON.
func lookup(doc any, path string) any {
	if path == "" {
		return nil
	}
	cur := doc
	for _, seg := range strings.Split(path, ".") {
		switch v := cur.(type) {
		case map[string]any:
			cur = v[seg]
		case []any:
			i, err := strconv.Atoi(seg)
			if err != nil || i < 0 || i >= len(v) {
				return nil
			}
			cur = v[i]
		default:
			return nil
		}
	}
	return cur
}

func toFloat(v any) (float64, bool) {
	switch x := v.(type) {
	case float64:
		return x, true
	case string:
		f, err := strconv.ParseFloat(strings.TrimSpace(x), 64)
		return f, err == nil
	}
	return 0, false
}

var (
	reHM    = regexp.MustCompile(`^(\d+):(\d{1,2})$`)
	reParts = regexp.MustCompile(`(\d+)\s*(h|hr|hrs|hour|hours|m|min|mins|minute|minutes)\b`)
	reNum   = regexp.MustCompile(`^-?\d+(\.\d+)?$`)
)

// parseMinutes accepts 15, 15.0, "15", "15 min", "1h 5m", "1 hr 5 mins",
// "01:05", "On Time", "RT" (right time).
func parseMinutes(v any) (int, bool) {
	switch x := v.(type) {
	case float64:
		return int(math.Round(x)), true
	case string:
		s := strings.ToLower(strings.TrimSpace(x))
		switch {
		case s == "":
			return 0, false
		case s == "on time" || s == "ontime" || s == "rt" || s == "right time" || s == "no delay":
			return 0, true
		case reNum.MatchString(s):
			f, _ := strconv.ParseFloat(s, 64)
			return int(math.Round(f)), true
		}
		if m := reHM.FindStringSubmatch(s); m != nil {
			h, _ := strconv.Atoi(m[1])
			mm, _ := strconv.Atoi(m[2])
			return h*60 + mm, true
		}
		total, found := 0, false
		for _, m := range reParts.FindAllStringSubmatch(s, -1) {
			n, _ := strconv.Atoi(m[1])
			if strings.HasPrefix(m[2], "h") {
				total += n * 60
			} else {
				total += n
			}
			found = true
		}
		return total, found
	}
	return 0, false
}
