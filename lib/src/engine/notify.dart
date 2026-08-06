/// Minimal change-notification primitives for the engine (pure Dart).
///
/// The engine must stay Flutter-free so it can run headless in the VM.
/// This is a tiny subset of `package:flutter/foundation`'s API surface, so
/// binding a painter is trivial: `CustomPainter(scene) : super(repaint: scene)`
/// accepts any [Listenable] — engine notify objects work unchanged.
library;

/// Interface for objects the painters can listen to for repaints.
abstract class Listenable {
  void addListener(VoidCallback listener);
  void removeListener(VoidCallback listener);
}

typedef VoidCallback = void Function();

/// Simple notifier; a single instance repaints every attached painter on the
/// same frame (multiple listeners are supported).
class ChangeNotifier extends Listenable {
  final List<VoidCallback> _listeners = [];

  @override
  void addListener(VoidCallback listener) {
    if (!_listeners.contains(listener)) _listeners.add(listener);
  }

  @override
  void removeListener(VoidCallback listener) {
    _listeners.remove(listener);
  }

  void notifyListeners() {
    // Copy so listeners can mutate the list during notification.
    for (final l in List<VoidCallback>.of(_listeners)) {
      l();
    }
  }

  bool get hasListeners => _listeners.isNotEmpty;
}

/// A [ChangeNotifier] that is also a single-value holder.
class ValueNotifier<T> extends ChangeNotifier {
  ValueNotifier(this._value);

  T _value;
  T get value => _value;

  set value(T v) {
    if (_value == v) return;
    _value = v;
    notifyListeners();
  }
}
