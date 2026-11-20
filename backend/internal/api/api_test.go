package api

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"

	"github.com/dilshadahmad2/nearby-live/backend/internal/geo"
	"github.com/dilshadahmad2/nearby-live/backend/internal/live"
	"github.com/dilshadahmad2/nearby-live/backend/internal/rail"
)

func testServer() *Server {
	stations := []rail.Station{
		{Code: "AAA", Name: "Alpha", Point: &geo.Point{Lat: 28, Lon: 77}},
		{Code: "CCC", Name: "Charlie", Point: &geo.Point{Lat: 29, Lon: 77}},
	}
	stops := map[string][]rail.Stop{"10001": {
		{Seq: 1, StationCode: "AAA", DepartureMin: rail.IntPtr(600)},
		{Seq: 2, StationCode: "CCC", ArrivalMin: rail.IntPtr(720)},
	}}
	s := New(rail.NewIndex(stations, []rail.Train{{Number: "10001", Name: "Test Express"}}, stops))
	s.Now = func() time.Time { return time.Date(2026, 11, 7, 11, 0, 0, 0, rail.IST) }
	return s
}

func get(t *testing.T, h http.Handler, method, url, body string) (int, map[string]any) {
	t.Helper()
	req := httptest.NewRequest(method, url, strings.NewReader(body))
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	var out map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil {
		t.Fatalf("%s %s: bad JSON %q", method, url, rec.Body.String())
	}
	return rec.Code, out
}

func TestEndpoints(t *testing.T) {
	h := testServer().Handler()

	code, body := get(t, h, "GET", "/v1/stations/aaa", "")
	if code != 200 || body["name"] != "Alpha" {
		t.Fatalf("station: %d %v", code, body)
	}
	if code, _ := get(t, h, "GET", "/v1/stations/ZZZ", ""); code != 404 {
		t.Fatalf("missing station: %d", code)
	}
	code, body = get(t, h, "GET", "/v1/stations/nearby?lat=28.01&lon=77&radius_km=5", "")
	if code != 200 || body["count"].(float64) != 1 {
		t.Fatalf("nearby: %d %v", code, body)
	}
	if code, _ := get(t, h, "GET", "/v1/stations/nearby?lat=x", ""); code != 400 {
		t.Fatalf("bad params: %d", code)
	}

	code, body = get(t, h, "GET", "/v1/trains/10001/position", "")
	pos := body["position"].(map[string]any)
	if code != 200 || pos["status"] != "running" {
		t.Fatalf("position: %d %v", code, body)
	}
	loc := pos["location"].(map[string]any)
	if lat := loc["lat"].(float64); lat < 28.49 || lat > 28.51 { // halfway at 11:00
		t.Fatalf("lat = %v", lat)
	}

	code, body = get(t, h, "GET", "/v1/trains/nearby?lat=28.5&lon=77&radius_km=3", "")
	if code != 200 || body["count"].(float64) != 1 {
		t.Fatalf("nearby trains: %d %v", code, body)
	}

	code, body = get(t, h, "POST", "/v1/position/estimate", `{
		"stops": [
			{"code": "AAA", "departure": "2026-11-07T10:00:00+05:30"},
			{"code": "CCC", "arrival": "2026-11-07T12:00:00+05:30"}
		],
		"at": "2026-11-07T10:30:00+05:30"
	}`)
	pos = body["position"].(map[string]any)
	if code != 200 || pos["status"] != "running" {
		t.Fatalf("estimate: %d %v", code, body)
	}

	if code, _ := get(t, h, "PUT", "/v1/admin/stations/AAA", `{"name":"x"}`); code != 403 {
		t.Fatalf("admin without token: %d", code)
	}
}

func authed(t *testing.T, h http.Handler, method, url, body string) (int, map[string]any) {
	t.Helper()
	req := httptest.NewRequest(method, url, strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer tok")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	var out map[string]any
	_ = json.Unmarshal(rec.Body.Bytes(), &out)
	return rec.Code, out
}

func TestDelayPushShiftsPositionAndLive(t *testing.T) {
	s := testServer()
	s.AdminToken = "tok"
	s.Delays.SetClock(s.Now)
	h := s.Handler()

	if code, _ := authed(t, h, "PUT", "/v1/admin/trains/10001/delay", `{"delay_min": 60, "last_station_code": "aaa"}`); code != 200 {
		t.Fatalf("push: %d", code)
	}
	// 11:00 with a 60 min delay = the train is just leaving AAA.
	code, body := get(t, h, "GET", "/v1/trains/10001/position", "")
	pos := body["position"].(map[string]any)
	if code != 200 || pos["delay_min"].(float64) != 60 {
		t.Fatalf("position: %d %v", code, body)
	}
	if lat := pos["location"].(map[string]any)["lat"].(float64); lat > 28.01 {
		t.Fatalf("late train lat = %v", lat)
	}
	if body["live_status"].(map[string]any)["last_station_code"] != "AAA" {
		t.Fatalf("live_status: %v", body["live_status"])
	}
	// delay_min overrides.
	_, body = get(t, h, "GET", "/v1/trains/10001/position?delay_min=0", "")
	if lat := body["position"].(map[string]any)["location"].(map[string]any)["lat"].(float64); lat < 28.49 {
		t.Fatalf("override lat = %v", lat)
	}

	// The live hub: publish trains and query around AAA.
	src := &live.TrainSource{Hub: s.Hub, Index: s.Index, Delays: s.Delays, Now: s.Now}
	s.Hub.Replace(live.KindTrain, "timetable", src.Snapshot())
	code, body = get(t, h, "GET", "/v1/live?lat=28&lon=77&radius_km=5&types=trains", "")
	if code != 200 || body["count"].(float64) != 1 {
		t.Fatalf("live: %d %v", code, body)
	}
	item := body["items"].([]any)[0].(map[string]any)
	if item["kind"] != "train" || item["delay_min"].(float64) != 60 {
		t.Fatalf("live item: %v", item)
	}
	if code, _ := get(t, h, "GET", "/v1/live/train/10001", ""); code != 200 {
		t.Fatalf("live object: %d", code)
	}
	if code, _ := get(t, h, "GET", "/v1/live/status", ""); code != 200 {
		t.Fatalf("status: %d", code)
	}
}

func TestMetricsAndWebSocketThroughMiddleware(t *testing.T) {
	s := testServer()
	ts := httptest.NewServer(s.Handler())
	defer ts.Close()

	// The stream must still upgrade through the middleware's response wrapper.
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	c, _, err := websocket.Dial(ctx, strings.Replace(ts.URL, "http", "ws", 1)+"/v1/live/ws", nil)
	if err != nil {
		t.Fatalf("websocket through middleware: %v", err)
	}
	if _, msg, err := c.Read(ctx); err != nil || !strings.Contains(string(msg), `"hello"`) {
		t.Fatalf("hello: %s %v", msg, err)
	}
	c.CloseNow()

	if _, err := http.Get(ts.URL + "/v1/stations/AAA"); err != nil {
		t.Fatal(err)
	}
	res, err := http.Get(ts.URL + "/metrics")
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	b, _ := io.ReadAll(res.Body)
	body := string(b)
	for _, want := range []string{
		`nearby_http_requests_total{method="GET",route="GET /v1/stations/{code}",status="2xx"} 1`,
		`nearby_http_request_duration_seconds_count{route="GET /v1/stations/{code}"} 1`,
		"nearby_stream_connections",
		"nearby_uptime_seconds",
	} {
		if !strings.Contains(body, want) {
			t.Errorf("metrics missing %q\n%s", want, body)
		}
	}
}
