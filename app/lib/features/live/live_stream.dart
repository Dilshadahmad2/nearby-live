import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../core/config.dart';
import '../../core/geo/geo_point.dart';

/// One live object from the backend hub (`/v1/live/ws`).
class LiveObject {
  const LiveObject({
    required this.kind,
    required this.id,
    required this.position,
    required this.headingDeg,
    required this.speedKmh,
    required this.label,
    this.name,
    this.altitudeM,
    this.onGround = false,
    this.status,
    this.delayMin,
    this.prevStop,
    this.nextStop,
    this.source,
    this.distanceKm,
    this.extra = const {},
  });

  final String kind; // train | flight | …
  final String id;
  final GeoPoint position;
  final double headingDeg;
  final double speedKmh;
  final String label;
  final String? name;
  final double? altitudeM;
  final bool onGround;
  final String? status;
  final int? delayMin;
  final String? prevStop;
  final String? nextStop;
  final String? source;
  final double? distanceKm;
  final Map<String, dynamic> extra;

  String get key => '$kind:$id';

  static LiveObject? fromJson(Object? j) {
    if (j is! Map) return null;
    final loc = j['location'];
    if (loc is! Map || loc['lat'] is! num || loc['lon'] is! num) return null;
    final extra = j['extra'];
    return LiveObject(
      kind: '${j['kind'] ?? ''}',
      id: '${j['id'] ?? ''}',
      position: GeoPoint((loc['lat'] as num).toDouble(), (loc['lon'] as num).toDouble()),
      headingDeg: (j['heading_deg'] as num?)?.toDouble() ?? 0,
      speedKmh: (j['speed_kmh'] as num?)?.toDouble() ?? 0,
      label: '${j['label'] ?? j['id'] ?? ''}',
      name: j['name'] as String?,
      altitudeM: (j['altitude_m'] as num?)?.toDouble(),
      onGround: j['on_ground'] == true,
      status: j['status'] as String?,
      delayMin: (j['delay_min'] as num?)?.toInt(),
      prevStop: j['prev_stop'] as String?,
      nextStop: j['next_stop'] as String?,
      source: j['source'] as String?,
      distanceKm: (j['distance_km'] as num?)?.toDouble(),
      extra: extra is Map ? Map<String, dynamic>.from(extra) : const {},
    );
  }
}

/// Result of applying one server message to a [LiveObjectStore].
enum ApplyResult { ignored, changed, resync }

/// The client's copy of the subscribed area, kept in sync by snapshot and
/// diff messages. Pure (no I/O), so it is unit-tested directly.
class LiveObjectStore {
  final Map<String, LiveObject> objects = {};

  /// Feeds the server runs, by kind → source (from snapshot / status).
  final Map<String, String> layers = {};
  int _seq = 0;
  bool _haveSnapshot = false;

  int get seq => _seq;

  ApplyResult apply(Map<String, dynamic> msg) {
    final ls = msg['layers'];
    if (ls is List) {
      for (final l in ls) {
        if (l is Map && l['kind'] != null) layers['${l['kind']}'] = '${l['source'] ?? ''}';
      }
    }
    switch (msg['type']) {
      case 'snapshot':
        objects.clear();
        for (final j in (msg['items'] as List? ?? const [])) {
          final o = LiveObject.fromJson(j);
          if (o != null) objects[o.key] = o;
        }
        _seq = (msg['seq'] as num?)?.toInt() ?? 0;
        _haveSnapshot = true;
        return ApplyResult.changed;
      case 'diff':
        final seq = (msg['seq'] as num?)?.toInt() ?? 0;
        // A gap means we missed a message: ask for a fresh snapshot.
        if (!_haveSnapshot || seq != _seq + 1) return ApplyResult.resync;
        _seq = seq;
        for (final j in (msg['upsert'] as List? ?? const [])) {
          final o = LiveObject.fromJson(j);
          if (o != null) objects[o.key] = o;
        }
        for (final r in (msg['remove'] as List? ?? const [])) {
          if (r is Map) objects.remove('${r['kind']}:${r['id']}');
        }
        return ApplyResult.changed;
      default:
        return ApplyResult.ignored;
    }
  }

  /// True when the server has a feed for [kind].
  bool serves(String kind) => layers.containsKey(kind);

  void reset() {
    objects.clear();
    layers.clear();
    _seq = 0;
    _haveSnapshot = false;
  }
}

/// What the client asks the server for.
class LiveSubscription {
  const LiveSubscription({
    required this.center,
    required this.radiusKm,
    this.types = const ['train', 'flight', 'traffic', 'weather'],
    this.intervalMs = 2000,
  });
  final GeoPoint center;
  final double radiusKm;
  final List<String> types;
  final int intervalMs;

  Map<String, dynamic> toJson() => {
        'type': 'subscribe',
        'lat': center.lat,
        'lon': center.lon,
        'radius_km': radiusKm,
        'types': types,
        'limit': 300,
        'interval_ms': intervalMs,
      };
}

/// WebSocket client for `/v1/live/ws`: keeps one connection open,
/// re-subscribes after reconnects (exponential back-off up to 30 s) and
/// publishes the current set of objects in the subscribed area.
class LiveStreamClient {
  LiveStreamClient(String baseUrl, {WebSocketChannel Function(Uri)? connect})
      : _uri = streamUri(baseUrl),
        _connect = connect ?? WebSocketChannel.connect;

  final Uri _uri;
  final WebSocketChannel Function(Uri) _connect;
  final store = LiveObjectStore();

  final _objects = StreamController<Map<String, LiveObject>>.broadcast();
  final _connected = StreamController<bool>.broadcast();

  WebSocketChannel? _ch;
  StreamSubscription<dynamic>? _sub;
  LiveSubscription? _want;
  Timer? _retry;
  int _attempt = 0;
  bool _running = false;
  bool isConnected = false;

  /// Current objects after every snapshot / diff.
  Stream<Map<String, LiveObject>> get objects => _objects.stream;

  /// Connection state changes.
  Stream<bool> get connected => _connected.stream;

  /// ws(s)://host/v1/live/ws from an http(s) base URL.
  static Uri streamUri(String baseUrl) {
    final b = Uri.parse(baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl);
    return b.replace(scheme: b.scheme == 'https' ? 'wss' : 'ws', path: '${b.path}/v1/live/ws');
  }

  void start() {
    if (_running) return;
    _running = true;
    _open();
  }

  void stop() {
    _running = false;
    _retry?.cancel();
    _sub?.cancel();
    _ch?.sink.close();
    _ch = null;
    _setConnected(false);
  }

  /// Replaces the subscription (sent now if connected, else on connect).
  void subscribe(LiveSubscription s) {
    _want = s;
    _send(s.toJson());
  }

  Future<void> dispose() async {
    stop();
    await _objects.close();
    await _connected.close();
  }

  void _open() {
    if (!_running) return;
    try {
      final ch = _connect(_uri);
      _ch = ch;
      _sub = ch.stream.listen(_onData, onError: (_) => _onClosed(), onDone: _onClosed, cancelOnError: true);
      ch.ready.then((_) {
        if (!identical(_ch, ch)) return;
        _attempt = 0;
        _setConnected(true);
        final w = _want;
        if (w != null) _send(w.toJson());
      }, onError: (_) => _onClosed());
    } catch (_) {
      _onClosed();
    }
  }

  void _onData(dynamic data) {
    if (data is! String) return;
    Map<String, dynamic> msg;
    try {
      msg = jsonDecode(data) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    switch (store.apply(msg)) {
      case ApplyResult.changed:
        _objects.add(Map.unmodifiable(store.objects));
      case ApplyResult.resync:
        final w = _want;
        if (w != null) _send(w.toJson());
      case ApplyResult.ignored:
        break;
    }
  }

  void _onClosed() {
    _sub?.cancel();
    _sub = null;
    _ch = null;
    store.reset();
    _setConnected(false);
    if (!_running) return;
    final delay = Duration(milliseconds: math.min(30000, 1000 * (1 << math.min(_attempt, 5))));
    _attempt++;
    _retry?.cancel();
    _retry = Timer(delay, _open);
  }

  void _send(Map<String, dynamic> m) {
    final ch = _ch;
    if (ch == null || !isConnected) return;
    try {
      ch.sink.add(jsonEncode(m));
    } catch (_) {}
  }

  void _setConnected(bool v) {
    if (isConnected == v) return;
    isConnected = v;
    if (!_connected.isClosed) _connected.add(v);
  }
}

/// Null when no backend is configured.
final liveStreamClientProvider = Provider<LiveStreamClient?>((ref) {
  const url = AppConfig.backendUrl;
  if (url.isEmpty) return null;
  final c = LiveStreamClient(url);
  ref.onDispose(c.dispose);
  return c;
});
