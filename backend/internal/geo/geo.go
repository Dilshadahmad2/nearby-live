// Package geo has the spherical helpers used for station distances and
// train position interpolation.
package geo

import "math"

// EarthRadiusKm is the mean Earth radius.
const EarthRadiusKm = 6371.0

// Point is a WGS84 coordinate.
type Point struct {
	Lat float64 `json:"lat"`
	Lon float64 `json:"lon"`
}

func rad(d float64) float64 { return d * math.Pi / 180 }
func deg(r float64) float64 { return r * 180 / math.Pi }

// HaversineKm is the great-circle distance between a and b in kilometres.
func HaversineKm(a, b Point) float64 {
	dLat := rad(b.Lat - a.Lat)
	dLon := rad(b.Lon - a.Lon)
	h := math.Sin(dLat/2)*math.Sin(dLat/2) +
		math.Cos(rad(a.Lat))*math.Cos(rad(b.Lat))*math.Sin(dLon/2)*math.Sin(dLon/2)
	return 2 * EarthRadiusKm * math.Asin(math.Min(1, math.Sqrt(h)))
}

// BearingDeg is the initial compass bearing from a to b (0 = north, clockwise).
func BearingDeg(a, b Point) float64 {
	la, lb := rad(a.Lat), rad(b.Lat)
	dLon := rad(b.Lon - a.Lon)
	y := math.Sin(dLon) * math.Cos(lb)
	x := math.Cos(la)*math.Sin(lb) - math.Sin(la)*math.Cos(lb)*math.Cos(dLon)
	return math.Mod(deg(math.Atan2(y, x))+360, 360)
}

// Interpolate returns the point a fraction f (0..1) of the way from a to b
// along the great circle.
func Interpolate(a, b Point, f float64) Point {
	if f <= 0 {
		return a
	}
	if f >= 1 {
		return b
	}
	d := HaversineKm(a, b) / EarthRadiusKm
	if d < 1e-12 {
		return a
	}
	la, loa := rad(a.Lat), rad(a.Lon)
	lb, lob := rad(b.Lat), rad(b.Lon)
	sa := math.Sin((1-f)*d) / math.Sin(d)
	sb := math.Sin(f*d) / math.Sin(d)
	x := sa*math.Cos(la)*math.Cos(loa) + sb*math.Cos(lb)*math.Cos(lob)
	y := sa*math.Cos(la)*math.Sin(loa) + sb*math.Cos(lb)*math.Sin(lob)
	z := sa*math.Sin(la) + sb*math.Sin(lb)
	return Point{Lat: deg(math.Atan2(z, math.Hypot(x, y))), Lon: deg(math.Atan2(y, x))}
}

// BBox is an axis-aligned box in degrees.
type BBox struct {
	South, West, North, East float64
}

// BoundingBox contains the circle of radiusKm around c.
func BoundingBox(c Point, radiusKm float64) BBox {
	dLat := deg(radiusKm / EarthRadiusKm)
	cos := math.Max(1e-6, math.Abs(math.Cos(rad(c.Lat))))
	dLon := deg(radiusKm / (EarthRadiusKm * cos))
	return BBox{
		South: math.Max(-90, c.Lat-dLat),
		North: math.Min(90, c.Lat+dLat),
		West:  math.Max(-180, c.Lon-dLon),
		East:  math.Min(180, c.Lon+dLon),
	}
}

// Contains reports whether p lies inside b.
func (b BBox) Contains(p Point) bool {
	return p.Lat >= b.South && p.Lat <= b.North && p.Lon >= b.West && p.Lon <= b.East
}
