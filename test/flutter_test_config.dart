// Opt-in leak tracking for `flutter test` (VM tests only).
// Run: LEAK_TRACKING=true flutter test test/clock_screen_leak_test.dart
// See: https://github.com/flutter/flutter/blob/main/docs/contributing/testing/Leak-tracking.md

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:leak_tracker_flutter_testing/leak_tracker_flutter_testing.dart';

bool _leakTrackingRequested() {
  if (kIsWeb) {
    return false;
  }
  return const bool.fromEnvironment('LEAK_TRACKING') ||
      (bool.tryParse(Platform.environment['LEAK_TRACKING'] ?? '') ?? false);
}

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  if (_leakTrackingRequested()) {
    LeakTesting.enable();
    LeakTracking.warnForUnsupportedPlatforms = false;
    LeakTracking.troubleshootingDocumentationLink =
        'https://github.com/flutter/flutter/blob/main/docs/contributing/testing/Leak-tracking.md';
  }
  await testMain();
}
