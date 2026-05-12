import 'package:fancy_clock/main.dart' as app;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// On-device soak: run next to `scripts/android_memwatch.sh` to correlate PSS over time.
///
/// ```bash
/// # terminal 1
/// scripts/android_memwatch.sh 5 120
///
/// # terminal 2 (profile is closer to release memory behavior)
/// flutter test integration_test/clock_soak_test.dart -d <device_id> --profile \
///   --dart-define=SOAK_SECONDS=600
/// ```
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const soakSeconds = int.fromEnvironment('SOAK_SECONDS', defaultValue: 45);

  testWidgets(
    'real app soak ($soakSeconds s, change SOAK_SECONDS via --dart-define)',
    (WidgetTester tester) async {
      await app.main();
      await tester.pump();
      for (var i = 0; i < soakSeconds; i++) {
        await tester.pump(const Duration(seconds: 1));
      }
    },
    timeout: Timeout.none,
  );
}
