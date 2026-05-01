import 'package:dio/dio.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import '../models/media_model.dart';

/// Handles stream extraction via the Cloudflare Worker proxy.
/// The worker implements a 5-provider waterfall with browser-like headers
/// to bypass Cloudflare bot protection.
///
/// Referrer trick: The worker returns the provider's referer alongside the
/// stream URL. We inject it into media_kit's network headers so the CDN
/// accepts our segment requests without 403/403 errors.
class ExtractorService {
  late final Dio _dio;
  late final String _workerUrl;

  ExtractorService() {
    _workerUrl = dotenv.env['EXTRACTOR_WORKER_URL'] ?? '';
    _dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 20),
      receiveTimeout: const Duration(seconds: 30),
    ));
  }

  /// Extract stream for a movie.
  /// Returns a [StreamResult] with the primary .m3u8 URL and the referer
  /// needed to play it without 403 errors.
  Future<StreamResult> extractMovie(String imdbId) async {
    try {
      final res = await _dio.get('$_workerUrl/extract', queryParameters: {
        'imdb': imdbId,
        'type': 'movie',
      });
      return StreamResult.fromJson(Map<String, dynamic>.from(res.data));
    } on DioException catch (e) {
      return StreamResult.error(
        e.response?.data?['error'] ?? e.message ?? 'Network error',
      );
    } catch (e) {
      return StreamResult.error(e.toString());
    }
  }

  /// Extract stream for a TV episode.
  Future<StreamResult> extractEpisode(
    String imdbId,
    int season,
    int episode,
  ) async {
    try {
      final res = await _dio.get('$_workerUrl/extract', queryParameters: {
        'imdb': imdbId,
        'type': 'tv',
        'season': season,
        'episode': episode,
      });
      return StreamResult.fromJson(Map<String, dynamic>.from(res.data));
    } on DioException catch (e) {
      return StreamResult.error(
        e.response?.data?['error'] ?? e.message ?? 'Network error',
      );
    } catch (e) {
      return StreamResult.error(e.toString());
    }
  }

  /// Builds a proxied stream URL for HLS segment requests.
  /// This fixes CDN referer checks on .ts chunks by routing them
  /// through the worker proxy.
  String buildProxiedUrl(String rawUrl, String referer) {
    final encoded = Uri.encodeComponent(rawUrl);
    final encodedRef = Uri.encodeComponent(referer);
    return '$_workerUrl/proxy?url=$encoded&referer=$encodedRef';
  }

  /// Build media_kit-compatible HTTP headers map.
  /// Inject the referer so the CDN doesn't block playback.
  Map<String, String> buildPlayerHeaders(String referer) {
    return {
      'Referer': referer,
      'Origin': referer,
      'User-Agent':
          'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36',
    };
  }
}
