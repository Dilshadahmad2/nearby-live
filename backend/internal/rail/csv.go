package rail

import (
	"compress/gzip"
	"encoding/csv"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"

	"github.com/dilshadahmad2/nearby-live/backend/internal/geo"
)

// LoadIndexFromCSV builds an index straight from the seed CSVs, without a
// database. Used by tests and by the server's read-only dev mode.
func LoadIndexFromCSV(dir string) (*Index, error) {
	var stations []Station
	if err := readCSV(filepath.Join(dir, "stations.csv.gz"), 7, func(r []string) error {
		st := Station{Code: r[0], Name: r[1], State: r[2], Zone: r[3], Address: r[4]}
		if r[5] != "" && r[6] != "" {
			lat, err1 := strconv.ParseFloat(r[5], 64)
			lon, err2 := strconv.ParseFloat(r[6], 64)
			if err1 != nil || err2 != nil {
				return fmt.Errorf("bad coordinates for %s", r[0])
			}
			st.Point = &geo.Point{Lat: lat, Lon: lon}
		}
		stations = append(stations, st)
		return nil
	}); err != nil {
		return nil, err
	}
	var trains []Train
	if err := readCSV(filepath.Join(dir, "trains.csv.gz"), 11, func(r []string) error {
		dur, _ := strconv.Atoi(r[8])
		dist, _ := strconv.Atoi(r[9])
		trains = append(trains, Train{Number: r[0], Name: r[1], Type: r[2], Zone: r[3], FromCode: r[4], ToCode: r[5],
			Departure: r[6], Arrival: r[7], DurationMin: dur, DistanceKm: dist, ReturnTrain: r[10]})
		return nil
	}); err != nil {
		return nil, err
	}
	stops := map[string][]Stop{}
	if err := readCSV(filepath.Join(dir, "train_stops.csv.gz"), 6, func(r []string) error {
		seq, err := strconv.Atoi(r[1])
		if err != nil {
			return err
		}
		day, _ := strconv.Atoi(r[3])
		stops[r[0]] = append(stops[r[0]], Stop{Seq: seq, StationCode: r[2], Day: day, ArrivalMin: optInt(r[4]), DepartureMin: optInt(r[5])})
		return nil
	}); err != nil {
		return nil, err
	}
	return NewIndex(stations, trains, stops), nil
}

func optInt(s string) *int {
	if s == "" {
		return nil
	}
	v, err := strconv.Atoi(s)
	if err != nil {
		return nil
	}
	return &v
}

func readCSV(path string, fields int, row func([]string) error) error {
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	defer f.Close()
	gz, err := gzip.NewReader(f)
	if err != nil {
		return fmt.Errorf("%s: %w", path, err)
	}
	r := csv.NewReader(gz)
	r.FieldsPerRecord = fields
	if _, err := r.Read(); err != nil {
		return fmt.Errorf("%s header: %w", path, err)
	}
	for {
		rec, err := r.Read()
		if err == io.EOF {
			return nil
		}
		if err != nil {
			return fmt.Errorf("%s: %w", path, err)
		}
		if err := row(rec); err != nil {
			return fmt.Errorf("%s: %w", path, err)
		}
	}
}
