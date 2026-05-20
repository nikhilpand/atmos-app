import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'stream_extractor_service.dart';
import 'torrentio_service.dart';

// ─── Generic Stremio Addon Client ────────────────────────────────────────────
//
// All Stremio addons use the same REST API protocol:
//   GET {baseUrl}/stream/{type}/{videoId}.json
//
// This single client can talk to ANY addon:
//   - Torrentio, MediaFusion, Comet, AIOStreams, etc.
//
// Addons return: { "streams": [{ "title": "...", "url": "...", "infoHash": "..." }] }
// ─────────────────────────────────────────────────────────────────────────────

/// A single stream from any Stremio addon
class StremioStream {
  final String name;
  final String title;
  final String? url;
  final String? infoHash;
  final int? fileIdx;
  final Map<String, dynamic>? behaviorHints;

  const StremioStream({
    required this.name,
    required this.title,
    this.url,
    this.infoHash,
    this.fileIdx,
    this.behaviorHints,
  });

  factory StremioStream.fromJson(Map<String, dynamic> json) {
    return StremioStream(
      name: json['name'] as String? ?? '',
      title: json['title'] as String? ?? '',
      url: json['url'] as String?,
      infoHash: json['infoHash'] as String?,
      fileIdx: json['fileIdx'] as int?,
      behaviorHints: json['behaviorHints'] as Map<String, dynamic>?,
    );
  }

  /// Whether this stream has a direct HTTP(S) URL (no torrent needed)
  bool get isDirectStream =>
      url != null && (url!.startsWith('http://') || url!.startsWith('https://'));

  /// Whether this is a torrent source (needs proxy to stream)
  bool get isTorrent => infoHash != null && infoHash!.isNotEmpty;

  /// Construct the standard magnet URL for this torrent stream
  String? get magnetUrl {
    if (infoHash == null || infoHash!.isEmpty) return null;
    const trackers =
        '&tr=udp%3A%2F%2Ftracker.opentrackr.org%3A1337%2Fannounce'
        '&tr=udp%3A%2F%2Fopen.stealth.si%3A80%2Fannounce'
        '&tr=udp%3A%2F%2Ftracker.torrent.eu.org%3A451%2Fannounce';
    return 'magnet:?xt=urn:btih:$infoHash$trackers';
  }

  /// Parse quality from title string
  String get quality {
    final lower = title.toLowerCase();
    if (lower.contains('2160p') || lower.contains('4k')) return '4K';
    if (lower.contains('1080p')) return '1080p';
    if (lower.contains('720p')) return '720p';
    if (lower.contains('480p')) return '480p';
    return 'HD';
  }

  @override
  String toString() => 'StremioStream($name, $quality, direct:$isDirectStream)';
}

/// Configuration for a Stremio addon
class StremioAddon {
  final String name;
  final String baseUrl;
  final bool supportsMovies;
  final bool supportsSeries;

  const StremioAddon({
    required this.name,
    required this.baseUrl,
    this.supportsMovies = true,
    this.supportsSeries = true,
  });
}

// ─── Pre-configured Free Addons ──────────────────────────────────────────────

/// Free Stremio addons — no debrid, no API key needed
const kFreeStremioAddons = <StremioAddon>[
  StremioAddon(
    name: 'MediaFusion',
    baseUrl: 'https://mediafusion.elfhosted.com',
  ),
];

// ─── Service ─────────────────────────────────────────────────────────────────

class StremioAddonService {
  static const _ua = 'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36';
  static const _timeout = Duration(seconds: 8);

  final List<StremioAddon> addons;

  StremioAddonService({List<StremioAddon>? customAddons})
      : addons = customAddons ?? kFreeStremioAddons;

  /// Fetch streams from a specific addon
  Future<List<StremioStream>> fetchStreams({
    required StremioAddon addon,
    required String imdbId,
    required String type,
    int season = 1,
    int episode = 1,
  }) async {
    if (imdbId.isEmpty) return [];

    final String videoId;
    final String contentType;

    if (type == 'movie') {
      videoId = imdbId;
      contentType = 'movie';
    } else {
      videoId = '$imdbId:$season:$episode';
      contentType = 'series';
    }

    final endpoint = '${addon.baseUrl}/stream/$contentType/$videoId.json';

    try {
      final res = await http.get(
        Uri.parse(endpoint),
        headers: {
          'User-Agent': _ua,
          'Accept': 'application/json',
        },
      ).timeout(_timeout);

      if (res.statusCode != 200) {
        debugPrint('[Stremio:${addon.name}] HTTP ${res.statusCode}');
        return [];
      }

      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final streams = (body['streams'] as List? ?? [])
          .map((s) => StremioStream.fromJson(s as Map<String, dynamic>))
          .toList();

      debugPrint('[Stremio:${addon.name}] Found ${streams.length} streams for $imdbId');
      return streams;
    } catch (e) {
      debugPrint('[Stremio:${addon.name}] Error: $e');
      return [];
    }
  }

  /// Fetch streams from ALL configured addons in parallel
  Future<List<StremioStream>> fetchFromAll({
    required String imdbId,
    required String type,
    int season = 1,
    int episode = 1,
  }) async {
    final futures = addons.map((addon) => fetchStreams(
          addon: addon,
          imdbId: imdbId,
          type: type,
          season: season,
          episode: episode,
        ));

    final results = await Future.wait(futures);
    final allStreams = <StremioStream>[];
    for (final list in results) {
      allStreams.addAll(list);
    }

    // Prioritize direct streams over torrents
    allStreams.sort((a, b) {
      if (a.isDirectStream && !b.isDirectStream) return -1;
      if (!a.isDirectStream && b.isDirectStream) return 1;
      return 0;
    });

    return allStreams;
  }

  /// Extract best stream as an ExtractedStream for the player
  Future<ExtractedStream?> extractBestStream({
    required String imdbId,
    required String type,
    int season = 1,
    int episode = 1,
  }) async {
    final streams = await fetchFromAll(
      imdbId: imdbId,
      type: type,
      season: season,
      episode: episode,
    );

    // 1. Prefer direct HTTP streams
    for (final stream in streams) {
      if (stream.isDirectStream && stream.url != null) {
        return ExtractedStream(
          url: stream.url!,
          headers: const {'User-Agent': _ua},
          providerName: 'Stremio (${stream.name})',
          subtitles: const [],
          qualities: [
            QualityOption(quality: stream.quality, url: stream.url!),
          ],
        );
      }
    }

    // 2. Fallback to torrent streams (using Webtor/Google Drive caching)
    for (final stream in streams.where((s) => s.isTorrent)) {
      final torrentioService = TorrentioService();
      final resolvedUrl = await torrentioService.resolveStreamUrl(
        stream.infoHash!,
        fileIdx: stream.fileIdx ?? 0,
      );
      if (resolvedUrl != null && resolvedUrl.isNotEmpty) {
        return ExtractedStream(
          url: resolvedUrl,
          headers: const {'User-Agent': _ua},
          providerName: 'Stremio Torrent (${stream.name})',
          subtitles: const [],
          qualities: [
            QualityOption(quality: stream.quality, url: resolvedUrl),
          ],
          magnetUrl: stream.magnetUrl,
        );
      }
    }

    return null;
  }
}
