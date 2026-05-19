import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../models/media_model.dart';

/// Persists a user's bookmarked movies and shows entirely on-device.
/// Backed by a Hive box, no server required.
class WatchlistService extends ChangeNotifier {
  static const _boxName = 'watchlist_v1';

  late Box<Map> _box;
  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;
    try {
      _box = await Hive.openBox<Map>(_boxName);
    } catch (e) {
      debugPrint('Watchlist box corrupted, deleting: $e');
      await Hive.deleteBoxFromDisk(_boxName);
      _box = await Hive.openBox<Map>(_boxName);
    }
    _initialized = true;
  }

  List<TmdbMedia> get items {
    if (!_initialized) return [];
    return _box.values.map((raw) {
      final m = Map<String, dynamic>.from(raw);
      return TmdbMedia(
        id: m['id'] as int,
        title: m['title'] as String,
        posterPath: m['posterPath'] as String?,
        backdropPath: m['backdropPath'] as String?,
        overview: m['overview'] as String?,
        voteAverage: (m['voteAverage'] as num).toDouble(),
        releaseDate: m['releaseDate'] as String?,
        firstAirDate: m['firstAirDate'] as String?,
        mediaType: m['mediaType'] == 'tv' ? MediaType.tv : MediaType.movie,
        imdbId: m['imdbId'] as String?,
      );
    }).toList();
  }

  bool isInWatchlist(int tmdbId) => _box.containsKey('$tmdbId');

  Future<void> add(TmdbMedia media) async {
    if (!_initialized) return;
    await _box.put('${media.id}', {
      'id': media.id,
      'title': media.title,
      'posterPath': media.posterPath,
      'backdropPath': media.backdropPath,
      'overview': media.overview,
      'voteAverage': media.voteAverage,
      'releaseDate': media.releaseDate,
      'firstAirDate': media.firstAirDate,
      'mediaType': media.mediaType == MediaType.tv ? 'tv' : 'movie',
      'imdbId': media.imdbId,
    });
    notifyListeners();
  }

  Future<void> remove(int tmdbId) async {
    if (!_initialized) return;
    await _box.delete('$tmdbId');
    notifyListeners();
  }

  Future<void> toggle(TmdbMedia media) async {
    if (isInWatchlist(media.id)) {
      await remove(media.id);
    } else {
      await add(media);
    }
  }

  Future<void> clear() async {
    await _box.clear();
    notifyListeners();
  }
}
