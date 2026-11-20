import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config.dart';
import '../../core/geo/geo_point.dart';
import '../../core/geo/geo_utils.dart';
import 'flight.dart';
import 'opensky_api.dart';

/// Where aircraft positions come from.
abstract interface class FlightDataSource {
  Future<List<FlightState>> states(GeoPoint center, double radiusKm);
}

/// Direct OpenSky access from the device (no backend).
class OpenSkyFlightSource implements FlightDataSource {
  OpenSkyFlightSource(this._api);
  final OpenSkyApi _api;

  @override
  Future<List<FlightState>> states(GeoPoint center, double radiusKm) => _api.states(boundingBox(center, radiusKm));
}

/// Flights from the Nearby Live backend's live hub (`/v1/live?types=flight`).
/// The backend shares one OpenSky budget between all users and returns
/// positions already dead-reckoned to the response time.
class BackendFlightSource implements FlightDataSource {
  BackendFlightSource(this._dio, this._baseUrl);
  final Dio _dio;
  final String _baseUrl;

  @override
  Future<List<FlightState>> states(GeoPoint center, double radiusKm) async {
    final res = await _dio.get<Map<String, dynamic>>('$_baseUrl/v1/live', queryParameters: {
      'lat': center.lat.toStringAsFixed(5),
      'lon': center.lon.toStringAsFixed(5),
      'radius_km': radiusKm.toStringAsFixed(1),
      'types': 'flight',
      'limit': 50,
    });
    return parseBackendFlights(res.data ?? const {}, DateTime.now());
  }
}

/// Parses `/v1/live` flight items. Positions are valid at [received].
List<FlightState> parseBackendFlights(Map<String, dynamic> json, DateTime received) {
  final items = json['items'];
  if (items is! List) return const [];
  final out = <FlightState>[];
  for (final it in items) {
    if (it is! Map || it['kind'] != 'flight') continue;
    final loc = it['location'];
    if (loc is! Map || loc['lat'] is! num || loc['lon'] is! num) continue;
    final extra = it['extra'];
    out.add(FlightState(
      icao24: '${it['id'] ?? ''}',
      callsign: '${it['label'] ?? ''}'.trim(),
      originCountry: extra is Map ? '${extra['country'] ?? ''}' : '',
      position: GeoPoint((loc['lat'] as num).toDouble(), (loc['lon'] as num).toDouble()),
      altitudeM: (it['altitude_m'] as num?)?.toDouble() ?? 0,
      velocityMs: ((it['speed_kmh'] as num?)?.toDouble() ?? 0) / 3.6,
      trackDeg: (it['heading_deg'] as num?)?.toDouble() ?? 0,
      onGround: it['on_ground'] == true,
      fixTime: received,
    ));
  }
  return out;
}

String _trimSlash(String u) => u.endsWith('/') ? u.substring(0, u.length - 1) : u;

/// Backend hub when `BACKEND_URL` is set, otherwise OpenSky directly.
final flightDataSourceProvider = Provider<FlightDataSource>((ref) {
  const url = AppConfig.backendUrl;
  if (url.isEmpty) return OpenSkyFlightSource(ref.watch(openSkyApiProvider));
  return BackendFlightSource(ref.watch(dioProvider), _trimSlash(url));
});
