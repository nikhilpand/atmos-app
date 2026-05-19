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
  int get sortScore {
    int score = seeders;
    if (quality == '4K') score += 3000;
    if (quality == '1080p') score += 2000;
    if (quality == '720p') score += 1000;
    if (codec == 'x265') score += 500; // smaller files
    if (audio == 'Atmos' || audio == 'DDP5.1') score += 200;
    return score;
  }

  @override
  String toString() => 'TorrentioSource($quality $codec $audio, seeds:$seeders, $provider)';
}

// ─── Service ─────────────────────────────────────────────────────────────────

class TorrentioService {
  static const _torrentioBase = 'https://torrentio.strem.fun';
  static const _webtorBase = 'https://webtor.io';
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
  Future<String?> resolveStreamUrl(String infoHash, {int fileIdx = 0}) async {
    if (infoHash.isEmpty) return null;

    try {
      // Webtor.io embed endpoint — returns an HTML page with the stream URL
      // We parse the actual video source from the page
      final magnetUrl = 'magnet:?xt=urn:btih:$infoHash'
          '&tr=udp%3A%2F%2Ftracker.opentrackr.org%3A1337%2Fannounce'
          '&tr=udp%3A%2F%2Fopen.stealth.si%3A80%2Fannounce'
          '&tr=udp%3A%2F%2Ftracker.torrent.eu.org%3A451%2Fannounce';

      final encodedMagnet = Uri.encodeComponent(magnetUrl);

      // Try the Webtor REST API for direct stream
      final apiUrl = '$_webtorBase/api/magnet/$infoHash';
      final res = await http.get(
        Uri.parse(apiUrl),
        headers: {'User-Agent': _ua},
      ).timeout(const Duration(seconds: 10));

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        // Look for video file in the response
        if (data is Map && data.containsKey('url')) {
          return data['url'] as String;
        }
        // Alternative: list of files
        if (data is List && data.isNotEmpty) {
          final videoFile = data.firstWhere(
            (f) => _isVideoFile(f['name'] ?? ''),
            orElse: () => data[fileIdx < data.length ? fileIdx : 0],
          );
          return videoFile['url'] as String?;
        }
      }

      // Fallback: construct the Webtor embed stream URL directly
      // This is the pattern Webtor uses for magnet streaming
      final streamUrl =
          '$_webtorBase/stream?magnet=$encodedMagnet&file_index=$fileIdx';
      return streamUrl;
    } catch (e) {
      debugPrint('[Webtor] Stream resolve error: $e');
      return null;
    }
  }

  /// Full extraction: Torrentio → best source → Webtor.io → ExtractedStream
  Future<ExtractedStream?> extractStream({
    required String imdbId,
    required String type,
    int season = 1,
    int episode = 1,
    String? qualityFilter, // '1080p', '4K', '720p' — null = best available
  }) async {
    // 1. Get sources from Torrentio
    final sources = await fetchSources(
      imdbId: imdbId,
      type: type,
      season: season,
      episode: episode,
    );
    if (sources.isEmpty) return null;

    // 2. Filter by quality if specified
    List<TorrentioSource> candidates = sources;
    if (qualityFilter != null) {
      candidates = sources.where((s) {
        final q = qualityFilter.toLowerCase();
        return s.quality.toLowerCase().contains(q);
      }).toList();
      if (candidates.isEmpty) candidates = sources; // fallback to all
    }

    // 3. Try top 3 sources (in case first Webtor resolve fails)
    for (final source in candidates.take(3)) {
      final streamUrl = await resolveStreamUrl(
        source.infoHash!,
        fileIdx: source.fileIdx ?? 0,
      );

      if (streamUrl != null && streamUrl.isNotEmpty) {
        debugPrint('[Torrentio] Resolved: ${source.quality} ${source.codec} → $streamUrl');
        return ExtractedStream(
          url: streamUrl,
          headers: {'User-Agent': _ua},
          providerName: 'Torrentio (${source.provider})',
          subtitles: const [],
          qualities: [
            QualityOption(quality: source.quality, url: streamUrl),
          ],
        );
      }
    }

    debugPrint('[Torrentio] Failed to resolve any stream URL');
    return null;
  }

  bool _isVideoFile(String name) {
    final lower = name.toLowerCase();
    return lower.endsWith('.mp4') ||
        lower.endsWith('.mkv') ||
        lower.endsWith('.avi') ||
        lower.endsWith('.webm');
  }
}
