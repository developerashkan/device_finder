---
name: project_device_finder
description: device_finder monorepo build — architecture, phases, verified math constants, key tuning discoveries
type: project
---

# device_finder (Flutter BLE tracking monorepo)

Working dir: `D:\Claude Project\Flutter\device_finder`. Monorepo: `packages/device_finder` (core, engine is pure-Dart — only dart:math/async/collection) + `packages/device_finder_ble` (optional flutter_blue_plus driver). ADR locked at `docs/architecture/0001-locked-tech-stack.md`.

**Why:** Publish to pub.dev; flutter_blue_plus is now commercially licensed → core must not depend on it; the engine must be VM-testable headlessly.
**How to apply:** Keep the engine Flutter-free (custom `notify.dart` ChangeNotifier subset instead of `package:flutter/foundation`); engine ↔ driver boundary = `RssiSample(deviceId, source, dbm, at, txPower?)`.

## Verified math constants (empirically tuned, all engine tests pass)
- Kalman: q1=0.05, **q2=3.0** (not 0.09 — discrete-time Q is much smaller than continuous; 0.09 over-converges P11), R=9, **P11 floor 1.64 dB²** (keeps K≈0.15, never locks up). Adaptive innovation boost: κ=4σ, boostSteps=4, boostQFactor=40 — fires by inflating P11 to 4R *before* the gain (first step jumps K≈0.8, lag 2.95 dB, settle 300 ms; sine smoothness max step 1.94 dB).
- Resolver: normalizes candidates as upper(0)/lower(1) — **a/b label order from solveTwoAnchors is unstable** (baseline direction flips) and previously caused phantom mirror flips. Degenerate (sep<1e-6) → return last fix, never commit. Heading-gated flips (minFlipHeadingCos=0.4).
- Trilateration degenerate (collinear): eigen pseudo-inverse (null direction gets large variance, ellipse honest, not collapsed).
- Dogleg test: walk must start y≥5 (y=3 was 39% degenerate); RSSI must be Kalman-smoothed per anchor (raw σ=3dB → ±2.5m position error, med err ~2m). Honest bounds: med err <1.2, max <5, worst-gap <4.5.

## Harness workflow (speed-run without Flutter)
- `cp packages/device_finder/lib/src/engine → /tmp/enginetest/lib/` (package layout `lib/engine/engine.dart`), import `package:engine/engine/engine.dart`, run with `~/dart-sdk/bin/dart run bin/engine_harness.dart`.
- `~/dart-sdk/bin/dart` = Dart 3.12.2 at `~/dart-sdk` (VM x86_64); Flutter SDK downloading to `/opt/flutter.tar.xz`.
- Host-file edits must be re-copied to /tmp before each run (cp -r re-syncs; stale copies caused several false failures).

**Status:** COMPLETE (all phases). Final gate: `flutter analyze` = No issues, `flutter test` = 31/31 passed on Flutter 3.38.0. Verifier agent findings all resolved (σ-adaptive Kalman gate, fusion degenerate-window guard + ghost re-arm, radar sector accumulation, resolver heading-gated relock). pub.dev artifacts: README/LICENSE/CHANGELOG/topics/platforms per package. Workflow skill saved as `device-finder-workflow`. Budget: Phase 0 research agents ≈165k tokens (flagged); build phases lean; total well over a naive 40k/phase only in Phase 0.

**Key API notes:** flutter_blue_plus 2.3.11: `connect(license: License.nonprofit)` (enum), `FlutterBluePlus.adapterState` is a stream getter, permissions handled inside the plugin. Publish-time: swap `path:` dep in device_finder_ble for hosted `device_finder: ^0.1.0`.
