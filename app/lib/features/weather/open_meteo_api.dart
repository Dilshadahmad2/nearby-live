import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config.dart';
import '../../core/geo/geo_point.dart';
import 'weather.dart';

/// Open-Meteo forecast API (free, no key).
class OpenMeteoApi {
  OpenMeteoApi(this._dio);
  final Dio _dio;

  static const _url = 'https://api.open-meteo.com/v1/forecast';

  Future<Weather> current(GeoPoint at) async {
    final res = await _dio.get<Map<String, dynamic>>(_url, queryParameters: {
      'latitude': at.lat.toStringAsFixed(4),
      'longitude': at.lon.toStringAsFixed(4),
      'current': 'temperature_2m,relative_humidity_2m,wind_speed_10m,precipitation_probability,weather_code',
      'wind_speed_unit': 'kmh',
      'timezone': 'auto',
    });
    return parseOpenMeteo(res.data ?? const {});
  }
}

/// Parses the `current` block of an Open-Meteo forecast response.
Weather parseOpenMeteo(Map<String, dynamic> json) {
  final cur = json['current'];
  if (cur is! Map) throw const FormatException('Open-Meteo: missing "current"');
  double d(String k) => (cur[k] as num?)?.toDouble() ?? 0;
  return Weather(
    temperatureC: d('temperature_2m'),
    humidityPct: d('relative_humidity_2m').round(),
    windKmh: d('wind_speed_10m'),
    rainPct: d('precipitation_probability').round(),
    code: (cur['weather_code'] as num?)?.toInt() ?? 0,
    observedAt: DateTime.tryParse('${cur['time'] ?? ''}') ?? DateTime.now(),
  );
}

final openMeteoApiProvider = Provider<OpenMeteoApi>((ref) => OpenMeteoApi(ref.watch(dioProvider)));
