import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AliasDatabase {
  static Box? _box;

  /// Manual high-priority aliases as fallback/bootstrap
  static const Map<String, List<String>> _manualAliases = {
    'breaking bad': ['bb', 'breakingbad'],
    'game of thrones': ['got', 'gameofthrones'],
    'stranger things': ['st', 'strangerthings'],
    'better call saul': ['bcs', 'bettercallsaul'],
    'the walking dead': ['twd', 'thewalkingdead'],
    'house of the dragon': ['hotd', 'hod', 'houseofthedragon'],
    'rick and morty': ['rm', 'ram', 'rickandmorty'],
    'the big bang theory': ['tbbt', 'bigbangtheory'],
    'how i met your mother': ['himym', 'howimetyourmother'],
    'modern family': ['mf', 'modernfamily'],
    'the lord of the rings': ['lotr', 'lordoftherings'],
    'attack on titan': ['aot', 'attackontitan'],
    'my hero academia': ['mha', 'myheroacademia'],
    'demon slayer': ['ds', 'demonslayer'],
    'one piece': ['op', 'onepiece'],
    'peaky blinders': ['pb', 'peakyblinders'],
    'prison break': ['pb', 'prisonbreak'],
    'money heist': ['mh', 'moneyheist'],
    'the office': ['theoffice'],
    'black mirror': ['bm', 'blackmirror'],
    'agents of s.h.i.e.l.d.': ['aos', 'agentsofshield'],
    'brooklyn nine-nine': ['b99', 'brooklyn99', 'brooklynninenine'],
    'the mandalorian': ['mando', 'mandalorian'],
    'wandavision': ['wv'],
  };

  /// Initialize the Hive box for aliases cache
  static Future<void> init() async {
    try {
      _box = await Hive.openBox('show_aliases');
    } catch (e) {
      // Safe fallback if Hive open fails
      debugPrint('[AliasDatabase] Hive init error: $e');
    }
  }

  /// Returns all search variations for a given title.
  /// Tries local Hive cache first, falls back to real-time Gemini API (with 1.5s timeout),
  /// and always merges with dynamic algorithmic variations.
  static Future<List<String>> getSearchVariations(String title) async {
    final normalized = title.trim().toLowerCase();
    final algorithmic = _getAlgorithmicVariations(title);

    if (_box == null) {
      return algorithmic;
    }

    // 1. Check local Hive cache
    final cached = _box!.get(normalized);
    if (cached != null && cached is List) {
      final list = cached.map((e) => e.toString()).toList();
      return _deduplicate([...list, ...algorithmic]);
    }

    // 2. Fetch from Gemini with a 1.5-second timeout
    try {
      final geminiList = await _fetchFromGemini(title).timeout(const Duration(milliseconds: 1500));
      if (geminiList.isNotEmpty) {
        await _box!.put(normalized, geminiList);
        return _deduplicate([...geminiList, ...algorithmic]);
      }
    } catch (_) {
      // Timeout or API error: run in the background to cache for next time
      _fetchAndCacheInBackground(title);
    }

    return algorithmic;
  }

  /// Dynamic algorithmic variations for any show
  static List<String> _getAlgorithmicVariations(String title) {
    final normalized = title.trim().toLowerCase();
    final variations = <String>{title.trim()};

    // 1. Manual check
    for (final entry in _manualAliases.entries) {
      if (entry.key == normalized || entry.key.replaceAll(RegExp(r'[^\w\s]'), '') == normalized) {
        variations.addAll(entry.value);
      }
    }

    // 2. Combined name (no spaces/punctuation)
    final alphanumericOnly = title.replaceAll(RegExp(r'[^\w]'), '');
    if (alphanumericOnly.isNotEmpty) {
      variations.add(alphanumericOnly);
    }

    // 3. Connector replacements (e.g. "and" -> "&", "n")
    if (normalized.contains(' and ')) {
      variations.add(title.replaceAll(RegExp(r'\band\b', caseSensitive: false), '&'));
      variations.add(title.replaceAll(RegExp(r'\band\b', caseSensitive: false), 'n'));
    }

    // 4. Initials generation
    final words = title.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    final stopWords = {'the', 'a', 'an', 'of', 'and', 'or'};
    final importantWords = words.where((w) => !stopWords.contains(w.toLowerCase())).toList();

    if (importantWords.length >= 2) {
      final initials = importantWords.map((w) => w[0].toLowerCase()).join();
      if (initials.length >= 2) {
        variations.add(initials);
        variations.add(initials.toUpperCase());
      }
    }

    if (words.length >= 2) {
      final allInitials = words.map((w) => w[0].toLowerCase()).join();
      if (allInitials.length >= 2) {
        variations.add(allInitials);
        variations.add(allInitials.toUpperCase());
      }
    }

    // 5. Strip leading common words
    if (words.isNotEmpty && stopWords.contains(words[0].toLowerCase())) {
      variations.add(words.skip(1).join(' '));
    }

    final result = <String>[];
    final seen = <String>{};
    for (final v in variations) {
      if (seen.add(v.toLowerCase())) {
        result.add(v);
      }
    }

    return result;
  }

  /// Fire background fetch and write to cache
  static void _fetchAndCacheInBackground(String title) {
    _fetchFromGemini(title).then((geminiList) {
      if (geminiList.isNotEmpty && _box != null) {
        _box!.put(title.trim().toLowerCase(), geminiList);
      }
    }).catchError((_) {});
  }

  /// Gemini API query
  static Future<List<String>> _fetchFromGemini(String title) async {
    String? apiKey;
    try {
      final prefs = await SharedPreferences.getInstance();
      apiKey = prefs.getString('custom_gemini_api_key');
    } catch (_) {}

    if (apiKey == null || apiKey.isEmpty) {
      apiKey = dotenv.env['GEMINI_API_KEY'];
    }

    if (apiKey == 'AIzaSyCbfVje1oHISOW-VXZA_JjPofIthycdnmg' || apiKey == null || apiKey.isEmpty) {
      return [];
    }

    final url = Uri.parse(
        'https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=$apiKey');

    try {
      final response = await http.post(
        url,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'contents': [
            {
              'parts': [
                {
                  'text': 'Given the movie or TV show title "$title", generate a JSON array of alternative titles, common abbreviations, acronyms, shortened names, or combined names (spaces/punctuation removed) that users or release groups might name its video files. For example, for "Breaking Bad" return ["bb", "breakingbad"]. Return ONLY a JSON list of strings. Do not include any other markdown text or comments.'
                }
              ]
            }
          ],
          'generationConfig': {
            'responseMimeType': 'application/json',
          }
        }),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final text = data['candidates']?[0]?['content']?['parts']?[0]?['text'] ?? '';
        final parsed = jsonDecode(text.trim());
        if (parsed is List) {
          return parsed.map((e) => e.toString().trim()).toList();
        }
      }
    } catch (_) {}
    return [];
  }

  static List<String> _deduplicate(List<String> list) {
    final seen = <String>{};
    return list.where((e) => seen.add(e.toLowerCase().trim())).toList();
  }
}
