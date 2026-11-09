// device_finder example — a 3D holographic radar over a simulated room
// (no Bluetooth needed), plus a Live mode that scans real BLE devices via
// device_finder_ble.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'src/finder_controller.dart';
import 'src/ui/home_screen.dart';
import 'src/ui/palette.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(DeviceFinderApp(controller: FinderController()));
}

class DeviceFinderApp extends StatefulWidget {
  const DeviceFinderApp({super.key, required this.controller, this.themeMode = ThemeMode.system, this.radarInitialTime, this.home});

  final FinderController controller;
  final ThemeMode themeMode;

  /// Screenshot hook: start radar animations at a fixed moment.
  final double? radarInitialTime;

  /// Overrides the home screen (screenshots / tests).
  final Widget? home;

  @override
  State<DeviceFinderApp> createState() => _DeviceFinderAppState();
}

class _DeviceFinderAppState extends State<DeviceFinderApp> {
  @override
  void dispose() {
    widget.controller.dispose();
    super.dispose();
  }

  ThemeData _theme(Palette p) {
    final scheme = ColorScheme.fromSeed(
      seedColor: p.accent,
      brightness: p.dark ? Brightness.dark : Brightness.light,
    ).copyWith(primary: p.accent, surface: p.bgBottom, onSurface: p.text);
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: p.bgBottom,
      splashFactory: InkSparkle.splashFactory,
      tooltipTheme: TooltipThemeData(
        waitDuration: const Duration(milliseconds: 500),
        textStyle: TextStyle(color: p.dark ? Colors.black : Colors.white),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light.copyWith(statusBarColor: Colors.transparent),
      child: MaterialApp(
        title: 'Finder · device_finder',
        debugShowCheckedModeBanner: false,
        themeMode: widget.themeMode,
        theme: _theme(Palette.lightPalette),
        darkTheme: _theme(Palette.darkPalette),
        home: widget.home ?? HomeScreen(controller: widget.controller, radarInitialTime: widget.radarInitialTime),
      ),
    );
  }
}
