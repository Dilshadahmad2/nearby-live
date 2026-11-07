import '../flights/flight.dart';
import '../trains/backend_train_source.dart';
import 'live_stream.dart';

/// Hub flight → [FlightState]. The hub has already dead-reckoned the
/// position to the send time, so the fix time is when it was received.
FlightState flightFromLive(LiveObject o, DateTime received) => FlightState(
      icao24: o.id,
      callsign: o.label,
      originCountry: '${o.extra['country'] ?? ''}',
      position: o.position,
      altitudeM: o.altitudeM ?? 0,
      velocityMs: o.speedKmh / 3.6,
      trackDeg: o.headingDeg,
      onGround: o.onGround,
      fixTime: received,
    );

/// Hub train → estimate that [snapToRail] turns into a drawable [Train].
BackendTrainEstimate trainEstimateFromLive(LiveObject o) => BackendTrainEstimate(
      number: o.id,
      name: o.name ?? o.label,
      fromCode: '${o.extra['from'] ?? ''}',
      toCode: '${o.extra['to'] ?? ''}',
      status: o.status ?? 'running',
      position: o.position,
      bearingDeg: o.headingDeg,
      speedKmh: o.speedKmh,
      distanceKm: o.distanceKm ?? 0,
      prevCode: o.prevStop,
      nextCode: o.nextStop,
      delayMin: o.delayMin,
    );
