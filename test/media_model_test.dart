import 'package:flutter_test/flutter_test.dart';
import 'package:atmos/models/media_model.dart';

void main() {
  group('Media Model JSON/Map Deserialization Tests', () {
    test('Genre.fromJson works with dynamic maps', () {
      final dynamicMap = <dynamic, dynamic>{
        'id': 28,
        'name': 'Action',
      };
      final genre = Genre.fromJson(dynamicMap);
      expect(genre.id, 28);
      expect(genre.name, 'Action');
    });

    test('Season.fromJson works with dynamic maps', () {
      final dynamicMap = <dynamic, dynamic>{
        'season_number': 1,
        'name': 'Season 1',
        'episode_count': 10,
        'poster_path': '/path.jpg',
      };
      final season = Season.fromJson(dynamicMap);
      expect(season.seasonNumber, 1);
      expect(season.name, 'Season 1');
      expect(season.episodeCount, 10);
      expect(season.posterPath, '/path.jpg');
    });

    test('Episode.fromJson works with dynamic maps', () {
      final dynamicMap = <dynamic, dynamic>{
        'episode_number': 5,
        'season_number': 1,
        'name': 'Episode 5',
        'overview': 'Episode overview',
        'still_path': '/still.jpg',
        'vote_average': 8.5,
        'runtime': 45,
      };
      final episode = Episode.fromJson(dynamicMap);
      expect(episode.episodeNumber, 5);
      expect(episode.seasonNumber, 1);
      expect(episode.name, 'Episode 5');
      expect(episode.overview, 'Episode overview');
      expect(episode.stillPath, '/still.jpg');
      expect(episode.voteAverage, 8.5);
      expect(episode.runtime, 45);
    });

    test('Cast.fromJson works with dynamic maps', () {
      final dynamicMap = <dynamic, dynamic>{
        'name': 'Actor Name',
        'profile_path': '/profile.jpg',
        'character': 'Character Name',
      };
      final cast = Cast.fromJson(dynamicMap);
      expect(cast.name, 'Actor Name');
      expect(cast.profilePath, '/profile.jpg');
      expect(cast.character, 'Character Name');
    });

    test('TmdbMedia.fromJson works with dynamic maps', () {
      final dynamicMap = <dynamic, dynamic>{
        'id': 12345,
        'title': 'Test Movie',
        'poster_path': '/poster.jpg',
        'backdrop_path': '/backdrop.jpg',
        'overview': 'Overview text',
        'vote_average': 7.8,
        'release_date': '2026-05-20',
        'media_type': 'movie',
        'imdb_id': 'tt1234567',
      };
      final media = TmdbMedia.fromJson(dynamicMap);
      expect(media.id, 12345);
      expect(media.title, 'Test Movie');
      expect(media.posterPath, '/poster.jpg');
      expect(media.backdropPath, '/backdrop.jpg');
      expect(media.overview, 'Overview text');
      expect(media.voteAverage, 7.8);
      expect(media.releaseDate, '2026-05-20');
      expect(media.mediaType, MediaType.movie);
      expect(media.imdbId, 'tt1234567');
    });

    test('TmdbDetails.fromJson works with dynamic maps (Hive fallback)', () {
      final dynamicMap = <dynamic, dynamic>{
        'id': 12345,
        'title': 'Test Movie Details',
        'poster_path': '/poster.jpg',
        'backdrop_path': '/backdrop.jpg',
        'overview': 'Detailed overview',
        'vote_average': 8.2,
        'release_date': '2026-05-20',
        'imdb_id': 'tt1234567',
        'genres': <dynamic>[
          <dynamic, dynamic>{'id': 28, 'name': 'Action'},
          <dynamic, dynamic>{'id': 12, 'name': 'Adventure'},
        ],
        'seasons': <dynamic>[
          <dynamic, dynamic>{
            'season_number': 1,
            'name': 'Season 1',
            'episode_count': 8,
            'poster_path': '/season1.jpg',
          }
        ],
        'runtime': 120,
        'status': 'Released',
        'credits': <dynamic, dynamic>{
          'cast': <dynamic>[
            <dynamic, dynamic>{
              'name': 'Actor 1',
              'profile_path': '/actor1.jpg',
              'character': 'Hero',
            }
          ]
        },
        'vote_count': 1000,
        'videos': <dynamic, dynamic>{
          'results': <dynamic>[
            <dynamic, dynamic>{
              'type': 'Trailer',
              'site': 'YouTube',
              'key': 'youtube_key',
            }
          ]
        }
      };

      final details = TmdbDetails.fromJson(dynamicMap, MediaType.movie);
      expect(details.id, 12345);
      expect(details.title, 'Test Movie Details');
      expect(details.genres.length, 2);
      expect(details.genres[0].name, 'Action');
      expect(details.seasons.length, 1);
      expect(details.seasons[0].seasonNumber, 1);
      expect(details.cast.length, 1);
      expect(details.cast[0].name, 'Actor 1');
      expect(details.trailerKey, 'youtube_key');
    });
  });
}
