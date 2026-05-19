import 'package:flutter_test/flutter_test.dart';
import 'package:atmos/services/stream_extractor_service.dart';

void main() {
  group('ExtractedStream', () {
    test('isHls detects m3u8 URLs', () {
      const stream = ExtractedStream(
        url: 'https://cdn.example.com/video.m3u8',
        headers: {},
        providerName: 'Test',
      );
      expect(stream.isHls, isTrue);
      expect(stream.isMp4, isFalse);
    });

    test('isMp4 detects mp4 URLs', () {
      const stream = ExtractedStream(
        url: 'https://cdn.example.com/video.mp4',
        headers: {},
        providerName: 'Test',
      );
      expect(stream.isMp4, isTrue);
      expect(stream.isHls, isFalse);
    });

    test('hasSubtitles returns true when subs exist', () {
      const stream = ExtractedStream(
        url: 'https://example.com/v.mp4',
        headers: {},
        providerName: 'Test',
        subtitles: [SubtitleInfo(url: 'https://sub.vtt', lang: 'eng')],
      );
      expect(stream.hasSubtitles, isTrue);
    });

    test('hasQualities returns true with multiple qualities', () {
      const stream = ExtractedStream(
        url: 'https://example.com/v.mp4',
        headers: {},
        providerName: 'Test',
        qualities: [
          QualityOption(quality: '1080p', url: 'https://a.mp4'),
          QualityOption(quality: '720p', url: 'https://b.mp4'),
        ],
      );
      expect(stream.hasQualities, isTrue);
    });

    test('hasQualities returns false with single quality', () {
      const stream = ExtractedStream(
        url: 'https://example.com/v.mp4',
        headers: {},
        providerName: 'Test',
        qualities: [QualityOption(quality: '720p', url: 'https://a.mp4')],
      );
      expect(stream.hasQualities, isFalse);
    });
  });

  group('SubtitleInfo', () {
    test('displayLabel uses label when available', () {
      const sub = SubtitleInfo(url: 'https://s.vtt', lang: 'eng', label: 'English');
      expect(sub.displayLabel, equals('English'));
    });

    test('displayLabel falls back to uppercase lang', () {
      const sub = SubtitleInfo(url: 'https://s.vtt', lang: 'eng');
      expect(sub.displayLabel, equals('ENG'));
    });
  });

  group('StreamExtractorService', () {
    late StreamExtractorService service;

    setUp(() {
      service = StreamExtractorService();
    });

    test('availableProviders has 5 providers', () {
      expect(StreamExtractorService.availableProviders.length, equals(5));
      expect(StreamExtractorService.availableProviders,
          contains('VidAPI'));
      expect(StreamExtractorService.availableProviders,
          contains('AutoEmbed'));
      expect(StreamExtractorService.availableProviders,
          contains('Videasy'));
      expect(StreamExtractorService.availableProviders,
          contains('VidSrc'));
      expect(StreamExtractorService.availableProviders,
          contains('2Embed'));
    });

    test('extractWithStatus returns null for empty IDs', () async {
      final result = await service.extractWithStatus(
        imdbId: '',
        tmdbId: '',
        type: 'movie',
      );
      expect(result, isNull);
    });

    test('extractWithStatus returns null for zero tmdbId', () async {
      final result = await service.extractWithStatus(
        imdbId: '',
        tmdbId: '0',
        type: 'movie',
      );
      expect(result, isNull);
    });

    test('status callback fires trying for all providers', () async {
      final statuses = <String, ProviderStatus>{};

      // This will timeout since we can't reach real APIs in test
      // but should fire 'trying' for all providers
      await service.extractWithStatus(
        imdbId: 'tt0111161',
        tmdbId: '278',
        type: 'movie',
        onStatus: (name, status) {
          // Capture the first status for each provider
          statuses.putIfAbsent(name, () => status);
        },
      );

      // All providers should have been attempted
      expect(statuses.length, equals(5));
      for (final entry in statuses.entries) {
        expect(entry.value, equals(ProviderStatus.trying),
            reason: '${entry.key} should have fired trying');
      }
    });

    test('extractFromProvider returns null for unknown provider', () async {
      final result = await service.extractFromProvider(
        providerName: 'FakeProvider',
        imdbId: 'tt0111161',
        tmdbId: '278',
        type: 'movie',
      );
      expect(result, isNull);
    });
  });

  group('QualityOption', () {
    test('toString formats correctly', () {
      const q = QualityOption(quality: '1080p', url: 'https://a.mp4');
      expect(q.toString(), contains('1080p'));
    });
  });
}
