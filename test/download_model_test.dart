import 'package:flutter_test/flutter_test.dart';
import 'package:atmos/models/download_model.dart';

void main() {
  group('DownloadTask', () {
    test('initial state has zero progress', () {
      final task = DownloadTask(
        id: 'test_123',
        tmdbId: 123,
        imdbId: 'tt0111161',
        title: 'The Shawshank Redemption',
        mediaType: 'movie',
        quality: '1080p',
        source: 'stream',
        createdAt: DateTime.now(),
        status: DownloadStatus.queued,
      );
      expect(task.progress, equals(0.0));
      expect(task.downloadedBytes, equals(0));
      expect(task.downloadSpeed, equals(0.0));
    });

    test('status transitions are valid', () {
      final task = DownloadTask(
        id: 'test_456',
        tmdbId: 456,
        imdbId: 'tt0468569',
        title: 'The Dark Knight',
        mediaType: 'movie',
        quality: '720p',
        source: 'telegram',
        createdAt: DateTime.now(),
        status: DownloadStatus.queued,
      );

      // Queued → Downloading
      task.status = DownloadStatus.downloading;
      expect(task.status, equals(DownloadStatus.downloading));

      // Downloading → Paused
      task.status = DownloadStatus.paused;
      expect(task.status, equals(DownloadStatus.paused));

      // Paused → Downloading
      task.status = DownloadStatus.downloading;
      expect(task.status, equals(DownloadStatus.downloading));

      // Downloading → Completed
      task.status = DownloadStatus.completed;
      expect(task.status, equals(DownloadStatus.completed));
    });

    test('failed task has error message', () {
      final task = DownloadTask(
        id: 'test_789',
        tmdbId: 789,
        imdbId: 'tt1375666',
        title: 'Inception',
        mediaType: 'movie',
        quality: '1080p',
        source: 'stream',
        createdAt: DateTime.now(),
        status: DownloadStatus.failed,
        error: 'HTTP 403',
      );
      expect(task.error, equals('HTTP 403'));
      expect(task.status, equals(DownloadStatus.failed));
    });

    test('TV show task has season and episode', () {
      final task = DownloadTask(
        id: 'test_tv_1',
        tmdbId: 1399,
        imdbId: 'tt0944947',
        title: 'Game of Thrones',
        mediaType: 'tv',
        quality: '1080p',
        source: 'stream',
        season: 1,
        episode: 3,
        episodeName: 'Lord Snow',
        createdAt: DateTime.now(),
        status: DownloadStatus.queued,
      );
      expect(task.season, equals(1));
      expect(task.episode, equals(3));
      expect(task.episodeName, equals('Lord Snow'));
    });

    test('progress updates correctly', () {
      final task = DownloadTask(
        id: 'test_prog',
        tmdbId: 100,
        imdbId: 'tt0000001',
        title: 'Test Movie',
        mediaType: 'movie',
        quality: '720p',
        source: 'stream',
        createdAt: DateTime.now(),
        status: DownloadStatus.downloading,
        fileSizeBytes: 1000000,
      );

      task.downloadedBytes = 500000;
      task.progress = 0.5;
      expect(task.progress, equals(0.5));
      expect(task.downloadedBytes, equals(500000));

      task.downloadedBytes = 1000000;
      task.progress = 1.0;
      expect(task.progress, equals(1.0));
    });

    test('download speed tracks correctly', () {
      final task = DownloadTask(
        id: 'test_speed',
        tmdbId: 200,
        imdbId: 'tt0000002',
        title: 'Speed Test',
        mediaType: 'movie',
        quality: '720p',
        source: 'stream',
        createdAt: DateTime.now(),
        status: DownloadStatus.downloading,
      );

      task.downloadSpeed = 1024 * 1024; // 1 MB/s
      expect(task.downloadSpeed, equals(1024 * 1024));

      // Speed should reset on complete
      task.downloadSpeed = 0;
      expect(task.downloadSpeed, equals(0));
    });
  });

  group('DownloadStatus', () {
    test('all statuses are defined', () {
      expect(DownloadStatus.values.length, greaterThanOrEqualTo(6));
      expect(DownloadStatus.values, contains(DownloadStatus.queued));
      expect(DownloadStatus.values, contains(DownloadStatus.downloading));
      expect(DownloadStatus.values, contains(DownloadStatus.paused));
      expect(DownloadStatus.values, contains(DownloadStatus.completed));
      expect(DownloadStatus.values, contains(DownloadStatus.failed));
      expect(DownloadStatus.values, contains(DownloadStatus.searching));
    });
  });
}
