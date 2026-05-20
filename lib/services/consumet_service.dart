import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'stream_extractor_service.dart';

/// Consumet API Service for high-speed dedicated Anime streams.
///
/// Searches multiple public Consumet instances in PARALLEL (not serial waterfall)
/// across both gogoanime and zoro providers. Returns the first success.
class ConsumetService {
  static const _ua = 'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36';
  static const _timeout = Duration(seconds: 7);

  // List of public Consumet instances to try in parallel
  static const _baseUrls = [
    'https://api.consumet.org',
    'https://consumet-api-clone.vercel.app',
    'https://consumet-api-nine.vercel.app',
    'https://c.delusionz.xyz',
  ];

  /// Resolves direct stream sources for an anime title and episode.
  /// Fires ALL base URLs × providers in parallel and returns the first success.
  Future<ExtractedStream?> extractAnimeStream({
    required String title,
    required int episode,
  }) async {
    if (title.isEmpty) return null;

    final sanitizedTitle = _sanitizeAnimeTitle(title);
    debugPrint('[Consumet] Searching anime stream for "$sanitizedTitle" ep $episode');

    // Fire all combinations in parallel — first success wins
    final providers = ['gogoanime', 'zoro'];
    final futures = <Future<ExtractedStream?>>[];

    for (final baseUrl in _baseUrls) {
      for (final provider in providers) {
        futures.add(_tryExtractSafe(
          baseUrl: baseUrl,
          provider: provider,
          title: sanitizedTitle,
          episode: episode,
        ));
      }
    }

    // Return first non-null result, or null if all fail
    final completer = Completer<ExtractedStream?>();
    int remaining = futures.length;

    for (final future in futures) {
      future.then((result) {
        if (result != null && !completer.isCompleted) {
          completer.complete(result);
        } else {
          remaining--;
          if (remaining <= 0 && !completer.isCompleted) {
            completer.complete(null);
          }
        }
      }).catchError((_) {
        remaining--;
        if (remaining <= 0 && !completer.isCompleted) {
          completer.complete(null);
        }
      });
    }

    // Safety timeout — don't wait forever
    return completer.future.timeout(
      const Duration(seconds: 12),
      onTimeout: () => null,
    );
  }

  /// Clean up anime title (remove year, special characters, TMDB extras)
  String _sanitizeAnimeTitle(String title) {
    var clean = title.replaceAll(RegExp(r'\(.*\)'), ''); // Remove parentheses content
    clean = clean.replaceAll(RegExp(r'\[.*\]'), ''); // Remove brackets content
    clean = clean.replaceAll(RegExp(r'\s-\s.*'), ''); // Remove episode suffixes
    // Remove year e.g. "2024" or "2023" at the end
    clean = clean.replaceAll(RegExp(r'\b\d{4}\b'), '');
    return clean.trim();
  }

  /// Safe wrapper that catches all errors instead of propagating
  Future<ExtractedStream?> _tryExtractSafe({
    required String baseUrl,
    required String provider,
    required String title,
    required int episode,
  }) async {
    try {
      return await _tryExtract(
        baseUrl: baseUrl,
        provider: provider,
        title: title,
        episode: episode,
      );
    } catch (e) {
      debugPrint('[Consumet] Error with $baseUrl/$provider: $e');
      return null;
    }
  }

  Future<ExtractedStream?> _tryExtract({
    required String baseUrl,
    required String provider,
    required String title,
    required int episode,
  }) async {
    // 1. Search anime
    final searchUri = Uri.parse('$baseUrl/anime/$provider/${Uri.encodeComponent(title)}');
    final searchResp = await http.get(searchUri, headers: {'User-Agent': _ua}).timeout(_timeout);

    if (searchResp.statusCode != 200) return null;
    final searchData = jsonDecode(searchResp.body);
    final results = searchData['results'] as List?;
    if (results == null || results.isEmpty) return null;

    // Find the best match ID (exact or first match)
    dynamic bestMatch;
    for (final item in results) {
      final itemTitle = item['title']?.toString() ?? '';
      if (itemTitle.toLowerCase() == title.toLowerCase()) {
        bestMatch = item;
        break;
      }
    }
    bestMatch ??= results.first;

    final animeId = bestMatch['id'] as String?;
    if (animeId == null) return null;

    // 2. Get episodes info
    final infoUri = Uri.parse('$baseUrl/anime/$provider/info/$animeId');
    final infoResp = await http.get(infoUri, headers: {'User-Agent': _ua}).timeout(_timeout);

    if (infoResp.statusCode != 200) return null;
    final infoData = jsonDecode(infoResp.body);
    final episodes = infoData['episodes'] as List?;
    if (episodes == null || episodes.isEmpty) return null;

    // Find the episode with matching episode number (manual loop — safe for null)
    dynamic epObj;
    for (final ep in episodes) {
      if (ep['number']?.toString() == episode.toString()) {
        epObj = ep;
        break;
      }
    }

    // Fallback: match by list index if not found by explicit number
    if (epObj == null && episode > 0 && episode <= episodes.length) {
      epObj = episodes[episode - 1];
    }

    if (epObj == null) return null;
    final episodeId = epObj['id'] as String?;
    if (episodeId == null) return null;

    // 3. Get streaming links
    final watchUri = Uri.parse('$baseUrl/anime/$provider/watch/$episodeId');
    final watchResp = await http.get(watchUri, headers: {'User-Agent': _ua}).timeout(_timeout);

    if (watchResp.statusCode != 200) return null;
    final watchData = jsonDecode(watchResp.body);
    final sources = watchData['sources'] as List?;
    if (sources == null || sources.isEmpty) return null;

    // Parse stream options
    String? primaryUrl;
    final List<QualityOption> qualities = [];
    final List<SubtitleInfo> subtitles = [];

    for (final s in sources) {
      final url = s['url'] as String?;
      final quality = s['quality'] as String? ?? 'default';
      if (url == null) continue;

      primaryUrl ??= url;
      qualities.add(QualityOption(quality: quality, url: url));
    }

    // Parse subtitles (if available, e.g. for Zoro provider)
    final subsList = watchData['subtitles'] as List?;
    if (subsList != null) {
      for (final sub in subsList) {
        final subUrl = sub['url'] as String?;
        final lang = sub['lang'] as String? ?? 'English';
        if (subUrl != null) {
          // Safe substring — clamp to actual string length
          final langCode = lang.toLowerCase().substring(0, min(3, lang.length));
          subtitles.add(SubtitleInfo(
            url: subUrl,
            lang: langCode,
            label: lang,
          ));
        }
      }
    }

    if (primaryUrl == null) return null;

    // Build extractor headers
    final Map<String, String> headers = {
      'User-Agent': _ua,
      'Referer': baseUrl,
    };
    if (watchData['headers'] != null) {
      final customHeaders = watchData['headers'] as Map;
      customHeaders.forEach((k, v) {
        headers[k.toString()] = v.toString();
      });
    }

    debugPrint('[Consumet] ✅ Match via $baseUrl ($provider)');
    return ExtractedStream(
      url: primaryUrl,
      headers: headers,
      providerName: 'Consumet ($provider)',
      qualities: qualities,
      subtitles: subtitles,
    );
  }
}
