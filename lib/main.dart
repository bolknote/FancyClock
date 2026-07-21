import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:fancy_clock/clock_font_metrics.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const Color clockBackground = Color.fromRGBO(32, 32, 32, 1.0);
const Color milkBackground = Color.fromRGBO(244, 240, 232, 1.0);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarIconBrightness: Brightness.light,
      statusBarIconBrightness: Brightness.light,
      statusBarBrightness: Brightness.dark,
    ),
  );
  runApp(const FancyClockApp());
}

class FontEntry {
  const FontEntry({required this.file, required this.fontFamily});

  final String file;
  final String fontFamily;
}

Future<List<FontEntry>> parseManifestAsset() async {
  final raw = await rootBundle.loadString('assets/fonts_manifest.json');
  final decoded = jsonDecode(raw);
  if (decoded is! List) {
    return const [];
  }
  final result = <FontEntry>[];
  final usedFamilies = <String>{};
  // Guides: educational helper strokes. Flow/Linefont/Barcode encode glyphs
  // as bars or dots instead of digits.
  final bannedStemPattern = RegExp(
      r'(_Guides$|Guides$|^Flow_|^Flow$|^Linefont$|Barcode)',
      caseSensitive: false);
  for (final item in decoded) {
    if (item is Map<String, dynamic>) {
      final f = item['file'];
      if (f is String && f.isNotEmpty) {
        final stem = f.replaceFirst(RegExp(r'\.[^.]+$'), '');
        if (bannedStemPattern.hasMatch(stem)) {
          // Exclude fonts that do not render plain readable digits.
          continue;
        }
        // Use deterministic ASCII-safe family ids per file to avoid collisions.
        final familyId =
            'ccf_${stem.replaceAll(RegExp(r'[^A-Za-z0-9_]'), '_')}';
        if (familyId.isNotEmpty && usedFamilies.add(familyId)) {
          result.add(FontEntry(file: f, fontFamily: familyId));
        }
      }
    }
  }
  return result;
}

Future<FontEntry?> tryRegisterFontEntry(FontEntry e) async {
  try {
    final loader = FontLoader(e.fontFamily);
    loader.addFont(rootBundle.load('assets/fonts/${e.file}'));
    await loader.load();
    if (!clockFontDigitsLookSane(e.fontFamily)) {
      return null;
    }
    return e;
  } catch (_) {
    return null;
  }
}

Future<List<FontEntry>> loadFontsFromManifest(List<FontEntry> entries) async {
  if (entries.isEmpty) {
    return const [];
  }

  final ready = <FontEntry>[];
  const chunk = 32;
  for (var i = 0; i < entries.length; i += chunk) {
    final slice = entries.sublist(i, math.min(i + chunk, entries.length));
    final results = await Future.wait(slice.map(tryRegisterFontEntry));
    for (final entry in results) {
      if (entry != null) {
        ready.add(entry);
      }
    }
  }
  return ready;
}

double _linearizeSrgb(double channel) => channel <= 0.03928
    ? channel / 12.92
    : math.pow((channel + 0.055) / 1.055, 2.4).toDouble();

double relativeLuminance(Color c) {
  final r = _linearizeSrgb(c.r);
  final g = _linearizeSrgb(c.g);
  final b = _linearizeSrgb(c.b);
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

double contrastRatio(Color a, Color b) {
  final l1 = relativeLuminance(a) + 0.05;
  final l2 = relativeLuminance(b) + 0.05;
  return l1 > l2 ? l1 / l2 : l2 / l1;
}

Color randomContrastingColor(
  math.Random rng, {
  required Color background,
  double minimumRatio = 4.55,
}) {
  for (var i = 0; i < 100; i++) {
    final h = rng.nextDouble() * 360.0;
    final s = 0.52 + rng.nextDouble() * 0.46;
    final l = 0.38 + rng.nextDouble() * 0.55;
    final c = HSLColor.fromAHSL(1.0, h, s, l).toColor();
    if (contrastRatio(c, background) >= minimumRatio) {
      return c;
    }
  }
  return Colors.white;
}

class DigitStyle {
  const DigitStyle({
    required this.character,
    required this.color,
    this.fontFamily,
  });

  final String character;
  final Color color;
  final String? fontFamily;
}

class FancyClockApp extends StatelessWidget {
  const FancyClockApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        scaffoldBackgroundColor: clockBackground,
        useMaterial3: true,
      ),
      home: const FancyClockBootstrapper(),
    );
  }
}

class FancyClockBootstrapper extends StatefulWidget {
  const FancyClockBootstrapper({super.key});

  @override
  State<FancyClockBootstrapper> createState() => _FancyClockBootstrapperState();
}

class _FancyClockBootstrapperState extends State<FancyClockBootstrapper> {
  late final Future<_BootData> boot;

  @override
  void initState() {
    super.initState();
    boot = _bootSequence();
  }

  Future<_BootData> _bootSequence() async {
    final declared = await parseManifestAsset();
    final loaded = await loadFontsFromManifest(declared);
    return _BootData(loadedFonts: loaded);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_BootData>(
      future: boot,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Scaffold(
            backgroundColor: clockBackground,
            body: Center(
              child: Text(
                '${snapshot.error}',
                style: const TextStyle(color: Colors.white54),
              ),
            ),
          );
        }
        if (!snapshot.hasData) {
          return const Scaffold(
            backgroundColor: clockBackground,
            body: Center(
              child: SizedBox.square(
                dimension: 40,
                child: CircularProgressIndicator(color: Colors.white24),
              ),
            ),
          );
        }
        return FancyClockScreen(
          fonts: snapshot.data!.loadedFonts,
        );
      },
    );
  }
}

class _BootData {
  _BootData({
    required this.loadedFonts,
  });

  final List<FontEntry> loadedFonts;
}

class FancyClockScreen extends StatefulWidget {
  const FancyClockScreen({
    required this.fonts,
    super.key,
  });

  final List<FontEntry> fonts;

  @override
  State<FancyClockScreen> createState() => _FancyClockScreenState();
}

class _FancyClockScreenState extends State<FancyClockScreen>
    with WidgetsBindingObserver {
  final math.Random _rng = math.Random.secure();

  Timer? _timer;

  /// One-shot wait until the next minute boundary before starting the 1 Hz ticker.
  Timer? _minuteAlignTimer;
  StreamSubscription<double>? _ambientLightSub;
  DateTime _lastLightSample = DateTime.fromMillisecondsSinceEpoch(0);
  Color _background = clockBackground;
  bool _brightMode = false;

  /// Reacts quickly to flash; slowly tracks ambient room light.
  double _ambientFast = 0.22;

  /// Tracks fast very slowly — with a flashlight fast runs ahead; slow barely keeps up.
  double _ambientSlow = 0.22;
  int _switchEvidence = 0;
  late List<DigitStyle> slots;
  String _lastShown = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _lastShown = DateTime.now().toLocalFormatted();
    slots = _buildSlots(_lastShown);
    _startAmbientLightSensor();
    _scheduleAlignedTicker();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_ambientLightSub?.cancel());
    _minuteAlignTimer?.cancel();
    _timer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _tick(force: true);
      _startAmbientLightSensor();
    } else if (state == AppLifecycleState.paused) {
      unawaited(_ambientLightSub?.cancel());
      _ambientLightSub = null;
    }
  }

  void _startAmbientLightSensor() {
    if (_ambientLightSub != null) {
      return;
    }
    _ambientLightSub = const EventChannel('fancy_clock/ambient_lux')
        .receiveBroadcastStream()
        .where((event) => event is num)
        .map((event) => (event as num).toDouble())
        .listen(
      _onAmbientLuma,
      onError: (_) {
        unawaited(_ambientLightSub?.cancel());
        _ambientLightSub = null;
        _useNoAmbientSensorFallback();
      },
      cancelOnError: false,
    );
  }

  void _onAmbientLuma(double luma) {
    if (!mounted) {
      return;
    }
    final now = DateTime.now();
    if (now.difference(_lastLightSample) < const Duration(milliseconds: 300)) {
      return;
    }
    _lastLightSample = now;
    _applyAmbientLuma(luma.clamp(0.0, 1.0).toDouble());
  }

  void _useNoAmbientSensorFallback() {
    if (!mounted || _background == milkBackground) {
      return;
    }
    _brightMode = true;
    _switchEvidence = 0;
    _ambientFast = 1.0;
    _ambientSlow = 1.0;
    setState(() {
      _background = milkBackground;
      slots = _recolorSlots(_lastShown, milkBackground);
    });
  }

  void _applyAmbientLuma(double ambientRaw) {
    _ambientFast = _ambientFast * 0.72 + ambientRaw * 0.28;
    _ambientSlow = _ambientSlow * 0.994 + _ambientFast * 0.006;
    final updated = _ambientMatchedBackground(_ambientFast);
    if ((updated.r - _background.r).abs() > 0.008 ||
        (updated.g - _background.g).abs() > 0.008 ||
        (updated.b - _background.b).abs() > 0.008) {
      if (!mounted) {
        return;
      }
      setState(() {
        _background = updated;
        // Only refresh contrast — reshuffling fonts every frame hammers the UI
        // and allocates; keep fonts until the minute tick.
        slots = _recolorSlots(_lastShown, updated);
      });
    }
  }

  Color _ambientMatchedBackground(double ambientLuma) {
    final a = ambientLuma.clamp(0.0, 1.0);
    // Two channels: fast reacts to a flashlight, slow tracks room light. Previously
    // baseline followed the same EMA, so the threshold was never reached.
    const brightDelta = 0.07;
    const darkDelta = 0.025;
    const brightEvidence = 4;
    const darkEvidence = 2;
    // After a flashlight, auto-exposure often keeps raw high, so fast stays above slow+ε for long.
    // Exit instead when the spike collapses (fast≈slow).
    // Below ~0.063 only when fast has nearly caught slow (spike collapsed).
    // Do not use ≥ ~0.071 or we leave milk mode right after entering (Δ slightly above bright threshold).
    const spikeCollapsedMaxDelta = 0.063;
    final delta = (a - _ambientSlow).clamp(-1.0, 1.0);
    final shouldBeBright = a > (_ambientSlow + brightDelta);
    final shouldBeDark = a < (_ambientSlow + darkDelta);
    final spikeCollapsed = delta < spikeCollapsedMaxDelta;
    if (_brightMode) {
      if (shouldBeDark || spikeCollapsed) {
        _switchEvidence++;
        if (_switchEvidence >= darkEvidence) {
          _brightMode = false;
          _switchEvidence = 0;
        }
      } else {
        _switchEvidence = 0;
      }
    } else {
      if (shouldBeBright) {
        _switchEvidence++;
        if (_switchEvidence >= brightEvidence) {
          _brightMode = true;
          _switchEvidence = 0;
        }
      } else {
        _switchEvidence = 0;
      }
    }
    return _brightMode ? milkBackground : clockBackground;
  }

  List<DigitStyle> _buildSlots(String hhmmColon) {
    final families = widget.fonts;
    return List<DigitStyle>.generate(
      hhmmColon.length,
      (i) {
        final ch = hhmmColon.substring(i, i + 1);
        final isSeparator = ch == ':';
        return DigitStyle(
          character: ch,
          color: randomContrastingColor(_rng, background: _background),
          fontFamily: isSeparator
              ? null
              : (families.isNotEmpty
                  ? families[_rng.nextInt(families.length)].fontFamily
                  : null),
        );
      },
      growable: false,
    );
  }

  /// Same fonts as [slots], new colors for contrast when only the background changes.
  List<DigitStyle> _recolorSlots(String hhmmColon, Color background) {
    final prev = slots;
    if (prev.length != hhmmColon.length) {
      return _buildSlots(hhmmColon);
    }
    for (var i = 0; i < hhmmColon.length; i++) {
      if (prev[i].character != hhmmColon.substring(i, i + 1)) {
        return _buildSlots(hhmmColon);
      }
    }
    return List<DigitStyle>.generate(
      hhmmColon.length,
      (i) {
        final ch = hhmmColon.substring(i, i + 1);
        final isSeparator = ch == ':';
        final old = prev[i];
        return DigitStyle(
          character: ch,
          color: randomContrastingColor(_rng, background: background),
          fontFamily: isSeparator ? null : old.fontFamily,
        );
      },
      growable: false,
    );
  }

  void _shuffleFor(String hhmmColon) {
    setState(() {
      slots = _buildSlots(hhmmColon);
    });
  }

  void _tick({bool force = false}) {
    final nowStr = DateTime.now().toLocalFormatted();
    if (force || nowStr != _lastShown) {
      _lastShown = nowStr;
      _shuffleFor(nowStr);
    }
  }

  void _scheduleAlignedTicker() {
    _minuteAlignTimer?.cancel();
    final now = DateTime.now();
    final delay = const Duration(minutes: 1) -
        Duration(seconds: now.second, microseconds: now.microsecond);
    _minuteAlignTimer = Timer(delay, () {
      _minuteAlignTimer = null;
      if (!mounted) {
        return;
      }
      _tick(force: true);
      _timer?.cancel();
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) {
          return;
        }
        _tick();
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _background,
      body: LayoutBuilder(
        builder: (context, constraints) {
          final side = math.min(constraints.maxWidth, constraints.maxHeight);
          final fontSize = side * 0.22;
          return Center(
            child: FittedBox(
              fit: BoxFit.contain,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final slot in slots)
                    Text(
                      slot.character,
                      style: TextStyle(
                        fontFamily: slot.fontFamily,
                        fontSize: fontSize,
                        fontWeight: FontWeight.w500,
                        color: slot.color,
                        height: 1.0,
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

extension on DateTime {
  String toLocalFormatted() {
    final l = toLocal();
    final h = l.hour.toString().padLeft(2, '0');
    final m = l.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }
}
