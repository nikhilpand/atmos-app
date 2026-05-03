import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;

/// AtmosIndex API client — searches the Supabase-backed media catalog
/// via the Cloudflare Worker. NO TELEGRAM LOGIN REQUIRED for search.
///
/// Endpoints:
///   GET /tg/search?title=X&year=Y&s=1&e=3  → catalog + live results
///   GET /tg/season?title=X&s=1              → all episodes for a season
///   GET /tg/stats                           → catalog size
class AtmosIndexClient {
  late final String _baseUrl;

  AtmosIndexClient() {
    _baseUrl = dotenv.env['EXTRACTOR_WORKER_URL'] ?? '';
  }

  bool get isConfigured => _baseUrl.isNotEmpty;

  // ── Search ──────────────────────────────────────────────────────────────────

  /// Search the media catalog. Returns results with channel_username + msg_id
  /// which can be resolved to TDLib file_ids for download.
  Future<List<IndexedMedia>> search(
    String title, {
    int? year,
    String? type,
    int? season,
    int? episode,
    String? quality,
  }) async {
    if (!isConfigured || title.trim().isEmpty) return [];

    final params = <String, String>{
      'title': title.trim(),
      if (year != null) 'year': '$year',
      if (season != null) 's': '$season',
      if (episode != null) 'e': '$episode',
      if (quality != null) 'quality': quality,
    };

    try {
      final uri =
          Uri.parse('$_baseUrl/tg/search').replace(queryParameters: params);
      final res = await http.get(uri).timeout(const Duration(seconds: 15));

      if (res.statusCode != 200) {
        debugPrint('[AtmosIndex] Search failed: ${res.statusCode}');
        return [];
      }

      final body = jsonDecode(res.body);
      final results = (body['results'] as List? ?? [])
          .map((r) => IndexedMedia.fromJson(r as Map<String, dynamic>))
          .toList();

      debugPrint('[AtmosIndex] Found ${results.length} results for "$title"');
      return results;
    } catch (e) {
      debugPrint('[AtmosIndex] Search error: $e');
      return [];
    }
  }

  /// Get all indexed episodes for a season.
  Future<List<IndexedMedia>> getSeason(String title, int season) async {
    if (!isConfigured) return [];

    try {
      final uri = Uri.parse('$_baseUrl/tg/season').replace(
        queryParameters: {'title': title.trim(), 's': '$season'},
      );
      final res = await http.get(uri).timeout(const Duration(seconds: 15));

      if (res.statusCode != 200) return [];

      final body = jsonDecode(res.body);
      return (body['results'] as List? ?? [])
          .map((r) => IndexedMedia.fromJson(r as Map<String, dynamic>))
          .toList();
    } catch (e) {
      debugPrint('[AtmosIndex] Season search error: $e');
      return [];
    }
  }

  /// Get catalog stats (total indexed, channel count).
  Future<Map<String, dynamic>> getStats() async {
    if (!isConfigured) return {};

    try {
      final res = await http
          .get(Uri.parse('$_baseUrl/tg/stats'))
          .timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return {};
      return jsonDecode(res.body) as Map<String, dynamic>;
    } catch (_) {
      return {};
    }
  }

  /// Pre-warm the worker (fire-and-forget health check).
  void warmUp() {
    if (!isConfigured) return;
    http.get(Uri.parse('$_baseUrl/health')).catchError((_) => http.Response('', 0));
  }
}

// ── Data model for indexed media ────────────────────────────────────────────

class IndexedMedia {
  final String channelUsername;
  final int msgId;
  final String title;
  final int? year;
  final int? season;
  final int? episode;
  final int? episodeEnd;
  final String quality;
  final String? sourceTag;
  final String? platformTag;
  final String? codec;
  final String? audio;
  final int fileSizeBytes;
  final String fileName;
  final bool isSeasonPack;

  const IndexedMedia({
    required this.channelUsername,
    required this.msgId,
    required this.title,
    this.year,
    this.season,
    this.episode,
    this.episodeEnd,
    this.quality = 'HD',
    this.sourceTag,
    this.platformTag,
    this.codec,
    this.audio,
    this.fileSizeBytes = 0,
    this.fileName = '',
    this.isSeasonPack = false,
  });

  factory IndexedMedia.fromJson(Map<String, dynamic> json) {
    return IndexedMedia(
      channelUsername: json['channel_username'] ?? '',
      msgId: json['msg_id'] ?? 0,
      title: json['title'] ?? '',
      year: json['year'],
      season: json['season'],
      episode: json['episode'],
      episodeEnd: json['episode_end'],
      quality: json['quality'] ?? 'HD',
      sourceTag: json['source_tag'],
      platformTag: json['platform_tag'],
      codec: json['codec'],
      audio: json['audio'],
      fileSizeBytes: json['file_size_bytes'] ?? 0,
      fileName: json['file_name'] ?? '',
      isSeasonPack: json['is_season_pack'] ?? false,
    );
  }

  /// Human-readable size.
  String get sizeFormatted {
    if (fileSizeBytes < 1024 * 1024 * 1024) {
      return '${(fileSizeBytes / (1024 * 1024)).toStringAsFixed(0)} MB';
    }
    return '${(fileSizeBytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  /// Display label for quality picker.
  String get displayLabel {
    final parts = <String>[quality];
    if (codec != null) parts.add(codec!);
    if (audio != null) parts.add(audio!);
    if (sourceTag != null) parts.add(sourceTag!);
    return parts.join(' • ');
  }

  @override
  String toString() =>
      'IndexedMedia($title, $quality, @$channelUsername/$msgId)';
}
