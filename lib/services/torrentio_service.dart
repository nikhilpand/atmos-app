import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;
import 'stream_extractor_service.dart';

// ─── Torrentio + Webtor.io Stream Provider ───────────────────────────────────
//
// Flow:
//   1. Hit Torrentio REST API (Stremio Addon Protocol) → get infoHash list
//   2. Parse quality/codec/size from `title` field
//   3. Convert best infoHash → HTTP stream via Webtor.io proxy
//   4. Return ExtractedStream ready for media_kit playback
//
// No debrid required. No API key. 100% free.
// ─────────────────────────────────────────────────────────────────────────────

/// A single torrent source from Torrentio
class TorrentioSource {
  final String title;
  final String? infoHash;
  final int? fileIdx;
  final String? url; // direct URL if debrid-resolved (unused for free)
  final String quality;
  final String codec;
  final String audio;
  final String sizeLabel;
  final int seeders;
  final String provider; // e.g. "YTS", "1337x", "EZTV"

  const TorrentioSource({
    required this.title,
    this.infoHash,
    this.fileIdx,
    this.url,
    this.quality = 'HD',
    this.codec = '',
    this.audio = '',
    this.sizeLabel = '',
    this.seeders = 0,
    this.provider = '',
  });

  /// Parse the Torrentio title field to extract metadata.
  /// Format: "Torrentio\n1080p • WEB-DL • x265 • DDP5.1\n💾 2.1 GB ⚙️ YTS 👤 156"
  factory TorrentioSource.fromJson(Map<String, dynamic> json) {
    final rawTitle = json['title'] as String? ?? '';
    final lines = rawTitle.split('\n');

    String quality = 'HD';
    String codec = '';
    String audio = '';
    String sizeLabel = '';
    int seeders = 0;
    String provider = '';

    // Parse quality line (line 1 or 2)
    for (final line in lines) {
      final lower = line.toLowerCase();
      // Quality detection
      if (lower.contains('2160p') || lower.contains('4k')) {
        quality = '4K';
      } else if (lower.contains('1080p')) {
        quality = '1080p';
      } else if (lower.contains('720p')) {
        quality = '720p';
      } else if (lower.contains('480p')) {
        quality = '480p';
      }

      // Codec
      if (lower.contains('x265') || lower.contains('hevc') || lower.contains('h.265')) {
        codec = 'x265';
      } else if (lower.contains('x264') || lower.contains('h.264')) {
        codec = 'x264';
      } else if (lower.contains('av1')) {
        codec = 'AV1';
      }

      // Audio
      if (lower.contains('atmos')) {
        audio = 'Atmos';
      } else if (lower.contains('ddp5.1') || lower.contains('dd+5.1')) {
        audio = 'DDP5.1';
      } else if (lower.contains('dts-hd')) {
        audio = 'DTS-HD';
      } else if (lower.contains('aac')) {
        audio = 'AAC';
      }

      // Size (💾 2.1 GB)
      final sizeMatch = RegExp(r'(\d+\.?\d*)\s*(GB|MB)', caseSensitive: false).firstMatch(line);
      if (sizeMatch != null) {
        sizeLabel = '${sizeMatch.group(1)} ${sizeMatch.group(2)}';
      }

      // Seeders (👤 156)
      final seedMatch = RegExp(r'👤\s*(\d+)').firstMatch(line);
      if (seedMatch != null) {
        seeders = int.tryParse(seedMatch.group(1)!) ?? 0;
      }

      // Provider (⚙️ YTS)
      final provMatch = RegExp(r'⚙️\s*(\w+)').firstMatch(line);
      if (provMatch != null) {
        provider = provMatch.group(1)!;
      }
    }

    return TorrentioSource(
      title: rawTitle,
      infoHash: json['infoHash'] as String?,
      fileIdx: json['fileIdx'] as int?,
      url: json['url'] as String?,
      quality: quality,
      codec: codec,
      audio: audio,
      sizeLabel: sizeLabel,
      seeders: seeders,
      provider: provider,
    );
  }

  /// Sort score: higher = better (prefer 1080p, high seeders, x265)
  /// NOTE: 4K is excluded — capped at 1080p per user preference.
  int get sortScore {
    int score = seeders;
    // 4K intentionally scores lower than 1080p — cap quality at 1080p
    if (quality == '4K') score += 500;
    if (quality == '1080p') score += 2000;
    if (quality == '720p') score += 1000;
    if (codec == 'x265') score += 500; // smaller files, prefer for streaming
    if (audio == 'Atmos' || audio == 'DDP5.1') score += 200;
    return score;
  }

  /// File size in bytes parsed from sizeLabel (e.g. "2.1 GB" → 2255xxxxxx)
  double get sizeGB {
    final m = RegExp(r'(\d+\.?\d*)\s*(GB|MB)', caseSensitive: false).firstMatch(sizeLabel);
    if (m == null) return 0;
    final val = double.tryParse(m.group(1)!) ?? 0;
    return m.group(2)!.toUpperCase() == 'GB' ? val : val / 1024;
  }

  /// True if this file is within the 3 GB streaming size limit
  bool get isWithinSizeLimit => sizeGB == 0 || sizeGB <= 3.0;

  @override
  String toString() => 'TorrentioSource($quality $codec $audio, seeds:$seeders, $provider)';
}

// ─── Service ─────────────────────────────────────────────────────────────────

class TorrentioService {
  static const _torrentioBase = 'https://torrentio.strem.fun';
  static const _ua = 'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36';
  static const _timeout = Duration(seconds: 8);

  /// Fetch torrent sources from Torrentio for a movie or episode.
  /// Tries the Cloudflare worker proxy first (avoids mobile CORS), then direct API.
  Future<List<TorrentioSource>> fetchSources({
    required String imdbId,
    required String type, // 'movie' or 'tv'
    int season = 1,
    int episode = 1,
  }) async {
    if (imdbId.isEmpty) return [];

    // Try via Cloudflare worker proxy first (avoids CORS + mobile network blocks)
    final workerUrl = dotenv.env['EXTRACTOR_WORKER_URL'] ?? '';
    if (workerUrl.isNotEmpty) {
      try {
        final params = <String, String>{
          'imdb': imdbId,
          'type': type == 'tv' ? 'series' : 'movie',
          if (type == 'tv') 'season': '$season',
          if (type == 'tv') 'episode': '$episode',
        };
        final uri = Uri.parse('$workerUrl/torrentio/streams').replace(queryParameters: params);
        final res = await http.get(uri, headers: {'User-Agent': _ua}).timeout(_timeout);
        if (res.statusCode == 200) {
          final body = jsonDecode(res.body) as Map<String, dynamic>;
          final streams = body['streams'] as List? ?? [];
          final sources = streams
              .map((s) => TorrentioSource.fromJson(s as Map<String, dynamic>))
              .where((s) => s.infoHash != null && s.infoHash!.isNotEmpty)
              .toList()
            ..sort((a, b) => b.sortScore.compareTo(a.sortScore));
          if (sources.isNotEmpty) {
            debugPrint('[Torrentio] Found ${sources.length} sources via worker proxy for $imdbId');
            return sources;
          }
        }
      } catch (e) {
        debugPrint('[Torrentio] Worker proxy failed, trying direct: $e');
      }
    }

    // Fallback: direct Torrentio API call
    final String endpoint;
    if (type == 'movie') {
      endpoint = '$_torrentioBase/stream/movie/$imdbId.json';
    } else {
      endpoint = '$_torrentioBase/stream/series/$imdbId:$season:$episode.json';
    }

    try {
      final res = await http.get(
        Uri.parse(endpoint),
        headers: { 'User-Agent': _ua, 'Accept': 'application/json' },
      ).timeout(_timeout);

      if (res.statusCode != 200) {
        debugPrint('[Torrentio] HTTP ${res.statusCode} for $endpoint');
        return [];
      }

      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final streams = body['streams'] as List? ?? [];

      final sources = streams
          .map((s) => TorrentioSource.fromJson(s as Map<String, dynamic>))
          .where((s) => s.infoHash != null && s.infoHash!.isNotEmpty)
          .toList()
        ..sort((a, b) => b.sortScore.compareTo(a.sortScore));

      debugPrint('[Torrentio] Found ${sources.length} sources (direct) for $imdbId');
      return sources;
    } catch (e) {
      debugPrint('[Torrentio] Error: $e');
      return [];
    }
  }

  /// Convert a torrent infoHash → streamable HTTP URL via Webtor.io.
  ///
  /// Webtor.io acts as a free torrent→HTTP proxy. It downloads the torrent
  /// server-side and serves it as a standard HTTP stream — no P2P on device,
  /// no IP exposure, no VPN needed.
  Future<String?> resolveStreamUrl(
    String infoHash, {
    int fileIdx = 0,
    String? filename,
  }) async {
    if (infoHash.isEmpty) return null;

    // Webtor CDN mirrors — try each until one works
    const mirrors = [
      'https://dq4w8c.webtor.io',
      'https://hx22fl.webtor.io',
      'https://webtor.io',
    ];

    const trackers =
        '&tr=udp%3A%2F%2Ftracker.opentrackr.org%3A1337%2Fannounce'
        '&tr=udp%3A%2F%2Fopen.stealth.si%3A80%2Fannounce'
        '&tr=udp%3A%2F%2Ftracker.torrent.eu.org%3A451%2Fannounce';

    final magnetUrl = 'magnet:?xt=urn:btih:$infoHash$trackers';

    for (final mirror in mirrors) {
      try {
        // Strategy 1: Direct stream URL with magnet
        final encodedMagnet = Uri.encodeComponent(magnetUrl);
        final streamUrl = '$mirror/stream?magnet=$encodedMagnet&file_index=$fileIdx';

        // Validate the URL actually responds before returning
        final headRes = await http.head(
          Uri.parse(streamUrl),
          headers: {'User-Agent': _ua, 'Range': 'bytes=0-0'},
        ).timeout(const Duration(seconds: 6));

        if (headRes.statusCode == 200 || headRes.statusCode == 206) {
          debugPrint('[Webtor] ✅ Stream validated via $mirror');
          return streamUrl;
        }

        // Strategy 2: Try embed page and parse actual video src
        final embedUrl = '$mirror/embed/$infoHash';
        final embedRes = await http.get(
          Uri.parse(embedUrl),
          headers: {'User-Agent': _ua},
        ).timeout(const Duration(seconds: 6));

        if (embedRes.statusCode == 200) {
          // Parse video source from the embed page
          final srcMatch = RegExp(r'(https?://[^\s"<>]+(?:\.mp4|\.mkv|\.avi|/stream)[^\s"<>]*)').firstMatch(embedRes.body);
          if (srcMatch != null) {
            debugPrint('[Webtor] ✅ Stream extracted from embed page via $mirror');
            return srcMatch.group(1);
          }
        }
      } catch (e) {
        debugPrint('[Webtor] Mirror $mirror failed: $e');
      }
    }

    // Final fallback: construct URL with first mirror (may need seeding time)
    final fallbackUrl = '${mirrors[0]}/stream?magnet=${Uri.encodeComponent(magnetUrl)}&file_index=$fileIdx';
    debugPrint('[Webtor] ⚠️ Using unvalidated fallback URL');
    return fallbackUrl;
  }

  /// Full extraction: Torrentio → best source → Webtor.io → ExtractedStream
  /// Caps quality at 1080p and file size at 3 GB.
  Future<ExtractedStream?> extractStream({
    required String imdbId,
    required String type,
    int season = 1,
    int episode = 1,
    String? qualityFilter,
  }) async {
    // 1. Get sources from Torrentio
    final sources = await fetchSources(
      imdbId: imdbId,
      type: type,
      season: season,
      episode: episode,
    );
    if (sources.isEmpty) return null;

    // 2. Hard cap: exclude 4K and files >3 GB (streaming platform, not downloader)
    var candidates = sources
        .where((s) => s.quality != '4K' && s.isWithinSizeLimit)
        .toList();

    // 3. If no candidates within limits, relax size (but keep quality cap)
    if (candidates.isEmpty) {
      candidates = sources.where((s) => s.quality != '4K').toList();
    }
    if (candidates.isEmpty) candidates = sources;

    // 4. Apply optional quality filter
    if (qualityFilter != null && qualityFilter != '4K') {
      final filtered = candidates.where((s) =>
          s.quality.toLowerCase().contains(qualityFilter.toLowerCase())).toList();
      if (filtered.isNotEmpty) candidates = filtered;
    }

    // 5. Re-sort by score (4K already penalised, size-limited already filtered)
    candidates.sort((a, b) => b.sortScore.compareTo(a.sortScore));

    debugPrint('[Torrentio] ${candidates.length} candidates (≤1080p ≤3GB) for $imdbId');

    // 6. Try top 5 sources (webtor can be flaky)
    for (final source in candidates.take(5)) {
      final filename = (source.title.split('\n')
          .skip(1)
          .firstWhere((l) => l.trim().isNotEmpty && !l.contains('👤') && !l.contains('💾'), orElse: () => ''));

      final streamUrl = await resolveStreamUrl(
        source.infoHash!,
        fileIdx: source.fileIdx ?? 0,
        filename: filename.trim().isNotEmpty ? filename.trim() : null,
      );

      if (streamUrl != null && streamUrl.isNotEmpty) {
        debugPrint('[Torrentio] ✅ Resolved: ${source.quality} ${source.codec} ${source.sizeGB.toStringAsFixed(1)}GB → $streamUrl');
        return ExtractedStream(
          url: streamUrl,
          headers: {'User-Agent': _ua},
          providerName: 'Torrentio/${source.provider} (${source.quality})',
          subtitles: const [],
          qualities: [
            QualityOption(quality: '${source.quality} ${source.sizeLabel}', url: streamUrl),
          ],
        );
      }
    }

    debugPrint('[Torrentio] Failed to resolve any stream URL');
    return null;
  }

}
