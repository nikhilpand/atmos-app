import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../models/media_model.dart';

class HistoryService {
  static const String _boxName = 'watch_history';
  late final Box<WatchHistory> _box;

  Future<void> init() async {
    await Hive.initFlutter();
    if (!Hive.isAdapterRegistered(0)) {
      Hive.registerAdapter(WatchHistoryAdapter());
    }
    try {
      _box = await Hive.openBox<WatchHistory>(_boxName);
    } catch (e) {
      debugPrint('History box corrupted, deleting: $e');
      await Hive.deleteBoxFromDisk(_boxName);
      _box = await Hive.openBox<WatchHistory>(_boxName);
    }
  }

  /// Save or update watch progress for a movie or episode.
  Future<void> saveProgress({
    required String imdbId,
    required int tmdbId,
    required String title,
    required String posterPath,
    required int progressSeconds,
    required int totalSeconds,
    required String mediaType,
    int? season,
    int? episode,
    String? episodeName,
  }) async {
    final key = _buildKey(imdbId, season, episode);
    final existing = _box.get(key);

    final entry = WatchHistory(
      imdbId: imdbId,
      tmdbId: tmdbId,
      title: title,
      posterPath: posterPath,
      progressSeconds: progressSeconds,
      totalSeconds: totalSeconds,
      lastWatched: DateTime.now(),
      mediaType: mediaType,
      season: season,
      episode: episode,
      episodeName: episodeName,
    );

    // Don't overwrite with less progress (e.g. on re-open)
    if (existing != null && existing.progressSeconds > progressSeconds) return;

    await _box.put(key, entry);
  }

  /// Returns null if not found or finished.
  WatchHistory? getProgress(String imdbId, {int? season, int? episode}) {
    final key = _buildKey(imdbId, season, episode);
    final h = _box.get(key);
    if (h == null || h.isFinished) return null;
    return h;
  }

  /// Returns all history entries, sorted by most recently watched.
  List<WatchHistory> getHistory() {
    final items = _box.values.toList();
    items.sort((a, b) => b.lastWatched.compareTo(a.lastWatched));
    return items;
  }

  /// Returns "Continue Watching" items (in-progress, not finished).
  List<WatchHistory> getContinueWatching() {
    return getHistory()
        .where((h) => !h.isFinished && h.progressPercent > 0.02)
        .take(20)
        .toList();
  }

  Future<void> removeEntry(String imdbId, {int? season, int? episode}) async {
    final key = _buildKey(imdbId, season, episode);
    await _box.delete(key);
  }

  Future<void> clearAll() async {
    await _box.clear();
  }

  String _buildKey(String imdbId, int? season, int? episode) {
    if (season != null && episode != null) {
      return '${imdbId}_s${season}_e$episode';
    }
    return imdbId;
  }
}
