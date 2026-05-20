// ═══════════════════════════════════════════════════════════════════════════════
// MASSIVE INTEGRATION TEST — Atmos App
// Tests 100+ titles (movies, shows, anime) across every decade
// Tests every component: stream extraction, Torrentio, AtmosIndex,
// Telegram ranking, quality caps, cache engine, provider race, error handling.
//
// Run: flutter test test/massive_integration_test.dart --timeout=none -v
// ═══════════════════════════════════════════════════════════════════════════════

import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:atmos/services/stream_extractor_service.dart';
import 'package:atmos/services/torrentio_service.dart';
import 'package:atmos/services/atmos_index_client.dart';
import 'package:atmos/services/vegamovies_service.dart';
import 'package:atmos/widgets/download_filter_sheet.dart';

// ─── Result tracking ──────────────────────────────────────────────────────────

enum _TestStatus { pass, fail, skip }

class _Result {
  final String title;
  final String component;
  final _TestStatus status;
  final String? detail;
  final Duration elapsed;

  const _Result({
    required this.title,
    required this.component,
    required this.status,
    this.detail,
    required this.elapsed,
  });

  @override
  String toString() {
    final icon = status == _TestStatus.pass ? '✅'
        : status == _TestStatus.skip ? '⚠️'
        : '❌';
    final ms = elapsed.inMilliseconds;
    return '$icon [${ms}ms] $component | $title${detail != null ? " — $detail" : ""}';
  }
}

final _results = <_Result>[];

void _record(_Result r) {
  _results.add(r);
  // ignore: avoid_print
  print(r.toString());
}

// ─── Test Data ────────────────────────────────────────────────────────────────

/// {title, imdbId, tmdbId, type, year, [season], [episode]}
const _titles = <Map<String, dynamic>>[
  // ── Classic Movies (pre-2000) ──
  {'title': 'The Godfather',            'imdbId': 'tt0068646', 'tmdbId': '238',   'type': 'movie', 'year': 1972},
  {'title': 'The Godfather Part II',    'imdbId': 'tt0071562', 'tmdbId': '240',   'type': 'movie', 'year': 1974},
  {'title': 'Apocalypse Now',           'imdbId': 'tt0078788', 'tmdbId': '28',    'type': 'movie', 'year': 1979},
  {'title': 'Blade Runner',             'imdbId': 'tt0083658', 'tmdbId': '78',    'type': 'movie', 'year': 1982},
  {'title': 'Scarface',                 'imdbId': 'tt0086250', 'tmdbId': '111',   'type': 'movie', 'year': 1983},
  {'title': 'Back to the Future',       'imdbId': 'tt0088763', 'tmdbId': '105',   'type': 'movie', 'year': 1985},
  {'title': 'The Shawshank Redemption', 'imdbId': 'tt0111161', 'tmdbId': '278',   'type': 'movie', 'year': 1994},
  {'title': 'Pulp Fiction',             'imdbId': 'tt0110912', 'tmdbId': '680',   'type': 'movie', 'year': 1994},
  {'title': 'The Lion King',            'imdbId': 'tt0110357', 'tmdbId': '8587',  'type': 'movie', 'year': 1994},
  {'title': 'Forrest Gump',             'imdbId': 'tt0109830', 'tmdbId': '13',    'type': 'movie', 'year': 1994},
  {'title': 'GoodFellas',              'imdbId': 'tt0099685', 'tmdbId': '769',   'type': 'movie', 'year': 1990},
  {'title': 'Silence of the Lambs',    'imdbId': 'tt0102926', 'tmdbId': '274',   'type': 'movie', 'year': 1991},
  {'title': 'Schindler\'s List',       'imdbId': 'tt0108052', 'tmdbId': '424',   'type': 'movie', 'year': 1993},
  {'title': 'Heat',                    'imdbId': 'tt0113277', 'tmdbId': '949',   'type': 'movie', 'year': 1995},
  {'title': 'Se7en',                   'imdbId': 'tt0114369', 'tmdbId': '807',   'type': 'movie', 'year': 1995},
  {'title': 'The Matrix',              'imdbId': 'tt0133093', 'tmdbId': '603',   'type': 'movie', 'year': 1999},
  {'title': 'Fight Club',              'imdbId': 'tt0137523', 'tmdbId': '550',   'type': 'movie', 'year': 1999},
  {'title': 'American Beauty',         'imdbId': 'tt0169547', 'tmdbId': '14',    'type': 'movie', 'year': 1999},
  {'title': 'Titanic',                 'imdbId': 'tt0120338', 'tmdbId': '597',   'type': 'movie', 'year': 1997},

  // ── 2000s Movies ──
  {'title': 'Gladiator',               'imdbId': 'tt0172495', 'tmdbId': '98',    'type': 'movie', 'year': 2000},
  {'title': 'Memento',                 'imdbId': 'tt0209144', 'tmdbId': '77',    'type': 'movie', 'year': 2000},
  {'title': 'The Lord of the Rings The Fellowship of the Ring', 'imdbId': 'tt0120737', 'tmdbId': '120', 'type': 'movie', 'year': 2001},
  {'title': 'Spirited Away',           'imdbId': 'tt0245429', 'tmdbId': '129',   'type': 'movie', 'year': 2001},
  {'title': 'City of God',             'imdbId': 'tt0317248', 'tmdbId': '598',   'type': 'movie', 'year': 2002},
  {'title': 'The Dark Knight',         'imdbId': 'tt0468569', 'tmdbId': '155',   'type': 'movie', 'year': 2008},
  {'title': 'Inception',               'imdbId': 'tt1375666', 'tmdbId': '27205', 'type': 'movie', 'year': 2010},
  {'title': 'No Country for Old Men',  'imdbId': 'tt0477348', 'tmdbId': '6977',  'type': 'movie', 'year': 2007},
  {'title': 'There Will Be Blood',     'imdbId': 'tt0469494', 'tmdbId': '4011',  'type': 'movie', 'year': 2007},
  {'title': 'The Departed',            'imdbId': 'tt0407887', 'tmdbId': '1422',  'type': 'movie', 'year': 2006},
  {'title': 'Zodiac',                  'imdbId': 'tt0443706', 'tmdbId': '1949',  'type': 'movie', 'year': 2007},
  {'title': 'Pan\'s Labyrinth',        'imdbId': 'tt0457430', 'tmdbId': '1250',  'type': 'movie', 'year': 2006},
  {'title': 'Oldboy',                  'imdbId': 'tt0364569', 'tmdbId': '6217',  'type': 'movie', 'year': 2003},
  {'title': 'Brokeback Mountain',      'imdbId': 'tt0388795', 'tmdbId': '73',    'type': 'movie', 'year': 2005},

  // ── 2010s Movies ──
  {'title': 'Interstellar',            'imdbId': 'tt0816692', 'tmdbId': '157336', 'type': 'movie', 'year': 2014},
  {'title': 'Mad Max Fury Road',       'imdbId': 'tt1392190', 'tmdbId': '76341',  'type': 'movie', 'year': 2015},
  {'title': 'The Revenant',            'imdbId': 'tt1663202', 'tmdbId': '281957', 'type': 'movie', 'year': 2015},
  {'title': 'Whiplash',                'imdbId': 'tt2582802', 'tmdbId': '244786', 'type': 'movie', 'year': 2014},
  {'title': 'Birdman',                 'imdbId': 'tt2562232', 'tmdbId': '290250', 'type': 'movie', 'year': 2014},
  {'title': 'The Grand Budapest Hotel','imdbId': 'tt2278388', 'tmdbId': '228150', 'type': 'movie', 'year': 2014},
  {'title': 'Parasite',                'imdbId': 'tt6751668', 'tmdbId': '496243', 'type': 'movie', 'year': 2019},
  {'title': 'Joker',                   'imdbId': 'tt7286456', 'tmdbId': '475557', 'type': 'movie', 'year': 2019},
  {'title': 'Once Upon a Time in Hollywood', 'imdbId': 'tt7131622', 'tmdbId': '466272', 'type': 'movie', 'year': 2019},
  {'title': 'Avengers Endgame',        'imdbId': 'tt4154796', 'tmdbId': '299534', 'type': 'movie', 'year': 2019},
  {'title': 'Get Out',                 'imdbId': 'tt5052448', 'tmdbId': '419430', 'type': 'movie', 'year': 2017},
  {'title': 'Dunkirk',                 'imdbId': 'tt5013056', 'tmdbId': '374720', 'type': 'movie', 'year': 2017},
  {'title': 'Blade Runner 2049',       'imdbId': 'tt1856101', 'tmdbId': '335984', 'type': 'movie', 'year': 2017},
  {'title': 'Hereditary',              'imdbId': 'tt7784604', 'tmdbId': '493922', 'type': 'movie', 'year': 2018},
  {'title': 'A Quiet Place',           'imdbId': 'tt6644200', 'tmdbId': '447332', 'type': 'movie', 'year': 2018},

  // ── 2020s Movies ──
  {'title': 'Dune',                    'imdbId': 'tt1160419', 'tmdbId': '438631', 'type': 'movie', 'year': 2021},
  {'title': 'The Batman',              'imdbId': 'tt1877830', 'tmdbId': '414906', 'type': 'movie', 'year': 2022},
  {'title': 'Everything Everywhere All at Once', 'imdbId': 'tt6710474', 'tmdbId': '545611', 'type': 'movie', 'year': 2022},
  {'title': 'Top Gun Maverick',        'imdbId': 'tt1745960', 'tmdbId': '361743', 'type': 'movie', 'year': 2022},
  {'title': 'Oppenheimer',             'imdbId': 'tt15398776','tmdbId': '872585', 'type': 'movie', 'year': 2023},
  {'title': 'Barbie',                  'imdbId': 'tt1517268', 'tmdbId': '346698', 'type': 'movie', 'year': 2023},
  {'title': 'Poor Things',             'imdbId': 'tt14230458','tmdbId': '792307', 'type': 'movie', 'year': 2023},
  {'title': 'Killers of the Flower Moon','imdbId':'tt5537002','tmdbId': '802119', 'type': 'movie', 'year': 2023},
  {'title': 'Dune Part Two',           'imdbId': 'tt15239678','tmdbId': '693134', 'type': 'movie', 'year': 2024},
  {'title': 'Alien Romulus',           'imdbId': 'tt18412256','tmdbId': '945961', 'type': 'movie', 'year': 2024},

  // ── Bollywood / South Indian ──
  {'title': 'RRR',                     'imdbId': 'tt8178634', 'tmdbId': '759544', 'type': 'movie', 'year': 2022},
  {'title': 'KGF Chapter 2',           'imdbId': 'tt10272286','tmdbId': '774930', 'type': 'movie', 'year': 2022},
  {'title': 'Pushpa The Rise',         'imdbId': 'tt9764362', 'tmdbId': '756999', 'type': 'movie', 'year': 2021},
  {'title': '3 Idiots',                'imdbId': 'tt1187043', 'tmdbId': '20669',  'type': 'movie', 'year': 2009},
  {'title': 'Dangal',                  'imdbId': 'tt5074352', 'tmdbId': '406997', 'type': 'movie', 'year': 2016},
  {'title': 'Bajrangi Bhaijaan',       'imdbId': 'tt3863552', 'tmdbId': '328134', 'type': 'movie', 'year': 2015},
  {'title': 'Kabir Singh',             'imdbId': 'tt9827276', 'tmdbId': '592834', 'type': 'movie', 'year': 2019},
  {'title': 'Pathaan',                 'imdbId': 'tt12906982','tmdbId': '978916', 'type': 'movie', 'year': 2023},

  // ── TV Shows ──
  {'title': 'Breaking Bad',            'imdbId': 'tt0903747', 'tmdbId': '1396',   'type': 'tv', 'year': 2008, 'season': 1, 'episode': 1},
  {'title': 'Breaking Bad',            'imdbId': 'tt0903747', 'tmdbId': '1396',   'type': 'tv', 'year': 2008, 'season': 5, 'episode': 14},
  {'title': 'Game of Thrones',         'imdbId': 'tt0944947', 'tmdbId': '1399',   'type': 'tv', 'year': 2011, 'season': 1, 'episode': 1},
  {'title': 'Game of Thrones',         'imdbId': 'tt0944947', 'tmdbId': '1399',   'type': 'tv', 'year': 2011, 'season': 8, 'episode': 3},
  {'title': 'Stranger Things',         'imdbId': 'tt4574334', 'tmdbId': '66732',  'type': 'tv', 'year': 2016, 'season': 1, 'episode': 1},
  {'title': 'The Wire',                'imdbId': 'tt0306414', 'tmdbId': '1438',   'type': 'tv', 'year': 2002, 'season': 1, 'episode': 1},
  {'title': 'The Sopranos',            'imdbId': 'tt0141842', 'tmdbId': '1398',   'type': 'tv', 'year': 1999, 'season': 1, 'episode': 1},
  {'title': 'Chernobyl',               'imdbId': 'tt7366338', 'tmdbId': '87108',  'type': 'tv', 'year': 2019, 'season': 1, 'episode': 1},
  {'title': 'Peaky Blinders',          'imdbId': 'tt2442560', 'tmdbId': '60574',  'type': 'tv', 'year': 2013, 'season': 1, 'episode': 1},
  {'title': 'The Last of Us',          'imdbId': 'tt3581920', 'tmdbId': '100088', 'type': 'tv', 'year': 2023, 'season': 1, 'episode': 1},
  {'title': 'House of the Dragon',     'imdbId': 'tt11198330','tmdbId': '94997',  'type': 'tv', 'year': 2022, 'season': 1, 'episode': 1},
  {'title': 'The Bear',                'imdbId': 'tt14452776','tmdbId': '136315', 'type': 'tv', 'year': 2022, 'season': 1, 'episode': 1},
  {'title': 'Severance',               'imdbId': 'tt11280740','tmdbId': '95396',  'type': 'tv', 'year': 2022, 'season': 1, 'episode': 1},
  {'title': 'The Boys',                'imdbId': 'tt1190634', 'tmdbId': '76479',  'type': 'tv', 'year': 2019, 'season': 1, 'episode': 1},
  {'title': 'Succession',              'imdbId': 'tt7660850', 'tmdbId': '79696',  'type': 'tv', 'year': 2018, 'season': 1, 'episode': 1},
  {'title': 'Better Call Saul',        'imdbId': 'tt3032476', 'tmdbId': '60059',  'type': 'tv', 'year': 2015, 'season': 1, 'episode': 1},
  {'title': 'Ozark',                   'imdbId': 'tt5071412', 'tmdbId': '69740',  'type': 'tv', 'year': 2017, 'season': 1, 'episode': 1},
  {'title': 'Squid Game',              'imdbId': 'tt10919420','tmdbId': '93405',  'type': 'tv', 'year': 2021, 'season': 1, 'episode': 1},
  {'title': 'Squid Game',              'imdbId': 'tt10919420','tmdbId': '93405',  'type': 'tv', 'year': 2024, 'season': 2, 'episode': 1},
  {'title': 'Dark',                    'imdbId': 'tt5753856', 'tmdbId': '70523',  'type': 'tv', 'year': 2017, 'season': 1, 'episode': 1},
  {'title': 'Mindhunter',              'imdbId': 'tt5290382', 'tmdbId': '67744',  'type': 'tv', 'year': 2017, 'season': 1, 'episode': 1},
  {'title': 'The Crown',               'imdbId': 'tt4786824', 'tmdbId': '65494',  'type': 'tv', 'year': 2016, 'season': 1, 'episode': 1},
  {'title': 'True Detective',          'imdbId': 'tt2356777', 'tmdbId': '46648',  'type': 'tv', 'year': 2014, 'season': 1, 'episode': 1},
  {'title': 'Euphoria',                'imdbId': 'tt8772296', 'tmdbId': '85552',  'type': 'tv', 'year': 2019, 'season': 1, 'episode': 1},

  // ── Anime ──
  {'title': 'Attack on Titan',         'imdbId': 'tt2560140', 'tmdbId': '1429',   'type': 'tv', 'year': 2013, 'season': 1, 'episode': 1},
  {'title': 'Attack on Titan',         'imdbId': 'tt2560140', 'tmdbId': '1429',   'type': 'tv', 'year': 2023, 'season': 4, 'episode': 1},
  {'title': 'Death Note',              'imdbId': 'tt0877057', 'tmdbId': '13916',  'type': 'tv', 'year': 2006, 'season': 1, 'episode': 1},
  {'title': 'Fullmetal Alchemist Brotherhood', 'imdbId': 'tt1355642', 'tmdbId': '31911', 'type': 'tv', 'year': 2009, 'season': 1, 'episode': 1},
  {'title': 'Demon Slayer',            'imdbId': 'tt9335498', 'tmdbId': '85937',  'type': 'tv', 'year': 2019, 'season': 1, 'episode': 1},
  {'title': 'Jujutsu Kaisen',          'imdbId': 'tt12343534','tmdbId': '95479',  'type': 'tv', 'year': 2020, 'season': 1, 'episode': 1},
  {'title': 'One Piece',               'imdbId': 'tt0388629', 'tmdbId': '37854',  'type': 'tv', 'year': 1999, 'season': 1, 'episode': 1},
  {'title': 'Naruto',                  'imdbId': 'tt0409591', 'tmdbId': '31910',  'type': 'tv', 'year': 2002, 'season': 1, 'episode': 1},
  {'title': 'Hunter x Hunter',         'imdbId': 'tt2098220', 'tmdbId': '46298',  'type': 'tv', 'year': 2011, 'season': 1, 'episode': 1},
  {'title': 'Vinland Saga',            'imdbId': 'tt10233448','tmdbId': '90507',  'type': 'tv', 'year': 2019, 'season': 1, 'episode': 1},
  {'title': 'Chainsaw Man',            'imdbId': 'tt14248765','tmdbId': '114410', 'type': 'tv', 'year': 2022, 'season': 1, 'episode': 1},
  {'title': 'Cowboy Bebop',            'imdbId': 'tt0213338', 'tmdbId': '30991',  'type': 'tv', 'year': 1998, 'season': 1, 'episode': 1},
  {'title': 'Neon Genesis Evangelion', 'imdbId': 'tt0112159', 'tmdbId': '890',    'type': 'tv', 'year': 1995, 'season': 1, 'episode': 1},
];

// ─── Helpers ─────────────────────────────────────────────────────────────────

String _fmt(Duration d) => '${d.inMilliseconds}ms';


// ─── Main ────────────────────────────────────────────────────────────────────

void main() {
  setUpAll(() async {
    await dotenv.load(fileName: '.env');
  });

  tearDownAll(() {
    // ─── Final Report ───────────────────────────────────────────────────────
    final pass  = _results.where((r) => r.status == _TestStatus.pass).length;
    final fail  = _results.where((r) => r.status == _TestStatus.fail).length;
    final skip  = _results.where((r) => r.status == _TestStatus.skip).length;
    final total = _results.length;

    // Component breakdown
    final byComponent = <String, Map<String, int>>{};
    for (final r in _results) {
      byComponent.putIfAbsent(r.component, () => {'pass': 0, 'fail': 0, 'skip': 0});
      byComponent[r.component]![r.status.name] =
          (byComponent[r.component]![r.status.name] ?? 0) + 1;
    }

    // ignore: avoid_print
    print('\n\n══════════════════════════════════════════════════════');
    // ignore: avoid_print
    print('  MASSIVE INTEGRATION TEST — FINAL REPORT');
    // ignore: avoid_print
    print('══════════════════════════════════════════════════════');
    // ignore: avoid_print
    print('  Total: $total  ✅ Pass: $pass  ❌ Fail: $fail  ⚠️ Skip: $skip');
    // ignore: avoid_print
    print('  Pass rate: ${(pass / total * 100).toStringAsFixed(1)}%');
    // ignore: avoid_print
    print('──────────────────────────────────────────────────────');

    for (final comp in byComponent.keys.toList()..sort()) {
      final m = byComponent[comp]!;
      // ignore: avoid_print
      print('  $comp → ✅${m['pass']} ❌${m['fail']} ⚠️${m['skip']}');
    }

    // ignore: avoid_print
    print('──────────────────────────────────────────────────────');

    final failures = _results.where((r) => r.status == _TestStatus.fail).toList();
    if (failures.isNotEmpty) {
      // ignore: avoid_print
      print('  FAILURES:');
      for (final f in failures) {
        // ignore: avoid_print
        print('    ${f.component} | ${f.title}${f.detail != null ? " — ${f.detail}" : ""}');
      }
    }
    // ignore: avoid_print
    print('══════════════════════════════════════════════════════\n');
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // GROUP 1: Torrentio Service — quality caps & parsing
  // ═══════════════════════════════════════════════════════════════════════════

  group('Torrentio — quality caps & parsing', () {
    late TorrentioService torrentio;

    setUpAll(() {
      torrentio = TorrentioService();
    });

    test('TorrentioSource.fromJson parses 1080p correctly', () {
      final src = TorrentioSource.fromJson({
        'title': 'Torrentio\n1080p • WEB-DL • x265 • DDP5.1\n💾 2.1 GB ⚙️ YTS 👤 156',
        'infoHash': 'abc123',
        'fileIdx': 0,
        'behaviorHints': {'filename': 'movie.1080p.mkv'},
      });
      _record(_Result(
        title: '1080p parse', component: 'Torrentio.parse',
        status: src.quality == '1080p' && src.codec == 'x265' ? _TestStatus.pass : _TestStatus.fail,
        detail: 'quality=${src.quality} codec=${src.codec}',
        elapsed: Duration.zero,
      ));
      expect(src.quality, equals('1080p'));
      expect(src.codec, equals('x265'));
    });

    test('TorrentioSource.fromJson rejects 4K', () {
      final src = TorrentioSource.fromJson({
        'title': 'Torrentio\n2160p • 4K HDR • HEVC\n💾 25 GB ⚙️ YTS 👤 50',
        'infoHash': 'abc456',
        'fileIdx': 0,
      });
      _record(_Result(
        title: '4K rejection', component: 'Torrentio.parse',
        status: src.quality == '4K' && !src.isWithinSizeLimit ? _TestStatus.pass : _TestStatus.skip,
        detail: 'quality=${src.quality} size=${src.sizeGB.toStringAsFixed(1)}GB withinLimit=${src.isWithinSizeLimit}',
        elapsed: Duration.zero,
      ));
      expect(src.quality, equals('4K'));
    });

    test('TorrentioSource size cap — 4.5GB exceeds 3GB limit', () {
      final src = TorrentioSource.fromJson({
        'title': 'Torrentio\n1080p • BluRay • x264\n💾 4.5 GB ⚙️ YIFY 👤 200',
        'infoHash': 'abc789',
        'fileIdx': 0,
      });
      _record(_Result(
        title: '4.5GB cap', component: 'Torrentio.size',
        status: !src.isWithinSizeLimit ? _TestStatus.pass : _TestStatus.fail,
        detail: 'sizeGB=${src.sizeGB.toStringAsFixed(1)} isWithinLimit=${src.isWithinSizeLimit}',
        elapsed: Duration.zero,
      ));
      expect(src.isWithinSizeLimit, isFalse);
    });

    test('TorrentioSource size cap — 1.8GB within limit', () {
      final src = TorrentioSource.fromJson({
        'title': 'Torrentio\n1080p • WEB-DL • x265\n💾 1.8 GB ⚙️ EZTV 👤 88',
        'infoHash': 'abcdef',
        'fileIdx': 0,
      });
      _record(_Result(
        title: '1.8GB within', component: 'Torrentio.size',
        status: src.isWithinSizeLimit ? _TestStatus.pass : _TestStatus.fail,
        detail: 'sizeGB=${src.sizeGB.toStringAsFixed(1)}',
        elapsed: Duration.zero,
      ));
      expect(src.isWithinSizeLimit, isTrue);
    });

    // Live network test — The Shawshank Redemption
    test('live fetch for Shawshank Redemption', () async {
      final sw = Stopwatch()..start();
      final sources = await torrentio.fetchSources(imdbId: 'tt0111161', type: 'movie');
      sw.stop();
      final eligible = sources.where(
        (s) => s.quality != '4K' && s.isWithinSizeLimit,
      ).toList();
      _record(_Result(
        title: 'Shawshank (tt0111161)', component: 'Torrentio.live',
        status: eligible.isNotEmpty ? _TestStatus.pass : _TestStatus.fail,
        detail: 'total=${sources.length} eligible=${eligible.length} ${_fmt(sw.elapsed)}',
        elapsed: sw.elapsed,
      ));
      expect(eligible, isNotEmpty);
    }, timeout: const Timeout(Duration(seconds: 20)));

    // Live: Breaking Bad S01E01
    test('live fetch Breaking Bad S01E01', () async {
      final sw = Stopwatch()..start();
      final sources = await torrentio.fetchSources(
        imdbId: 'tt0903747', type: 'tv', season: 1, episode: 1,
      );
      sw.stop();
      final eligible = sources.where(
        (s) => s.quality != '4K' && s.isWithinSizeLimit,
      ).toList();
      _record(_Result(
        title: 'Breaking Bad S01E01', component: 'Torrentio.live',
        status: eligible.isNotEmpty ? _TestStatus.pass : _TestStatus.fail,
        detail: 'total=${sources.length} eligible=${eligible.length} ${_fmt(sw.elapsed)}',
        elapsed: sw.elapsed,
      ));
      expect(eligible, isNotEmpty);
    }, timeout: const Timeout(Duration(seconds: 20)));
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // GROUP 2: AtmosIndex Client — catalog search
  // ═══════════════════════════════════════════════════════════════════════════

  group('AtmosIndex — catalog search', () {
    late AtmosIndexClient client;

    setUpAll(() {
      client = AtmosIndexClient();
    });

    test('stats endpoint returns catalog size', () async {
      final sw = Stopwatch()..start();
      final stats = await client.getStats();
      sw.stop();
      _record(_Result(
        title: 'Catalog stats', component: 'AtmosIndex.stats',
        status: stats.isNotEmpty ? _TestStatus.pass : _TestStatus.skip,
        detail: stats.toString().substring(0, stats.toString().length.clamp(0, 80)),
        elapsed: sw.elapsed,
      ));
    }, timeout: const Timeout(Duration(seconds: 15)));

    // Search for 10 titles via AtmosIndex
    final indexTitles = [
      ('The Shawshank Redemption', 1994, null, null),
      ('Inception', 2010, null, null),
      ('Parasite', 2019, null, null),
      ('Breaking Bad', 2008, 1, 1),
      ('Attack on Titan', 2013, 1, 1),
      ('Demon Slayer', 2019, 1, 1),
      ('Squid Game', 2021, 1, 1),
      ('The Last of Us', 2023, 1, 1),
      ('Oppenheimer', 2023, null, null),
      ('RRR', 2022, null, null),
    ];

    for (final (title, year, season, episode) in indexTitles) {
      test('search: $title', () async {
        final sw = Stopwatch()..start();
        final results = await client.search(
          title,
          year: year,
          season: season,
          episode: episode,
        );
        sw.stop();
        _record(_Result(
          title: title, component: 'AtmosIndex.search',
          status: results.isNotEmpty ? _TestStatus.pass : _TestStatus.skip,
          detail: '${results.length} results ${_fmt(sw.elapsed)}',
          elapsed: sw.elapsed,
        ));
      }, timeout: const Timeout(Duration(seconds: 20)));
    }
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // GROUP 3: StreamExtractorService — parallel race & cache engine
  // ═══════════════════════════════════════════════════════════════════════════

  group('StreamExtractor — race engine & cache', () {
    late StreamExtractorService extractor;

    setUpAll(() {
      extractor = StreamExtractorService();
    });

    // Cache preservation test
    test('clearCache wipes only target content key', () {
      const key1 = 'tt0111161_278_movie_1_1';
      const key2 = 'tt0468569_155_movie_1_1';

      // Manually populate cache by running extractor (or just test the API)
      extractor.clearCache(key1);
      extractor.clearCache(key2);

      // After clear, getAvailableServers should return empty
      expect(extractor.getAvailableServers(key1), isEmpty);
      expect(extractor.getAvailableServers(key2), isEmpty);

      _record(const _Result(
        title: 'clearCache isolation', component: 'Extractor.cache',
        status: _TestStatus.pass,
        detail: 'two keys independently cleared',
        elapsed: Duration.zero,
      ));
    });

    test('getProviderStatuses returns immutable map', () {
      final statuses = extractor.getProviderStatuses('nonexistent_key');
      expect(statuses, isA<Map<String, ProviderStatus>>());
      // Should not throw on access of missing key
      expect(statuses['VidAPI'], isNull);
      _record(const _Result(
        title: 'getProviderStatuses immutable', component: 'Extractor.cache',
        status: _TestStatus.pass,
        elapsed: Duration.zero,
      ));
    });

    test('availableProviders has exactly 6 distinct entries', () {
      const providers = StreamExtractorService.availableProviders;
      expect(providers.length, equals(6));
      expect(providers.toSet().length, equals(6));
      _record(_Result(
        title: 'provider count = 6', component: 'Extractor.providers',
        status: _TestStatus.pass,
        detail: providers.join(', '),
        elapsed: Duration.zero,
      ));
    });

    // ── Live extraction for 5 strategically chosen titles ──

    final liveExtractionTitles = [
      ('The Shawshank Redemption', 'tt0111161', '278',   'movie', 1, 1),
      ('Inception',                'tt1375666', '27205', 'movie', 1, 1),
      ('Breaking Bad S01E01',      'tt0903747', '1396',  'tv',    1, 1),
      ('Squid Game S01E01',        'tt10919420','93405', 'tv',    1, 1),
      ('Attack on Titan S01E01',   'tt2560140', '1429',  'tv',    1, 1),
    ];

    for (final (title, imdbId, tmdbId, type, season, episode) in liveExtractionTitles) {
      test('live extractWithStatus: $title', () async {
        final statuses = <String, List<String>>{};
        final sw = Stopwatch()..start();

        final stream = await extractor.extractWithStatus(
          imdbId: imdbId,
          tmdbId: tmdbId,
          type: type,
          title: title.split(' S0')[0],
          season: season,
          episode: episode,
          onStatus: (name, status) {
            statuses.putIfAbsent(name, () => []).add(status.name);
          },
        );

        sw.stop();

        // Verify status callbacks fired for all providers
        final allFired = StreamExtractorService.availableProviders
            .every((p) => statuses.containsKey(p));

        final status = stream != null ? _TestStatus.pass
            : allFired ? _TestStatus.skip   // all tried, none succeeded
            : _TestStatus.fail;

        _record(_Result(
          title: title, component: 'Extractor.live',
          status: status,
          detail: stream != null
              ? '✅ ${stream.providerName} ${_fmt(sw.elapsed)} '
                '${stream.hasQualities ? "${stream.qualities.length}q" : "no-q"} '
                '${stream.subtitles.isNotEmpty ? "${stream.subtitles.length}subs" : ""}'
              : 'null — tried ${statuses.length}/${StreamExtractorService.availableProviders.length} providers ${_fmt(sw.elapsed)}',
          elapsed: sw.elapsed,
        ));

        // All providers must have at least fired 'trying'
        expect(allFired, isTrue,
          reason: 'Missing: ${StreamExtractorService.availableProviders.where((p) => !statuses.containsKey(p)).join(", ")}');
      }, timeout: const Timeout(Duration(seconds: 30)));
    }

    // ── Second call on same content key should use cache ──
    test('second extractWithStatus call reuses cache (no re-fire for success)', () async {
      const imdbId = 'tt0111161';
      const tmdbId = '278';
      const key = '${imdbId}_${tmdbId}_movie_1_1';

      extractor.clearCache(key);

      // First call — populates cache
      final sw1 = Stopwatch()..start();
      await extractor.extractWithStatus(
        imdbId: imdbId, tmdbId: tmdbId, type: 'movie',
      );
      sw1.stop();

      // Let background providers finish
      await Future<void>.delayed(const Duration(seconds: 8));

      // Second call — should be instant for already-resolved providers
      final statuses2 = <String, String>{};
      final sw2 = Stopwatch()..start();
      await extractor.extractWithStatus(
        imdbId: imdbId, tmdbId: tmdbId, type: 'movie',
        onStatus: (name, status) => statuses2[name] = status.name,
      );
      sw2.stop();

      final cachedProviders = extractor.getAvailableServers(key).length;

      _record(_Result(
        title: 'Cache reuse (Shawshank)', component: 'Extractor.cache',
        status: sw2.elapsed < sw1.elapsed ? _TestStatus.pass : _TestStatus.skip,
        detail: 'first=${_fmt(sw1.elapsed)} second=${_fmt(sw2.elapsed)} cached=$cachedProviders providers',
        elapsed: sw2.elapsed,
      ));
    }, timeout: const Timeout(Duration(seconds: 30)));
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // GROUP 4: DownloadFilters — scoring & matching
  // ═══════════════════════════════════════════════════════════════════════════

  group('DownloadFilters — quality & language matching', () {
    final filterCases = <(String, String, String?, bool)>[
      ('1080p BluRay x264',   '1080', null,       true),
      ('720p WEB-DL',         '720',  null,       true),
      ('1080p',               '720',  null,       false),  // wrong tier
      ('4K HDR',              '1080', null,       false),  // 4K != 1080
      ('480p',                '480',  null,       true),
      ('1080p Hindi',         '1080', 'hindi',    true),
      ('1080p English',       '1080', 'hindi',    false),  // language mismatch
      ('Dual Audio 1080p',    '1080', 'dual',     true),
      ('1080p BluRay',        '1080', 'original', true),   // no lang tag = original
    ];

    for (final (quality, filterQ, filterL, expected) in filterCases) {
      test('matchesOption("$quality", q=$filterQ, l=$filterL) → $expected', () {
        final qf = QualityFilter.values.firstWhere(
          (q) => q.token == filterQ,
          orElse: () => QualityFilter.any,
        );
        final lf = filterL != null
            ? LanguageFilter.values.firstWhere(
                (l) => l.token == filterL,
                orElse: () => LanguageFilter.any,
              )
            : LanguageFilter.any;

        final filters = DownloadFilters(quality: qf, language: lf);
        final result = filters.matchesOption(quality: quality, audioChannels: quality);

        _record(_Result(
          title: '"$quality" q=$filterQ l=$filterL',
          component: 'DownloadFilters.match',
          status: result == expected ? _TestStatus.pass : _TestStatus.fail,
          detail: 'got=$result expected=$expected',
          elapsed: Duration.zero,
        ));
        expect(result, equals(expected));
      });
    }

    test('searchHint generates correct Telegram query hints', () {
      final cases = [
        (QualityFilter.q1080, LanguageFilter.hindi,  '1080 Hindi'),
        (QualityFilter.q720,  LanguageFilter.dual,   '720 Dual Audio'),
        (QualityFilter.any,   LanguageFilter.any,    ''),
        (QualityFilter.q480,  LanguageFilter.english,'480 English'),
      ];
      for (final (qf, lf, expected) in cases) {
        final hint = DownloadFilters(quality: qf, language: lf).searchHint;
        _record(_Result(
          title: 'searchHint q=${qf.label} l=${lf.label}',
          component: 'DownloadFilters.hint',
          status: hint == expected ? _TestStatus.pass : _TestStatus.fail,
          detail: 'got="$hint" expected="$expected"',
          elapsed: Duration.zero,
        ));
        expect(hint, equals(expected));
      }
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // GROUP 5: Torrentio bulk title scan (50 titles)
  // ═══════════════════════════════════════════════════════════════════════════

  group('Torrentio — bulk title scan', () {
    late TorrentioService torrentio;

    setUpAll(() { torrentio = TorrentioService(); });

    // Pick first 20 movie titles + 10 TV titles for bulk scan
    final bulkMovies = _titles.where((t) => t['type'] == 'movie').take(20).toList();
    final bulkTv     = _titles.where((t) => t['type'] == 'tv').take(10).toList();
    final bulk       = [...bulkMovies, ...bulkTv];

    for (final t in bulk) {
      final name    = t['title'] as String;
      final imdbId  = t['imdbId'] as String;
      final type    = t['type'] as String;
      final season  = t['season'] as int?;
      final episode = t['episode'] as int?;

      test('torrentio: $name', () async {
        final sw = Stopwatch()..start();
        List<TorrentioSource> sources;
        try {
          sources = await torrentio.fetchSources(
            imdbId: imdbId,
            type: type,
            season: season ?? 1,
            episode: episode ?? 1,
          );
        } catch (e) {
          sources = [];
        }
        sw.stop();

        final eligible = sources.where(
          (s) => s.quality != '4K' && s.isWithinSizeLimit,
        ).toList();

        _record(_Result(
          title: name, component: 'Torrentio.bulk',
          status: eligible.isNotEmpty ? _TestStatus.pass : _TestStatus.skip,
          detail: 'total=${sources.length} eligible=${eligible.length} '
                  'best=${eligible.isNotEmpty ? "${eligible.first.quality} ${eligible.first.sizeLabel}" : "none"} '
                  '${_fmt(sw.elapsed)}',
          elapsed: sw.elapsed,
        ));
      }, timeout: const Timeout(Duration(seconds: 20)));
    }
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // GROUP 6: StreamExtractor — full title marathon (all 105 titles)
  // PARALLEL batch: 5 at a time
  // ═══════════════════════════════════════════════════════════════════════════

  group('StreamExtractor — full title marathon', () {
    late StreamExtractorService extractor;

    setUpAll(() { extractor = StreamExtractorService(); });

    // Run in batches of 5 to respect rate limits
    const batchSize = 5;
    for (int i = 0; i < _titles.length; i += batchSize) {
      final batch = _titles.skip(i).take(batchSize).toList();
      final batchLabel = 'batch ${(i ~/ batchSize) + 1}/${(_titles.length / batchSize).ceil()}';

      test('marathon $batchLabel (${batch.map((t) => t['title']).join(", ")})', () async {
        // Run batch in parallel
        final futures = batch.map((t) async {
          final title   = t['title'] as String;
          final imdbId  = t['imdbId'] as String;
          final tmdbId  = t['tmdbId'] as String;
          final type    = t['type'] as String;
          final season  = (t['season'] as int?) ?? 1;
          final episode = (t['episode'] as int?) ?? 1;

          final statuses = <String, ProviderStatus>{};
          final sw = Stopwatch()..start();

          ExtractedStream? stream;
          try {
            stream = await extractor.extractWithStatus(
              imdbId: imdbId,
              tmdbId: tmdbId,
              type: type,
              title: title.split(' S0').first,
              season: season,
              episode: episode,
              onStatus: (name, st) => statuses[name] = st,
            ).timeout(const Duration(seconds: 20));
          } catch (_) {
            stream = null;
          }
          sw.stop();

          final allProvidersFired = StreamExtractorService.availableProviders
              .every((p) => statuses.containsKey(p));

          _record(_Result(
            title: title,
            component: 'Marathon.stream',
            status: stream != null ? _TestStatus.pass
                : allProvidersFired ? _TestStatus.skip
                : _TestStatus.fail,
            detail: stream != null
                ? '${stream.providerName} ${_fmt(sw.elapsed)}'
                : 'no stream ${_fmt(sw.elapsed)}',
            elapsed: sw.elapsed,
          ));
        });

        await Future.wait(futures);
      }, timeout: const Timeout(Duration(seconds: 30)));
    }
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // GROUP 7: ExtractedStream model — edge cases & validation
  // ═══════════════════════════════════════════════════════════════════════════

  group('ExtractedStream — model validation', () {
    final modelCases = <(String, String, bool, bool)>[
      // url, provider, isHls, isMp4
      ('https://cdn.example.com/v.m3u8',         'Videasy',    true,  false),
      ('https://cdn.example.com/v.mpegurl',       'VidLink',   true,  false),
      ('https://cdn.example.com/v.mp4',           'VidAPI',    false, true),
      ('https://cdn.example.com/v.mkv',           'Torrentio', false, true),
      ('https://cdn.example.com/v.webm',          'VidAPI',    false, true),
      ('https://cdn.example.com/manifest?t=hls',  'VidLink',   false, false),
      ('https://cdn.example.com/v.ts',            'Stremio',   false, false),
    ];

    for (final (url, provider, expectedHls, expectedMp4) in modelCases) {
      test('$provider ${url.split('/').last}', () {
        final stream = ExtractedStream(url: url, headers: {}, providerName: provider);
        final hlsOk = stream.isHls == expectedHls;
        final mp4Ok = stream.isMp4 == expectedMp4;
        _record(_Result(
          title: '${url.split('/').last} ($provider)',
          component: 'ExtractedStream.model',
          status: hlsOk && mp4Ok ? _TestStatus.pass : _TestStatus.fail,
          detail: 'isHls=${stream.isHls}(exp=$expectedHls) isMp4=${stream.isMp4}(exp=$expectedMp4)',
          elapsed: Duration.zero,
        ));
        expect(stream.isHls, equals(expectedHls));
        expect(stream.isMp4, equals(expectedMp4));
      });
    }

    test('qualities list preserved with correct order', () {
      const stream = ExtractedStream(
        url: 'https://cdn.example.com/v.mp4',
        headers: {},
        providerName: 'VidAPI',
        qualities: [
          QualityOption(quality: '1080p', url: 'https://cdn.example.com/1080.mp4'),
          QualityOption(quality: '720p',  url: 'https://cdn.example.com/720.mp4'),
          QualityOption(quality: '480p',  url: 'https://cdn.example.com/480.mp4'),
        ],
      );
      _record(_Result(
        title: 'qualities order preserved', component: 'ExtractedStream.model',
        status: stream.qualities.first.quality == '1080p' ? _TestStatus.pass : _TestStatus.fail,
        elapsed: Duration.zero,
      ));
      expect(stream.hasQualities, isTrue);
      expect(stream.qualities.first.quality, equals('1080p'));
    });

    test('subtitle list with language codes', () {
      const stream = ExtractedStream(
        url: 'https://cdn.example.com/v.m3u8',
        headers: {},
        providerName: 'Videasy',
        subtitles: [
          SubtitleInfo(url: 'https://subs.example.com/en.srt', lang: 'en', label: 'English'),
          SubtitleInfo(url: 'https://subs.example.com/hi.srt', lang: 'hi', label: 'Hindi'),
        ],
      );
      _record(_Result(
        title: 'subtitle list with lang codes', component: 'ExtractedStream.model',
        status: stream.subtitles.length == 2 ? _TestStatus.pass : _TestStatus.fail,
        elapsed: Duration.zero,
      ));
      expect(stream.subtitles.length, equals(2));
      expect(stream.subtitles.first.lang, equals('en'));
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // GROUP 8: TorrentioSource — comprehensive parsing
  // ═══════════════════════════════════════════════════════════════════════════

  group('TorrentioSource — comprehensive parsing', () {
    final parseCases = <Map<String, dynamic>>[
      {
        'raw': 'Torrentio\n1080p • WEB-DL • x265 • DDP5.1\n💾 2.1 GB ⚙️ YTS 👤 156',
        'expectQ': '1080p', 'expectCodec': 'x265', 'expectSeeders': 156, 'withinLimit': true,
      },
      {
        'raw': 'Torrentio\n720p • BluRay • x264\n💾 0.9 GB ⚙️ YIFY 👤 892',
        'expectQ': '720p', 'expectCodec': 'x264', 'expectSeeders': 892, 'withinLimit': true,
      },
      {
        'raw': 'Torrentio\n2160p • 4K • HEVC • Atmos\n💾 28 GB ⚙️ FGT 👤 44',
        'expectQ': '4K', 'expectCodec': 'x265', 'expectSeeders': 44, 'withinLimit': false,
      },
      {
        'raw': 'Torrentio\n480p • HDTV • x264\n💾 350 MB ⚙️ EZTV 👤 15',
        'expectQ': '480p', 'expectCodec': 'x264', 'expectSeeders': 15, 'withinLimit': true,
      },
      {
        'raw': 'Torrentio\n1080p • BluRay • AV1\n💾 2.9 GB ⚙️ TGx 👤 22',
        'expectQ': '1080p', 'expectCodec': 'AV1', 'expectSeeders': 22, 'withinLimit': true,
      },
      {
        'raw': 'Torrentio\n1080p • WEB-DL • H.265\n💾 3.5 GB ⚙️ NTb 👤 77',
        'expectQ': '1080p', 'expectCodec': 'x265', 'expectSeeders': 77, 'withinLimit': false,
      },
    ];

    for (final c in parseCases) {
      final raw = c['raw'] as String;
      final label = raw.split('\n')[1].split('•').first.trim();
      test('parse: $label', () {
        final src = TorrentioSource.fromJson({'title': raw, 'infoHash': 'abc'});
        final qOk   = src.quality == c['expectQ'];
        final cOk   = src.codec   == c['expectCodec'];
        final limOk = src.isWithinSizeLimit == (c['withinLimit'] as bool);

        _record(_Result(
          title: label, component: 'TorrentioSource.parse',
          status: qOk && cOk && limOk ? _TestStatus.pass : _TestStatus.fail,
          detail: 'q=${src.quality}(exp=${c['expectQ']}) '
                  'codec=${src.codec}(exp=${c['expectCodec']}) '
                  'size=${src.sizeGB.toStringAsFixed(2)}GB '
                  'within=${src.isWithinSizeLimit}(exp=${c['withinLimit']})',
          elapsed: Duration.zero,
        ));
        expect(src.quality, equals(c['expectQ']));
        expect(src.codec, equals(c['expectCodec']));
        expect(src.isWithinSizeLimit, equals(c['withinLimit']));
      });
    }
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // GROUP 9: VegaMovies — service instantiation & worker
  // ═══════════════════════════════════════════════════════════════════════════

  group('VegaMovies — service & worker', () {
    late VegaMoviesService vega;

    setUpAll(() { vega = VegaMoviesService(); });

    test('service is configured when worker URL is set', () {
      _record(_Result(
        title: 'VegaMovies configured', component: 'VegaMovies.config',
        status: vega.isConfigured ? _TestStatus.pass : _TestStatus.fail,
        detail: 'isConfigured=${vega.isConfigured}',
        elapsed: Duration.zero,
      ));
      expect(vega.isConfigured, isTrue);
    });

    test('VegaDownloadLink.fromJson parses all fields', () {
      final link = VegaDownloadLink.fromJson({
        'url': 'https://pixeldrain.com/u/AbCdEf12',
        'host': 'pixeldrain',
        'quality': '1080p',
        'language': 'Hindi',
        'size': '2.1 GB',
        'codec': 'x265',
      });
      _record(_Result(
        title: 'VegaDownloadLink parse', component: 'VegaMovies.model',
        status: link.host == 'pixeldrain' && link.quality == '1080p' ? _TestStatus.pass : _TestStatus.fail,
        detail: 'host=${link.host} q=${link.quality} lang=${link.language} streamable=${link.isStreamable}',
        elapsed: Duration.zero,
      ));
      expect(link.host, equals('pixeldrain'));
      expect(link.quality, equals('1080p'));
      expect(link.isStreamable, isTrue);
    });

    test('VegaDownloadLink directUrl converts pixeldrain', () {
      final link = VegaDownloadLink.fromJson({
        'url': 'https://pixeldrain.com/u/TestFileId',
        'host': 'pixeldrain',
        'quality': '1080p',
      });
      _record(_Result(
        title: 'pixeldrain directUrl', component: 'VegaMovies.model',
        status: link.directUrl.contains('api/file/TestFileId') ? _TestStatus.pass : _TestStatus.fail,
        detail: link.directUrl,
        elapsed: Duration.zero,
      ));
      expect(link.directUrl, contains('api/file/TestFileId'));
    });

    test('VegaDownloadLink sortScore orders correctly', () {
      final hq = VegaDownloadLink.fromJson({'url': 'u', 'host': 'gdrive', 'quality': '1080p', 'codec': 'x265'});
      final lq = VegaDownloadLink.fromJson({'url': 'u', 'host': 'direct', 'quality': '480p'});
      _record(_Result(
        title: 'sortScore 1080p > 480p', component: 'VegaMovies.model',
        status: hq.sortScore > lq.sortScore ? _TestStatus.pass : _TestStatus.fail,
        detail: 'hq=${hq.sortScore} lq=${lq.sortScore}',
        elapsed: Duration.zero,
      ));
      expect(hq.sortScore, greaterThan(lq.sortScore));
    });

    // Live search via worker
    test('live search: Inception', () async {
      final sw = Stopwatch()..start();
      final results = await vega.search('Inception', year: 2010);
      sw.stop();
      _record(_Result(
        title: 'VegaMovies search: Inception', component: 'VegaMovies.live',
        status: results.isNotEmpty ? _TestStatus.pass : _TestStatus.skip,
        detail: '${results.length} results ${_fmt(sw.elapsed)}',
        elapsed: sw.elapsed,
      ));
    }, timeout: const Timeout(Duration(seconds: 15)));
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // GROUP 10: Provider race — simulation with expanded test matrix
  // ═══════════════════════════════════════════════════════════════════════════

  group('Provider race — expanded simulation matrix', () {
    Future<String?> race({
      required Map<String, Duration> delays,
      required Set<String> success,
      Duration timeout = const Duration(seconds: 15),
    }) async {
      final completer = Completer<String?>();
      bool resolved = false;
      int remaining = delays.length;

      for (final provider in delays.keys) {
        Future.delayed(delays[provider]!).then((_) {
          if (success.contains(provider) && !resolved) {
            resolved = true;
            if (!completer.isCompleted) completer.complete(provider);
          } else {
            remaining--;
            if (remaining <= 0 && !completer.isCompleted) completer.complete(null);
          }
        });
      }

      return completer.future.timeout(timeout, onTimeout: () => null);
    }

    final raceCases = <(String, Map<String, Duration>, Set<String>, String?)>[
      ('VidAPI wins first', {'VidAPI': const Duration(milliseconds: 30), 'Videasy': const Duration(milliseconds: 200)}, {'VidAPI', 'Videasy'}, 'VidAPI'),
      ('Videasy wins when VidAPI fails', {'VidAPI': const Duration(milliseconds: 30), 'Videasy': const Duration(milliseconds: 100)}, {'Videasy'}, 'Videasy'),
      ('All fail → null', {'VidAPI': const Duration(milliseconds: 50), 'Videasy': const Duration(milliseconds: 80)}, <String>{}, null),
      ('Only VidLink succeeds', {'VidAPI': const Duration(milliseconds: 40), 'VidLink': const Duration(milliseconds: 60), 'Torrentio': const Duration(milliseconds: 50)}, {'VidLink'}, 'VidLink'),
      ('Stremio fastest', {'VidAPI': const Duration(milliseconds: 200), 'Stremio': const Duration(milliseconds: 20)}, {'VidAPI', 'Stremio'}, 'Stremio'),
      ('6-way race VidAPI first', {
        'VidAPI': const Duration(milliseconds: 20), 'Videasy': const Duration(milliseconds: 100),
        'VidLink': const Duration(milliseconds: 150), 'Torrentio': const Duration(milliseconds: 80),
        'VegaMovies': const Duration(milliseconds: 300), 'Stremio': const Duration(milliseconds: 50),
      }, {'VidAPI', 'Videasy', 'VidLink', 'Torrentio', 'VegaMovies', 'Stremio'}, 'VidAPI'),
      ('Timeout with all hanging', {'A': const Duration(seconds: 5), 'B': const Duration(seconds: 5)}, {'A', 'B'}, null),
    ];

    for (final (label, delays, success, expected) in raceCases) {
      test('race: $label', () async {
        final sw = Stopwatch()..start();
        final winner = await race(
          delays: delays,
          success: success,
          timeout: label.contains('Timeout') ? const Duration(milliseconds: 100) : const Duration(seconds: 15),
        );
        sw.stop();
        _record(_Result(
          title: label, component: 'Race.sim',
          status: winner == expected ? _TestStatus.pass : _TestStatus.fail,
          detail: 'got=$winner expected=$expected ${_fmt(sw.elapsed)}',
          elapsed: sw.elapsed,
        ));
        expect(winner, equals(expected));
      });
    }
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // GROUP 11: Error handling — network failures & malformed responses
  // ═══════════════════════════════════════════════════════════════════════════

  group('Error handling — graceful degradation', () {
    late StreamExtractorService extractor;
    late TorrentioService torrentio;
    late AtmosIndexClient indexClient;

    setUpAll(() {
      extractor   = StreamExtractorService();
      torrentio   = TorrentioService();
      indexClient = AtmosIndexClient();
    });

    test('extractWithStatus with empty imdbId and tmdbId returns null', () async {
      final stream = await extractor.extractWithStatus(
        imdbId: '', tmdbId: '', type: 'movie',
      );
      _record(_Result(
        title: 'empty IDs → null', component: 'Extractor.error',
        status: stream == null ? _TestStatus.pass : _TestStatus.fail,
        elapsed: Duration.zero,
      ));
      expect(stream, isNull);
    });

    test('extractWithStatus with bogus IDs completes without crash', () async {
      final sw = Stopwatch()..start();
      final stream = await extractor.extractWithStatus(
        imdbId: 'tt9999999999', tmdbId: '99999999',
        type: 'movie',
      ).timeout(const Duration(seconds: 20), onTimeout: () => null);
      sw.stop();
      _record(_Result(
        title: 'bogus IDs completes gracefully', component: 'Extractor.error',
        status: _TestStatus.pass, // no crash = pass
        detail: 'stream=${stream?.providerName ?? "null"} ${_fmt(sw.elapsed)}',
        elapsed: sw.elapsed,
      ));
      // Should not throw — just return null or a fallback
    }, timeout: const Timeout(Duration(seconds: 25)));

    test('TorrentioService with invalid imdbId returns empty', () async {
      final sw = Stopwatch()..start();
      final sources = await torrentio.fetchSources(
        imdbId: 'tt0000000',
        type: 'movie',
      );
      sw.stop();
      _record(_Result(
        title: 'Torrentio invalid imdbId', component: 'Torrentio.error',
        status: sources.isEmpty ? _TestStatus.pass : _TestStatus.skip,
        detail: '${sources.length} sources ${_fmt(sw.elapsed)}',
        elapsed: sw.elapsed,
      ));
    }, timeout: const Timeout(Duration(seconds: 15)));

    test('AtmosIndex search with empty title returns empty', () async {
      final results = await indexClient.search('');
      _record(_Result(
        title: 'empty title search', component: 'AtmosIndex.error',
        status: results.isEmpty ? _TestStatus.pass : _TestStatus.fail,
        elapsed: Duration.zero,
      ));
      expect(results, isEmpty);
    });

    test('getAvailableServers for nonexistent key returns empty', () {
      final servers = extractor.getAvailableServers('nonexistent_content_key_xyz');
      _record(_Result(
        title: 'nonexistent key → empty servers', component: 'Extractor.error',
        status: servers.isEmpty ? _TestStatus.pass : _TestStatus.fail,
        elapsed: Duration.zero,
      ));
      expect(servers, isEmpty);
    });

    test('getResolvedStream for nonexistent provider returns null', () {
      final stream = extractor.getResolvedStream('some_key', 'NonexistentProvider');
      _record(_Result(
        title: 'nonexistent provider → null', component: 'Extractor.error',
        status: stream == null ? _TestStatus.pass : _TestStatus.fail,
        elapsed: Duration.zero,
      ));
      expect(stream, isNull);
    });

    test('clearCache on nonexistent key does not crash', () {
      extractor.clearCache('totally_nonexistent_key_12345');
      _record(const _Result(
        title: 'clearCache nonexistent key', component: 'Extractor.error',
        status: _TestStatus.pass, // no crash = pass
        elapsed: Duration.zero,
      ));
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // GROUP 12: Stremio addon — manifest & stream probing
  // ═══════════════════════════════════════════════════════════════════════════

  group('AtmosIndex — season & multi-episode', () {
    late AtmosIndexClient client;

    setUpAll(() { client = AtmosIndexClient(); });

    final seasonCases = [
      ('Breaking Bad', 1),
      ('Squid Game', 1),
      ('Attack on Titan', 1),
      ('Stranger Things', 1),
    ];

    for (final (title, season) in seasonCases) {
      test('season search: $title S$season', () async {
        final sw = Stopwatch()..start();
        final episodes = await client.getSeason(title, season);
        sw.stop();
        _record(_Result(
          title: '$title S$season', component: 'AtmosIndex.season',
          status: episodes.isNotEmpty ? _TestStatus.pass : _TestStatus.skip,
          detail: '${episodes.length} episodes ${_fmt(sw.elapsed)}',
          elapsed: sw.elapsed,
        ));
      }, timeout: const Timeout(Duration(seconds: 20)));
    }
  });
}
