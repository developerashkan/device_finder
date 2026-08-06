/// Source fusion: blends connected-link and advertising RSSI.
///
/// Rule: "cleanest source wins the window", with a source-preference tie-break
/// (connected link is the ADR-preferred source). Per source we keep a ring
/// buffer of samples (span ≤ [windowSeconds]); each window yields (μ, σ,
/// count, freshness). The winner is the freshest source whose σ is within a
/// small tolerance of the best σ — but a degenerate σ=0 window (a still
/// beacon with identical samples) is treated as untrustworthy and never
/// allowed to win over a valid window of the preferred source. If everything
/// is noisy (> [maxSigmaDb]) the freshest observation overall wins. Silence
/// surfaces as staleness — never extrapolate from stale windows.
library;

import 'dart:math' as math;

import '../model.dart';

class FusionResult {
  FusionResult({
    required this.mean,
    required this.sigma,
    required this.count,
    required this.source,
    required this.fresh,
    required this.stale,
  });

  /// Window mean RSSI (dBm) of the winning source.
  final double mean;

  /// Window sample std (dB).
  final double sigma;

  final int count;
  final RssiSource source;

  /// True when at least one valid, fresh window exists.
  final bool fresh;

  /// True when the held estimate is older than [SourceFusion.staleAfter] —
  /// output must be displayed as stale, never extrapolated.
  final bool stale;
}

class SourceFusion {
  SourceFusion({
    this.windowSeconds = 2.5,
    this.maxSigmaDb = 15.0,
    this.sigmaTolerance = 1.25,
    this.minAdvertisingSamples = 2,
    this.minLinkSamples = 3,
    this.staleAfter = 2.5,
    this.ghostAfter = 5.0,
    this.minSigmaDb = 0.25, // only true σ≈0 artifacts are degenerate
  });

  final double windowSeconds;
  final double maxSigmaDb;
  final double sigmaTolerance;
  final int minAdvertisingSamples;
  final int minLinkSamples;
  final double staleAfter;
  final double ghostAfter;

  /// Windows with σ below this are degenerate (e.g. a still beacon with
  /// identical samples) and never win the "cleanest" contest.
  final double minSigmaDb;

  final Map<RssiSource, List<RssiSample>> _buffers = {
    RssiSource.advertising: [],
    RssiSource.connectedLink: [],
  };
  bool _ghosted = false;

  void push(RssiSample s) {
    final buf = _buffers[s.source]!;
    buf.add(s);
    final cutoff = s.at.subtract(Duration(milliseconds: (windowSeconds * 1000).round()));
    while (buf.isNotEmpty && buf.first.at.isBefore(cutoff)) {
      buf.removeAt(0);
    }
  }

  void reset() {
    _buffers[RssiSource.advertising]!.clear();
    _buffers[RssiSource.connectedLink]!.clear();
    _ghosted = false;
  }

  /// True once a ghosted (dropped) window has been detected and not yet
  /// re-armed by fresh samples.
  bool get ghosted => _ghosted;

  ({double mean, double sigma, int count, double age})? _window(RssiSource s, DateTime now) {
    final buf = _buffers[s]!;
    if (buf.isEmpty) return null;
    final min = s == RssiSource.advertising ? minAdvertisingSamples : minLinkSamples;
    final cutoff = now.subtract(Duration(milliseconds: (windowSeconds * 1000).round()));
    final live = buf.where((e) => !e.at.isBefore(cutoff)).toList();
    if (live.length < min) return null;
    final mean = live.fold<double>(0, (a, e) => a + e.dbm) / live.length;
    final variance = live.fold<double>(0, (a, e) => a + (e.dbm - mean) * (e.dbm - mean)) / live.length;
    final age = (now.millisecondsSinceEpoch - live.last.at.millisecondsSinceEpoch) / 1000.0;
    return (mean: mean, sigma: math.sqrt(variance), count: live.length, age: age);
  }

  /// Latest fused estimate, or null when nothing valid is in the window.
  ///
  /// Semantics:
  /// - fresh window(s) → fused mean (cleanest source wins; source-preference
  ///   tie-break; degenerate σ=0 windows never win).
  /// - no valid window but last sample within [staleAfter] → stale hold
  ///   (mean of last sample, `fresh: false`).
  /// - within [ghostAfter] of last sample → stale hold.
  /// - beyond [ghostAfter] → null (ghost dropped, no output).
  FusionResult? estimate(DateTime now) {
    final advert = _window(RssiSource.advertising, now);
    final link = _window(RssiSource.connectedLink, now);

    // The preferred source's valid window is a baseline; a degenerate window
    // (σ below the floor) can never win against a valid one.
    RssiSource? bestSource;
    double? bestSigma;

    final windows = <(RssiSource, ({double mean, double sigma, int count, double age})?)>[
      (RssiSource.connectedLink, link),
      (RssiSource.advertising, advert),
    ];
    for (final (source, w) in windows) {
      if (w == null) continue;
      if (bestSource == null || bestSigma == null) {
        bestSource = source;
        bestSigma = w.sigma;
      } else if (_isPreferable(source, w, bestSource, bestSigma)) {
        bestSource = source;
        bestSigma = w.sigma;
      }
    }

    final best = bestSource;
    final bestS = bestSigma;
    if (best == null || bestS == null) {
      return _staleOrGhost(now);
    }

    // Winner = the cleanest valid window (within tolerance), preferring the
    // freshest; the connected-link source wins ties and degenerate windows
    // never win.
    RssiSource? winner;
    double? winnerAge;
    for (final (source, w) in windows) {
      if (w == null) continue;
      if (w.sigma < minSigmaDb) continue; // degenerate
      if (w.sigma > sigmaTolerance * bestS) continue;
      if (winner == null) {
        winner = source;
        winnerAge = w.age;
        continue;
      }
      final currentAge = winnerAge!;
      // Fresher wins; exact-tie → connected link preferred.
      if (w.age < currentAge - 1e-9) {
        winner = source;
        winnerAge = w.age;
      } else if ((w.age - currentAge).abs() <= 1e-9 && source == RssiSource.connectedLink) {
        winner = source;
      }
    }
    winner ??= best;
    final w = winner == RssiSource.advertising ? advert : link;

    final age = (now.millisecondsSinceEpoch - _buffers[winner]!.last.at.millisecondsSinceEpoch) / 1000.0;
    if (age > ghostAfter) {
      _ghosted = true;
      return null;
    }
    _ghosted = false; // fresh samples re-arm the estimator
    if (age > staleAfter) {
      return FusionResult(
        mean: w!.mean,
        sigma: w.sigma,
        count: w.count,
        source: winner,
        fresh: false,
        stale: true,
      );
    }
    return FusionResult(
      mean: w!.mean,
      sigma: w.sigma,
      count: w.count,
      source: winner,
      fresh: true,
      stale: false,
    );
  }

  /// A candidate window is preferable as the best when it is meaningfully
  /// cleaner than the current best, or when it is a valid (non-degenerate)
  /// window of the preferred source.
  bool _isPreferable(
    RssiSource source,
    ({double mean, double sigma, int count, double age}) w,
    RssiSource bestSource,
    double bestSigma,
  ) {
    // A degenerate window can never be "best" when a valid one exists.
    if (w.sigma < minSigmaDb) return false;
    if (bestSigma < minSigmaDb) return true; // current best is degenerate
    final cleaner = w.sigma < bestSigma - 1e-9;
    if (cleaner) return true;
    final tie = (w.sigma - bestSigma).abs() <= 1e-9;
    return tie && source == RssiSource.connectedLink && bestSource == RssiSource.advertising;
  }

  FusionResult? _staleOrGhost(DateTime now) {
    final link = _buffers[RssiSource.connectedLink];
    final adv = _buffers[RssiSource.advertising];
    final lastSeen = [
      if (link!.isNotEmpty) link.last,
      if (adv!.isNotEmpty) adv.last,
    ];
    if (lastSeen.isEmpty) return null;
    lastSeen.sort((a, b) => b.at.compareTo(a.at));
    final last = lastSeen.first;
    final age = (now.millisecondsSinceEpoch - last.at.millisecondsSinceEpoch) / 1000.0;
    if (age > ghostAfter) {
      _ghosted = true;
      return null;
    }
    if (age > staleAfter) {
      return FusionResult(
        mean: last.dbm,
        sigma: maxSigmaDb,
        count: 0,
        source: last.source,
        fresh: false,
        stale: true,
      );
    }
    return null;
  }
}
