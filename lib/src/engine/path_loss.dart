/// Log-distance path-loss model: `d = 10^((Tx − RSSI) / (10·n))`.
library;

import 'dart:math' as math;

/// Lower/upper clamp for distance estimates (meters).
const double kMinDistanceMeters = 0.5;
const double kMaxDistanceMeters = 30.0;

/// Default priors when no calibration profile exists:
/// −59 dBm at 1 m with exponent 2.8 (typical furnished indoor).
const double kDefaultTxPower = -59.0;
const double kDefaultExponent = 2.8;

/// Estimate distance (m) from RSSI (dBm).
double distanceFromRssi(double rssi, {double txPower = kDefaultTxPower, double exponent = kDefaultExponent}) {
  final d = math.pow(10.0, (txPower - rssi) / (10.0 * exponent)).toDouble();
  return d.clamp(kMinDistanceMeters, kMaxDistanceMeters);
}

/// Inverse model: expected RSSI (dBm) at a given distance (m).
double rssiFromDistance(double meters, {double txPower = kDefaultTxPower, double exponent = kDefaultExponent}) {
  return txPower - 10.0 * exponent * math.log(meters.clamp(kMinDistanceMeters, kMaxDistanceMeters)) / math.ln10;
}

/// Distance uncertainty propagation from filtered RSSI std (dB).
///
/// σ_d = (d·ln10 / (10·n)) · σ_R, with a floor of 1.5 dB on σ_R.
double distanceSigma(double meters, double rssiSigmaDb, {double exponent = kDefaultExponent}) {
  final sr = math.max(rssiSigmaDb, 1.5);
  return (meters * math.ln10 / (10.0 * exponent)) * sr;
}
