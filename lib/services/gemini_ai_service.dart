import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_dotenv/flutter_dotenv.dart';

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

  /// Check if the Gemini service is online and active.
  Future<bool> isGeminiConfigured() async {
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
}
