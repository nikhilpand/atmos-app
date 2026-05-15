import 'package:hive/hive.dart';

part 'media_model.g.dart';

enum MediaType { movie, tv }

@HiveType(typeId: 0)
class WatchHistory extends HiveObject {
  @HiveField(0)
  String imdbId;

  @HiveField(1)
  String title;

  @HiveField(2)
  String posterPath;

  @HiveField(3)
  int progressSeconds;

  @HiveField(4)
  int totalSeconds;

  @HiveField(5)
  DateTime lastWatched;

  @HiveField(6)
  String mediaType; // 'movie' or 'tv'

  @HiveField(7)
  int? season;

  @HiveField(8)
  int? episode;

  @HiveField(9)
  String? episodeName;

  /// TMDB integer ID — used for routing to /details/:type/:id
  /// (added in v2.1; legacy entries may have 0)
  @HiveField(10)
  int tmdbId;

  WatchHistory({
    required this.imdbId,
    required this.title,
    required this.posterPath,
    required this.progressSeconds,
    required this.totalSeconds,
    required this.lastWatched,
    required this.mediaType,
    this.season,
    this.episode,
    this.episodeName,
    this.tmdbId = 0,
  });

  double get progressPercent =>
      totalSeconds > 0 ? progressSeconds / totalSeconds : 0;

  bool get isFinished => progressPercent > 0.90;

  String get displaySubtitle {
    if (mediaType == 'tv' && season != null && episode != null) {
      return 'S${season!.toString().padLeft(2, '0')}E${episode!.toString().padLeft(2, '0')}${episodeName != null ? ' - $episodeName' : ''}';
    }
    return '';
  }
}

/// TMDB API Response Models
class TmdbMedia {
  final int id;
  final String title;
  final String? posterPath;
  final String? backdropPath;
  final String? overview;
  final double voteAverage;
  final String? releaseDate;
  final String? firstAirDate;
  final MediaType mediaType;
  final String? imdbId;

  TmdbMedia({
    required this.id,
    required this.title,
    this.posterPath,
    this.backdropPath,
    this.overview,
    required this.voteAverage,
    this.releaseDate,
    this.firstAirDate,
    required this.mediaType,
    this.imdbId,
  });

  String get year {
    final date = releaseDate ?? firstAirDate ?? '';
    return date.length >= 4 ? date.substring(0, 4) : '';
  }

  String get posterUrl =>
      posterPath != null ? 'https://image.tmdb.org/t/p/w342$posterPath' : '';

  String get backdropUrl =>
      backdropPath != null ? 'https://image.tmdb.org/t/p/w1280$backdropPath' : '';

  String get posterUrlLow =>
      posterPath != null ? 'https://image.tmdb.org/t/p/w185$posterPath' : '';

  factory TmdbMedia.fromJson(Map<String, dynamic> json) {
    final isMovie = json['media_type'] == 'movie' ||
        json.containsKey('release_date') && !json.containsKey('first_air_date');
    return TmdbMedia(
      id: json['id'],
      title: json['title'] ?? json['name'] ?? 'Unknown',
      posterPath: json['poster_path'],
      backdropPath: json['backdrop_path'],
      overview: json['overview'],
      voteAverage: (json['vote_average'] ?? 0).toDouble(),
      releaseDate: json['release_date'],
      firstAirDate: json['first_air_date'],
      mediaType: isMovie ? MediaType.movie : MediaType.tv,
      imdbId: json['imdb_id'],
    );
  }
}

class TmdbDetails extends TmdbMedia {
  final List<Genre> genres;
  final List<Season> seasons;
  final int? runtime;
  final String? status;
  final int? numberOfSeasons;
  final int? numberOfEpisodes;
  final List<Cast> cast;
  final int voteCount;          // P12: for "7.4 (3.2K)" badge
  final String? trailerKey;     // P11: YouTube key for trailer button

  TmdbDetails({
    required super.id,
    required super.title,
    super.posterPath,
    super.backdropPath,
    super.overview,
    required super.voteAverage,
    super.releaseDate,
    super.firstAirDate,
    required super.mediaType,
    super.imdbId,
    required this.genres,
    required this.seasons,
    this.runtime,
    this.status,
    this.numberOfSeasons,
    this.numberOfEpisodes,
    required this.cast,
    this.voteCount = 0,
    this.trailerKey,
  });

  factory TmdbDetails.fromJson(Map<String, dynamic> json, MediaType type) {
    // P11: Extract trailer key from videos appendix
    String? trailerKey;
    final videos = json['videos']?['results'] as List?;
    if (videos != null && videos.isNotEmpty) {
      final trailer = videos.firstWhere(
        (v) => v['type'] == 'Trailer' && v['site'] == 'YouTube',
        orElse: () => videos.first,
      );
      trailerKey = trailer['key'] as String?;
    }

    return TmdbDetails(
      id: json['id'],
      title: json['title'] ?? json['name'] ?? 'Unknown',
      posterPath: json['poster_path'],
      backdropPath: json['backdrop_path'],
      overview: json['overview'],
      voteAverage: (json['vote_average'] ?? 0).toDouble(),
      releaseDate: json['release_date'],
      firstAirDate: json['first_air_date'],
      mediaType: type,
      imdbId: json['imdb_id'] ?? json['external_ids']?['imdb_id'],
      genres: (json['genres'] as List? ?? [])
          .map((g) => Genre.fromJson(g))
          .toList(),
      seasons: (json['seasons'] as List? ?? [])
          .where((s) => s['season_number'] > 0)
          .map((s) => Season.fromJson(s))
          .toList(),
      runtime: json['runtime'],
      status: json['status'],
      numberOfSeasons: json['number_of_seasons'],
      numberOfEpisodes: json['number_of_episodes'],
      cast: ((json['credits']?['cast'] ?? []) as List)
          .take(15)
          .map((c) => Cast.fromJson(c))
          .toList(),
      voteCount: json['vote_count'] ?? 0,
      trailerKey: trailerKey,
    );
  }

  /// Convenience: extract raw genre IDs for the taste-profile engine.
  List<int> get genreIds => genres.map((g) => g.id).toList();
}

class Genre {
  final int id;
  final String name;
  Genre({required this.id, required this.name});
  factory Genre.fromJson(Map<String, dynamic> j) =>
      Genre(id: j['id'], name: j['name']);
}

class Season {
  final int seasonNumber;
  final String name;
  final int episodeCount;
  final String? posterPath;
  Season({
    required this.seasonNumber,
    required this.name,
    required this.episodeCount,
    this.posterPath,
  });
  factory Season.fromJson(Map<String, dynamic> j) => Season(
        seasonNumber: j['season_number'],
        name: j['name'],
        episodeCount: j['episode_count'],
        posterPath: j['poster_path'],
      );
}

class Episode {
  final int episodeNumber;
  final int seasonNumber;
  final String name;
  final String? overview;
  final String? stillPath;
  final double? voteAverage;
  final int? runtime;

  Episode({
    required this.episodeNumber,
    required this.seasonNumber,
    required this.name,
    this.overview,
    this.stillPath,
    this.voteAverage,
    this.runtime,
  });

  String get stillUrl =>
      stillPath != null ? 'https://image.tmdb.org/t/p/w300$stillPath' : '';

  factory Episode.fromJson(Map<String, dynamic> j) => Episode(
        episodeNumber: j['episode_number'],
        seasonNumber: j['season_number'],
        name: j['name'],
        overview: j['overview'],
        stillPath: j['still_path'],
        voteAverage: (j['vote_average'] ?? 0).toDouble(),
        runtime: j['runtime'],
      );
}

class Cast {
  final String name;
  final String? profilePath;
  final String character;
  Cast({required this.name, this.profilePath, required this.character});
  factory Cast.fromJson(Map<String, dynamic> j) => Cast(
        name: j['name'],
        profilePath: j['profile_path'],
        character: j['character'] ?? '',
      );
  String get profileUrl =>
      profilePath != null ? 'https://image.tmdb.org/t/p/w185$profilePath' : '';
}

class StreamResult {
  final bool success;
  final String? primaryStream;
  final List<String> allStreams;
  final String provider;
  final String referer;
  final String? error;

  StreamResult({
    required this.success,
    this.primaryStream,
    required this.allStreams,
    required this.provider,
    required this.referer,
    this.error,
  });

  factory StreamResult.fromJson(Map<String, dynamic> j) => StreamResult(
        success: j['success'] ?? false,
        primaryStream: j['primary'],
        allStreams: (j['streams'] as List? ?? []).cast<String>(),
        provider: j['provider'] ?? '',
        referer: j['referer'] ?? '',
        error: j['error'],
      );

  factory StreamResult.error(String message) => StreamResult(
        success: false,
        allStreams: [],
        provider: '',
        referer: '',
        error: message,
      );
}
