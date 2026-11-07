import '../../core/geo/geo_point.dart';

enum TrainStatus { moving, stopped, delayed }

String trainStatusLabel(TrainStatus s) => switch (s) {
      TrainStatus.moving => 'Moving',
      TrainStatus.stopped => 'At station',
      TrainStatus.delayed => 'Delayed',
    };

/// A train snapped to a rail line.
class Train {
  const Train({
    required this.id,
    required this.name,
    required this.number,
    required this.from,
    required this.to,
    required this.route,
    required this.arcM,
    required this.speedMs,
    required this.position,
    required this.fixTime,
    this.status = TrainStatus.moving,
    this.estimated = true,
  });

  final String id;
  final String name;
  final String number;
  final String from;
  final String to;

  /// The rail line the train runs on (head runs toward increasing arc length).
  final List<GeoPoint> route;

  /// Arc length of the head along [route], metres, at [fixTime].
  final double arcM;

  /// Signed speed along [route], m/s.
  final double speedMs;
  final GeoPoint position;
  final DateTime fixTime;
  final TrainStatus status;

  /// True when the position is estimated (mock / schedule interpolation).
  final bool estimated;

  String get subtitle => '$name ($from → $to)';
}
