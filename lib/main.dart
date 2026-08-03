import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const Color clockBackground = Color.fromRGBO(32, 32, 32, 1.0);
const Color milkBackground = Color.fromRGBO(244, 240, 232, 1.0);
const int fontPoolTargetSize = 100;
const Duration fontPoolRotationPeriod = Duration(minutes: 5);
const double targetDigitHeightRatio = 0.897;
const MethodChannel settingsChannel = MethodChannel('fancy_clock/settings');

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

  String get stem => file.replaceFirst(RegExp(r'\.[^.]+$'), '');
  String get glyphAsset => 'assets/glyphs/$stem.json';
}

class GlyphData {
  const GlyphData({
    required this.advance,
    required this.path,
  });

  final double advance;
  final ui.Path path;
}

class GlyphFont {
  const GlyphFont({
    required this.entry,
    required this.unitsPerEm,
    required this.ascent,
    required this.descent,
    required this.visualBounds,
    required this.glyphs,
  });

  final FontEntry entry;
  final double unitsPerEm;
  final double ascent;
  final double descent;
  final ui.Rect visualBounds;
  final Map<String, GlyphData> glyphs;

  double get lineHeight => ascent - descent;
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
      r'(_Guides$|Guides$|^Flow_|^Flow$|^Linefont$|Barcode|^Coral_Pixels$)',
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

double _jsonDouble(Object? value) => value is num ? value.toDouble() : 0;

ui.Path _pathFromCommands(Object? rawCommands) {
  final path = ui.Path();
  if (rawCommands is! List) {
    return path;
  }
  for (final rawCommand in rawCommands) {
    if (rawCommand is! List || rawCommand.isEmpty) {
      continue;
    }
    final op = rawCommand.first;
    if (op == 'M' && rawCommand.length >= 3) {
      path.moveTo(_jsonDouble(rawCommand[1]), _jsonDouble(rawCommand[2]));
    } else if (op == 'L' && rawCommand.length >= 3) {
      path.lineTo(_jsonDouble(rawCommand[1]), _jsonDouble(rawCommand[2]));
    } else if (op == 'Q' && rawCommand.length >= 5) {
      path.quadraticBezierTo(
        _jsonDouble(rawCommand[1]),
        _jsonDouble(rawCommand[2]),
        _jsonDouble(rawCommand[3]),
        _jsonDouble(rawCommand[4]),
      );
    } else if (op == 'C' && rawCommand.length >= 7) {
      path.cubicTo(
        _jsonDouble(rawCommand[1]),
        _jsonDouble(rawCommand[2]),
        _jsonDouble(rawCommand[3]),
        _jsonDouble(rawCommand[4]),
        _jsonDouble(rawCommand[5]),
        _jsonDouble(rawCommand[6]),
      );
    } else if (op == 'Z') {
      path.close();
    }
  }
  return path;
}

Future<GlyphFont?> tryLoadGlyphFont(FontEntry e) async {
  try {
    final raw = await rootBundle.loadString(e.glyphAsset);
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      return null;
    }
    final rawGlyphs = decoded['glyphs'];
    if (rawGlyphs is! Map<String, dynamic>) {
      return null;
    }
    final glyphs = <String, GlyphData>{};
    ui.Rect? visualBounds;
    for (final ch in '0123456789'.split('')) {
      final rawGlyph = rawGlyphs[ch];
      if (rawGlyph is! Map<String, dynamic>) {
        return null;
      }
      final path = _pathFromCommands(rawGlyph['commands']);
      final bounds = path.getBounds();
      if (bounds.isEmpty) {
        return null;
      }
      visualBounds =
          visualBounds == null ? bounds : visualBounds.expandToInclude(bounds);
      glyphs[ch] = GlyphData(
        advance: _jsonDouble(rawGlyph['advance']),
        path: path,
      );
    }
    final bounds = visualBounds;
    if (bounds == null || bounds.isEmpty) {
      return null;
    }
    return GlyphFont(
      entry: e,
      unitsPerEm: _jsonDouble(decoded['unitsPerEm']),
      ascent: _jsonDouble(decoded['ascent']),
      descent: _jsonDouble(decoded['descent']),
      visualBounds: bounds,
      glyphs: Map<String, GlyphData>.unmodifiable(glyphs),
    );
  } catch (_) {
    return null;
  }
}

Future<_FontPoolData> _loadInitialFontPool(
  List<FontEntry> entries, {
  int targetSize = fontPoolTargetSize,
}) async {
  if (entries.isEmpty) {
    return _FontPoolData(
      loadedFonts: const [],
      remainingFonts: const [],
    );
  }

  final candidates = List<FontEntry>.from(entries)
    ..shuffle(math.Random.secure());
  final ready = <GlyphFont>[];
  var nextIndex = 0;
  for (;
      nextIndex < candidates.length && ready.length < targetSize;
      nextIndex++) {
    final font = await tryLoadGlyphFont(candidates[nextIndex]);
    if (font != null) {
      ready.add(font);
    }
  }
  return _FontPoolData(
    loadedFonts: ready,
    remainingFonts: List<FontEntry>.unmodifiable(candidates.sublist(nextIndex)),
  );
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

Future<bool> loadAmbientCameraEnabled() async {
  try {
    return await settingsChannel.invokeMethod<bool>(
          'getAmbientCameraEnabled',
        ) ??
        false;
  } catch (_) {
    return false;
  }
}

Future<void> saveAmbientCameraEnabled(bool enabled) async {
  try {
    await settingsChannel.invokeMethod<void>(
      'setAmbientCameraEnabled',
      enabled,
    );
  } catch (_) {
    // Keep the in-memory UI state usable even on platforms without the channel.
  }
}

class DigitStyle {
  const DigitStyle({
    required this.character,
    required this.color,
    this.glyphFont,
  });

  final String character;
  final Color color;
  final GlyphFont? glyphFont;
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
    final pool = await _loadInitialFontPool(declared);
    return _BootData(
      loadedFonts: pool.loadedFonts,
      remainingFonts: pool.remainingFonts,
      ambientCameraEnabled: await loadAmbientCameraEnabled(),
    );
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
          remainingFonts: snapshot.data!.remainingFonts,
          ambientCameraEnabled: snapshot.data!.ambientCameraEnabled,
        );
      },
    );
  }
}

class _FontPoolData {
  _FontPoolData({
    required this.loadedFonts,
    required this.remainingFonts,
  });

  final List<GlyphFont> loadedFonts;
  final List<FontEntry> remainingFonts;
}

class _BootData {
  _BootData({
    required this.loadedFonts,
    required this.remainingFonts,
    required this.ambientCameraEnabled,
  });

  final List<GlyphFont> loadedFonts;
  final List<FontEntry> remainingFonts;
  final bool ambientCameraEnabled;
}

class FancyClockScreen extends StatefulWidget {
  const FancyClockScreen({
    required this.fonts,
    this.remainingFonts = const [],
    this.ambientCameraEnabled = false,
    super.key,
  });

  final List<GlyphFont> fonts;
  final List<FontEntry> remainingFonts;
  final bool ambientCameraEnabled;

  @override
  State<FancyClockScreen> createState() => _FancyClockScreenState();
}

class _FancyClockScreenState extends State<FancyClockScreen>
    with WidgetsBindingObserver {
  final math.Random _rng = math.Random.secure();
  late final List<GlyphFont> _activeFonts;
  late final List<FontEntry> _remainingFonts;

  Timer? _timer;

  /// One-shot wait until the next minute boundary before starting the 1 Hz ticker.
  Timer? _minuteAlignTimer;
  Timer? _fontRotationTimer;
  StreamSubscription<double>? _ambientLightSub;
  DateTime _lastLightSample = DateTime.fromMillisecondsSinceEpoch(0);
  Color _background = clockBackground;
  bool _brightMode = false;
  late bool _ambientCameraEnabled;

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
    _activeFonts = List<GlyphFont>.from(widget.fonts);
    _remainingFonts = List<FontEntry>.from(widget.remainingFonts);
    _ambientCameraEnabled = widget.ambientCameraEnabled;
    WidgetsBinding.instance.addObserver(this);
    _lastShown = DateTime.now().toLocalFormatted();
    slots = _buildSlots(_lastShown);
    if (_ambientCameraEnabled) {
      _startAmbientLightSensor();
    }
    _scheduleAlignedTicker();
    _scheduleFontRotation();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_ambientLightSub?.cancel());
    _minuteAlignTimer?.cancel();
    _fontRotationTimer?.cancel();
    _timer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _tick(force: true);
      if (_ambientCameraEnabled) {
        _startAmbientLightSensor();
      }
    } else if (state == AppLifecycleState.paused) {
      unawaited(_ambientLightSub?.cancel());
      _ambientLightSub = null;
    }
  }

  void _startAmbientLightSensor() {
    if (!_ambientCameraEnabled || _ambientLightSub != null) {
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

  void _stopAmbientLightSensor() {
    unawaited(_ambientLightSub?.cancel());
    _ambientLightSub = null;
    _brightMode = false;
    _switchEvidence = 0;
    _ambientFast = 0.22;
    _ambientSlow = 0.22;
  }

  void _toggleAmbientCamera() {
    final enabled = !_ambientCameraEnabled;
    setState(() {
      _ambientCameraEnabled = enabled;
      if (!enabled) {
        _stopAmbientLightSensor();
        _background = clockBackground;
        slots = _recolorSlots(_lastShown, clockBackground);
      }
    });
    if (enabled) {
      unawaited(saveAmbientCameraEnabled(enabled).then((_) {
        if (mounted && _ambientCameraEnabled) {
          _startAmbientLightSensor();
        }
      }));
    } else {
      unawaited(saveAmbientCameraEnabled(enabled));
    }
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

  void _scheduleFontRotation() {
    _fontRotationTimer?.cancel();
    if (_remainingFonts.isEmpty || _activeFonts.isEmpty) {
      return;
    }
    _fontRotationTimer = Timer.periodic(fontPoolRotationPeriod, (_) {
      unawaited(_rotateOneFont());
    });
  }

  Future<void> _rotateOneFont() async {
    if (!mounted || _remainingFonts.isEmpty || _activeFonts.isEmpty) {
      return;
    }
    final nextIndex = _rng.nextInt(_remainingFonts.length);
    final next = _remainingFonts.removeAt(nextIndex);
    final loaded = await tryLoadGlyphFont(next);
    if (!mounted) {
      return;
    }
    if (loaded == null) {
      return;
    }
    setState(() {
      final replaceIndex = _rng.nextInt(_activeFonts.length);
      final replaced = _activeFonts[replaceIndex];
      _activeFonts[replaceIndex] = loaded;
      _remainingFonts.add(replaced.entry);
      slots = _buildSlots(_lastShown);
    });
  }

  List<DigitStyle> _buildSlots(String hhmmColon) {
    final families = _activeFonts;
    return List<DigitStyle>.generate(
      hhmmColon.length,
      (i) {
        final ch = hhmmColon.substring(i, i + 1);
        final isSeparator = ch == ':';
        return DigitStyle(
          character: ch,
          color: randomContrastingColor(_rng, background: _background),
          glyphFont: isSeparator
              ? null
              : (families.isNotEmpty
                  ? families[_rng.nextInt(families.length)]
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
          glyphFont: isSeparator ? null : old.glyphFont,
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
      body: Stack(
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              final side =
                  math.min(constraints.maxWidth, constraints.maxHeight);
              final fontSize = side * 0.22;
              return Center(
                child: FittedBox(
                  fit: BoxFit.contain,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final slot in slots)
                        if (slot.glyphFont case final glyphFont?)
                          GlyphDigit(
                            font: glyphFont,
                            character: slot.character,
                            color: slot.color,
                            fontSize: fontSize,
                          )
                        else if (slot.character == ':')
                          ClockSeparator(
                            color: slot.color,
                            fontSize: fontSize,
                          )
                        else
                          Text(
                            slot.character,
                            style: TextStyle(
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
          Positioned(
            top: 8,
            right: 8,
            child: SafeArea(
              child: IconButton(
                tooltip: 'Ambient camera',
                color: _background == clockBackground
                    ? Colors.white54
                    : Colors.black54,
                icon: Icon(
                  _ambientCameraEnabled
                      ? Icons.videocam_outlined
                      : Icons.videocam_off_outlined,
                ),
                onPressed: _toggleAmbientCamera,
                style: IconButton.styleFrom(
                  backgroundColor: (_background == clockBackground
                          ? Colors.white
                          : Colors.black)
                      .withValues(alpha: 0.08),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class GlyphDigit extends StatelessWidget {
  const GlyphDigit({
    required this.font,
    required this.character,
    required this.color,
    required this.fontSize,
    super.key,
  });

  final GlyphFont font;
  final String character;
  final Color color;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final glyph = font.glyphs[character];
    if (glyph == null) {
      return Text(
        character,
        style: TextStyle(
          fontSize: fontSize,
          fontWeight: FontWeight.w500,
          color: color,
          height: 1.0,
        ),
      );
    }
    final scale = fontSize * targetDigitHeightRatio / font.visualBounds.height;
    final width = math.max(1.0, glyph.advance * scale);
    return SizedBox(
      width: width,
      height: fontSize,
      child: CustomPaint(
        painter: GlyphDigitPainter(
          font: font,
          glyph: glyph,
          color: color,
          fontSize: fontSize,
        ),
      ),
    );
  }
}

class GlyphDigitPainter extends CustomPainter {
  const GlyphDigitPainter({
    required this.font,
    required this.glyph,
    required this.color,
    required this.fontSize,
  });

  final GlyphFont font;
  final GlyphData glyph;
  final Color color;
  final double fontSize;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = fontSize * targetDigitHeightRatio / font.visualBounds.height;
    final paint = Paint()
      ..style = PaintingStyle.fill
      ..color = color;
    canvas.save();
    final visualCenterY =
        (font.visualBounds.top + font.visualBounds.bottom) / 2;
    canvas.translate(0, size.height / 2 + visualCenterY * scale);
    canvas.scale(scale, -scale);
    canvas.drawPath(glyph.path, paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant GlyphDigitPainter oldDelegate) =>
      oldDelegate.font != font ||
      oldDelegate.glyph != glyph ||
      oldDelegate.color != color ||
      oldDelegate.fontSize != fontSize;
}

class ClockSeparator extends StatelessWidget {
  const ClockSeparator({
    required this.color,
    required this.fontSize,
    super.key,
  });

  final Color color;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: fontSize * 0.22,
      height: fontSize,
      child: CustomPaint(
        painter: ClockSeparatorPainter(color: color),
      ),
    );
  }
}

class ClockSeparatorPainter extends CustomPainter {
  const ClockSeparatorPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.fill
      ..color = color;
    final radius = size.height * 0.07;
    final centerX = size.width / 2;
    canvas.drawCircle(Offset(centerX, size.height * 0.38), radius, paint);
    canvas.drawCircle(Offset(centerX, size.height * 0.62), radius, paint);
  }

  @override
  bool shouldRepaint(covariant ClockSeparatorPainter oldDelegate) =>
      oldDelegate.color != color;
}

extension on DateTime {
  String toLocalFormatted() {
    final l = toLocal();
    final h = l.hour.toString().padLeft(2, '0');
    final m = l.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }
}
