import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter_dotenv/flutter_dotenv.dart';

/// OpenSubtitles.com REST API v1 client.
///
/// Free tier: 5 downloads/day, 200 search requests/24h.
/// No API key required for search (only for download token).
///
/// Usage:
///   final subs = await subtitleService.search(imdbId: 'tt1375666', language: 'en');
///   final url  = await subtitleService.getDownloadUrl(fileId: subs.first.fileId);
class SubtitleTrack {
  final int fileId;
  final String languageName;
  final String languageCode;
  final String releaseName;
  final double rating;
  final int downloadCount;

  const SubtitleTrack({
    required this.fileId,
    required this.languageName,
    required this.languageCode,
    required this.releaseName,
    required this.rating,
    required this.downloadCount,
  });

  factory SubtitleTrack.fromJson(Map<String, dynamic> json) {
    final attrs = json['attributes'] as Map<String, dynamic>? ?? {};
    final files = (attrs['files'] as List?)?.first as Map? ?? {};
    return SubtitleTrack(
      fileId: (files['file_id'] as int?) ?? 0,
      languageName: attrs['language'] as String? ?? '',
      languageCode: attrs['language'] as String? ?? '',
      releaseName: attrs['release'] as String? ?? '',
      rating: (attrs['ratings'] as num?)?.toDouble() ?? 0.0,
      downloadCount: (attrs['download_count'] as int?) ?? 0,
    );
  }
}

/// Available subtitle languages with their display names.
const subtitleLanguages = <String, String>{
  'en': 'English',
  'es': 'Spanish',
  'fr': 'French',
  'de': 'German',
  'pt': 'Portuguese',
  'hi': 'Hindi',
  'ar': 'Arabic',
  'zh-cn': 'Chinese (Simplified)',
  'ja': 'Japanese',
  'ko': 'Korean',
  'ru': 'Russian',
  'it': 'Italian',
  'tr': 'Turkish',
  'pl': 'Polish',
  'nl': 'Dutch',
};

class SubtitleService {
  static const _baseUrl = 'https://api.opensubtitles.com/api/v1';
  static const _appName = 'Atmos v3.0';

  String? _apiKey;

  SubtitleService() {
    _apiKey = dotenv.env['OPENSUBTITLES_API_KEY'];
  }

  Map<String, String> get _headers => {
    'Content-Type': 'application/json',
    'Accept': 'application/json',
    'User-Agent': _appName,
    if (_apiKey != null) 'Api-Key': _apiKey!,
  };

  // ── Search ───────────────────────────────────────────────────────────────────

  /// Search for subtitles by IMDb ID + language code.
  /// Returns a list sorted by download count (most popular first).
  Future<List<SubtitleTrack>> search({
    required String imdbId,
    String language = 'en',
    int season = 0,
    int episode = 0,
  }) async {
    try {
      final params = <String, String>{
        'imdb_id': imdbId.replaceFirst('tt', ''),
        'languages': language,
        'order_by': 'download_count',
        'order_direction': 'desc',
      };
      if (season > 0) params['season_number'] = '$season';
      if (episode > 0) params['episode_number'] = '$episode';

      final uri = Uri.parse('$_baseUrl/subtitles').replace(queryParameters: params);
      final res = await http.get(uri, headers: _headers);
      if (res.statusCode != 200) return [];
      final body = jsonDecode(res.body);
      final data = body['data'] as List? ?? [];
      return data
          .map((j) => SubtitleTrack.fromJson(j as Map<String, dynamic>))
          .where((t) => t.fileId > 0)
          .toList();
    } catch (e) {
      return [];
    }
  }

  // ── Download Link ─────────────────────────────────────────────────────────────

  /// Exchange a subtitle file_id for a direct download URL (.srt/.vtt).
  /// Requires API key for authenticated requests (higher daily quota).
  Future<String?> getDownloadUrl(int fileId) async {
    if (_apiKey == null) {
      // Unauthenticated: use the public VTT mirror endpoint
      return 'https://dl.opensubtitles.org/api/download?file_id=$fileId&sub_format=vtt';
    }
    try {
      final uri = Uri.parse('$_baseUrl/download');
      final res = await http.post(uri,
        headers: _headers,
        body: jsonEncode({'file_id': fileId, 'sub_format': 'vtt'}),
      );
      if (res.statusCode != 200) return null;
      final body = jsonDecode(res.body);
      return body['link'] as String?;
    } catch (_) {
      return null;
    }
  }

  // ── Language helpers ─────────────────────────────────────────────────────────

  String languageName(String code) =>
      subtitleLanguages[code] ?? code.toUpperCase();

  List<String> get availableLanguageCodes =>
      subtitleLanguages.keys.toList();
}
