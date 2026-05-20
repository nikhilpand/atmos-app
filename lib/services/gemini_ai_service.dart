import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:shared_preferences/shared_preferences.dart';

class GeminiCategory {
  final String categoryName;
  final String description;
  final List<int> tmdbGenreIds;
  final String sortBy;

  const GeminiCategory({
    required this.categoryName,
    required this.description,
    required this.tmdbGenreIds,
    required this.sortBy,
  });

  factory GeminiCategory.fromJson(Map<String, dynamic> json) {
    return GeminiCategory(
      categoryName: json['category_name'] as String? ?? 'Custom Picks',
      description: json['description'] as String? ?? '',
      tmdbGenreIds: (json['tmdb_genre_ids'] as List? ?? [])
          .map((id) => int.tryParse(id.toString()) ?? 0)
          .where((id) => id > 0)
          .toList(),
      sortBy: json['sort_by'] as String? ?? 'popularity.desc',
    );
  }
}

class GeminiRecommendation {
  final String title;
  final int tmdbId;
  final String type; // 'movie' or 'tv'
  final String reason;
  final String category;
  final double confidence;

  const GeminiRecommendation({
    required this.title,
    required this.tmdbId,
    required this.type,
    required this.reason,
    required this.category,
    required this.confidence,
  });

  factory GeminiRecommendation.fromJson(Map<String, dynamic> json) {
    return GeminiRecommendation(
      title: json['title'] as String? ?? '',
      tmdbId: json['tmdb_id'] as int? ?? 0,
      type: json['type'] as String? ?? 'movie',
      reason: json['reason'] as String? ?? '',
      category: json['category'] as String? ?? 'Recommended',
      confidence: (json['confidence'] as num? ?? 0.8).toDouble(),
    );
  }
}

class GeminiAiService {
  static const _timeout = Duration(seconds: 15);
  static const _ua = 'Atmos-App/2.0';

  String get _baseUrl {
    final envUrl = dotenv.env['HF_SPACE_URL'] ?? '';
    if (envUrl.isNotEmpty) return envUrl.trimRight();
    return 'https://nikhil1776-torrentindex.hf.space';
  }

  Future<String?> _getApiKey() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      String? key = prefs.getString('custom_gemini_api_key');
      if (key == null || key.isEmpty) {
        key = dotenv.env['GEMINI_API_KEY'];
      }
      if (key == 'AIzaSyAOd7Mh1r08hgbKhbjZIO40pZ1WVeRcr-k' ||
          key == 'AIzaSyCbfVje1oHISOW-VXZA_JjPofIthycdnmg') {
        return null;
      }
      return key;
    } catch (_) {
      return null;
    }
  }

  /// Check if the Gemini service is online and active.
  Future<bool> isGeminiConfigured() async {
    final key = await _getApiKey();
    if (key != null && key.isNotEmpty) {
      return true;
    }
    try {
      final resp = await http.get(
        Uri.parse('$_baseUrl/api/health'),
        headers: {'User-Agent': _ua},
      ).timeout(const Duration(seconds: 5));

      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body);
        return data['gemini'] == true;
      }
    } catch (e) {
      debugPrint('[GeminiAI] Health check failed: $e');
    }
    return false;
  }

  /// Fetch AI-generated recommendations based on watch history.
  Future<List<GeminiRecommendation>> getRecommendations({
    required List<Map<String, dynamic>> watchHistory,
    required List<String> searchHistory,
    required List<String> preferredGenres,
    String preferredLang = 'English',
  }) async {
    final key = await _getApiKey();
    if (key != null && key.isNotEmpty) {
      final prompt = """You are a movie/TV show recommendation engine.
Based on the user's viewing history and preferences, suggest 20 personalized recommendations.

Watch History (most recent first): ${jsonEncode(watchHistory.take(20).toList())}
Recent Searches: ${jsonEncode(searchHistory.take(10).toList())}
Preferred Genres: ${jsonEncode(preferredGenres)}
Preferred Language: $preferredLang

Return a JSON array of objects with:
- "title": exact movie/show title
- "tmdb_id": TMDB ID if known, else 0
- "type": "movie" or "tv"
- "reason": 1-line explanation
- "category": one of "Because You Watched", "Trending in Your Taste", "Hidden Gems", "New Releases", "Genre Deep Dive"
- "confidence": 0.0-1.0

Prioritize quality hidden gems over obvious mainstream picks.
Return ONLY valid JSON array.""";

      try {
        final resp = await http.post(
          Uri.parse('https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=$key'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'contents': [{'parts': [{'text': prompt}]}],
            'generationConfig': {
              'responseMimeType': 'application/json',
            }
          }),
        ).timeout(_timeout);

        if (resp.statusCode == 200) {
          final data = jsonDecode(resp.body);
          final text = data['candidates']?[0]?['content']?['parts']?[0]?['text'] ?? '';
          final cleaned = _cleanJsonArrayResponse(text);
          final parsed = jsonDecode(cleaned) as List? ?? [];
          return parsed.map((item) => GeminiRecommendation.fromJson(item as Map<String, dynamic>)).toList();
        } else {
          debugPrint('[GeminiAI] Direct Recommendations HTTP ${resp.statusCode}: ${resp.body}');
        }
      } catch (e) {
        debugPrint('[GeminiAI] Direct Recommendations error: $e');
      }
      return [];
    }

    try {
      final payload = {
        'watch_history': watchHistory,
        'search_history': searchHistory,
        'preferred_genres': preferredGenres,
        'preferred_lang': preferredLang,
      };

      final resp = await http.post(
        Uri.parse('$_baseUrl/api/gemini/recommend'),
        headers: {
          'Content-Type': 'application/json',
          'User-Agent': _ua,
        },
        body: jsonEncode(payload),
      ).timeout(_timeout);

      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body);
        final list = data['recommendations'] as List? ?? [];
        return list.map((item) => GeminiRecommendation.fromJson(item as Map<String, dynamic>)).toList();
      } else {
        debugPrint('[GeminiAI] Recommendations HTTP ${resp.statusCode}: ${resp.body}');
      }
    } catch (e) {
      debugPrint('[GeminiAI] Recommendations error: $e');
    }
    return [];
  }

  /// Fetch AI-generated categories based on watch history.
  Future<List<GeminiCategory>> getCategories({
    required List<Map<String, dynamic>> watchHistory,
    required List<String> preferredGenres,
  }) async {
    final key = await _getApiKey();
    if (key != null && key.isNotEmpty) {
      final prompt = """Create 8 personalized content category names for a streaming app home screen.
User watches: ${jsonEncode(watchHistory.take(15).toList())}
Preferred genres: ${jsonEncode(preferredGenres)}

Return JSON array with:
- "category_name": creative Netflix-style name
- "description": what belongs here
- "tmdb_genre_ids": array of TMDB genre IDs
- "sort_by": "popularity.desc" or "vote_average.desc" or "release_date.desc"

Good examples: "Mind-Bending Thrillers", "Anime After Dark", "Feel-Good Weekend Picks"
Return ONLY valid JSON.""";

      try {
        final resp = await http.post(
          Uri.parse('https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=$key'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'contents': [{'parts': [{'text': prompt}]}],
            'generationConfig': {
              'responseMimeType': 'application/json',
            }
          }),
        ).timeout(_timeout);

        if (resp.statusCode == 200) {
          final data = jsonDecode(resp.body);
          final text = data['candidates']?[0]?['content']?['parts']?[0]?['text'] ?? '';
          final cleaned = _cleanJsonArrayResponse(text);
          final parsed = jsonDecode(cleaned) as List? ?? [];
          return parsed.map((item) => GeminiCategory.fromJson(item as Map<String, dynamic>)).toList();
        } else {
          debugPrint('[GeminiAI] Direct Categories HTTP ${resp.statusCode}: ${resp.body}');
        }
      } catch (e) {
        debugPrint('[GeminiAI] Direct Categories error: $e');
      }
      return [];
    }

    try {
      final payload = {
        'watch_history': watchHistory,
        'preferred_genres': preferredGenres,
      };

      final resp = await http.post(
        Uri.parse('$_baseUrl/api/gemini/categorize'),
        headers: {
          'Content-Type': 'application/json',
          'User-Agent': _ua,
        },
        body: jsonEncode(payload),
      ).timeout(_timeout);

      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body);
        final list = data['categories'] as List? ?? [];
        return list.map((item) => GeminiCategory.fromJson(item as Map<String, dynamic>)).toList();
      } else {
        debugPrint('[GeminiAI] Categories HTTP ${resp.statusCode}: ${resp.body}');
      }
    } catch (e) {
      debugPrint('[GeminiAI] Categories error: $e');
    }
    return [];
  }

  String _cleanJsonArrayResponse(String raw) {
    var cleaned = raw.trim();
    if (cleaned.startsWith('```')) {
      final lines = cleaned.split('\n');
      if (lines.isNotEmpty && lines.first.startsWith('```')) {
        lines.removeAt(0);
      }
      if (lines.isNotEmpty && lines.last.startsWith('```')) {
        lines.removeLast();
      }
      cleaned = lines.join('\n').trim();
    }
    
    final startIndex = cleaned.indexOf('[');
    final endIndex = cleaned.lastIndexOf(']');
    if (startIndex != -1 && endIndex != -1 && endIndex > startIndex) {
      cleaned = cleaned.substring(startIndex, endIndex + 1);
    }
    
    return cleaned;
  }
}
