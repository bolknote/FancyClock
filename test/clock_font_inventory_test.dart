// ignore_for_file: avoid_print
//
// Measures layout with the host Flutter/Skia backend. Device/Android may differ
// slightly; re-check on hardware if a glyph looks wrong despite passing here.

import 'dart:convert';

import 'package:fancy_clock/clock_font_metrics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Same manifest rules as [parseManifestAsset] in `lib/main.dart`.
List<({String file, String fontFamily})> _manifestEntriesFromJson(String raw) {
  final decoded = jsonDecode(raw);
  if (decoded is! List) {
    return const [];
  }
  final result = <({String file, String fontFamily})>[];
  final usedFamilies = <String>{};
  final bannedStemPattern = RegExp(r'(_Guides$|Guides$)', caseSensitive: false);
  for (final item in decoded) {
    if (item is Map<String, dynamic>) {
      final f = item['file'];
      if (f is String && f.isNotEmpty) {
        final stem = f.replaceFirst(RegExp(r'\.[^.]+$'), '');
        if (bannedStemPattern.hasMatch(stem)) {
          continue;
        }
        final familyId =
            'ccf_${stem.replaceAll(RegExp(r'[^A-Za-z0-9_]'), '_')}';
        if (familyId.isNotEmpty && usedFamilies.add(familyId)) {
          result.add((file: f, fontFamily: familyId));
        }
      }
    }
  }
  return result;
}

void main() {
  test(
    'count fonts after load + clockFontDigitsLookSane',
    () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final raw = await rootBundle.loadString('assets/fonts_manifest.json');
      final entries = _manifestEntriesFromJson(raw);
      var manifestCount = entries.length;
      var fileMissing = 0;
      var loadFailed = 0;
      var rejectedMetrics = 0;
      var passed = 0;

      for (final e in entries) {
        try {
          await rootBundle.load('assets/fonts/${e.file}');
        } catch (_) {
          fileMissing++;
          continue;
        }
        try {
          final loader = FontLoader(e.fontFamily);
          loader.addFont(rootBundle.load('assets/fonts/${e.file}'));
          await loader.load();
        } catch (_) {
          loadFailed++;
          continue;
        }
        if (!clockFontDigitsLookSane(e.fontFamily)) {
          rejectedMetrics++;
        } else {
          passed++;
        }
      }

      print(
        'Font inventory: manifest(after Guides ban)=$manifestCount '
        'missing_file=$fileMissing load_failed=$loadFailed '
        'rejected_metrics=$rejectedMetrics passed=$passed',
      );

      expect(manifestCount, greaterThan(0),
          reason: 'fonts_manifest.json should list fonts');
      if (fileMissing == manifestCount) {
        print(
          'No .ttf under assets/fonts/ (often gitignored). '
          'Run scripts/fetch_fonts.py then re-run: '
          'flutter test test/clock_font_inventory_test.dart',
        );
      }
    },
    timeout: Timeout.none,
  );
}
