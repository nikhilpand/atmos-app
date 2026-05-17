import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;
import 'stream_extractor_service.dart';

// ─── VegaMovies DDL Service ──────────────────────────────────────────────────
//
// Scrapes VegaMovies via the Cloudflare Worker proxy for direct download links.
// VegaMovies hosts DDL files on GDrive, PixelDrain, HubCloud.
//
// Architecture:
//   App → CF Worker (/vegamovies/search, /vegamovies/links)
//       → VegaMovies site (domain-rotated)
//       → Extract GDrive/PixelDrain/HubCloud DDL links
//
// These links support HTTP Range headers → resume-capable downloads.
// ─────────────────────────────────────────────────────────────────────────────

/// A search result from VegaMovies
class VegaSearchResult {
  final String title;
  final String postUrl;
  final String? posterUrl;
  final String? year;
  final String? quality;
  final String? language;

  const VegaSearchResult({
    required this.title,
    required this.postUrl,
    this.posterUrl,
    this.year,
    this.quality,
    this.language,
  });

  factory VegaSearchResult.fromJson(Map<String, dynamic> json) {
    return VegaSearchResult(
      title: json['title'] ?? '',
      postUrl: json['post_url'] ?? '',
      posterUrl: json['poster_url'],
      year: json['year'],
      quality: json['quality'],
      language: json['language'],
    );
  }

  @override
  String toString() => 'VegaSearchResult($title, $year, $quality)';
}

/// A direct download link extracted from a VegaMovies post
class VegaDownloadLink {
  final String url;
  final String host; // 'gdrive', 'pixeldrain', 'hubcloud', 'direct'
  final String quality; // '480p', '720p', '1080p', '4K'
  final String? language; // 'Hindi', 'English', 'Dual Audio'
  final String? sizeLabel; // '1.2 GB'
  final String? codec; // 'x264', 'x265'

  const VegaDownloadLink({
    required this.url,
    required this.host,
    required this.quality,
    this.language,
    this.sizeLabel,
    this.codec,
  });

  factory VegaDownloadLink.fromJson(Map<String, dynamic> json) {
    return VegaDownloadLink(
      url: json['url'] ?? '',
      host: json['host'] ?? 'direct',
      quality: json['quality'] ?? 'HD',
      language: json['language'],
      sizeLabel: json['size'],
      codec: json['codec'],
    );
  }

  /// Whether this link supports HTTP resume (Range headers)
  bool get supportsResume => host == 'gdrive' || host == 'pixeldrain' || host == 'direct';

  /// Whether this is streamable (not just downloadable)
  bool get isStreamable => host == 'gdrive' || host == 'pixeldrain';

  /// Convert GDrive sharing URL to direct download URL
  String get directUrl {
    if (host == 'gdrive') {
      // Extract file ID from various GDrive URL formats
      final fileIdMatch = RegExp(r'/d/([a-zA-Z0-9_-]+)').firstMatch(url);
      if (fileIdMatch != null) {
        return 'https://drive.google.com/uc?export=download&id=${fileIdMatch.group(1)}';
      }
    }
    if (host == 'pixeldrain') {
      // Convert pixeldrain.com/u/FILE_ID to direct API download
      final idMatch = RegExp(r'/u/([a-zA-Z0-9]+)').firstMatch(url);
      if (idMatch != null) {
        return 'https://pixeldrain.com/api/file/${idMatch.group(1)}';
      }
    }
    return url;
  }

  /// Sort score: higher = better
  int get sortScore {
    int score = 0;
    // Quality
    if (quality.contains('4K') || quality.contains('2160')) score += 4000;
    if (quality.contains('1080')) score += 3000;
    if (quality.contains('720')) score += 2000;
    if (quality.contains('480')) score += 1000;
    // Host reliability
    if (host == 'gdrive') score += 500;
    if (host == 'pixeldrain') score += 400;
    if (host == 'direct') score += 300;
    // Codec efficiency
    if (codec == 'x265') score += 100;
    return score;
  }

  @override
  String toString() => 'VegaDownloadLink($quality $language, $host, $sizeLabel)';
}

// ─── Service ─────────────────────────────────────────────────────────────────

class VegaMoviesService {
  late final String _workerUrl;
  static const _timeout = Duration(seconds: 10);
  static const _ua = 'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36';

  VegaMoviesService() {
    _workerUrl = dotenv.env['EXTRACTOR_WORKER_URL'] ?? '';
  }

  bool get isConfigured => _workerUrl.isNotEmpty;

  /// Search VegaMovies for a title.
  Future<List<VegaSearchResult>> search(
    String title, {
    int? year,
    String? quality,
  }) async {
    if (!isConfigured || title.trim().isEmpty) return [];

    final params = <String, String>{
      'q': title.trim(),
      if (year != null) 'year': '$year',
      if (quality != null) 'quality': quality,
    };

    try {
      final uri = Uri.parse('$_workerUrl/vegamovies/search')
          .replace(queryParameters: params);
      final res = await http
          .get(uri, headers: {'User-Agent': _ua})
          .timeout(_timeout);

      if (res.statusCode != 200) {
        debugPrint('[VegaMovies] Search failed: ${res.statusCode}');
        return [];
      }

      final body = jsonDecode(res.body);
      final results = (body['results'] as List? ?? [])
          .map((r) => VegaSearchResult.fromJson(r as Map<String, dynamic>))
          .toList();

      debugPrint('[VegaMovies] Found ${results.length} results for "$title"');
      return results;
    } catch (e) {
      debugPrint('[VegaMovies] Search error: $e');
      return [];
    }
  }

  /// Extract download links from a VegaMovies post page.
  Future<List<VegaDownloadLink>> getLinks(String postUrl) async {
    if (!isConfigured || postUrl.isEmpty) return [];

    try {
      final uri = Uri.parse('$_workerUrl/vegamovies/links')
          .replace(queryParameters: {'url': postUrl});
      final res = await http
          .get(uri, headers: {'User-Agent': _ua})
          .timeout(_timeout);

      if (res.statusCode != 200) {
        debugPrint('[VegaMovies] Links extraction failed: ${res.statusCode}');
        return [];
      }

      final body = jsonDecode(res.body);
      final links = (body['links'] as List? ?? [])
          .map((l) => VegaDownloadLink.fromJson(l as Map<String, dynamic>))
          .toList()
        ..sort((a, b) => b.sortScore.compareTo(a.sortScore));

      debugPrint('[VegaMovies] Extracted ${links.length} download links');
      return links;
    } catch (e) {
      debugPrint('[VegaMovies] Links error: $e');
      return [];
    }
  }

  /// Full extraction: search → best post → extract links → return stream
  Future<ExtractedStream?> extractStream({
    required String title,
    int? year,
    String? qualityFilter,
  }) async {
    // 1. Search
    final results = await search(title, year: year);
    if (results.isEmpty) return null;

    // 2. Get links from best result
    final links = await getLinks(results.first.postUrl);
    if (links.isEmpty) return null;

    // 3. Filter by quality if specified
    List<VegaDownloadLink> candidates = links;
    if (qualityFilter != null) {
      candidates = links
          .where((l) => l.quality.toLowerCase().contains(qualityFilter.toLowerCase()))
          .toList();
      if (candidates.isEmpty) candidates = links;
    }

    // 4. Pick best streamable link
    final best = candidates.firstWhere(
      (l) => l.isStreamable,
      orElse: () => candidates.first,
    );

    return ExtractedStream(
      url: best.directUrl,
      headers: const {'User-Agent': _ua},
      providerName: 'VegaMovies (${best.host})',
      subtitles: const [],
      qualities: candidates
          .where((l) => l.isStreamable)
          .map((l) => QualityOption(quality: '${l.quality} ${l.language ?? ""}', url: l.directUrl))
          .toList(),
    );
  }

  /// Get download-ready links for the download service
  Future<List<VegaDownloadLink>> getDownloadLinks({
    required String title,
    int? year,
    String? quality,
    String? language,
  }) async {
    final results = await search(title, year: year, quality: quality);
    if (results.isEmpty) return [];

    final links = await getLinks(results.first.postUrl);

    // Filter by language if specified
    if (language != null && language.isNotEmpty) {
      final filtered = links
          .where((l) => (l.language ?? '').toLowerCase().contains(language.toLowerCase()))
          .toList();
      if (filtered.isNotEmpty) return filtered;
    }

    return links;
  }
}
