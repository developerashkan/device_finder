import 'package:flutter/foundation.dart' as foundation;
import 'package:device_finder/src/engine/notify.dart' as engine;

/// Bridges the engine's pure-Dart [Listenable] (notify.dart) to Flutter's
/// [Listenable] so widgets like ListenableBuilder or CustomPainter can
/// bind to engine objects.
class FlutterListenable implements foundation.Listenable {
  FlutterListenable(this._engine);
  final engine.Listenable _engine;

  @override
  void addListener(foundation.VoidCallback listener) => _engine.addListener(listener);

  @override
  void removeListener(foundation.VoidCallback listener) => _engine.removeListener(listener);
}

extension ListenableExt on engine.Listenable {
  foundation.Listenable get toFlutter => FlutterListenable(this);
}
