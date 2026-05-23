import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_dotenv/flutter_dotenv.dart';

/// Flutter client for the Atmos HuggingFace Space torrent caching proxy.
///
/// Flow:
///   1. Submit a magnet link via [submitMagnet]
///   2. Poll status via [pollStatus] until completed
///   3. Get the stream URL via [getStreamUrl]
///   4. Player switches to the HF-cached stream (seekable, fast)
class TorrentCacheService {
  static const _timeout = Duration(seconds: 10);
  static const _ua = 'Atmos-App/2.0';

  String get _baseUrl {
    // Primary: env-configured URL, Fallback: default HF Space
    final envUrl = dotenv.env['HF_SPACE_URL'] ?? '';
    if (envUrl.isNotEmpty) return envUrl.trimRight();
    return 'https://nikhil1776-torrentindex.hf.space';
  }

  /// Check if the caching server is alive and configured.
  /// If it is offline (e.g. HuggingFace space sleeping), it will send a wake-up request
  /// and retry up to 3 times to allow the container to boot.
  Future<CacheServerHealth> healthCheck() async {
    int attempts = 3;
    for (int i = 0; i < attempts; i++) {
      try {
        debugPrint('[TorrentCache] Checking server health (attempt ${i + 1}/$attempts)...');
        final resp = await http.get(
          Uri.parse('$_baseUrl/api/health'),
          headers: {'User-Agent': _ua},
        ).timeout(i == 0 ? const Duration(seconds: 5) : _timeout); // First attempt fast timeout to start wakeup

        if (resp.statusCode == 200) {
          final data = jsonDecode(resp.body);
          return CacheServerHealth(
            isOnline: true,
            aria2Running: data['aria2'] == true,
            gdriveConfigured: data['gdrive'] == true,
            geminiConfigured: data['gemini'] == true,
            cacheExpiryHours: data['cache_expiry_hours'] ?? 24,
          );
        }
      } catch (e) {
        debugPrint('[TorrentCache] Health check attempt ${i + 1} failed: $e');
      }
      if (i < attempts - 1) {
        // Wait 3 seconds before retrying to give HuggingFace space time to spin up
        await Future.delayed(const Duration(seconds: 3));
      }
    }
    return const CacheServerHealth(isOnline: false);
  }

  /// Submit a magnet link for torrent→GDrive caching.
  /// Returns a task ID to poll for progress.
  Future<String?> submitMagnet(String magnetLink) async {
    try {
      debugPrint('[TorrentCache] Submitting magnet for caching...');
      final resp = await http.post(
        Uri.parse('$_baseUrl/api/torrent-to-drive'),
        headers: {
          'Content-Type': 'application/json',
          'User-Agent': _ua,
        },
        body: jsonEncode({'magnet_link': magnetLink}),
      ).timeout(_timeout);

      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body);
        final taskId = data['task_id'] as String?;
        debugPrint('[TorrentCache] ✅ Magnet submitted, task_id=$taskId');
        return taskId;
      } else {
        debugPrint('[TorrentCache] Submit failed: ${resp.statusCode} ${resp.body}');
      }
    } catch (e) {
      debugPrint('[TorrentCache] Submit error: $e');
    }
    return null;
  }

  /// Poll for task status. Returns the current state of the download/upload.
  Future<CacheTaskStatus> pollStatus(String taskId) async {
    try {
      final resp = await http.get(
        Uri.parse('$_baseUrl/api/status/$taskId'),
        headers: {'User-Agent': _ua},
      ).timeout(_timeout);

      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body);
        return CacheTaskStatus(
          taskId: taskId,
          status: data['status'] ?? 'unknown',
          progress: (data['progress'] ?? 0).toInt(),
          filename: data['filename'] ?? '',
          fileId: data['file_id'] as String?,
          streamUrl: data['stream_url'] as String?,
          error: data['error'] as String?,
        );
      } else if (resp.statusCode == 404) {
        return CacheTaskStatus(taskId: taskId, status: 'not_found');
      }
    } catch (e) {
      debugPrint('[TorrentCache] Poll error: $e');
    }
    return CacheTaskStatus(taskId: taskId, status: 'error', error: 'Network error');
  }

  /// Get full stream URL from a GDrive file ID.
  String getStreamUrl(String fileId) => '$_baseUrl/api/stream/$fileId';

  /// Submit magnet and poll until complete, with progress callback.
  /// Returns the stream URL on success, null on failure.
  Future<String?> cacheAndWaitForStream(
    String magnetLink, {
    void Function(CacheTaskStatus status)? onProgress,
    Duration pollInterval = const Duration(seconds: 5),
    Duration maxWait = const Duration(minutes: 30),
  }) async {
    final taskId = await submitMagnet(magnetLink);
    if (taskId == null) return null;

    final deadline = DateTime.now().add(maxWait);

    while (DateTime.now().isBefore(deadline)) {
      await Future.delayed(pollInterval);

      final status = await pollStatus(taskId);
      onProgress?.call(status);

      if (status.status == 'completed' && status.fileId != null) {
        final streamUrl = getStreamUrl(status.fileId!);
        debugPrint('[TorrentCache] ✅ Cache complete: $streamUrl');
        return streamUrl;
      }

      if (status.status == 'failed' || status.status == 'error') {
        debugPrint('[TorrentCache] ❌ Caching failed: ${status.error}');
        return null;
      }
    }

    debugPrint('[TorrentCache] ⏰ Timed out waiting for cache');
    return null;
  }
}

// ── Models ───────────────────────────────────────────────────────────────────

class CacheServerHealth {
  final bool isOnline;
  final bool aria2Running;
  final bool gdriveConfigured;
  final bool geminiConfigured;
  final int cacheExpiryHours;

  const CacheServerHealth({
    this.isOnline = false,
    this.aria2Running = false,
    this.gdriveConfigured = false,
    this.geminiConfigured = false,
    this.cacheExpiryHours = 24,
  });

  bool get isFullyOperational => isOnline && aria2Running && gdriveConfigured;
}

class CacheTaskStatus {
  final String taskId;
  final String status; // 'active', 'downloading', 'uploading', 'completed', 'failed'
  final int progress; // 0-100
  final String filename;
  final String? fileId;
  final String? streamUrl;
  final String? error;

  const CacheTaskStatus({
    required this.taskId,
    this.status = 'unknown',
    this.progress = 0,
    this.filename = '',
    this.fileId,
    this.streamUrl,
    this.error,
  });

  bool get isComplete => status == 'completed';
  bool get isFailed => status == 'failed' || status == 'error';
  bool get isActive => !isComplete && !isFailed;
}
