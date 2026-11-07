// Package api is the Nearby Live HTTP API (JSON over net/http).
package api

import (
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/dilshadahmad2/nearby-live/backend/internal/alerts"
	"github.com/dilshadahmad2/nearby-live/backend/internal/delay"
	"github.com/dilshadahmad2/nearby-live/backend/internal/geo"
	"github.com/dilshadahmad2/nearby-live/backend/internal/live"
	"github.com/dilshadahmad2/nearby-live/backend/internal/rail"
	"github.com/dilshadahmad2/nearby-live/backend/internal/stream"
)

// IndexLoader reloads the in-memory index from the database.
type IndexLoader func(ctx context.Context) (*rail.Index, error)

// StationWriter persists a station edit.
type StationWriter func(ctx context.Context, st rail.Station) error

// Server serves the API from an atomically swappable [rail.Index].
type Server struct {
	index      atomic.Pointer[rail.Index]
	Load       IndexLoader
	Write      StationWriter
	AdminToken string
	Now        func() time.Time
	Log        *slog.Logger

	// Delays holds live train delays (provider and/or pushed).
	Delays *delay.Service
	// Hub holds live positions of every tracked object.
	Hub *live.Hub
	// Sky is the OpenSky feed (nil = none); also in Refreshers.
	Sky *live.OpenSky
	// Traffic is the TomTom feed (nil = no key); also in Refreshers.
	Traffic *live.Traffic
	// Refreshers fetch areas on demand (flights, weather, traffic).
	Refreshers live.Refreshers
	// Stream serves GET /v1/live/ws (created from Hub/Sky when nil).
	Stream *stream.Server
	// Alerts stores push alert subscriptions (memory when nil).
	Alerts alerts.Store

	metrics *metrics
}

// New creates a server around an initial index.
func New(ix *rail.Index) *Server {
	s := &Server{
		Now:     time.Now,
		Log:     slog.Default(),
		Delays:  delay.NewService(nil, nil, delay.Config{}),
		Hub:     live.NewHub(),
		metrics: newMetrics(),
	}
	s.index.Store(ix)
	return s
}

// Index returns the current index.
func (s *Server) Index() *rail.Index { return s.index.Load() }

// Handler returns the routed handler with CORS, logging and panic recovery.
func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", s.health)
	mux.HandleFunc("GET /metrics", s.serveMetrics)

	mux.HandleFunc("GET /v1/stations", s.searchStations)
	mux.HandleFunc("GET /v1/stations/nearby", s.nearbyStations)
	mux.HandleFunc("GET /v1/stations/bbox", s.bboxStations)
	mux.HandleFunc("GET /v1/stations/{code}", s.station)
	mux.HandleFunc("GET /v1/stations/{code}/trains", s.stationTrains)

	mux.HandleFunc("GET /v1/trains", s.searchTrains)
	mux.HandleFunc("GET /v1/trains/nearby", s.nearbyTrains)
	mux.HandleFunc("GET /v1/trains/{number}", s.train)
	mux.HandleFunc("GET /v1/trains/{number}/route", s.route)
	mux.HandleFunc("GET /v1/trains/{number}/position", s.position)
	mux.HandleFunc("GET /v1/trains/{number}/live", s.trainLive)
	mux.HandleFunc("POST /v1/position/estimate", s.estimate)

	if s.Stream == nil {
		s.Stream = &stream.Server{Hub: s.Hub, Refreshers: s.Refreshers, Log: s.Log}
	}
	mux.Handle("GET /v1/live/ws", s.Stream)
	mux.HandleFunc("GET /v1/live", s.liveNearby)
	mux.HandleFunc("GET /v1/live/bbox", s.liveBBox)
	mux.HandleFunc("GET /v1/live/status", s.liveStatus)
	mux.HandleFunc("GET /v1/live/{kind}/{id}", s.liveObject)
	mux.HandleFunc("PUT /v1/admin/trains/{number}/delay", s.admin(s.putDelay))

	if s.Alerts == nil {
		s.Alerts = &alerts.MemStore{}
	}
	mux.HandleFunc("PUT /v1/alerts/subscriptions/{token}", s.putAlertSub)
	mux.HandleFunc("GET /v1/alerts/subscriptions/{token}", s.getAlertSub)
	mux.HandleFunc("DELETE /v1/alerts/subscriptions/{token}", s.deleteAlertSub)

	mux.HandleFunc("PUT /v1/admin/stations/{code}", s.admin(s.putStation))
	mux.HandleFunc("POST /v1/admin/reload", s.admin(s.reload))
	return s.middleware(mux)
}

// ------------------------------------------------------------------ health

func (s *Server) health(w http.ResponseWriter, _ *http.Request) {
	st, loc, tr, stops := s.Index().Counts()
	writeJSON(w, http.StatusOK, map[string]any{
		"status":            "ok",
		"stations":          st,
		"stations_with_geo": loc,
		"trains":            tr,
		"timetable_stops":   stops,
		"index_loaded_at":   s.Index().LoadedAt,
		"data_source":       "datameet/railways (CC0)",
	})
}

// ---------------------------------------------------------------- stations

func (s *Server) searchStations(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query().Get("q")
	if strings.TrimSpace(q) == "" {
		writeErr(w, http.StatusBadRequest, "q is required (station code or name)")
		return
	}
	writeJSON(w, http.StatusOK, list(s.Index().SearchStations(q, intParam(r, "limit", 20, 1, 200))))
}

func (s *Server) nearbyStations(w http.ResponseWriter, r *http.Request) {
	p, ok := pointParam(w, r)
	if !ok {
		return
	}
	radius := floatParam(r, "radius_km", 5, 0.1, 200)
	writeJSON(w, http.StatusOK, list(s.Index().NearbyStations(p, radius, intParam(r, "limit", 50, 1, 500))))
}

func (s *Server) bboxStations(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	var b geo.BBox
	var err error
	for _, f := range []struct {
		k string
		v *float64
	}{{"south", &b.South}, {"west", &b.West}, {"north", &b.North}, {"east", &b.East}} {
		if *f.v, err = strconv.ParseFloat(q.Get(f.k), 64); err != nil {
			writeErr(w, http.StatusBadRequest, "south, west, north and east are required numbers")
			return
		}
	}
	if b.South > b.North || b.West > b.East {
		writeErr(w, http.StatusBadRequest, "invalid bounding box")
		return
	}
	writeJSON(w, http.StatusOK, list(s.Index().StationsInBBox(b, intParam(r, "limit", 500, 1, 5000))))
}

func (s *Server) station(w http.ResponseWriter, r *http.Request) {
	st := s.Index().Station(r.PathValue("code"))
	if st == nil {
		writeErr(w, http.StatusNotFound, "station not found")
		return
	}
	writeJSON(w, http.StatusOK, st)
}

func (s *Server) stationTrains(w http.ResponseWriter, r *http.Request) {
	ix := s.Index()
	st := ix.Station(r.PathValue("code"))
	if st == nil {
		writeErr(w, http.StatusNotFound, "station not found")
		return
	}
	type row struct {
		Train        rail.Train `json:"train"`
		Seq          int        `json:"seq"`
		ArrivalMin   *int       `json:"arrival_min,omitempty"`
		DepartureMin *int       `json:"departure_min,omitempty"`
	}
	var out []row
	for _, n := range ix.TrainsAtStation(st.Code) {
		t := ix.Train(n)
		if t == nil {
			continue
		}
		for _, sp := range ix.Stops(n) {
			if sp.StationCode == st.Code {
				out = append(out, row{Train: *t, Seq: sp.Seq, ArrivalMin: sp.ArrivalMin, DepartureMin: sp.DepartureMin})
				break
			}
		}
	}
	writeJSON(w, http.StatusOK, list(out))
}

// ------------------------------------------------------------------ trains

func (s *Server) searchTrains(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query().Get("q")
	if strings.TrimSpace(q) == "" {
		writeErr(w, http.StatusBadRequest, "q is required (train number or name)")
		return
	}
	writeJSON(w, http.StatusOK, list(s.Index().SearchTrains(q, intParam(r, "limit", 20, 1, 200))))
}

func (s *Server) train(w http.ResponseWriter, r *http.Request) {
	t := s.Index().Train(r.PathValue("number"))
	if t == nil {
		writeErr(w, http.StatusNotFound, "train not found")
		return
	}
	writeJSON(w, http.StatusOK, t)
}

// route returns the timetable with each stop's station and location.
func (s *Server) route(w http.ResponseWriter, r *http.Request) {
	ix := s.Index()
	num := r.PathValue("number")
	t := ix.Train(num)
	stops := ix.Stops(num)
	if t == nil || len(stops) == 0 {
		writeErr(w, http.StatusNotFound, "train not found")
		return
	}
	type stop struct {
		rail.Stop
		Name  string     `json:"name,omitempty"`
		Point *geo.Point `json:"location"`
	}
	out := make([]stop, 0, len(stops))
	for _, sp := range stops {
		row := stop{Stop: sp}
		if st := ix.Station(sp.StationCode); st != nil {
			row.Name, row.Point = st.Name, st.Point
		}
		out = append(out, row)
	}
	writeJSON(w, http.StatusOK, map[string]any{"train": t, "stops": out})
}

// position estimates where a train is from its timetable, shifted by the
// live delay when one is known.
//
//	GET /v1/trains/{number}/position?at=RFC3339&delay_min=15&live=1
//
// delay_min overrides the live delay; live=1 asks the delay provider for a
// fresh status first (counts against its budget).
func (s *Server) position(w http.ResponseWriter, r *http.Request) {
	at, ok := timeParam(w, r, s.Now())
	if !ok {
		return
	}
	s.writePosition(w, r, r.PathValue("number"), at, r.URL.Query().Get("live") == "1")
}

// trainLive is position with live=1.
func (s *Server) trainLive(w http.ResponseWriter, r *http.Request) {
	s.writePosition(w, r, r.PathValue("number"), s.Now(), true)
}

func (s *Server) writePosition(w http.ResponseWriter, r *http.Request, num string, at time.Time, fetch bool) {
	ix := s.Index()
	t := ix.Train(num)
	if len(ix.Stops(num)) == 0 {
		writeErr(w, http.StatusNotFound, "no timetable for this train")
		return
	}
	resp := map[string]any{"train": t}
	var d time.Duration
	if v := r.URL.Query().Get("delay_min"); v != "" {
		d = time.Duration(intParam(r, "delay_min", 0, -600, 6000)) * time.Minute
	} else {
		st, have := s.Delays.Latest(num)
		if fetch {
			// Which journey? Estimate with what we know, then ask for that one.
			pos, _ := ix.TrainPosition(num, at, s.Delays.DelayFor(num))
			ctx, cancel := context.WithTimeout(r.Context(), 12*time.Second)
			fresh, err := s.Delays.Get(ctx, num, pos.JourneyStart)
			cancel()
			if err == nil {
				st, have = fresh, true
			} else {
				resp["live_error"] = err.Error()
			}
		}
		if have {
			d = time.Duration(st.DelayMin) * time.Minute
			resp["live_status"] = st
		}
	}
	pos, _ := ix.TrainPosition(num, at, d)
	if st, ok := resp["live_status"].(delay.Status); ok && st.Point != nil && at.Sub(st.ReportedAt) < live.LiveFixMaxAge {
		// The provider reported coordinates: they beat the timetable.
		p := *st.Point
		pos.Point = &p
		pos.Estimated = false
		resp["position_source"] = st.Source
	} else {
		resp["position_source"] = "timetable"
	}
	resp["position"] = pos
	writeJSON(w, http.StatusOK, resp)
}

// nearbyTrains estimates which trains are within radius of a point now,
// applying known live delays. live=1 refreshes the delay of the nearest
// few trains from the provider first.
//
//	GET /v1/trains/nearby?lat=28.65&lon=77.24&radius_km=5
func (s *Server) nearbyTrains(w http.ResponseWriter, r *http.Request) {
	p, ok := pointParam(w, r)
	if !ok {
		return
	}
	at, ok := timeParam(w, r, s.Now())
	if !ok {
		return
	}
	radius := floatParam(r, "radius_km", 5, 0.1, 100)
	limit := intParam(r, "limit", 20, 1, 200)
	ix := s.Index()
	got := ix.NearbyTrains(p, radius, at, limit, s.Delays.DelayFor)
	if r.URL.Query().Get("live") == "1" && s.Delays.HasProvider() {
		ctx, cancel := context.WithTimeout(r.Context(), 12*time.Second)
		var wg sync.WaitGroup
		for i, t := range got {
			if i >= 5 {
				break
			}
			wg.Add(1)
			go func(num string, start time.Time) {
				defer wg.Done()
				_, _ = s.Delays.Get(ctx, num, start)
			}(t.Train.Number, t.Position.JourneyStart)
		}
		wg.Wait()
		cancel()
		got = ix.NearbyTrains(p, radius, at, limit, s.Delays.DelayFor)
	}
	// Attach the live status where one is known, so clients can tell
	// "on time (reported)" from "no live data".
	type item struct {
		rail.NearbyTrain
		LiveStatus *delay.Status `json:"live_status,omitempty"`
	}
	out := make([]item, 0, len(got))
	for _, t := range got {
		it := item{NearbyTrain: t}
		if st, ok := s.Delays.Latest(t.Train.Number); ok {
			it.LiveStatus = &st
		}
		out = append(out, it)
	}
	writeJSON(w, http.StatusOK, list(out))
}

// EstimateRequest is the body of POST /v1/position/estimate: live provider
// data (e.g. "departed X at …, expected at Y at …") turned into a position
// using the station table.
type EstimateRequest struct {
	Stops []struct {
		Code      string     `json:"code"`
		Arrival   *time.Time `json:"arrival"`
		Departure *time.Time `json:"departure"`
	} `json:"stops"`
	At       *time.Time `json:"at"`
	DelayMin int        `json:"delay_min"`
}

func (s *Server) estimate(w http.ResponseWriter, r *http.Request) {
	var req EstimateRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<20)).Decode(&req); err != nil {
		writeErr(w, http.StatusBadRequest, "invalid JSON: "+err.Error())
		return
	}
	if len(req.Stops) < 2 {
		writeErr(w, http.StatusBadRequest, "at least two stops (with times) are required")
		return
	}
	ix := s.Index()
	tl := make([]rail.TimedStop, 0, len(req.Stops))
	var unknown []string
	for i, sp := range req.Stops {
		a, d := sp.Arrival, sp.Departure
		if a == nil {
			a = d
		}
		if d == nil {
			d = a
		}
		if a == nil {
			writeErr(w, http.StatusBadRequest, "every stop needs an arrival or departure time")
			return
		}
		ts := rail.TimedStop{Seq: i + 1, Code: strings.ToUpper(sp.Code), Arrival: *a, Departure: *d}
		if st := ix.Station(sp.Code); st != nil {
			ts.Name, ts.Point = st.Name, st.Point
		} else {
			unknown = append(unknown, sp.Code)
		}
		if i > 0 && ts.Arrival.Before(tl[len(tl)-1].Departure) {
			writeErr(w, http.StatusBadRequest, "stop times must not go backwards")
			return
		}
		tl = append(tl, ts)
	}
	at := s.Now()
	if req.At != nil {
		at = *req.At
	}
	pos := rail.EstimateAt(tl, at, time.Duration(req.DelayMin)*time.Minute)
	writeJSON(w, http.StatusOK, map[string]any{"position": pos, "unknown_stations": unknown})
}

// ------------------------------------------------------------------- admin

func (s *Server) admin(h http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if s.AdminToken == "" {
			writeErr(w, http.StatusForbidden, "admin API disabled (set ADMIN_TOKEN)")
			return
		}
		got := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
		if subtle.ConstantTimeCompare([]byte(got), []byte(s.AdminToken)) != 1 {
			writeErr(w, http.StatusUnauthorized, "invalid admin token")
			return
		}
		h(w, r)
	}
}

// putStation adds or corrects a station (e.g. fills in missing coordinates).
func (s *Server) putStation(w http.ResponseWriter, r *http.Request) {
	var st rail.Station
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<16)).Decode(&st); err != nil {
		writeErr(w, http.StatusBadRequest, "invalid JSON: "+err.Error())
		return
	}
	st.Code = strings.ToUpper(r.PathValue("code"))
	if strings.TrimSpace(st.Name) == "" {
		writeErr(w, http.StatusBadRequest, "name is required")
		return
	}
	if st.Point != nil && (st.Point.Lat < -90 || st.Point.Lat > 90 || st.Point.Lon < -180 || st.Point.Lon > 180) {
		writeErr(w, http.StatusBadRequest, "location out of range")
		return
	}
	if s.Write == nil {
		writeErr(w, http.StatusServiceUnavailable, "no database configured")
		return
	}
	if err := s.Write(r.Context(), st); err != nil {
		s.Log.Error("upsert station", "err", err)
		writeErr(w, http.StatusInternalServerError, "could not save station")
		return
	}
	s.reload(w, r)
}

func (s *Server) reload(w http.ResponseWriter, r *http.Request) {
	if s.Load == nil {
		writeErr(w, http.StatusServiceUnavailable, "no database configured")
		return
	}
	ix, err := s.Load(r.Context())
	if err != nil {
		s.Log.Error("reload index", "err", err)
		writeErr(w, http.StatusInternalServerError, "reload failed")
		return
	}
	s.index.Store(ix)
	s.health(w, r)
}

// -------------------------------------------------------------------- live

func kindsParam(r *http.Request) []live.Kind {
	var out []live.Kind
	for _, k := range strings.Split(r.URL.Query().Get("types"), ",") {
		if k = strings.TrimSpace(strings.ToLower(k)); k != "" {
			out = append(out, live.Kind(strings.TrimSuffix(k, "s")))
		}
	}
	return out
}

// liveNearby returns every tracked object within radius of a point.
//
//	GET /v1/live?lat=28.65&lon=77.24&radius_km=10&types=train,flight&limit=100
func (s *Server) liveNearby(w http.ResponseWriter, r *http.Request) {
	p, ok := pointParam(w, r)
	if !ok {
		return
	}
	radius := floatParam(r, "radius_km", 10, 0.1, 500)
	kinds := kindsParam(r)
	s.Refreshers.Ensure(r.Context(), kinds, p, radius, 3*time.Second)
	res := s.Hub.FindArea(live.Query{Center: &p, RadiusKm: radius, Kinds: kinds, Limit: intParam(r, "limit", 100, 1, 2000)})
	writeJSON(w, http.StatusOK, map[string]any{"count": len(res), "items": nonNil(res), "layers": s.Hub.Status()})
}

// liveBBox returns tracked objects in a map viewport.
func (s *Server) liveBBox(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	var b geo.BBox
	var err error
	for _, f := range []struct {
		k string
		v *float64
	}{{"south", &b.South}, {"west", &b.West}, {"north", &b.North}, {"east", &b.East}} {
		if *f.v, err = strconv.ParseFloat(q.Get(f.k), 64); err != nil {
			writeErr(w, http.StatusBadRequest, "south, west, north and east are required numbers")
			return
		}
	}
	if b.South > b.North || b.West > b.East {
		writeErr(w, http.StatusBadRequest, "invalid bounding box")
		return
	}
	kinds := kindsParam(r)
	c := geo.Point{Lat: (b.South + b.North) / 2, Lon: (b.West + b.East) / 2}
	s.Refreshers.Ensure(r.Context(), kinds, c, geo.HaversineKm(c, geo.Point{Lat: b.North, Lon: b.East}), 3*time.Second)
	res := s.Hub.Find(live.Query{BBox: &b, Kinds: kinds, Limit: intParam(r, "limit", 500, 1, 5000)})
	writeJSON(w, http.StatusOK, map[string]any{"count": len(res), "items": nonNil(res), "layers": s.Hub.Status()})
}

// liveObject returns one object, e.g. /v1/live/train/12951 or /v1/live/flight/800c1b.
func (s *Server) liveObject(w http.ResponseWriter, r *http.Request) {
	k := live.Kind(strings.TrimSuffix(strings.ToLower(r.PathValue("kind")), "s"))
	id := r.PathValue("id")
	if k == live.KindTrain {
		// Always fresh for a single train (cheap).
		if o, ok := live.TrainObject(s.Index(), s.Delays, id, s.Now()); ok {
			writeJSON(w, http.StatusOK, o)
			return
		}
	} else if o, ok := s.Hub.Get(k, strings.ToLower(id)); ok {
		writeJSON(w, http.StatusOK, o)
		return
	}
	writeErr(w, http.StatusNotFound, "not currently tracked")
}

// liveStatus reports every feed.
func (s *Server) liveStatus(w http.ResponseWriter, _ *http.Request) {
	out := map[string]any{"layers": s.Hub.Status(), "delays": s.Delays.Stats()}
	if s.Stream != nil {
		out["stream_connections"] = s.Stream.Conns()
	}
	if s.Sky != nil {
		out["opensky"] = s.Sky.Usage()
	}
	if s.Traffic != nil {
		out["tomtom"] = s.Traffic.Usage()
	}
	writeJSON(w, http.StatusOK, out)
}

// DelayReport is the body of PUT /v1/admin/trains/{number}/delay.
type DelayReport struct {
	DelayMin        int        `json:"delay_min"`
	JourneyDate     string     `json:"journey_date"` // YYYY-MM-DD; default: current journey
	LastStationCode string     `json:"last_station_code"`
	Location        *geo.Point `json:"location"`
	Source          string     `json:"source"`
	ReportedAt      *time.Time `json:"reported_at"`
}

// putDelay ingests a live status from any feed (cron job, partner, scraper
// you are allowed to run).
func (s *Server) putDelay(w http.ResponseWriter, r *http.Request) {
	num := r.PathValue("number")
	ix := s.Index()
	if len(ix.Stops(num)) == 0 {
		writeErr(w, http.StatusNotFound, "unknown train")
		return
	}
	var rep DelayReport
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<16)).Decode(&rep); err != nil {
		writeErr(w, http.StatusBadRequest, "invalid JSON: "+err.Error())
		return
	}
	if rep.DelayMin < -600 || rep.DelayMin > 6000 {
		writeErr(w, http.StatusBadRequest, "delay_min out of range")
		return
	}
	if rep.JourneyDate != "" {
		if _, err := time.Parse("2006-01-02", rep.JourneyDate); err != nil {
			writeErr(w, http.StatusBadRequest, "journey_date must be YYYY-MM-DD")
			return
		}
	} else {
		pos, _ := ix.TrainPosition(num, s.Now(), time.Duration(rep.DelayMin)*time.Minute)
		rep.JourneyDate = delay.DateKey(pos.JourneyStart)
	}
	st := delay.Status{
		TrainNumber:     num,
		JourneyDate:     rep.JourneyDate,
		DelayMin:        rep.DelayMin,
		LastStationCode: strings.ToUpper(rep.LastStationCode),
		Point:           rep.Location,
		Source:          rep.Source,
		ReportedAt:      s.Now(),
	}
	if st.Source == "" {
		st.Source = "push"
	}
	if rep.ReportedAt != nil {
		st.ReportedAt = *rep.ReportedAt
	}
	if err := s.Delays.Put(r.Context(), st); err != nil {
		s.Log.Error("save delay", "err", err)
		writeErr(w, http.StatusInternalServerError, "could not save")
		return
	}
	writeJSON(w, http.StatusOK, st)
}

// ------------------------------------------------------------------ alerts

// putAlertSub creates or updates a device's alert settings. The device's
// push token is the key; only that device knows it.
//
//	PUT /v1/alerts/subscriptions/{token}
//	{"platform":"android","location":{"lat":28.65,"lon":77.24},"train_km":2,"flight_km":3,
//	 "late_min":30,"train_numbers":["12951"],"quiet_start":22,"quiet_end":7,"tz_offset_min":330}
func (s *Server) putAlertSub(w http.ResponseWriter, r *http.Request) {
	sub := alerts.Subscription{QuietStart: -1, QuietEnd: -1, TZOffsetMin: 330}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<16)).Decode(&sub); err != nil {
		writeErr(w, http.StatusBadRequest, "invalid JSON: "+err.Error())
		return
	}
	sub.DeviceToken = r.PathValue("token")
	if err := sub.Validate(); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	sub.UpdatedAt = s.Now()
	if err := s.Alerts.Put(r.Context(), sub); err != nil {
		s.Log.Error("save alert subscription", "err", err)
		writeErr(w, http.StatusInternalServerError, "could not save")
		return
	}
	writeJSON(w, http.StatusOK, sub)
}

func (s *Server) getAlertSub(w http.ResponseWriter, r *http.Request) {
	sub, ok, err := s.Alerts.Get(r.Context(), r.PathValue("token"))
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "could not load")
		return
	}
	if !ok {
		writeErr(w, http.StatusNotFound, "no subscription for this device")
		return
	}
	writeJSON(w, http.StatusOK, sub)
}

func (s *Server) deleteAlertSub(w http.ResponseWriter, r *http.Request) {
	if err := s.Alerts.Delete(r.Context(), r.PathValue("token")); err != nil {
		writeErr(w, http.StatusInternalServerError, "could not delete")
		return
	}
	writeJSON(w, http.StatusOK, map[string]bool{"deleted": true})
}

func nonNil[T any](v []T) []T {
	if v == nil {
		return []T{}
	}
	return v
}

// --------------------------------------------------------------- plumbing

func (s *Server) middleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Access-Control-Allow-Headers", "Authorization, Content-Type")
		w.Header().Set("Access-Control-Allow-Methods", "GET, POST, PUT, OPTIONS")
		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		defer func() {
			if v := recover(); v != nil {
				s.Log.Error("panic", "path", r.URL.Path, "err", v)
				writeErr(w, http.StatusInternalServerError, "internal error")
			}
		}()
		rec := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
		next.ServeHTTP(rec, r)
		if s.metrics != nil && r.Pattern != "GET /v1/live/ws" { // streams are long-lived; counted as a gauge
			s.metrics.observe(r.Method, r.Pattern, rec.status, time.Since(start))
		}
		s.Log.Debug("request", "method", r.Method, "path", r.URL.Path, "status", rec.status, "dur", time.Since(start))
	})
}

func list[T any](items []T) map[string]any {
	if items == nil {
		items = []T{}
	}
	return map[string]any{"count": len(items), "items": items}
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

func writeErr(w http.ResponseWriter, code int, msg string) {
	writeJSON(w, code, map[string]string{"error": msg})
}

func intParam(r *http.Request, k string, def, lo, hi int) int {
	v, err := strconv.Atoi(r.URL.Query().Get(k))
	if err != nil {
		return def
	}
	return max(lo, min(hi, v))
}

func floatParam(r *http.Request, k string, def, lo, hi float64) float64 {
	v, err := strconv.ParseFloat(r.URL.Query().Get(k), 64)
	if err != nil {
		return def
	}
	return max(lo, min(hi, v))
}

func pointParam(w http.ResponseWriter, r *http.Request) (geo.Point, bool) {
	q := r.URL.Query()
	lat, err1 := strconv.ParseFloat(q.Get("lat"), 64)
	lon, err2 := strconv.ParseFloat(q.Get("lon"), 64)
	if err := errors.Join(err1, err2); err != nil || lat < -90 || lat > 90 || lon < -180 || lon > 180 {
		writeErr(w, http.StatusBadRequest, "lat and lon are required (degrees)")
		return geo.Point{}, false
	}
	return geo.Point{Lat: lat, Lon: lon}, true
}

func timeParam(w http.ResponseWriter, r *http.Request, def time.Time) (time.Time, bool) {
	v := r.URL.Query().Get("at")
	if v == "" {
		return def, true
	}
	t, err := time.Parse(time.RFC3339, v)
	if err != nil {
		writeErr(w, http.StatusBadRequest, "at must be RFC 3339, e.g. 2026-11-07T18:30:00+05:30")
		return time.Time{}, false
	}
	return t, true
}
