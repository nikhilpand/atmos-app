import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/download_model.dart';

/// Multi-source torrent search engine.
///
/// **Primary**: Torrentio (Stremio addon) — aggregates 20+ indexers (1337x,
/// ThePirateBay, MagnetDL, TorrentGalaxy, EZTV, etc.) into a single JSON API.
/// Not blocked by ISPs because it runs on Stremio's CDN infrastructure.
///
/// **Fallback**: YTS API (for movies only — often ISP-blocked in India).
class TorrentSearchService {
  // ── Torrentio ─────────────────────────────────────────────────────────────
  // Stremio addon — the real workhorse. Returns up to 100 sources per title.
  // Docs: https://torrentio.strem.fun/configure
  //
  // Stream endpoint format:
  //   /stream/movie/{imdbId}.json
  //   /stream/series/{imdbId}:{season}:{episode}.json
  //
  // Each result has: name, title, infoHash, fileIdx, behaviorHints.filename
  // The `title` field contains release name, seeders (👤), size (💾), indexer (⚙️)
  // The `name` field contains quality tier (e.g. "Torrentio\n4k DV | HDR")

  // Configure Torrentio to prioritize 1337x and ThePirateBay, sort by quality then size, and filter out 4K/cam
  static const _torrentioBase = 'https://torrentio.strem.fun/providers=1337x,thepiratebay,torrentgalaxy,magnetdl,eztv,yts|sort=qualitysize|qualityfilter=4k,scr,cam';

  // ── YTS (fallback, often ISP-blocked) ─────────────────────────────────────
  static const _ytsBase = 'https://yts.mx/api/v2';

  // ── Knaben (multi-indexer, rarely blocked) ─────────────────────────────────
  // Aggregates 1337x, RuTracker, RARBG archive, TorrentGalaxy, and 15+ more.
  // Supports IMDB ID search → very accurate for movies & TV.
  static const _knabenBase = 'https://knaben.eu/api';

  // ── BTDigg (DHT crawler, title-based, no IMDB) ────────────────────────────
  // Indexes ~3B torrents from the DHT network. Good last-resort for niche content.
  static const _btdiggBase = 'https://btdigg.org/api';

  // Well-known public trackers appended to every magnet
  static const _trackers = [
    'udp://tracker.opentrackr.org:1337/announce',
    'udp://tracker.openbittorrent.com:6969/announce',
    'udp://open.stealth.si:80/announce',
    'udp://tracker.torrent.eu.org:451/announce',
    'udp://exodus.desync.com:6969/announce',
    'udp://tracker.tiny-vps.com:6969/announce',
  ];

  // ════════════════════════════════════════════════════════════════════════════
  // PUBLIC API
  // ════════════════════════════════════════════════════════════════════════════

  /// Search for movie downloads by IMDB ID.
  /// Cascade: Torrentio → Knaben → YTS
  Future<List<QualityOption>> searchMovie(String imdbId) async {
    final cleanId = _normalizeImdbId(imdbId);
    if (cleanId.isEmpty) return [];

    // 1) Primary: Torrentio (fast, not blocked)
    var results = await _searchTorrentio('movie', cleanId);
    if (results.isNotEmpty) return results;

    // 2) Fallback: Knaben multi-indexer
    results = await _searchKnaben(cleanId, isMovie: true);
    if (results.isNotEmpty) return results;

    // 3) Last resort: YTS
    return _searchYts(cleanId);
  }

  /// Search for TV episode downloads.
  /// Cascade: Torrentio → Knaben
  Future<List<QualityOption>> searchEpisode(
      String imdbId, int season, int episode) async {
    final cleanId = _normalizeImdbId(imdbId);
    if (cleanId.isEmpty) return [];

    // 1) Primary: Torrentio
    var results = await _searchTorrentio('series', '$cleanId:$season:$episode');
    if (results.isNotEmpty) return results;

    // 2) Fallback: Knaben
    return _searchKnaben(cleanId, isMovie: false, season: season, episode: episode);
  }

  /// Title-based search (no IMDB required) — uses Knaben + BTDigg.
  /// Useful when IMDB ID is absent or for Telegram source verification.
  Future<List<QualityOption>> searchByTitle(
    String title, {
    bool isMovie = true,
    int? season,
    int? episode,
  }) async {
    final query = season != null
        ? '$title S${season.toString().padLeft(2, '0')}E${episode.toString().padLeft(2, '0')}'
        : title;

    final results = await Future.wait([
      _searchKnabenByTitle(query),
      _searchBtdigg(query),
    ]);

    final seen = <String>{};
    final merged = <QualityOption>[];
    for (final list in results) {
      for (final q in list) {
        if (q.hash.isNotEmpty && seen.add(q.hash)) merged.add(q);
      }
    }
    merged.sort(_qualitySort);
    return merged.take(20).toList();
  }

  // ════════════════════════════════════════════════════════════════════════════
  // TORRENTIO
  // ════════════════════════════════════════════════════════════════════════════

  Future<List<QualityOption>> _searchTorrentio(
      String type, String idPath) async {
    try {
      final uri = Uri.parse('$_torrentioBase/stream/$type/$idPath.json');
      final res = await http.get(uri, headers: {
        'User-Agent': 'Atmos/2.0',
      }).timeout(const Duration(seconds: 12));

      if (res.statusCode != 200) {
        print('[TorrentSearch] Torrentio HTTP ${res.statusCode}');
        return [];
      }

      final json = jsonDecode(res.body) as Map<String, dynamic>;
      final streams = json['streams'] as List<dynamic>? ?? [];
      if (streams.isEmpty) return [];

      final options = <QualityOption>[];
      final seenHashes = <String>{};

      for (final s in streams) {
        final sMap = s as Map<String, dynamic>;
        final infoHash = (sMap['infoHash'] as String?) ?? '';
        if (infoHash.isEmpty || !seenHashes.add(infoHash)) continue;

        final name = (sMap['name'] as String?) ?? '';
        final title = (sMap['title'] as String?) ?? '';
        final hints = sMap['behaviorHints'] as Map<String, dynamic>?;
        final filename = hints?['filename'] as String? ?? '';

        // Parse quality from the `name` field (e.g. "Torrentio\n4k DV | HDR")
        final quality = _parseTorrentioQuality(name, title, filename);

        // Parse seeders and file size from the `title` field
        final seeders = _parseSeeders(title);
        final sizeBytes = _parseSizeBytes(title);
        final source = _parseSource(title);

        // Parse codec info from filename/title
        final videoCodec = _parseVideoCodec(filename.isNotEmpty ? filename : title);
        final audioChannels = _parseAudioChannels(filename.isNotEmpty ? filename : title);

        // Skip very low-seed torrents (likely dead) or impossibly large files for mobile (30GB+)
        if (seeders < 1) continue;
        if (sizeBytes > 30 * 1024 * 1024 * 1024) continue;

        options.add(QualityOption(
          quality: quality,
          hash: infoHash,
          sizeBytes: sizeBytes,
          type: source,
          videoCodec: videoCodec,
          audioChannels: audioChannels,
          source: 'torrent',
          seeders: seeders,
          fileName: filename.isNotEmpty ? filename : title,
        ));
      }

      // Sort: highest quality first, then by seeders
      options.sort(_qualitySort);

      // Limit to top 20 to keep the picker manageable
      return options.take(20).toList();
    } catch (e) {
      print('[TorrentSearch] Torrentio error: $e');
      return [];
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // KNABEN (multi-indexer)
  // ═══════════════════════════════════════════════════════════════════════════

  Future<List<QualityOption>> _searchKnaben(
    String imdbId, {
    required bool isMovie,
    int? season,
    int? episode,
  }) async {
    try {
      final query = season != null
          ? '$imdbId S${season.toString().padLeft(2, '0')}E${episode.toString().padLeft(2, '0')}'
          : imdbId;
      final uri = Uri.parse('$_knabenBase/search').replace(queryParameters: {
        'q': query,
        'categories': isMovie ? '201,207' : '205,208', // Knaben category codes
        'limit': '20',
        'sort': 'seeders',
        'order': 'desc',
      });
      final res = await http.get(uri, headers: {'User-Agent': 'Atmos/2.0'})
          .timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return [];

      final json = jsonDecode(res.body);
      final hits = (json['hits'] as List?) ?? [];
      final options = <QualityOption>[];
      final seen = <String>{};

      for (final h in hits) {
        final hash = (h['infoHash'] as String? ?? '').toLowerCase();
        if (hash.isEmpty || !seen.add(hash)) continue;
        final name = (h['name'] as String?) ?? '';
        final seeders = (h['seeders'] as int?) ?? 0;
        if (seeders < 1) continue;
        options.add(QualityOption(
          quality: _parseTorrentioQuality(name, name, name),
          hash: hash,
          sizeBytes: (h['size'] as int?) ?? 0,
          type: 'knaben',
          videoCodec: _parseVideoCodec(name),
          audioChannels: _parseAudioChannels(name),
          source: 'torrent',
          seeders: seeders,
          fileName: name,
        ));
      }
      options.sort(_qualitySort);
      return options.take(20).toList();
    } catch (_) { return []; }
  }

  Future<List<QualityOption>> _searchKnabenByTitle(String title) async {
    return _searchKnaben(title, isMovie: true);
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // BTDigg (DHT crawler)
  // ═══════════════════════════════════════════════════════════════════════════

  Future<List<QualityOption>> _searchBtdigg(String title) async {
    try {
      final uri = Uri.parse('$_btdiggBase/search').replace(queryParameters: {
        'q': title,
        'p': '0',
      });
      final res = await http.get(uri, headers: {'User-Agent': 'Atmos/2.0'})
          .timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return [];

      final json = jsonDecode(res.body);
      final results = (json['results'] as List?) ?? [];
      final options = <QualityOption>[];
      final seen = <String>{};

      for (final r in results) {
        final hash = (r['ih'] as String? ?? '').toLowerCase();
        if (hash.isEmpty || !seen.add(hash)) continue;
        final name = (r['name'] as String?) ?? '';
        options.add(QualityOption(
          quality: _parseTorrentioQuality(name, name, name),
          hash: hash,
          sizeBytes: _parseRawSize(r['size'] as String? ?? ''),
          type: 'btdigg',
          videoCodec: _parseVideoCodec(name),
          audioChannels: _parseAudioChannels(name),
          source: 'torrent',
          seeders: 0,
          fileName: name,
        ));
      }
      options.sort(_qualitySort);
      return options.take(10).toList();
    } catch (_) { return []; }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // YTS (FALLBACK)
  // ═══════════════════════════════════════════════════════════════════════════

  Future<List<QualityOption>> _searchYts(String imdbId) async {
    try {
      final uri = Uri.parse(
        '$_ytsBase/list_movies.json?query_term=${Uri.encodeComponent(imdbId)}&limit=1',
      );
      final res = await http.get(uri).timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return [];

      final json = jsonDecode(res.body) as Map<String, dynamic>;
      final data = json['data'] as Map<String, dynamic>?;
      final movies = data?['movies'] as List<dynamic>?;
      if (movies == null || movies.isEmpty) return [];

      final movie = movies.first as Map<String, dynamic>;
      final torrents = movie['torrents'] as List<dynamic>? ?? [];

      return torrents.map((t) {
        final tMap = t as Map<String, dynamic>;
        final quality = tMap['quality'] as String? ?? 'unknown';
        final type = tMap['type'] as String? ?? '';
        final hash = tMap['hash'] as String? ?? '';
        final sizeMb = (tMap['size_bytes'] as int?) ?? 0;
        return QualityOption(
          quality: type.isNotEmpty ? '$quality.$type' : quality,
          hash: hash,
          sizeBytes: sizeMb,
          type: type,
          videoCodec: tMap['video_codec'] as String?,
          audioChannels: tMap['audio_channels'] as String?,
          fileName: movie['title_long'] as String? ?? 'YTS Release',
        );
      }).where((q) => q.hash.isNotEmpty).toList()
        ..sort(_qualitySort);
    } catch (_) { return []; }
  }

  // ════════════════════════════════════════════════════════════════════════════
  // PARSERS
  // ════════════════════════════════════════════════════════════════════════════

  String _normalizeImdbId(String id) {
    // If already starts with "tt", return as is
    if (id.startsWith('tt')) return id;
    // If it's just digits, prefix with "tt"
    if (RegExp(r'^\d+$').hasMatch(id)) return 'tt$id';
    // Otherwise return empty (can't search without IMDB ID)
    return '';
  }

  /// Parse quality from Torrentio's `name` field.
  /// Examples: "Torrentio\n4k DV | HDR", "Torrentio\n1080p", "Torrentio\n720p"
  String _parseTorrentioQuality(String name, String title, String filename) {
    final combined = '$name $title $filename'.toUpperCase();

    if (combined.contains('2160P') || combined.contains('4K') || combined.contains('UHD')) {
      // Check for HDR variants
      if (combined.contains('DV') || combined.contains('DOLBY VISION')) {
        if (combined.contains('HDR')) return '4K DV+HDR';
        return '4K DV';
      }
      if (combined.contains('HDR10+') || combined.contains('HDR10PLUS')) return '4K HDR10+';
      if (combined.contains('HDR')) return '4K HDR';
      return '4K';
    }
    if (combined.contains('1080P')) {
      if (combined.contains('REMUX')) return '1080p Remux';
      if (combined.contains('BLURAY') || combined.contains('BLU-RAY')) return '1080p BluRay';
      if (combined.contains('WEB-DL') || combined.contains('WEBDL')) return '1080p WEB-DL';
      return '1080p';
    }
    if (combined.contains('720P')) return '720p';
    if (combined.contains('480P')) return '480p';
    if (combined.contains('REMUX')) return 'Remux';
    return 'Unknown';
  }

  /// Parse seeders from title: "👤 76"
  int _parseSeeders(String title) {
    final match = RegExp(r'👤\s*(\d+)').firstMatch(title);
    return int.tryParse(match?.group(1) ?? '') ?? 0;
  }

  /// Parse file size from title: "💾 3.46 GB" or "💾 850 MB"
  int _parseSizeBytes(String title) {
    final match = RegExp(r'💾\s*([\d.]+)\s*(GB|MB|TB)', caseSensitive: false)
        .firstMatch(title);
    if (match == null) return 0;

    final value = double.tryParse(match.group(1)!) ?? 0;
    final unit = match.group(2)!.toUpperCase();
    switch (unit) {
      case 'TB':
        return (value * 1024 * 1024 * 1024 * 1024).round();
      case 'GB':
        return (value * 1024 * 1024 * 1024).round();
      case 'MB':
        return (value * 1024 * 1024).round();
      default:
        return 0;
    }
  }

  /// Parse source/indexer from title: "⚙️ 1337x"
  String _parseSource(String title) {
    final match = RegExp(r'⚙️\s*(\S+)').firstMatch(title);
    return match?.group(1) ?? '';
  }

  /// Parse video codec from filename/title
  String? _parseVideoCodec(String text) {
    final t = text.toUpperCase();
    if (t.contains('X265') || t.contains('H.265') || t.contains('H265') || t.contains('HEVC')) {
      return 'HEVC (x265)';
    }
    if (t.contains('X264') || t.contains('H.264') || t.contains('H264') || t.contains('AVC')) {
      return 'AVC (x264)';
    }
    if (t.contains('AV1')) return 'AV1';
    if (t.contains('VP9')) return 'VP9';
    return null;
  }

  /// Parse audio from filename/title
  String? _parseAudioChannels(String text) {
    final t = text.toUpperCase();
    if (t.contains('ATMOS')) return 'Atmos';
    if (t.contains('TRUEHD')) return 'TrueHD';
    if (t.contains('DTS-HD')) return 'DTS-HD MA';
    if (t.contains('DTS')) return 'DTS';
    if (t.contains('DD+') || t.contains('DDP') || t.contains('EAC3')) return 'DD+';
    if (t.contains('AC3') || t.contains('DD5') || t.contains('DD 5')) return 'DD 5.1';
    if (t.contains('AAC')) return 'AAC';
    if (t.contains('7.1')) return '7.1ch';
    if (t.contains('5.1')) return '5.1ch';
    return null;
  }

  /// Sort by quality tier (best first), then by seeders (most first)
  int _qualitySort(QualityOption a, QualityOption b) {
    final aOrd = _qualityOrder(a.quality);
    final bOrd = _qualityOrder(b.quality);
    if (aOrd != bOrd) return aOrd.compareTo(bOrd);
    // Same quality tier — prefer more seeders (approximated by size for now)
    return b.sizeBytes.compareTo(a.sizeBytes);
  }

  int _qualityOrder(String quality) {
    final q = quality.toLowerCase();
    if (q.contains('1080')) {
      if (q.contains('remux')) return 0;
      if (q.contains('bluray')) return 1;
      return 2;
    }
    if (q.contains('4k') || q.contains('2160')) {
      if (q.contains('remux')) return 3;
      if (q.contains('dv')) return 4;
      if (q.contains('hdr')) return 5;
      return 6;
    }
    if (q.contains('720')) return 7;
    if (q.contains('480')) return 8;
    return 99;
  }

  /// Parse a raw size string like "1.4 GB" or "850 MB" to bytes.
  /// Used by BTDigg which returns sizes as human-readable strings.
  int _parseRawSize(String raw) {
    final match = RegExp(r'([\d.]+)\s*(TB|GB|MB|KB)', caseSensitive: false)
        .firstMatch(raw.trim());
    if (match == null) return 0;
    final value = double.tryParse(match.group(1)!) ?? 0;
    switch (match.group(2)!.toUpperCase()) {
      case 'TB': return (value * 1024 * 1024 * 1024 * 1024).round();
      case 'GB': return (value * 1024 * 1024 * 1024).round();
      case 'MB': return (value * 1024 * 1024).round();
      case 'KB': return (value * 1024).round();
      default:   return 0;
    }
  }
}
