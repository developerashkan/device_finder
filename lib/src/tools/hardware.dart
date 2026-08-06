/// Hardware capability adaptation.
///
/// Rules locked by the ADR:
/// - Prefer connected-link RSSI over advertising RSSI when available.
/// - If a device broadcasts TxPower (AD 0x0A), use it as a free calibration
///   reference; otherwise fall back to the priors (−59 dBm @ 1 m, n = 2.8).
library;

import '../engine/model.dart';

/// Source preference for fusion: connected link always wins the tie-break.
const List<RssiSource> sourcePreferenceOrder = [
  RssiSource.connectedLink,
  RssiSource.advertising,
];

/// Per-source noise priors (σ in dB) — used by the fusion winner logic.
double sigmaForSource(RssiSource source) =>
    source == RssiSource.connectedLink ? 4.0 : 7.0;

/// Picks the best profile for a device: a stored profile wins; else, if the
/// device advertises TxPower, a derived profile; else the defaults.
///
/// [txPowerFromDevice] is typically parsed from AD 0x0A.
CalibrationProfile resolveProfile({
  required String deviceId,
  CalibrationProfile? stored,
  double? txPowerFromDevice,
  double exponent = 2.8,
}) {
  if (stored != null && !stored.isDefault) return stored;
  if (txPowerFromDevice != null) {
    return CalibrationProfile(
      txPower: txPowerFromDevice,
      exponent: exponent,
      residualRmsDb: 0,
      calibratedAt: DateTime.fromMillisecondsSinceEpoch(0),
      distancesUsed: const [],
      samplesPerDistance: 0,
    );
  }
  return CalibrationProfile.defaults;
}
