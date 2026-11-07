import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'geo/geo_point.dart';

/// Build-time configuration. Pass keys with `--dart-define`.
abstract final class AppConfig {
  /// TomTom Traffic Flow key. When empty, traffic uses the mock source.
  static const tomTomKey = String.fromEnvironment('TOMTOM_KEY');

  /// Demo location: Old Delhi, near Red Fort (the prototype's scenario).
  static const demoUser = GeoPoint(28.6540, 77.2410);

  static const ranges = <int>[2, 5, 10, 50];
  static const defaultRange = 5;

  static const weatherPoll = Duration(minutes: 10);
  static const flightPoll = Duration(seconds: 20);
  static const trafficPoll = Duration(minutes: 3);
  static const trainPoll = Duration(seconds: 15);

  static const userAgent = 'NearbyLive/0.1 (Flutter; +https://github.com/dilshadahmad2/nearby-live)';
}

final dioProvider = Provider<Dio>((ref) {
  final dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(seconds: 25),
    headers: {'User-Agent': AppConfig.userAgent},
  ));
  ref.onDispose(dio.close);
  return dio;
});
