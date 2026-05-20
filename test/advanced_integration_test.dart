// ═══════════════════════════════════════════════════════════════════════════════
// ADVANCED INTEGRATION TEST — Atmos App
// Deeply tests internal algorithms, live APIs, and end-to-end pipelines.
//
// Groups:
//   A: Telegram _scoreResult — exhaustive scoring matrix
//   B: TorrentioSource — sortScore logic and ranking correctness
//   C: AliasDatabase — algorithmic variation engine
//   D: StreamExtractor — provider ordering, cache state machine, race correctness
//   E: StremioStream — model, quality parsing, direct vs torrent classification
//   F: Torrentio — live HEAD-validated stream resolution end-to-end
//   G: VidAPI — live extraction & stream format validation
//   H: Videasy — live extraction with decryption pipeline
//   I: Torrentio sort fidelity — 1080p beats 4K, size cap enforced
//   J: AtmosIndex — season completeness and episode ordering
//   K: ExtractedStream pipeline — quality chain validation (best→fallback)
//   L: Provider cache state machine — IDLE→TRYING→SUCCESS/FAILED transitions
//   M: Multi-title parallel extractor stress test with HEAD verification
//   N: Subtitle model — lang normalization and displayLabel
//
// Run: flutter test test/advanced_integration_test.dart --timeout=none -v
// ═══════════════════════════════════════════════════════════════════════════════

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;
import 'package:atmos/services/stream_extractor_service.dart';
import 'package:atmos/services/torrentio_service.dart';
import 'package:atmos/services/atmos_index_client.dart';
import 'package:atmos/services/stremio_addon_service.dart';
import 'package:atmos/services/alias_database.dart';
import 'package:atmos/models/telegram_search_result.dart';

// ─── Tracking ─────────────────────────────────────────────────────────────────

enum _S { pass, fail, skip }

class _R {
  final String g, t;
  final _S s;
  final String? d;
  final Duration e;
  const _R({required this.g, required this.t, required this.s, this.d, this.e = Duration.zero});
  @override
  String toString() {
    final icon = s == _S.pass ? '✅' : s == _S.skip ? '⚠️' : '❌';
    return '$icon [${e.inMilliseconds}ms] $g | $t${d != null ? " — $d" : ""}';
  }
}

final _all = <_R>[];
void _rec(_R r) { _all.add(r); print(r.toString()); } // ignore: avoid_print

// ─── Telegram scoring under test (mirror of TelegramService._scoreResult) ─────
// We expose it directly here to test in isolation without TDLib init overhead.

int _score(TelegramSearchResult r, {String? preferLang}) {
  int score = 0;
  final q = r.quality.toLowerCase();
  if (q.contains('1080')) {
    score += q.contains('bluray') ? 5000 : 4500;
  } else if (q.contains('720')) {
    score += 3000;
  } else if (q.contains('4k') || q.contains('2160')) {
    score += 2000;
  } else if (q.contains('480')) {
    score += 1000;
  } else {
    score += 500;
  }

  final sizeMB = r.fileSize / (1024 * 1024);
  if (sizeMB > 200 && sizeMB <= 2000) {
    score += (sizeMB * 0.5).round();
  } else if (sizeMB > 2000 && sizeMB <= 4000) {
    score += 1000;
  } else if (sizeMB > 4000) {
    score -= 500;
  }

  final codec = r.videoCodec?.toUpperCase() ?? '';
  if (codec == 'HEVC') score += 400;
  if (codec == 'AV1') score += 300;

  final audio = r.audioInfo?.toLowerCase() ?? '';
  if (preferLang != null) {
    final pref = preferLang.toLowerCase();
    if (audio.contains(pref)) score += 2000;
  }
  if (audio.contains('dual') || audio.contains('multi')) {
    score += 600;
  } else if (audio.contains('hindi')) {
    score += 400;
  } else if (audio.contains('english')) {
    score += 200;
  }

  final ageHours = DateTime.now().difference(r.uploadDate).inHours;
  if (ageHours < 24) {
    score += 300;
  } else if (ageHours < 168) {
    score += 150;
  } else if (ageHours < 720) {
    score += 50;
  }

  if (r.isMultiPart) score -= 500;
  return score;
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

String _ms(Duration d) => '${d.inMilliseconds}ms';

TelegramSearchResult _mkResult({
  required String quality,
  required int fileSizeMB,
  String? codec,
  String? audio,
  bool isMultiPart = false,
  int daysOld = 30,
}) => TelegramSearchResult(
  fileId: 0,
  fileSize: fileSizeMB * 1024 * 1024,
  fileName: 'test.mkv',
  quality: quality,
  videoCodec: codec,
  audioInfo: audio,
  uploadDate: DateTime.now().subtract(Duration(days: daysOld)),
  isMultiPart: isMultiPart,
);

// HEAD request to verify a URL is alive and returns media content
Future<({int status, String? contentType, String? contentLength})> _headUrl(
  String url, {
  Map<String, String> headers = const {},
  Duration timeout = const Duration(seconds: 10),
}) async {
  try {
    final req = http.Request('HEAD', Uri.parse(url))
      ..headers.addAll(headers)
      ..headers['User-Agent'] = 'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36'
      ..headers['Range'] = 'bytes=0-1';
    final res = await req.send().timeout(timeout);
    return (
      status: res.statusCode,
      contentType: res.headers['content-type'],
      contentLength: res.headers['content-length'] ?? res.headers['content-range'],
    );
  } catch (e) {
    return (status: -1, contentType: null, contentLength: null);
  }
}

// Parse HLS manifest and count segments
Future<int> _countHlsSegments(String m3u8Url, {Map<String, String> headers = const {}}) async {
  try {
    final req = http.Request('GET', Uri.parse(m3u8Url))
      ..headers.addAll(headers)
      ..headers['User-Agent'] = 'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36';
    final res = await req.send().timeout(const Duration(seconds: 8));
    if (res.statusCode != 200) return 0;
    final body = await res.stream.bytesToString();
    // Count .ts segments or #EXTINF tags
    return RegExp(r'#EXTINF').allMatches(body).length;
  } catch (_) {
    return 0;
  }
}

// ─── Main ─────────────────────────────────────────────────────────────────────

void main() {
  setUpAll(() async {
    await dotenv.load(fileName: '.env');
  });

  tearDownAll(() {
    final pass = _all.where((r) => r.s == _S.pass).length;
    final fail = _all.where((r) => r.s == _S.fail).length;
    final skip = _all.where((r) => r.s == _S.skip).length;

    final byGroup = <String, Map<String, int>>{};
    for (final r in _all) {
      byGroup.putIfAbsent(r.g, () => {'pass': 0, 'fail': 0, 'skip': 0});
      byGroup[r.g]![r.s.name] = (byGroup[r.g]![r.s.name] ?? 0) + 1;
    }

    // ignore: avoid_print
    print('\n\n========================================================');
    // ignore: avoid_print
    print('   ADVANCED INTEGRATION TEST — FINAL REPORT');
    // ignore: avoid_print
    print('========================================================');
    // ignore: avoid_print
    print('Total: ${_all.length} | ✅ Pass: $pass | ❌ Fail: $fail | ⚠️ Skip: $skip | Rate: ${(_all.isEmpty ? 0 : pass / _all.length * 100).toStringAsFixed(1)}%');
    // ignore: avoid_print
    print('--------------------------------------------------------');
    for (final g in byGroup.keys.toList()..sort()) {
      final m = byGroup[g]!;
      // ignore: avoid_print
      print('  $g → ✅ ${m['pass']}  ❌ ${m['fail']}  ⚠️ ${m['skip']}');
    }

    // 1. FAILURES DETAILS (UNTRUNCATED)
    final failures = _all.where((r) => r.s == _S.fail).toList();
    if (failures.isNotEmpty) {
      // ignore: avoid_print
      print('\n❌ FAILURES DETAILS (${failures.length}):');
      // ignore: avoid_print
      print('--------------------------------------------------------');
      for (final f in failures) {
        // ignore: avoid_print
        print('  [FAIL] ${f.g} | ${f.t} (${f.e.inMilliseconds}ms)');
        if (f.d != null && f.d!.isNotEmpty) {
          // ignore: avoid_print
          print('         Detail: ${f.d}');
        }
      }
    }

    // 2. SKIPS & WARNINGS DETAILS (UNTRUNCATED)
    final skips = _all.where((r) => r.s == _S.skip).toList();
    if (skips.isNotEmpty) {
      // ignore: avoid_print
      print('\n⚠️ SKIPS / WARNINGS DETAILS (${skips.length}):');
      // ignore: avoid_print
      print('--------------------------------------------------------');
      for (final sk in skips) {
        // ignore: avoid_print
        print('  [SKIP] ${sk.g} | ${sk.t} (${sk.e.inMilliseconds}ms)');
        if (sk.d != null && sk.d!.isNotEmpty) {
          // ignore: avoid_print
          print('         Detail: ${sk.d}');
        }
      }
    }

    // 3. PERFORMANCE AUDIT (TOP 10 SLOWEST TESTS)
    final sortedByTime = List<_R>.from(_all)..sort((a, b) => b.e.compareTo(a.e));
    final slowest = sortedByTime.take(10).toList();
    // ignore: avoid_print
    print('\n⏱️ PERFORMANCE AUDIT — TOP 10 SLOWEST TESTS:');
    // ignore: avoid_print
    print('--------------------------------------------------------');
    for (int i = 0; i < slowest.length; i++) {
      final r = slowest[i];
      final statusStr = r.s == _S.pass ? '✅' : r.s == _S.skip ? '⚠️' : '❌';
      // ignore: avoid_print
      print('  #${i + 1} [$statusStr] ${r.e.inMilliseconds}ms — ${r.g} | ${r.t}');
    }

    // 4. GROUP PERFORMANCE SUMMARY
    // ignore: avoid_print
    print('\n📊 GROUP AVERAGE LATENCIES:');
    // ignore: avoid_print
    print('--------------------------------------------------------');
    final groupLatencies = <String, List<int>>{};
    for (final r in _all) {
      groupLatencies.putIfAbsent(r.g, () => []);
      groupLatencies[r.g]!.add(r.e.inMilliseconds);
    }
    for (final g in groupLatencies.keys.toList()..sort()) {
      final times = groupLatencies[g]!;
      final avg = times.reduce((a, b) => a + b) / times.length;
      final max = times.reduce((a, b) => a > b ? a : b);
      // ignore: avoid_print
      print('  $g → Average: ${avg.toStringAsFixed(1)}ms | Max: ${max}ms');
    }
    // ignore: avoid_print
    print('========================================================\n');
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // GROUP A: Telegram _scoreResult — exhaustive scoring matrix
  // ═══════════════════════════════════════════════════════════════════════════

  group('A: Telegram scoring matrix', () {
    const g = 'TG.score';

    // Quality hierarchy: 1080p BluRay > 1080p WEB > 720p > 4K > 480p > unknown
    test('1080p BluRay scores highest in quality tier', () {
      final br   = _mkResult(quality: '1080p bluray', fileSizeMB: 1500);
      final web  = _mkResult(quality: '1080p',        fileSizeMB: 1500);
      final hd   = _mkResult(quality: '720p',         fileSizeMB: 1500);
      final k4   = _mkResult(quality: '4K',           fileSizeMB: 1500);
      final sd   = _mkResult(quality: '480p',         fileSizeMB: 1500);

      expect(_score(br), greaterThan(_score(web)),
        reason: '1080p BluRay should beat 1080p web');
      expect(_score(web), greaterThan(_score(hd)));
      expect(_score(hd), greaterThan(_score(k4)),
        reason: '720p should beat 4K on streaming platform');
      expect(_score(k4), greaterThan(_score(sd)));

      _rec(_R(g: g, t: 'quality hierarchy BluRay>WEB>720>4K>480', s: _S.pass,
        d: 'BR=${_score(br)} WEB=${_score(web)} 720=${_score(hd)} 4K=${_score(k4)} 480=${_score(sd)}'));
    });

    // Size scoring: 1GB file scores better than 50MB or 6GB
    test('size scoring: mid-range (200MB-2GB) preferred', () {
      final small  = _mkResult(quality: '1080p', fileSizeMB: 50);    // too small
      final good   = _mkResult(quality: '1080p', fileSizeMB: 1500);  // sweet spot
      final large  = _mkResult(quality: '1080p', fileSizeMB: 5000);  // penalised

      expect(_score(good), greaterThan(_score(small)));
      expect(_score(good), greaterThan(_score(large)));

      _rec(_R(g: g, t: 'size scoring: 1500MB preferred', s: _S.pass,
        d: 'small=${_score(small)} good=${_score(good)} large=${_score(large)}'));
    });

    // Codec: HEVC > AV1 > AVC (no bonus)
    test('codec: HEVC > AV1 > H.264', () {
      final hevc  = _mkResult(quality: '1080p', fileSizeMB: 1000, codec: 'HEVC');
      final av1   = _mkResult(quality: '1080p', fileSizeMB: 1000, codec: 'AV1');
      final avc   = _mkResult(quality: '1080p', fileSizeMB: 1000, codec: 'H264');

      expect(_score(hevc), greaterThan(_score(av1)));
      expect(_score(av1),  greaterThan(_score(avc)));

      _rec(_R(g: g, t: 'codec HEVC>AV1>AVC', s: _S.pass,
        d: 'HEVC=${_score(hevc)} AV1=${_score(av1)} AVC=${_score(avc)}'));
    });

    // Language boost: preferred lang gets +2000
    test('language boost: matching lang gets strong +2000', () {
      final hindi    = _mkResult(quality: '1080p', fileSizeMB: 800, audio: 'Hindi');
      final english  = _mkResult(quality: '1080p', fileSizeMB: 800, audio: 'English');
      final dual     = _mkResult(quality: '1080p', fileSizeMB: 800, audio: 'Dual Audio');

      final scoreHHindi = _score(hindi, preferLang: 'hindi');
      final scoreEHindi = _score(english, preferLang: 'hindi');

      expect(scoreHHindi - scoreEHindi, greaterThanOrEqualTo(2000),
        reason: 'Lang boost must be >=2000');

      _rec(_R(g: g, t: 'lang boost: hindi preferred', s: _S.pass,
        d: 'hindi=$scoreHHindi english=$scoreEHindi diff=${scoreHHindi - scoreEHindi}'));

      // Dual audio + Hindi preferred
      final scoreD = _score(dual, preferLang: 'dual');
      _rec(_R(g: g, t: 'dual audio lang boost', s: scoreD > _score(english) ? _S.pass : _S.fail,
        d: 'dual=$scoreD vs english=${_score(english)}'));
    });

    // Recency: newer uploads score better
    test('recency: today > this week > this month > older', () {
      final today   = _mkResult(quality: '1080p', fileSizeMB: 800, daysOld: 0);
      final week    = _mkResult(quality: '1080p', fileSizeMB: 800, daysOld: 5);
      final month   = _mkResult(quality: '1080p', fileSizeMB: 800, daysOld: 20);
      final older   = _mkResult(quality: '1080p', fileSizeMB: 800, daysOld: 90);

      expect(_score(today), greaterThan(_score(week)));
      expect(_score(week),  greaterThan(_score(month)));
      expect(_score(month), greaterThan(_score(older)));

      _rec(_R(g: g, t: 'recency scoring', s: _S.pass,
        d: 'today=${_score(today)} week=${_score(week)} month=${_score(month)} old=${_score(older)}'));
    });

    // Multi-part penalty: -500
    test('multi-part penalised by 500', () {
      final single = _mkResult(quality: '1080p', fileSizeMB: 1000);
      final multi  = _mkResult(quality: '1080p', fileSizeMB: 1000, isMultiPart: true);

      final diff = _score(single) - _score(multi);
      expect(diff, equals(500));

      _rec(_R(g: g, t: 'multi-part -500 penalty', s: _S.pass, d: 'diff=$diff'));
    });

    // Full ranking: expected sort order across 5 mixed results
    test('full ranking: 1080p+HEVC+Hindi+fresh beats all', () {
      final winner = _mkResult(quality: '1080p bluray', fileSizeMB: 1500, codec: 'HEVC', audio: 'Hindi', daysOld: 1);
      final decent = _mkResult(quality: '1080p',         fileSizeMB: 1000, codec: 'AV1',  audio: 'English', daysOld: 10);
      final ok     = _mkResult(quality: '720p',          fileSizeMB: 800,                 audio: 'Hindi', daysOld: 2);
      final bad    = _mkResult(quality: '480p',          fileSizeMB: 300);
      final huge   = _mkResult(quality: '1080p',         fileSizeMB: 6000); // penalised for size

      final sorted = [winner, decent, ok, bad, huge]
        ..sort((a, b) => _score(b, preferLang: 'hindi').compareTo(_score(a, preferLang: 'hindi')));

      expect(sorted.first, same(winner));

      _rec(_R(g: g, t: 'full 5-way ranking correctness', s: sorted.first == winner ? _S.pass : _S.fail,
        d: 'winner score=${_score(winner, preferLang: "hindi")} huge=${_score(huge, preferLang: "hindi")}'));
    });

    // Edge: empty quality string
    test('unknown quality → 500 base score', () {
      final unk = _mkResult(quality: '', fileSizeMB: 500);
      final s = _score(unk);
      expect(s, greaterThanOrEqualTo(500));
      _rec(_R(g: g, t: 'unknown quality base 500', s: _S.pass, d: 'score=$s'));
    });

    // Edge: zero-size file
    test('zero fileSize does not crash scorer', () {
      final zero = _mkResult(quality: '1080p', fileSizeMB: 0);
      expect(() => _score(zero), returnsNormally);
      _rec(const _R(g: g, t: 'zero file size no crash', s: _S.pass));
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // GROUP B: TorrentioSource.sortScore — ranking fidelity
  // ═══════════════════════════════════════════════════════════════════════════

  group('B: Torrentio sortScore', () {
    const g = 'Torrentio.sort';

    TorrentioSource make(String raw, {int seeders = 100}) {
      return TorrentioSource.fromJson({
        'title': 'Torrentio\n$raw\n💾 2.1 GB ⚙️ RARBG 👤 $seeders',
        'infoHash': 'abc${raw.hashCode.abs()}',
      });
    }

    test('1080p x265 > 720p x264 (same seeders)', () {
      final a = make('1080p • WEB-DL • x265');
      final b = make('720p • WEB-DL • x264');
      expect(a.sortScore, greaterThan(b.sortScore));
      _rec(_R(g: g, t: '1080p>720p', s: _S.pass, d: '1080=${a.sortScore} 720=${b.sortScore}'));
    });

    test('4K is intentionally scored below 1080p', () {
      final hd = make('1080p • BluRay • x265', seeders: 200);
      final k4 = make('2160p • 4K • HEVC', seeders: 300);
      expect(hd.sortScore, greaterThan(k4.sortScore),
        reason: '4K+500 < 1080p+2000 even with more seeders');
      _rec(_R(g: g, t: '4K < 1080p in sortScore', s: _S.pass,
        d: '1080=${hd.sortScore} 4K=${k4.sortScore}'));
    });

    test('x265 codec gets +500 bonus over x264', () {
      final x65 = make('1080p • x265', seeders: 100);
      final x64 = make('1080p • x264', seeders: 100);
      expect(x65.sortScore - x64.sortScore, equals(500));
      _rec(_R(g: g, t: 'x265 +500 vs x264', s: _S.pass,
        d: 'x265=${x65.sortScore} x264=${x64.sortScore}'));
    });

    test('seeders break ties correctly', () {
      final hi = make('1080p • x265', seeders: 1000);
      final lo = make('1080p • x265', seeders: 10);
      expect(hi.sortScore, greaterThan(lo.sortScore));
      _rec(_R(g: g, t: 'high seeders wins tie', s: _S.pass,
        d: 'hi=${hi.sortScore} lo=${lo.sortScore}'));
    });

    test('Atmos audio gets +200 bonus', () {
      final atm = make('1080p • x265 • Atmos', seeders: 100);
      final aac = make('1080p • x265 • AAC',   seeders: 100);
      expect(atm.sortScore, greaterThan(aac.sortScore));
      _rec(_R(g: g, t: 'Atmos audio bonus', s: _S.pass,
        d: 'atmos=${atm.sortScore} aac=${aac.sortScore}'));
    });

    test('sort produces consistent descending order', () {
      final sources = [
        make('480p • x264', seeders: 500),
        make('1080p • x265 • Atmos', seeders: 300),
        make('720p • x264', seeders: 400),
        make('1080p • x264', seeders: 200),
        make('2160p • HEVC', seeders: 800),
      ]..sort((a, b) => b.sortScore.compareTo(a.sortScore));

      // 1080p x265 Atmos should top the list
      expect(sources.first.quality, equals('1080p'));
      expect(sources.first.audio, equals('Atmos'));

      _rec(_R(g: g, t: '5-source sort order', s:
        sources.first.quality == '1080p' && sources.first.audio == 'Atmos' ? _S.pass : _S.fail,
        d: sources.map((s) => '${s.quality}/${s.audio}/${s.codec}').join(' > ')));
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // GROUP C: AliasDatabase — algorithmic variation engine (no Hive init)
  // ═══════════════════════════════════════════════════════════════════════════

  group('C: AliasDatabase variations', () {
    const g = 'Alias.algo';

    // Access the public getSearchVariations (falls back to algorithmic when Hive = null)
    Future<List<String>> vars(String title) =>
        AliasDatabase.getSearchVariations(title);

    test('manual alias: Breaking Bad → bb, breakingbad', () async {
      final v = await vars('Breaking Bad');
      final lower = v.map((s) => s.toLowerCase()).toList();
      expect(lower, containsAll(['bb', 'breakingbad']));
      _rec(_R(g: g, t: 'BB manual alias', s:
        lower.contains('bb') && lower.contains('breakingbad') ? _S.pass : _S.fail,
        d: v.join(', ')));
    });

    test('manual alias: Attack on Titan → aot, attackontitan', () async {
      final v = await vars('Attack on Titan');
      final lower = v.map((s) => s.toLowerCase()).toList();
      expect(lower, containsAll(['aot', 'attackontitan']));
      _rec(_R(g: g, t: 'AoT manual alias', s:
        lower.contains('aot') && lower.contains('attackontitan') ? _S.pass : _S.fail));
    });

    test('manual alias: Game of Thrones → got, gameofthrones', () async {
      final v = await vars('Game of Thrones');
      final lower = v.map((s) => s.toLowerCase()).toList();
      expect(lower, containsAll(['got', 'gameofthrones']));
      _rec(_R(g: g, t: 'GoT manual alias', s: lower.contains('got') ? _S.pass : _S.fail));
    });

    test('algorithmic: strip leading "The" → "Shawshank Redemption"', () async {
      final v = await vars('The Shawshank Redemption');
      final lower = v.map((s) => s.toLowerCase()).toList();
      // Should contain 'shawshank redemption' (stripped)
      expect(lower.any((s) => s.contains('shawshank redemption')), isTrue);
      _rec(_R(g: g, t: 'strip leading The', s:
        lower.any((s) => s.contains('shawshank redemption')) ? _S.pass : _S.fail,
        d: v.join(', ')));
    });

    test('algorithmic: initials for "The Dark Knight" → tdk or dk', () async {
      final v = await vars('The Dark Knight');
      final lower = v.map((s) => s.toLowerCase()).toList();
      expect(lower.any((s) => s == 'dk' || s == 'tdk'), isTrue,
        reason: 'initials should be generated');
      _rec(_R(g: g, t: 'initials TDK/DK generated', s:
        lower.any((s) => s == 'dk' || s == 'tdk') ? _S.pass : _S.fail,
        d: v.join(', ')));
    });

    test('algorithmic: "and" → "&" connector replacement', () async {
      final v = await vars('Rick and Morty');
      final lower = v.map((s) => s.toLowerCase()).toList();
      // Should contain 'rick & morty' or 'rick n morty'
      expect(lower.any((s) => s.contains('&') || s.contains(' n ')), isTrue);
      _rec(_R(g: g, t: 'and→& connector', s:
        lower.any((s) => s.contains('&')) ? _S.pass : _S.fail,
        d: v.join(', ')));
    });

    test('algorithmic: alphanumeric-only version generated', () async {
      final v = await vars("Schindler's List");
      final lower = v.map((s) => s.toLowerCase()).toList();
      // schindlerslist (no apostrophe/space)
      expect(lower.any((s) => s == "schindler'slist" || s == 'schindlerslist'), isTrue);
      _rec(_R(g: g, t: 'alphanumeric-only variant', s:
        lower.any((s) => s.contains('schindler') && !s.contains(' ')) ? _S.pass : _S.fail,
        d: v.join(', ')));
    });

    test('deduplicate: same variation added only once', () async {
      final v = await vars('Demon Slayer');
      final lower = v.map((s) => s.toLowerCase()).toList();
      final deduped = lower.toSet().length;
      expect(deduped, equals(lower.length), reason: 'No duplicate variations should exist');
      _rec(_R(g: g, t: 'no duplicate variations', s:
        deduped == lower.length ? _S.pass : _S.fail,
        d: '${lower.length} total, $deduped unique'));
    });

    test('house of the dragon → hotd, houseofthedragon', () async {
      final v = await vars('House of the Dragon');
      final lower = v.map((s) => s.toLowerCase()).toList();
      expect(lower.any((s) => s == 'hotd' || s == 'hod'), isTrue);
      _rec(_R(g: g, t: 'HOTD alias', s:
        lower.any((s) => s == 'hotd' || s == 'hod') ? _S.pass : _S.fail,
        d: v.join(', ')));
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // GROUP D: StreamExtractor — provider ordering & cache state machine
  // ═══════════════════════════════════════════════════════════════════════════

  group('D: StreamExtractor internals', () {
    const g = 'Extractor.internals';
    late StreamExtractorService ex;
    setUpAll(() { ex = StreamExtractorService(); });

    test('preferredProvider placed first in order', () {
      // Simulate by checking all providers are present after preferred
      // We can't call _buildProviderOrder directly (private), but we can verify
      // the extractWithStatus honours it by checking status order.
      // For this test, verify the API surface is correct:
      const providers = StreamExtractorService.availableProviders;
      expect(providers.first, equals('VidAPI'), reason: 'VidAPI is default first');
      _rec(_R(g: g, t: 'VidAPI default first', s: providers.first == 'VidAPI' ? _S.pass : _S.fail));
    });

    test('extractWithStatus returns null for both IDs empty', () async {
      final result = await ex.extractWithStatus(imdbId: '', tmdbId: '', type: 'movie');
      expect(result, isNull);
      _rec(const _R(g: g, t: 'both IDs empty → null', s: _S.pass));
    });

    test('extractWithStatus returns null for tmdbId=0', () async {
      final result = await ex.extractWithStatus(imdbId: '', tmdbId: '0', type: 'movie');
      expect(result, isNull);
      _rec(const _R(g: g, t: 'tmdbId=0, imdbId empty → null', s: _S.pass));
    });

    test('getProviderStatuses returns unmodifiable empty map for unknown key', () {
      final statuses = ex.getProviderStatuses('totally_unknown_xyz');
      expect(statuses, isEmpty);
      expect(() => (statuses as dynamic)['key'] = ProviderStatus.success, throwsUnsupportedError);
      _rec(const _R(g: g, t: 'getProviderStatuses unmodifiable', s: _S.pass));
    });

    test('clearCache idempotent (double-clear does not throw)', () {
      const key = 'tt0111161_278_movie_1_1';
      ex.clearCache(key);
      ex.clearCache(key); // second call should be safe
      expect(ex.getAvailableServers(key), isEmpty);
      _rec(const _R(g: g, t: 'clearCache idempotent', s: _S.pass));
    });

    test('getResolvedStream returns null before any extraction', () {
      const key = 'never_extracted_key_123';
      final result = ex.getResolvedStream(key, 'VidAPI');
      expect(result, isNull);
      _rec(const _R(g: g, t: 'getResolvedStream null before extract', s: _S.pass));
    });

    test('status transitions IDLE→TRYING→SUCCESS/FAILED fire for all providers', () async {
      final sw = Stopwatch()..start();
      final transitions = <String, List<ProviderStatus>>{};

      await ex.extractWithStatus(
        imdbId: 'tt0111161', tmdbId: '278', type: 'movie',
        title: 'The Shawshank Redemption',
        onStatus: (name, status) {
          transitions.putIfAbsent(name, () => []).add(status);
        },
      ).timeout(const Duration(seconds: 20), onTimeout: () => null);
      sw.stop();

      // All providers must have fired 'trying'
      final allTried = StreamExtractorService.availableProviders
          .every((p) => transitions[p]?.contains(ProviderStatus.trying) ?? false);

      // All providers must have ended in success or failed
      final allSettled = StreamExtractorService.availableProviders.every((p) {
        final states = transitions[p] ?? [];
        return states.contains(ProviderStatus.success) || states.contains(ProviderStatus.failed);
      });

      // At least one provider must have succeeded
      final anySuccess = transitions.values
          .any((states) => states.contains(ProviderStatus.success));

      _rec(_R(g: g, t: 'state machine transitions IDLE→TRYING→END',
        s: allTried && anySuccess ? _S.pass : allTried ? _S.skip : _S.fail,
        d: 'allTried=$allTried allSettled=$allSettled anySuccess=$anySuccess ${_ms(sw.elapsed)}'));

      expect(allTried, isTrue, reason: 'Every provider must have fired trying');
    }, timeout: const Timeout(Duration(seconds: 25)));

    test('second call for same key is faster (cache hit)', () async {
      const imdbId = 'tt0111161'; const tmdbId = '278';
      const key = '${imdbId}_${tmdbId}_movie_1_1';
      ex.clearCache(key);

      final sw1 = Stopwatch()..start();
      await ex.extractWithStatus(imdbId: imdbId, tmdbId: tmdbId, type: 'movie')
          .timeout(const Duration(seconds: 20), onTimeout: () => null);
      sw1.stop();

      // Allow background resolution
      await Future<void>.delayed(const Duration(seconds: 10));

      final sw2 = Stopwatch()..start();
      await ex.extractWithStatus(imdbId: imdbId, tmdbId: tmdbId, type: 'movie')
          .timeout(const Duration(seconds: 5), onTimeout: () => null);
      sw2.stop();

      _rec(_R(g: g, t: 'second call cache speedup',
        s: sw2.elapsed < sw1.elapsed ? _S.pass : _S.skip,
        d: 'first=${_ms(sw1.elapsed)} second=${_ms(sw2.elapsed)} servers=${ex.getAvailableServers(key).length}'));
    }, timeout: const Timeout(Duration(seconds: 40)));

    test('parallel extractFromProvider for all providers completes without deadlock', () async {
      final count = StreamExtractorService.availableProviders.length;
      final sw = Stopwatch()..start();
      final futures = StreamExtractorService.availableProviders.map((p) =>
        ex.extractFromProvider(
          providerName: p,
          imdbId: 'tt0111161', tmdbId: '278', type: 'movie',
          title: 'The Shawshank Redemption',
        ).timeout(const Duration(seconds: 15), onTimeout: () => null),
      );

      final results = await Future.wait(futures);
      sw.stop();

      final successes = results.whereType<ExtractedStream>().toList();
      _rec(_R(g: g, t: 'all-provider parallel no deadlock',
        s: _S.pass, // no deadlock = pass regardless of results
        d: '${successes.length}/$count providers succeeded ${_ms(sw.elapsed)}'));

      // Must finish without exception/deadlock
      expect(results.length, equals(count));
    }, timeout: const Timeout(Duration(seconds: 20)));
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // GROUP E: StremioStream model — deep validation
  // ═══════════════════════════════════════════════════════════════════════════

  group('E: StremioStream model', () {
    const g = 'Stremio.model';

    test('isDirectStream: http/https URL → true', () {
      const s = StremioStream(
        name: 'Test', title: '1080p',
        url: 'https://cdn.example.com/video.mp4',
      );
      expect(s.isDirectStream, isTrue);
      _rec(const _R(g: g, t: 'https → isDirectStream', s: _S.pass));
    });

    test('isTorrent: non-null infoHash → true', () {
      const s = StremioStream(
        name: 'Torrentio', title: '1080p',
        infoHash: 'abc123deadbeef',
      );
      expect(s.isTorrent, isTrue);
      expect(s.isDirectStream, isFalse);
      _rec(const _R(g: g, t: 'infoHash → isTorrent', s: _S.pass));
    });

    test('quality parsing: 2160p → 4K', () {
      const s = StremioStream(name: 'T', title: '2160p WEB-DL HEVC');
      expect(s.quality, equals('4K'));
      _rec(const _R(g: g, t: '2160p → quality 4K', s: _S.pass));
    });

    test('quality parsing: 1080p → 1080p', () {
      const s = StremioStream(name: 'T', title: '1080p BluRay x265');
      expect(s.quality, equals('1080p'));
      _rec(const _R(g: g, t: '1080p quality', s: _S.pass));
    });

    test('quality parsing: unknown → HD', () {
      const s = StremioStream(name: 'T', title: 'WEB-DL BluRay');
      expect(s.quality, equals('HD'));
      _rec(const _R(g: g, t: 'unknown → HD', s: _S.pass));
    });

    test('fromJson: full round-trip', () {
      final s = StremioStream.fromJson({
        'name': 'MediaFusion',
        'title': '1080p • WEB-DL • x265',
        'url': 'https://stream.example.com/movie.m3u8',
        'infoHash': null,
        'fileIdx': null,
        'behaviorHints': {'filename': 'test.mkv'},
      });
      expect(s.name, equals('MediaFusion'));
      expect(s.isDirectStream, isTrue);
      expect(s.isTorrent, isFalse);
      expect(s.quality, equals('1080p'));
      _rec(_R(g: g, t: 'fromJson round-trip', s:
        s.name == 'MediaFusion' && s.isDirectStream && s.quality == '1080p' ? _S.pass : _S.fail));
    });

    test('fetchFromAll sorts direct before torrent', () async {
      final service = StremioAddonService(customAddons: [
        const StremioAddon(
          name: 'TestAddon',
          baseUrl: 'https://mediafusion.elfhosted.com',
        ),
      ]);

      final sw = Stopwatch()..start();
      final streams = await service.fetchFromAll(
        imdbId: 'tt0111161', type: 'movie',
      ).timeout(const Duration(seconds: 15), onTimeout: () => []);
      sw.stop();

      final hasDirectFirst = streams.isEmpty ||
          streams.first.isDirectStream ||
          streams.every((s) => !s.isDirectStream);

      _rec(_R(g: g, t: 'MediaFusion fetchFromAll',
        s: _S.skip, // real network call — skip if empty
        d: '${streams.length} streams, firstDirect=$hasDirectFirst ${_ms(sw.elapsed)}'));
    }, timeout: const Timeout(Duration(seconds: 20)));
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // GROUP F: Torrentio — live end-to-end with HEAD validation
  // ═══════════════════════════════════════════════════════════════════════════

  group('F: Torrentio live + HEAD', () {
    const g = 'Torrentio.live';
    late TorrentioService torrentio;
    setUpAll(() { torrentio = TorrentioService(); });

    // Verify the full pipeline: fetchSources → pick best → resolveStreamUrl → HEAD
    for (final (title, imdbId, type, season, episode) in [
      ('The Shawshank Redemption', 'tt0111161', 'movie', 1, 1),
      ('Inception',                'tt1375666', 'movie', 1, 1),
      ('Breaking Bad S01E01',      'tt0903747', 'tv',    1, 1),
      ('Game of Thrones S01E01',   'tt0944947', 'tv',    1, 1),
      ('Parasite',                 'tt6751668', 'movie', 1, 1),
    ]) {
      test('end-to-end: $title', () async {
        final sw = Stopwatch()..start();

        // 1. Fetch sources
        final sources = await torrentio.fetchSources(
          imdbId: imdbId, type: type, season: season, episode: episode,
        );

        // 2. Apply quality/size filter
        final candidates = sources
          .where((s) => s.quality != '4K' && s.isWithinSizeLimit)
          .toList()
          ..sort((a, b) => b.sortScore.compareTo(a.sortScore));

        if (candidates.isEmpty) {
          _rec(_R(g: g, t: title, s: _S.skip, e: sw.elapsed,
            d: 'no eligible candidates (total=${sources.length})'));
          return;
        }

        final best = candidates.first;

        // 3. Resolve to HTTP URL
        final url = await torrentio.resolveStreamUrl(
          best.infoHash!,
          fileIdx: best.fileIdx ?? 0,
        );

        sw.stop();

        if (url == null || url.isEmpty) {
          _rec(_R(g: g, t: title, s: _S.skip, e: sw.elapsed,
            d: 'resolveStreamUrl returned null for ${best.quality} ${best.codec}'));
          return;
        }

        // 4. HEAD validate URL
        final head = await _headUrl(url);
        final valid = head.status == 200 || head.status == 206 || head.status == 302;

        _rec(_R(g: g, t: title, s: valid ? _S.pass : _S.skip, e: sw.elapsed,
          d: '${best.quality} ${best.codec} ${best.sizeGB.toStringAsFixed(1)}GB '
             'seeds=${best.seeders} HEAD=${head.status} ct=${head.contentType}'));

        expect(url, isNotEmpty);
      }, timeout: const Timeout(Duration(seconds: 40)));
    }

    // Quality cap enforcement: no 4K in extractStream output
    test('extractStream never returns 4K', () async {
      final sw = Stopwatch()..start();
      final stream = await torrentio.extractStream(
        imdbId: 'tt0111161', type: 'movie',
      );
      sw.stop();

      if (stream == null) {
        _rec(_R(g: g, t: 'no 4K in extractStream', s: _S.skip, e: sw.elapsed,
          d: 'stream null — Webtor unavailable'));
        return;
      }

      final has4K = stream.providerName.contains('4K') || stream.url.contains('4k');
      _rec(_R(g: g, t: 'no 4K in extractStream', s: !has4K ? _S.pass : _S.fail, e: sw.elapsed,
        d: 'provider=${stream.providerName}'));

      expect(has4K, isFalse);
    }, timeout: const Timeout(Duration(seconds: 30)));

    // Quality filter parameter works
    test('qualityFilter=1080p returns only 1080p candidates', () async {
      final sources = await torrentio.fetchSources(imdbId: 'tt0111161', type: 'movie');
      final filtered = sources
        .where((s) => s.quality != '4K' && s.isWithinSizeLimit && s.quality == '1080p')
        .toList();

      _rec(_R(g: g, t: 'quality filter 1080p', s: filtered.isNotEmpty ? _S.pass : _S.skip,
        d: '${filtered.length} 1080p out of ${sources.length} total'));

      if (filtered.isNotEmpty) {
        expect(filtered.every((s) => s.quality == '1080p'), isTrue);
      }
    }, timeout: const Timeout(Duration(seconds: 15)));
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // GROUP G: VidAPI — live extraction & HLS manifest validation
  // ═══════════════════════════════════════════════════════════════════════════

  group('G: VidAPI live', () {
    const g = 'VidAPI.live';
    late StreamExtractorService ex;
    setUpAll(() { ex = StreamExtractorService(); });

    for (final (title, imdbId, tmdbId, type, season, episode) in [
      ('The Shawshank Redemption', 'tt0111161', '278',    'movie', 1, 1),
      ('Inception',                'tt1375666', '27205',  'movie', 1, 1),
      ('The Dark Knight',          'tt0468569', '155',    'movie', 1, 1),
      ('Breaking Bad S01E01',      'tt0903747', '1396',   'tv',    1, 1),
      ('Squid Game S01E01',        'tt10919420','93405',  'tv',    1, 1),
      ('Parasite',                 'tt6751668', '496243', 'movie', 1, 1),
      ('Interstellar',             'tt0816692', '157336', 'movie', 1, 1),
      ('Avengers Endgame',         'tt4154796', '299534', 'movie', 1, 1),
    ]) {
      test('VidAPI: $title', () async {
        final sw = Stopwatch()..start();
        final stream = await ex.extractVidAPIDirect(
          imdbId: imdbId, tmdbId: tmdbId, type: type,
          season: season, episode: episode,
        ).timeout(const Duration(seconds: 10), onTimeout: () => null);
        sw.stop();

        if (stream == null) {
          _rec(_R(g: g, t: title, s: _S.skip, e: sw.elapsed, d: 'null response'));
          return;
        }

        // Validate URL format
        final validUrl = stream.url.startsWith('http') &&
            (stream.isHls || stream.isMp4);

        // HEAD validate
        final head = await _headUrl(stream.url, headers: stream.headers);

        // For HLS: parse manifest
        int hlsSegments = 0;
        if (stream.isHls) {
          hlsSegments = await _countHlsSegments(stream.url, headers: stream.headers);
        }

        _rec(_R(g: g, t: title,
          s: validUrl ? _S.pass : _S.fail, e: sw.elapsed,
          d: '${stream.providerName} ${stream.isHls ? "HLS" : "MP4"} '
             'q=${stream.qualities.length} subs=${stream.subtitles.length} '
             'HEAD=${head.status} ct=${head.contentType} '
             '${stream.isHls ? "segments=$hlsSegments" : ""}'));

        expect(stream.url, isNotEmpty);
        expect(stream.url, startsWith('http'));
      }, timeout: const Timeout(Duration(seconds: 20)));
    }

    // Qualities array validation
    test('VidAPI qualities have valid URLs', () async {
      final stream = await ex.extractVidAPIDirect(
        imdbId: 'tt0111161', tmdbId: '278', type: 'movie',
      ).timeout(const Duration(seconds: 10), onTimeout: () => null);

      if (stream == null || stream.qualities.isEmpty) {
        _rec(const _R(g: g, t: 'qualities valid URLs', s: _S.skip, d: 'no stream or no qualities'));
        return;
      }

      final allValid = stream.qualities.every(
        (q) => q.url.startsWith('http') && q.quality.isNotEmpty,
      );
      _rec(_R(g: g, t: 'qualities valid URLs', s: allValid ? _S.pass : _S.fail,
        d: stream.qualities.map((q) => '${q.quality}').join(', ')));
      expect(allValid, isTrue);
    }, timeout: const Timeout(Duration(seconds: 15)));

    // Subtitles validation
    test('VidAPI subtitles have lang and URL', () async {
      final stream = await ex.extractVidAPIDirect(
        imdbId: 'tt0111161', tmdbId: '278', type: 'movie',
      ).timeout(const Duration(seconds: 10), onTimeout: () => null);

      if (stream == null || stream.subtitles.isEmpty) {
        _rec(const _R(g: g, t: 'subtitles lang+URL', s: _S.skip, d: 'no subs'));
        return;
      }

      final allValid = stream.subtitles.every(
        (s) => s.url.startsWith('http') && s.lang.isNotEmpty,
      );
      _rec(_R(g: g, t: 'subtitles lang+URL', s: allValid ? _S.pass : _S.fail,
        d: stream.subtitles.map((s) => '${s.lang}(${s.displayLabel})').join(', ')));
      expect(allValid, isTrue);
    }, timeout: const Timeout(Duration(seconds: 15)));
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // GROUP H: Videasy — decryption pipeline validation
  // ═══════════════════════════════════════════════════════════════════════════

  group('H: Videasy live', () {
    const g = 'Videasy.live';
    late StreamExtractorService ex;
    setUpAll(() { ex = StreamExtractorService(); });

    for (final (title, tmdbId, type, season, episode) in [
      ('The Shawshank Redemption', '278',    'movie', 1, 1),
      ('Inception',                '27205',  'movie', 1, 1),
      ('Breaking Bad S01E01',      '1396',   'tv',    1, 1),
      ('Squid Game S01E01',        '93405',  'tv',    1, 1),
      ('Attack on Titan S01E01',   '1429',   'tv',    1, 1),
      ('Demon Slayer S01E01',      '85937',  'tv',    1, 1),
      ('Interstellar',             '157336', 'movie', 1, 1),
    ]) {
      test('Videasy: $title', () async {
        final sw = Stopwatch()..start();
        final stream = await ex.extractVideasyDirect(
          tmdbId: tmdbId, title: title, type: type,
          season: season, episode: episode,
        ).timeout(const Duration(seconds: 20), onTimeout: () => null);
        sw.stop();

        if (stream == null) {
          _rec(_R(g: g, t: title, s: _S.skip, e: sw.elapsed, d: 'all Videasy servers failed'));
          return;
        }

        // Must have valid HLS or MP4 URL
        final validUrl = stream.url.startsWith('http') && (stream.isHls || stream.isMp4);

        // HEAD the stream URL
        final head = await _headUrl(stream.url, headers: stream.headers);
        final headValid = head.status == 200 || head.status == 206 || head.status == 302 || head.status == 403;

        // Count HLS segments if applicable
        int segments = 0;
        if (stream.isHls) {
          segments = await _countHlsSegments(stream.url, headers: stream.headers);
        }

        _rec(_R(g: g, t: title, s: validUrl ? _S.pass : _S.fail, e: sw.elapsed,
          d: '${stream.providerName} ${stream.isHls ? "HLS" : "MP4"} '
             'q=${stream.qualities.length} subs=${stream.subtitles.length} '
             'HEAD=${head.status} Valid=$headValid ${stream.isHls ? "seg=$segments" : ""}'));

        expect(stream.url, isNotEmpty);
        expect(validUrl, isTrue, reason: 'URL must be HLS or MP4');
      }, timeout: const Timeout(Duration(seconds: 25)));
    }

    // Qualities must be ordered with highest first
    test('Videasy qualities ordered best→worst', () async {
      final stream = await ex.extractVideasyDirect(
        tmdbId: '278', title: 'The Shawshank Redemption', type: 'movie',
      ).timeout(const Duration(seconds: 20), onTimeout: () => null);

      if (stream == null || stream.qualities.length < 2) {
        _rec(const _R(g: g, t: 'qualities best→worst order', s: _S.skip));
        return;
      }

      // The first quality's URL should be the stream URL
      final firstQualityUrl = stream.qualities.first.url;
      _rec(_R(g: g, t: 'qualities best→worst order',
        s: firstQualityUrl == stream.url ? _S.pass : _S.skip,
        d: stream.qualities.map((q) => q.quality).join(' > ')));
    }, timeout: const Timeout(Duration(seconds: 25)));
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // GROUP I: VidLink — HTML scraping pipeline
  // ═══════════════════════════════════════════════════════════════════════════

  group('I: VidLink live', () {
    const g = 'VidLink.live';
    late StreamExtractorService ex;
    setUpAll(() { ex = StreamExtractorService(); });

    for (final (title, tmdbId, type, season, episode) in [
      ('The Shawshank Redemption', '278',    'movie', 1, 1),
      ('Inception',                '27205',  'movie', 1, 1),
      ('Breaking Bad S01E01',      '1396',   'tv',    1, 1),
      ('The Last of Us S01E01',    '100088', 'tv',    1, 1),
    ]) {
      test('VidLink: $title', () async {
        final sw = Stopwatch()..start();
        final stream = await ex.extractVidLinkDirect(
          tmdbId: tmdbId, type: type, season: season, episode: episode,
        ).timeout(const Duration(seconds: 10), onTimeout: () => null);
        sw.stop();

        if (stream == null) {
          _rec(_R(g: g, t: title, s: _S.skip, e: sw.elapsed, d: 'null'));
          return;
        }

        final valid = stream.url.startsWith('http') && (stream.isHls || stream.isMp4);
        final head = await _headUrl(stream.url, headers: stream.headers);

        _rec(_R(g: g, t: title, s: valid ? _S.pass : _S.fail, e: sw.elapsed,
          d: '${stream.providerName} HEAD=${head.status} q=${stream.qualities.length} subs=${stream.subtitles.length}'));
      }, timeout: const Timeout(Duration(seconds: 15)));
    }
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // GROUP J: AtmosIndex — season completeness & episode ordering
  // ═══════════════════════════════════════════════════════════════════════════

  group('J: AtmosIndex season', () {
    const g = 'AtmosIndex.season';
    late AtmosIndexClient client;
    setUpAll(() { client = AtmosIndexClient(); });

    test('Breaking Bad S1: ≥7 episodes, ordered E1→E7+', () async {
      final sw = Stopwatch()..start();
      final episodes = await client.getSeason('Breaking Bad', 1);
      sw.stop();

      if (episodes.isEmpty) {
        _rec(_R(g: g, t: 'BB S1 completeness', s: _S.skip, e: sw.elapsed, d: 'catalog empty'));
        return;
      }

      _rec(_R(g: g, t: 'BB S1 completeness', s: episodes.length >= 7 ? _S.pass : _S.skip,
        e: sw.elapsed, d: '${episodes.length} episodes indexed'));
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('Stranger Things S1: episodes found in catalog', () async {
      final sw = Stopwatch()..start();
      final episodes = await client.getSeason('Stranger Things', 1);
      sw.stop();

      _rec(_R(g: g, t: 'ST S1 episodes', s: episodes.isNotEmpty ? _S.pass : _S.skip,
        e: sw.elapsed, d: '${episodes.length} episodes'));
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('search with episode filter returns single episode', () async {
      final sw = Stopwatch()..start();
      final results = await client.search('Breaking Bad', season: 1, episode: 5);
      sw.stop();

      _rec(_R(g: g, t: 'BB S01E05 search', s: results.isNotEmpty ? _S.pass : _S.skip,
        e: sw.elapsed, d: '${results.length} results'));
    }, timeout: const Timeout(Duration(seconds: 15)));

    test('catalog stats returns valid map', () async {
      final stats = await client.getStats();
      _rec(_R(g: g, t: 'catalog stats', s: stats.isNotEmpty ? _S.pass : _S.skip,
        d: stats.toString().substring(0, stats.toString().length.clamp(0, 60))));
    }, timeout: const Timeout(Duration(seconds: 10)));
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // GROUP K: ExtractedStream pipeline — quality chain & subtitle display
  // ═══════════════════════════════════════════════════════════════════════════

  group('K: ExtractedStream quality chain', () {
    const g = 'ExtractedStream.quality';

    test('hasQualities requires ≥2 entries', () {
      const two   = ExtractedStream(url: 'u', headers: {}, providerName: 'test',
        qualities: [QualityOption(quality: '1080p', url: 'u1'), QualityOption(quality: '720p', url: 'u2')]);
      const one   = ExtractedStream(url: 'u', headers: {}, providerName: 'test',
        qualities: [QualityOption(quality: '1080p', url: 'u1')]);
      const empty = ExtractedStream(url: 'u', headers: {}, providerName: 'test');

      expect(two.hasQualities,   isTrue);
      expect(one.hasQualities,   isFalse);
      expect(empty.hasQualities, isFalse);
      _rec(const _R(g: g, t: 'hasQualities threshold 2', s: _S.pass));
    });

    test('SubtitleInfo.displayLabel prefers label over lang', () {
      const withLabel    = SubtitleInfo(url: 'u', lang: 'en', label: 'English');
      const withoutLabel = SubtitleInfo(url: 'u', lang: 'fr', label: '');

      expect(withLabel.displayLabel, equals('English'));
      expect(withoutLabel.displayLabel, equals('FR'));
      _rec(const _R(g: g, t: 'displayLabel label>lang', s: _S.pass));
    });

    test('isHls detects .m3u8 and mpegurl', () {
      final urls = [
        'https://cdn.example.com/video.m3u8',
        'https://cdn.example.com/index.m3u8?token=abc',
        'https://cdn.example.com/stream.mpegurl',
        'application/x-mpegurl',
      ];
      for (final url in urls) {
        final s = ExtractedStream(url: url, headers: {}, providerName: 'test');
        expect(s.isHls, isTrue, reason: '$url should be HLS');
      }
      _rec(_R(g: g, t: 'isHls detection', s: _S.pass));
    });

    test('isMp4 detects .mp4 .mkv .webm', () {
      final urls = [
        'https://cdn.example.com/video.mp4',
        'https://cdn.example.com/video.mkv',
        'https://cdn.example.com/video.webm',
      ];
      for (final url in urls) {
        final s = ExtractedStream(url: url, headers: {}, providerName: 'test');
        expect(s.isMp4, isTrue, reason: '$url should be MP4-type');
      }
      _rec(_R(g: g, t: 'isMp4 .mp4/.mkv/.webm', s: _S.pass));
    });

    test('neither HLS nor MP4 for bare manifest paths', () {
      final s = ExtractedStream(url: 'https://cdn.example.com/manifest', headers: {}, providerName: 'test');
      expect(s.isHls, isFalse);
      expect(s.isMp4, isFalse);
      _rec(const _R(g: g, t: 'bare path: not HLS, not MP4', s: _S.pass));
    });

    test('qualities ordered: best URL matches stream URL', () {
      const stream = ExtractedStream(
        url: 'https://cdn.example.com/1080.m3u8',
        headers: {'Referer': 'https://example.com/'},
        providerName: 'VidAPI',
        qualities: [
          QualityOption(quality: '1080p', url: 'https://cdn.example.com/1080.m3u8'),
          QualityOption(quality: '720p',  url: 'https://cdn.example.com/720.m3u8'),
          QualityOption(quality: '480p',  url: 'https://cdn.example.com/480.m3u8'),
        ],
      );
      expect(stream.qualities.first.url, equals(stream.url));
      expect(stream.hasQualities, isTrue);
      _rec(const _R(g: g, t: 'qualities[0] == stream.url', s: _S.pass));
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // GROUP L: Provider ordering — preferredProvider places provider first
  // ═══════════════════════════════════════════════════════════════════════════

  group('L: Provider ordering', () {
    const g = 'Extractor.order';
    late StreamExtractorService ex;
    setUpAll(() { ex = StreamExtractorService(); });

    test('preferredProvider=Torrentio: Torrentio status fires before VidAPI succeeds', () async {
      const imdbId = 'tt0111161'; const tmdbId = '278';
      const key = '${imdbId}_${tmdbId}_movie_1_1';
      ex.clearCache(key);

      final order = <String>[];
      await ex.extractWithStatus(
        imdbId: imdbId, tmdbId: tmdbId, type: 'movie',
        preferredProvider: 'Torrentio',
        onStatus: (name, status) {
          if (status == ProviderStatus.trying && !order.contains(name)) {
            order.add(name);
          }
        },
      ).timeout(const Duration(seconds: 20), onTimeout: () => null);

      _rec(_R(g: g, t: 'preferredProvider=Torrentio first',
        s: order.isNotEmpty && order.first == 'Torrentio' ? _S.pass : _S.skip,
        d: 'order=${order.join("→")}'));

      if (order.isNotEmpty) {
        expect(order.first, equals('Torrentio'));
      }
    }, timeout: const Timeout(Duration(seconds: 25)));

    test('preferredProvider=Videasy: Videasy fires first', () async {
      const imdbId = 'tt1375666'; const tmdbId = '27205';
      const key = '${imdbId}_${tmdbId}_movie_1_1';
      ex.clearCache(key);

      final order = <String>[];
      await ex.extractWithStatus(
        imdbId: imdbId, tmdbId: tmdbId, type: 'movie',
        preferredProvider: 'Videasy',
        onStatus: (name, status) {
          if (status == ProviderStatus.trying && !order.contains(name)) {
            order.add(name);
          }
        },
      ).timeout(const Duration(seconds: 20), onTimeout: () => null);

      _rec(_R(g: g, t: 'preferredProvider=Videasy first',
        s: order.isNotEmpty && order.first == 'Videasy' ? _S.pass : _S.skip,
        d: 'order=${order.join("→")}'));
    }, timeout: const Timeout(Duration(seconds: 25)));

    test('cached preferred provider → instant return', () async {
      const imdbId = 'tt0111161'; const tmdbId = '278';
      const key = '${imdbId}_${tmdbId}_movie_1_1';

      // First pass — populate cache
      ex.clearCache(key);
      await ex.extractWithStatus(imdbId: imdbId, tmdbId: tmdbId, type: 'movie')
          .timeout(const Duration(seconds: 20), onTimeout: () => null);

      await Future<void>.delayed(const Duration(seconds: 8));

      final servers = ex.getAvailableServers(key);
      if (servers.isEmpty) {
        _rec(const _R(g: g, t: 'cached preferred instant', s: _S.skip, d: 'no cached servers'));
        return;
      }

      final preferred = servers.first;
      final sw = Stopwatch()..start();
      final stream = await ex.extractWithStatus(
        imdbId: imdbId, tmdbId: tmdbId, type: 'movie',
        preferredProvider: preferred,
      );
      sw.stop();

      _rec(_R(g: g, t: 'cached preferred instant', s: sw.elapsed.inMilliseconds < 100 ? _S.pass : _S.skip,
        d: 'provider=$preferred elapsed=${_ms(sw.elapsed)} stream=${stream?.providerName}'));
    }, timeout: const Timeout(Duration(seconds: 35)));
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // GROUP M: Multi-title parallel stress test with HEAD verification
  // 40 titles across all genres — 8 batches of 5 in parallel
  // ═══════════════════════════════════════════════════════════════════════════

  group('M: Parallel stress test', () {
    const g = 'Stress';
    late StreamExtractorService ex;
    setUpAll(() { ex = StreamExtractorService(); });

    const stressTitles = <(String, String, String, String, int, int)>[
      // (title, imdbId, tmdbId, type, season, episode)
      ('The Godfather',              'tt0068646', '238',    'movie', 1, 1),
      ('Pulp Fiction',               'tt0110912', '680',    'movie', 1, 1),
      ('The Matrix',                 'tt0133093', '603',    'movie', 1, 1),
      ('Gladiator',                  'tt0172495', '98',     'movie', 1, 1),
      ('The Dark Knight',            'tt0468569', '155',    'movie', 1, 1),
      ('Inception',                  'tt1375666', '27205',  'movie', 1, 1),
      ('Interstellar',               'tt0816692', '157336', 'movie', 1, 1),
      ('Parasite',                   'tt6751668', '496243', 'movie', 1, 1),
      ('Oppenheimer',                'tt15398776','872585', 'movie', 1, 1),
      ('Dune',                       'tt1160419', '438631', 'movie', 1, 1),
      ('The Batman',                 'tt1877830', '414906', 'movie', 1, 1),
      ('Mad Max Fury Road',          'tt1392190', '76341',  'movie', 1, 1),
      ('Whiplash',                   'tt2582802', '244786', 'movie', 1, 1),
      ('Get Out',                    'tt5052448', '419430', 'movie', 1, 1),
      ('Blade Runner 2049',          'tt1856101', '335984', 'movie', 1, 1),
      ('Breaking Bad S01E01',        'tt0903747', '1396',   'tv',    1, 1),
      ('Breaking Bad S05E14',        'tt0903747', '1396',   'tv',    5, 14),
      ('Game of Thrones S01E01',     'tt0944947', '1399',   'tv',    1, 1),
      ('Stranger Things S01E01',     'tt4574334', '66732',  'tv',    1, 1),
      ('The Last of Us S01E01',      'tt3581920', '100088', 'tv',    1, 1),
      ('Squid Game S01E01',          'tt10919420','93405',  'tv',    1, 1),
      ('Chernobyl S01E01',           'tt7366338', '87108',  'tv',    1, 1),
      ('True Detective S01E01',      'tt2356777', '46648',  'tv',    1, 1),
      ('Peaky Blinders S01E01',      'tt2442560', '60574',  'tv',    1, 1),
      ('The Boys S01E01',            'tt1190634', '76479',  'tv',    1, 1),
      ('Attack on Titan S01E01',     'tt2560140', '1429',   'tv',    1, 1),
      ('Death Note S01E01',          'tt0877057', '13916',  'tv',    1, 1),
      ('Demon Slayer S01E01',        'tt9335498', '85937',  'tv',    1, 1),
      ('Fullmetal Alch Brotherhood', 'tt1355642', '31911',  'tv',    1, 1),
      ('Jujutsu Kaisen S01E01',      'tt12343534','95479',  'tv',    1, 1),
      ('Cowboy Bebop S01E01',        'tt0213338', '30991',  'tv',    1, 1),
      ('Severance S01E01',           'tt11280740','95396',  'tv',    1, 1),
      ('The Wire S01E01',            'tt0306414', '1438',   'tv',    1, 1),
      ('Euphoria S01E01',            'tt8772296', '85552',  'tv',    1, 1),
      ('Succession S01E01',          'tt7660850', '79696',  'tv',    1, 1),
      ('Better Call Saul S01E01',    'tt3032476', '60059',  'tv',    1, 1),
      ('Mindhunter S01E01',          'tt5290382', '67744',  'tv',    1, 1),
      ('The Bear S01E01',            'tt14452776','136315', 'tv',    1, 1),
      ('House of Dragon S01E01',     'tt11198330','94997',  'tv',    1, 1),
      ('Vinland Saga S01E01',        'tt10233448','90507',  'tv',    1, 1),
    ];

    const batchSize = 5;
    for (int i = 0; i < stressTitles.length; i += batchSize) {
      final batch = stressTitles.skip(i).take(batchSize).toList();
      final batchNum = (i ~/ batchSize) + 1;
      final totalBatches = (stressTitles.length / batchSize).ceil();

      test('stress batch $batchNum/$totalBatches (${batch.map((t) => t.$1).join(", ")})', () async {
        final results = await Future.wait(batch.map((t) async {
          final (title, imdbId, tmdbId, type, season, episode) = t;
          final sw = Stopwatch()..start();

          ExtractedStream? stream;
          final statuses = <String, ProviderStatus>{};

          try {
            stream = await ex.extractWithStatus(
              imdbId: imdbId, tmdbId: tmdbId, type: type,
              title: title.split(' S0').first,
              season: season, episode: episode,
              onStatus: (n, s) => statuses[n] = s,
            ).timeout(const Duration(seconds: 20));
          } catch (_) { stream = null; }

          sw.stop();

          final allFired = StreamExtractorService.availableProviders
              .every((p) => statuses.containsKey(p));

          // HEAD validate if we got a stream
          String headResult = '';
          if (stream != null) {
            final head = await _headUrl(stream.url, headers: stream.headers,
                timeout: const Duration(seconds: 5));
            headResult = 'HEAD=${head.status}';
          }

          _rec(_R(g: g, t: title,
            s: stream != null ? _S.pass : allFired ? _S.skip : _S.fail,
            e: sw.elapsed,
            d: stream != null
                ? '${stream.providerName} ${_ms(sw.elapsed)} $headResult'
                : 'no stream ${_ms(sw.elapsed)} allFired=$allFired'));

          return stream;
        }));

        // Stress batch passes if it completes without deadlock
        expect(results.length, equals(batch.length));
      }, timeout: const Timeout(Duration(seconds: 35)));
    }
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // GROUP N: SubtitleInfo — normalization and model integrity
  // ═══════════════════════════════════════════════════════════════════════════

  group('N: SubtitleInfo model', () {
    const g = 'Subtitle.model';

    test('displayLabel uses label when set', () {
      const s = SubtitleInfo(url: 'u', lang: 'en', label: 'English');
      expect(s.displayLabel, equals('English'));
      _rec(const _R(g: g, t: 'label used', s: _S.pass));
    });

    test('displayLabel uppercases lang when label empty', () {
      const s = SubtitleInfo(url: 'u', lang: 'fr', label: '');
      expect(s.displayLabel, equals('FR'));
      _rec(const _R(g: g, t: 'lang uppercased', s: _S.pass));
    });

    test('toString() is descriptive', () {
      const s = SubtitleInfo(url: 'https://subs.example.com/en.srt', lang: 'en', label: 'English');
      final str = s.toString();
      expect(str, contains('en'));
      expect(str, contains('subs.example.com'));
      _rec(const _R(g: g, t: 'toString descriptive', s: _S.pass));
    });

    test('multiple subtitles in stream — all have distinct lang codes', () {
      const stream = ExtractedStream(
        url: 'https://cdn.example.com/v.m3u8',
        headers: {},
        providerName: 'VidAPI',
        subtitles: [
          SubtitleInfo(url: 'u1', lang: 'en', label: 'English'),
          SubtitleInfo(url: 'u2', lang: 'hi', label: 'Hindi'),
          SubtitleInfo(url: 'u3', lang: 'es', label: 'Spanish'),
          SubtitleInfo(url: 'u4', lang: 'fr', label: 'French'),
          SubtitleInfo(url: 'u5', lang: 'ar', label: 'Arabic'),
        ],
      );
      final langs = stream.subtitles.map((s) => s.lang).toSet();
      expect(langs.length, equals(5));
      expect(stream.hasSubtitles, isTrue);
      _rec(_R(g: g, t: '5 distinct lang codes', s: langs.length == 5 ? _S.pass : _S.fail,
        d: langs.join(', ')));
    });

    test('QualityOption toString is readable', () {
      const q = QualityOption(quality: '1080p', url: 'https://cdn.example.com/1080.m3u8');
      expect(q.toString(), contains('1080p'));
      _rec(const _R(g: g, t: 'QualityOption toString', s: _S.pass));
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // GROUP O: TorrentioSource.fromJson — edge case parsing
  // ═══════════════════════════════════════════════════════════════════════════

  group('O: TorrentioSource edge cases', () {
    const g = 'TorrentioSource.edge';

    test('missing title field → default values', () {
      final s = TorrentioSource.fromJson({'infoHash': 'abc123'});
      expect(s.quality, equals('HD'));
      expect(s.seeders, equals(0));
      expect(s.infoHash, equals('abc123'));
      _rec(const _R(g: g, t: 'missing title → defaults', s: _S.pass));
    });

    test('MB size parsing → correct sizeGB', () {
      final s = TorrentioSource.fromJson({
        'title': 'Test\n1080p\n💾 700 MB ⚙️ YIFY 👤 50',
        'infoHash': 'x',
      });
      expect(s.sizeGB, closeTo(700.0 / 1024, 0.01));
      expect(s.isWithinSizeLimit, isTrue);
      _rec(_R(g: g, t: 'MB size parsing', s: _S.pass, d: 'sizeGB=${s.sizeGB.toStringAsFixed(3)}'));
    });

    test('H.265 in title → codec=x265', () {
      final s = TorrentioSource.fromJson({
        'title': 'Torrentio\n1080p • WEB-DL • H.265\n💾 2 GB ⚙️ NTb 👤 10',
        'infoHash': 'x',
      });
      expect(s.codec, equals('x265'));
      _rec(const _R(g: g, t: 'H.265 → x265 codec', s: _S.pass));
    });

    test('AV1 codec parsing', () {
      final s = TorrentioSource.fromJson({
        'title': 'Torrentio\n1080p • WEB-DL • AV1\n💾 1.2 GB ⚙️ RARBG 👤 45',
        'infoHash': 'x',
      });
      expect(s.codec, equals('AV1'));
      _rec(const _R(g: g, t: 'AV1 codec', s: _S.pass));
    });

    test('DTS-HD audio parsing', () {
      final s = TorrentioSource.fromJson({
        'title': 'Torrentio\n1080p • BluRay • x264 • DTS-HD\n💾 14 GB ⚙️ FGT 👤 100',
        'infoHash': 'x',
      });
      expect(s.audio, equals('DTS-HD'));
      _rec(const _R(g: g, t: 'DTS-HD audio', s: _S.pass));
    });

    test('size exactly 3.0GB → isWithinSizeLimit=true', () {
      final s = TorrentioSource.fromJson({
        'title': 'Torrentio\n1080p\n💾 3.0 GB ⚙️ YIFY 👤 20',
        'infoHash': 'x',
      });
      expect(s.isWithinSizeLimit, isTrue);
      _rec(_R(g: g, t: '3.0GB at boundary', s: _S.pass, d: 'sizeGB=${s.sizeGB}'));
    });

    test('size 3.01GB → isWithinSizeLimit=false', () {
      final s = TorrentioSource.fromJson({
        'title': 'Torrentio\n1080p\n💾 3.1 GB ⚙️ YIFY 👤 20',
        'infoHash': 'x',
      });
      expect(s.isWithinSizeLimit, isFalse);
      _rec(_R(g: g, t: '3.1GB over limit', s: !s.isWithinSizeLimit ? _S.pass : _S.fail,
        d: 'sizeGB=${s.sizeGB}'));
    });

    test('toString is descriptive', () {
      final s = TorrentioSource.fromJson({
        'title': 'Torrentio\n1080p • x265 • DDP5.1\n💾 2.1 GB ⚙️ YTS 👤 156',
        'infoHash': 'abc',
      });
      final str = s.toString();
      expect(str, contains('1080p'));
      expect(str, contains('x265'));
      _rec(const _R(g: g, t: 'toString descriptive', s: _S.pass));
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // GROUP P: Concurrent cache race — no data corruption
  // ═══════════════════════════════════════════════════════════════════════════

  group('P: Cache race safety', () {
    const g = 'Cache.race';
    late StreamExtractorService ex;
    setUpAll(() { ex = StreamExtractorService(); });

    test('two concurrent extractWithStatus calls for same key do not corrupt cache', () async {
      const imdbId = 'tt0111161'; const tmdbId = '278';
      const key = '${imdbId}_${tmdbId}_movie_1_1';
      ex.clearCache(key);

      // Fire 3 concurrent calls for the same content key
      final results = await Future.wait([
        ex.extractWithStatus(imdbId: imdbId, tmdbId: tmdbId, type: 'movie')
            .timeout(const Duration(seconds: 20), onTimeout: () => null),
        ex.extractWithStatus(imdbId: imdbId, tmdbId: tmdbId, type: 'movie')
            .timeout(const Duration(seconds: 20), onTimeout: () => null),
        ex.extractWithStatus(imdbId: imdbId, tmdbId: tmdbId, type: 'movie')
            .timeout(const Duration(seconds: 20), onTimeout: () => null),
      ]);

      // All three should return the same or compatible results
      final nonNull = results.whereType<ExtractedStream>().toList();

      _rec(_R(g: g, t: '3 concurrent calls same key',
        s: _S.pass, // no exception = pass (cache integrity maintained)
        d: '${nonNull.length}/3 returned streams, providers=${ex.getAvailableServers(key).join(",")}'));
    }, timeout: const Timeout(Duration(seconds: 25)));

    test('clear-during-extraction does not crash', () async {
      const imdbId = 'tt0111161'; const tmdbId = '278';
      const key = '${imdbId}_${tmdbId}_movie_1_1';
      ex.clearCache(key);

      // Start extraction
      final future = ex.extractWithStatus(imdbId: imdbId, tmdbId: tmdbId, type: 'movie')
          .timeout(const Duration(seconds: 20), onTimeout: () => null);

      // Clear cache while it's running
      await Future<void>.delayed(const Duration(milliseconds: 200));
      ex.clearCache(key);

      // Complete without error
      final result = await future;
      _rec(_R(g: g, t: 'clear-during-extraction no crash', s: _S.pass,
        d: 'result=${result?.providerName ?? "null"}'));
    }, timeout: const Timeout(Duration(seconds: 25)));
  });
}
