import 'dart:io';

import 'package:fancy_clock/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:leak_tracker_flutter_testing/leak_tracker_flutter_testing.dart';

bool get _leakTrackingOn =>
    const bool.fromEnvironment('LEAK_TRACKING') ||
    (bool.tryParse(Platform.environment['LEAK_TRACKING'] ?? '') ?? false);

/// Drives [_scheduleAlignedTicker]: align-to-minute delay, then a few 1s ticks.
Future<void> _pumpThroughTicker(WidgetTester tester) async {
  await tester.pump(const Duration(minutes: 1));
  await tester.pump(const Duration(seconds: 2));
}

Future<void> _mountScreen(WidgetTester tester) async {
  await tester.pumpWidget(
    const MaterialApp(
      home: FancyClockScreen(fonts: []),
    ),
  );
  await tester.pump();
  await _pumpThroughTicker(tester);
}

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
}

void main() {
  setUpAll(() {
    if (_leakTrackingOn) {
      LeakTesting.settings = LeakTesting.settings.withCreationStackTrace();
    }
  });

  testWidgets('FancyClockScreen disposes timers without leaking', (
    WidgetTester tester,
  ) async {
    await _mountScreen(tester);
    await _unmount(tester);
  });

  testWidgets('FancyClockScreen pause tears down ambient sensor without leaking', (
    WidgetTester tester,
  ) async {
    await _mountScreen(tester);
    final binding = WidgetsBinding.instance;
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await _unmount(tester);
  });

  testWidgets('FancyClockScreen repeated mount/unmount stays leak-free', (
    WidgetTester tester,
  ) async {
    for (var i = 0; i < 5; i++) {
      await _mountScreen(tester);
      await _unmount(tester);
    }
  });
}
