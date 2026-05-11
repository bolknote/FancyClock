import 'package:flutter/painting.dart';

/// Heuristic filter after [FontLoader.load]: rejects digits whose **layout**
/// (TextPainter width/height) looks like a missing glyph, slab, or extreme
/// outlier vs other digits.
///
/// **Limitation:** Skia may assign “normal” bounds to a glyph that still draws
/// badly on screen (e.g. barcode-like “9” on some devices). Host `flutter test`
/// and Android can disagree. Those cases need a device-side check, golden test,
/// or a filename/stem ban once the `.ttf` is identified (same idea as `_Guides`
/// in the manifest parser).
bool clockFontDigitsLookSane(String fontFamily) {
  const size = 96.0;
  const digits = '0123456789';
  final baseStyle = TextStyle(
    fontFamily: fontFamily,
    fontSize: size,
    fontWeight: FontWeight.w500,
    height: 1.0,
  );

  double medianDoubles(List<double> values) {
    final s = List<double>.from(values)..sort();
    final n = s.length;
    if (n == 0) {
      return 0;
    }
    final mid = n ~/ 2;
    return n.isOdd ? s[mid] : (s[mid - 1] + s[mid]) / 2;
  }

  final widths = <double>[];
  final heights = <double>[];
  for (final ch in digits.split('')) {
    final tp = TextPainter(
      text: TextSpan(text: ch, style: baseStyle),
      textDirection: TextDirection.ltr,
    )..layout();
    widths.add(tp.width);
    heights.add(tp.height);
  }

  final mw = medianDoubles(widths);
  final mh = medianDoubles(heights);
  if (mw < 1.0 || mh < 1.0) {
    return false;
  }

  final refBodyWidths = <double>[
    widths[0],
    widths[2],
    widths[3],
    widths[4],
    widths[5],
    widths[6],
    widths[7],
    widths[8],
    widths[9],
  ]..sort();
  final refW = refBodyWidths[refBodyWidths.length ~/ 2];

  for (var i = 0; i < 10; i++) {
    final w = widths[i];
    final h = heights[i];
    if (w < 0.5 || h < 0.5) {
      return false;
    }
    if (w > mw * 3.8 || w > refW * 4.2) {
      return false;
    }
    if (h > mh * 2.4) {
      return false;
    }
  }

  final w1 = widths[1];
  if (w1 < refW * 0.04 || w1 > refW * 4.2) {
    return false;
  }
  for (var i = 0; i < 10; i++) {
    if (i == 1) {
      continue;
    }
    if (widths[i] < refW * 0.1) {
      return false;
    }
  }
  return true;
}
