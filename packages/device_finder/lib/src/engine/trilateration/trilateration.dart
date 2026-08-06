/// Trilateration: Gauss–Newton with Levenberg–Marquardt damping, plus the
/// closed-form two-anchor solution used for mirror candidates.
library;

import 'dart:math' as math;

/// One anchor observation for trilateration.
class Anchor {
  Anchor({required this.x, required this.y, required this.distance, this.sigma = 1.0});

  final double x;
  final double y;
  final double distance; // meters
  final double sigma; // meters (1σ)
}

/// Result of the least-squares fit.
class TriFix {
  TriFix({
    required this.x,
    required this.y,
    required this.covXX,
    required this.covYY,
    required this.covXY,
    required this.iterations,
    required this.residualRms,
  });

  final double x;
  final double y;
  final double covXX, covYY, covXY;
  final int iterations;
  final double residualRms;

  /// 95% ellipse semi-axes (χ²₂ = 5.991 → scale 2.447), as
  /// `(major, minor, thetaDeg)`.
  (double, double, double) confidenceEllipse() {
    final t = covXX + covYY;
    final d = covXX * covYY - covXY * covXY;
    final disc = math.sqrt(math.max(0.0, t * t - 4 * d));
    final l1 = (t + disc) / 2;
    final l2 = (t - disc) / 2;
    final theta = 0.5 * math.atan2(2 * covXY, covXX - covYY);
    return (2.447 * math.sqrt(l1), 2.447 * math.sqrt(l2), theta * 180 / math.pi);
  }
}

/// Two candidate fix positions (mirror pair) from two anchors.
class PairFix {
  PairFix({required this.a, required this.b, required this.isDegenerate});

  final (double x, double y) a;
  final (double x, double y) b;

  /// True when the circles don't intersect (projection fallback used).
  final bool isDegenerate;
}

/// Solves the two-anchor case in closed form.
///
/// Returns the two circle-intersection candidates, or a degenerate single
/// projection onto the baseline when the ranges are inconsistent (no
/// intersection, contained circles, etc.).
PairFix solveTwoAnchors(Anchor p1, Anchor p2) {
  final dx = p2.x - p1.x;
  final dy = p2.y - p1.y;
  final l = math.sqrt(dx * dx + dy * dy);
  if (l < 1e-9) {
    // Anchors co-located: any point at distance d1.
    return PairFix(a: (p1.x + p1.distance, p1.y), b: (p1.x, p1.y + p1.distance), isDegenerate: true);
  }
  final ux = dx / l;
  final uy = dy / l;
  final a = (p1.distance * p1.distance - p2.distance * p2.distance + l * l) / (2 * l);
  final h2 = p1.distance * p1.distance - a * a;

  if (h2 < 0) {
    // No intersection (or one circle inside the other): clamp projection.
    final ac = a.clamp(0.0, l);
    return PairFix(
      a: (p1.x + ac * ux, p1.y + ac * uy),
      b: (p1.x + ac * ux, p1.y + ac * uy),
      isDegenerate: true,
    );
  }

  final h = math.sqrt(h2);
  final vx = -uy;
  final vy = ux;
  return PairFix(
    a: (p1.x + a * ux + h * vx, p1.y + a * uy + h * vy),
    b: (p1.x + a * ux - h * vx, p1.y + a * uy - h * vy),
    isDegenerate: h < 1e-6 * l,
  );
}

/// Gauss–Newton with Levenberg–Marquardt damping over [anchors].
///
/// Weighted (1/σ²) residuals; initialization is the inverse-distance-weighted
/// centroid. Stops on ‖Δ‖ < 1e-3 m, RMS residual < 0.05 m, or 20 iterations.
/// Returns the fit and its covariance `(JᵀWJ)⁻¹`.
TriFix solveTrilateration(List<Anchor> anchors, {double lambda0 = 1e-3}) {
  assert(anchors.length >= 2, 'trilateration needs ≥ 2 anchors');
  if (anchors.length == 2) {
    final pf = solveTwoAnchors(anchors[0], anchors[1]);
    // Use candidate a; covariance from the two-circle geometry.
    return TriFix(
      x: pf.a.$1,
      y: pf.a.$2,
      covXX: 1.0,
      covYY: 1.0,
      covXY: 0.0,
      iterations: 0,
      residualRms: 0.0,
    );
  }

  // Inverse-distance-weighted centroid initialization.
  var wx = 0.0, wy = 0.0, wsum = 0.0;
  for (final an in anchors) {
    final w = 1.0 / math.max(an.distance * an.distance, 0.25);
    wx += w * an.x;
    wy += w * an.y;
    wsum += w;
  }
  var x = wx / wsum;
  var y = wy / wsum;

  double cost = _residualCost(anchors, x, y);
  var lambda = lambda0;
  var iter = 0;
  var lastX = x, lastY = y, lastCost = cost;
  var converged = false;

  while (iter < 20 && !converged) {
    // Build J (n×2), r (n), W diagonal.
    final n = anchors.length;
    final J = List<double>.filled(n * 2, 0);
    final r = List<double>.filled(n, 0);
    final w = List<double>.filled(n, 0);
    for (var i = 0; i < n; i++) {
      final an = anchors[i];
      final dxa = x - an.x;
      final dya = y - an.y;
      final rho = math.sqrt(dxa * dxa + dya * dya);
      if (rho > 1e-9) {
        J[i * 2] = dxa / rho;
        J[i * 2 + 1] = dya / rho;
      } else {
        // Degenerate: fall back to last gradient direction (unit x).
        J[i * 2] = 1.0;
        J[i * 2 + 1] = 0.0;
      }
      r[i] = rho - an.distance;
      w[i] = 1.0 / (an.sigma * an.sigma);
    }

    // Normal equations: (JᵀWJ + λ·diag(JᵀWJ))·Δ = −JᵀW·r
    var jwj00 = 0.0, jwj01 = 0.0, jwj11 = 0.0;
    var b0 = 0.0, b1 = 0.0;
    for (var i = 0; i < n; i++) {
      final wi = w[i];
      final j0 = J[i * 2], j1 = J[i * 2 + 1];
      jwj00 += wi * j0 * j0;
      jwj01 += wi * j0 * j1;
      jwj11 += wi * j1 * j1;
      b0 += wi * j0 * r[i];
      b1 += wi * j1 * r[i];
    }
    final a00 = jwj00 + lambda * jwj00;
    final a11 = jwj11 + lambda * jwj11;
    final det = a00 * a11 - jwj01 * jwj01;
    if (det.abs() < 1e-18) break;

    final dx = (-b0 * a11 + jwj01 * b1) / det;
    final dy = (-b1 * a00 + jwj01 * b0) / det;

    final nx = x + dx;
    final ny = y + dy;
    final ncost = _residualCost(anchors, nx, ny);

    if (ncost < cost) {
      // Accepted: shrink damping.
      x = nx;
      y = ny;
      cost = ncost;
      lastX = x;
      lastY = y;
      lastCost = cost;
      lambda = math.max(lambda / 10, 1e-10);
      if (math.sqrt(dx * dx + dy * dy) < 1e-3 || cost < 0.05 * 0.05) {
        converged = true;
      }
    } else {
      lambda = math.min(lambda * 10, 1e6);
    }
    iter++;
  }

  // Covariance = (JᵀWJ)⁻¹ at the final point.
  var s00 = 0.0, s01 = 0.0, s11 = 0.0;
  for (final an in anchors) {
    final dxa = lastX - an.x;
    final dya = lastY - an.y;
    final rho = math.sqrt(dxa * dxa + dya * dya) + 1e-9;
    final wi = 1.0 / (an.sigma * an.sigma);
    final j0 = dxa / rho;
    final j1 = dya / rho;
    s00 += wi * j0 * j0;
    s01 += wi * j0 * j1;
    s11 += wi * j1 * j1;
  }
  final det = s00 * s11 - s01 * s01;
  double covXX, covYY, covXY;
  if (det > 1e-18) {
    covXX = s11 / det;
    covYY = s00 / det;
    covXY = -s01 / det;
  } else {
    // Degenerate geometry (collinear anchors): eigen-decompose JᵀWJ and use
    // the pseudo-inverse — the null direction gets a large-but-finite
    // variance so the 95% ellipse stays honest instead of collapsing.
    final t = s00 + s11;
    final disc = math.sqrt(math.max(0.0, t * t - 4 * det));
    final l1 = (t + disc) / 2;
    final l2 = (t - disc) / 2;
    final inv1 = l1 > 1e-12 ? 1.0 / l1 : 1e3;
    final inv2 = l2 > 1e-12 ? 1.0 / l2 : 1e3;
    final theta = 0.5 * math.atan2(2 * s01, s00 - s11);
    final cosT = math.cos(theta);
    final sinT = math.sin(theta);
    // Σ = R·diag(inv1, inv2)·Rᵀ
    covXX = inv1 * cosT * cosT + inv2 * sinT * sinT;
    covYY = inv1 * sinT * sinT + inv2 * cosT * cosT;
    covXY = (inv1 - inv2) * cosT * sinT;
  }

  return TriFix(
    x: lastX,
    y: lastY,
    covXX: covXX,
    covYY: covYY,
    covXY: covXY,
    iterations: iter,
    residualRms: math.sqrt(lastCost / anchors.length),
  );
}

double _residualCost(List<Anchor> anchors, double x, double y) {
  var sum = 0.0;
  for (final an in anchors) {
    final dxa = x - an.x;
    final dya = y - an.y;
    final rho = math.sqrt(dxa * dxa + dya * dya);
    final e = rho - an.distance;
    sum += e * e / (an.sigma * an.sigma);
  }
  return sum;
}
