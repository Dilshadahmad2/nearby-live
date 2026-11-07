package api

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/dilshadahmad2/nearby-live/backend/internal/geo"
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
