// ignore_for_file: avoid_print

import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _digits = '0123456789';

/// Same manifest rules as [parseManifestAsset] in `lib/main.dart`.
List<({String file, String glyphAsset})> _manifestEntriesFromJson(String raw) {
  final decoded = jsonDecode(raw);
  if (decoded is! List) {
    return const [];
  }
  final result = <({String file, String glyphAsset})>[];
  final usedFamilies = <String>{};
  final bannedStemPattern = RegExp(
      r'(_Guides$|Guides$|^Flow_|^Flow$|^Linefont$|Barcode|^Coral_Pixels$)',
      caseSensitive: false);
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
          result.add((file: f, glyphAsset: 'assets/glyphs/$stem.json'));
        }
      }
    }
  }
  return result;
}

bool _glyphAssetLooksUsable(String raw) {
  final decoded = jsonDecode(raw);
  if (decoded is! Map<String, dynamic>) {
    return false;
  }
  if (decoded['ascent'] is! num || decoded['descent'] is! num) {
    return false;
  }
  final glyphs = decoded['glyphs'];
  if (glyphs is! Map<String, dynamic>) {
    return false;
  }
  for (final ch in _digits.split('')) {
    final glyph = glyphs[ch];
    if (glyph is! Map<String, dynamic>) {
      return false;
    }
    if (glyph['advance'] is! num) {
      return false;
    }
    final commands = glyph['commands'];
    if (commands is! List || commands.isEmpty) {
      return false;
    }
  }
  return true;
}

void main() {
  test(
    'count generated digit glyph assets after manifest filters',
    () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final raw = await rootBundle.loadString('assets/fonts_manifest.json');
      final entries = _manifestEntriesFromJson(raw);
      final manifestCount = entries.length;
      var missingAsset = 0;
      var rejectedJson = 0;
      var passed = 0;

      for (final e in entries) {
        String glyphRaw;
        try {
          glyphRaw = await rootBundle.loadString(e.glyphAsset);
        } catch (_) {
          missingAsset++;
          continue;
        }
        try {
          if (_glyphAssetLooksUsable(glyphRaw)) {
            passed++;
          } else {
            rejectedJson++;
          }
        } catch (_) {
          rejectedJson++;
        }
      }

      print(
        'Glyph inventory: manifest(after helper-font ban)=$manifestCount '
        'missing_asset=$missingAsset rejected_json=$rejectedJson '
        'passed=$passed',
      );

      expect(manifestCount, greaterThan(0),
          reason: 'fonts_manifest.json should list fonts');
      if (missingAsset == manifestCount) {
        print(
          'No generated glyph JSON under assets/glyphs/. '
          'Run scripts/fetch_fonts.py, scripts/prune_fonts.py, then '
          'scripts/extract_glyphs.py.',
        );
      } else {
        expect(missingAsset, 0);
        expect(rejectedJson, 0);
        expect(passed, manifestCount);
      }
    },
    timeout: Timeout.none,
  );
}
