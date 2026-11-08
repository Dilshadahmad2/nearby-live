import 'dart:math' as math;

/// Lifecycle of an object on screen.
enum PresencePhase { hidden, entering, present, leaving }

/// Per-object enter/exit state machine:
/// hidden → entering (ease in) → present → leaving (ease out) → hidden.
///
/// [value] runs 0 → 1 while entering and 1 → 0 while leaving; overlays use it
/// for opacity / scale, models for their "rise out of the ground" height.
/// Reversals are continuous: an object that re-enters while leaving picks up
/// from its current value.
class Presence {
  Presence({
    this.enterDuration = const Duration(milliseconds: 900),
    this.leaveDuration = const Duration(milliseconds: 700),
  });

  final Duration enterDuration;
  final Duration leaveDuration;

  PresencePhase phase = PresencePhase.hidden;
  double value = 0;

  /// Seconds spent in the current phase.
  double phaseTime = 0;

  bool get isVisible => phase != PresencePhase.hidden;

  /// Shown fully enough for the card / pin / beam.
  bool get isShown => phase == PresencePhase.present || (phase == PresencePhase.entering && value > .6);

  /// Advances the machine by [dt] seconds with the latest in-range flag.
  void update(double dt, bool inRange) {
    final before = phase;
    switch (phase) {
      case PresencePhase.hidden:
        if (inRange) phase = PresencePhase.entering;
      case PresencePhase.entering:
        if (!inRange) {
          phase = PresencePhase.leaving;
        } else {
          value = math.min(1.0, value + dt / _secs(enterDuration));
          if (value >= 1) phase = PresencePhase.present;
        }
      case PresencePhase.present:
        if (!inRange) phase = PresencePhase.leaving;
      case PresencePhase.leaving:
        if (inRange) {
          phase = PresencePhase.entering;
        } else {
          value = math.max(0.0, value - dt / _secs(leaveDuration));
          if (value <= 0) phase = PresencePhase.hidden;
        }
    }
    phaseTime = before == phase ? phaseTime + dt : 0;
  }

  void reset() {
    phase = PresencePhase.hidden;
    value = 0;
    phaseTime = 0;
  }

  static double _secs(Duration d) => math.max(1e-3, d.inMicroseconds / 1e6);
}

/// Configuration for [ScriptedMover] (the prototype's `TRAIN_CFG` /
/// `PLANE_CFG`).
class MoverConfig {
  const MoverConfig({
    required this.start,
    required this.target,
    required this.ease,
    required this.eps,
    required this.crawl,
    required this.leave,
    required this.end,
  });

  /// Progress where the object appears.
  final double start;

  /// Progress it eases toward while entering.
  final double target;

  /// Exponential ease rate (1/s).
  final double ease;

  /// Within this of [target] counts as arrived.
  final double eps;

  /// Slow drift while present (units/s).
  final double crawl;

  /// Speed while leaving (units/s) — "accelerates away".
  final double leave;

  /// Progress past which a leaving object is hidden.
  final double end;
}

/// Positional variant of the state machine, used for the demo train and
/// plane: the object eases in to a target position, crawls, then accelerates
/// away when it leaves the range. Port of the prototype's `step()`.
class ScriptedMover {
  ScriptedMover(this.config);

  final MoverConfig config;
  PresencePhase phase = PresencePhase.hidden;
  double progress = 0;

  void update(double dt, bool inRange) {
    final c = config;
    if (phase == PresencePhase.hidden && inRange) {
      phase = PresencePhase.entering;
      progress = c.start;
    }
    if ((phase == PresencePhase.entering || phase == PresencePhase.present) && !inRange) {
      phase = PresencePhase.leaving;
    }
    switch (phase) {
      case PresencePhase.entering:
        progress += (c.target - progress) * math.min(1.0, dt * c.ease);
        if ((c.target - progress).abs() < c.eps) phase = PresencePhase.present;
      case PresencePhase.present:
        progress += c.crawl * dt;
      case PresencePhase.leaving:
        progress += c.leave * dt;
        if (progress > c.end) phase = PresencePhase.hidden;
      case PresencePhase.hidden:
        break;
    }
  }

  /// Card/pin visible: well into the approach, or arrived.
  bool isShown(double threshold) =>
      phase == PresencePhase.present || (phase == PresencePhase.entering && progress > threshold);

  void reset() {
    phase = PresencePhase.hidden;
    progress = 0;
  }
}

/// Back-out easing used for "rise out of the ground" (prototype `easeBack`).
double easeBack(double t) {
  final x = t.clamp(0.0, 1.0);
  const s = 1.7;
  final u = x - 1;
  return 1 + (s + 1) * u * u * u + s * u * u;
}

/// Exponential approach of [current] toward [target] at [rate] (1/s).
double approach(double current, double target, double dt, double rate) =>
    current + (target - current) * math.min(1.0, dt * rate);
