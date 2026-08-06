/// Direction hints — computed, not hardcoded.
///
/// With one observer, the best direction cue is the bearing from the observer
/// to the latest fix. Four coarse buckets keep the UI honest about RSSI-grade
/// angular accuracy (fine angles are noise).
///
/// Pure Dart (no Flutter): the observer position is passed as (x, y) doubles
/// so this stays VM-testable.
library;

import 'dart:math' as math;

import 'model.dart';

enum DirectionHint {
  forward('Forward', 'Move forward'),
  left('Turn Left', 'Turn left'),
  right('Turn Right', 'Turn right'),
  back('Turn Around', 'Turn around'),
  searching('Searching', 'Moving… searching');

  const DirectionHint(this.title, this.subtitle);

  final String title;
  final String subtitle;
}

/// Computes the direction hint from the observer to the latest fix.
///
/// The observer is assumed to face +y (screen up). Returns [DirectionHint]
/// when a fix exists; otherwise [DirectionHint.searching].
DirectionHint directionFromFix({
  required PositionFix? fix,
  double observerX = 0,
  double observerY = 0,
}) {
  if (fix == null) return DirectionHint.searching;
  final dx = fix.x - observerX;
  final dy = fix.y - observerY;
  final angleDeg = math.atan2(dx, dy) * 180 / math.pi; // +90 = right, -90 = left
  if (angleDeg >= -45 && angleDeg < 45) return DirectionHint.forward;
  if (angleDeg >= 45 && angleDeg < 135) return DirectionHint.right;
  if (angleDeg >= -135 && angleDeg < -45) return DirectionHint.left;
  return DirectionHint.back;
}
