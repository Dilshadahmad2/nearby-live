package geo

import (
	"math"
	"testing"
)

func TestHaversine(t *testing.T) {
	redFort := Point{28.6562, 77.2410}
	indiaGate := Point{28.6129, 77.2295}
	if d := HaversineKm(redFort, indiaGate); math.Abs(d-4.94) > .05 {
		t.Fatalf("Red Fort → India Gate = %.3f km", d)
	}
	if d := HaversineKm(Point{0, 0}, Point{1, 0}); math.Abs(d-111.19) > .01 {
		t.Fatalf("1° lat = %.3f km", d)
	}
}

func TestInterpolate(t *testing.T) {
	a, b := Point{28, 77}, Point{29, 78}
	mid := Interpolate(a, b, .5)
	if math.Abs(HaversineKm(a, mid)-HaversineKm(mid, b)) > 1e-6 {
		t.Fatal("midpoint not equidistant")
	}
	if Interpolate(a, b, 0) != a || Interpolate(a, b, 1) != b {
		t.Fatal("endpoints")
	}
	q := Interpolate(a, b, .25)
	if math.Abs(HaversineKm(a, q)-HaversineKm(a, b)/4) > 1e-6 {
		t.Fatal("quarter point distance")
	}
}

func TestBearingAndBBox(t *testing.T) {
	if b := BearingDeg(Point{0, 0}, Point{0, 1}); math.Abs(b-90) > 1e-9 {
		t.Fatalf("east bearing = %v", b)
	}
	c := Point{28.65, 77.24}
	box := BoundingBox(c, 10)
	if !box.Contains(Point{c.Lat + .089, c.Lon}) || box.Contains(Point{c.Lat + .1, c.Lon}) {
		t.Fatal("bbox north edge")
	}
}
