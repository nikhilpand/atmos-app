import 'dart:async';
import 'dart:io';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/download_model.dart';
import 'telegram_service.dart';

/// Central download engine — Telegram CDN only.
///
/// Routes all downloads through TDLib's file download API:
///   - AtmosIndex catalog search → resolve file_id → TDLib downloadFile
///   - Supports full-season batch downloads
///
/// Torrent engine has been removed to reduce APK size and library count.
class DownloadService extends ChangeNotifier {
  static const _boxName = 'downloads_v1';

  late Box<DownloadTask> _box;
  int _maxConcurrent = 2;
  bool _wifiOnly = false;
  TelegramService? telegramService;

  // Speed tracking for Telegram: fileId → (lastBytes, lastTimestamp)
  final _telegramSpeedMap = <int, ({int bytes, DateTime at})>{};

  // Debounce: batch all progress updates and fire a single notifyListeners()
  bool _pendingNotify = false;

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  Future<void> init(String downloadDir) async {
    if (!Hive.isAdapterRegistered(10)) {
      Hive.registerAdapter(DownloadStatusAdapter());
    }
    if (!Hive.isAdapterRegistered(11)) {
      Hive.registerAdapter(QualityOptionAdapter());
    }
    if (!Hive.isAdapterRegistered(12)) {
      Hive.registerAdapter(DownloadTaskAdapter());
    }
    _box = await Hive.openBox<DownloadTask>(_boxName);

    // Load persisted settings
    final prefs = await SharedPreferences.getInstance();
    _maxConcurrent = prefs.getInt('dl_max_concurrent') ?? 2;
    _wifiOnly = prefs.getBool('dl_wifi_only') ?? false;

    // Reset any stale "downloading" tasks from last session
    for (final task in _box.values) {
      if (task.status == DownloadStatus.downloading ||
          task.status == DownloadStatus.searching ||
          task.status == DownloadStatus.converting) {
        task.status = DownloadStatus.paused;
        await task.save();
      }
    }
    notifyListeners();
  }

  /// Reload settings after user changes them in Settings screen.
  Future<void> reloadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    _maxConcurrent = prefs.getInt('dl_max_concurrent') ?? 2;
    _wifiOnly = prefs.getBool('dl_wifi_only') ?? false;
  }

  @override
  void dispose() {
    _box.close();
    super.dispose();
  }

  // ── Public API ────────────────────────────────────────────────────────────

  List<DownloadTask> get allTasks =>
      _box.values.toList()
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

  List<DownloadTask> get active => allTasks
      .where((t) =>
          t.status == DownloadStatus.downloading ||
          t.status == DownloadStatus.searching ||
          t.status == DownloadStatus.converting ||
          t.status == DownloadStatus.paused ||
          t.status == DownloadStatus.queued ||
          t.status == DownloadStatus.failed)
      .toList();

  List<DownloadTask> get completed =>
      allTasks.where((t) => t.status == DownloadStatus.completed).toList();

  DownloadTask? getTask(String id) => _box.get(id);

  bool isDownloaded(int tmdbId, {int? season, int? episode}) {
    return allTasks.any((t) =>
        t.tmdbId == tmdbId &&
        t.status == DownloadStatus.completed &&
        (season == null || t.season == season) &&
        (episode == null || t.episode == episode));
  }

  bool isDownloading(int tmdbId, {int? season, int? episode}) {
    return allTasks.any((t) =>
        t.tmdbId == tmdbId &&
        (t.status == DownloadStatus.downloading ||
            t.status == DownloadStatus.searching ||
            t.status == DownloadStatus.queued) &&
        (season == null || t.season == season) &&
        (episode == null || t.episode == episode));
  }

  /// Queue a new download from a [QualityOption] source.
  Future<DownloadTask> startDownload({
    required int tmdbId,
    required String imdbId,
    required String title,
    required String mediaType,
    required QualityOption quality,
    int? season,
    int? episode,
    String? episodeName,
    String? posterPath,
  }) async {
    // ── Wi-Fi check
    if (_wifiOnly) {
      final conn = await Connectivity().checkConnectivity();
      if (!conn.contains(ConnectivityResult.wifi)) {
        final fakeTask = DownloadTask(
          id: _buildId(tmdbId, season, episode, quality.quality),
          tmdbId: tmdbId, imdbId: imdbId, title: title, mediaType: mediaType,
          season: season, episode: episode, episodeName: episodeName,
          quality: quality.quality, posterPath: posterPath,
          fileSizeBytes: quality.sizeBytes, audioChannels: quality.audioChannels,
          videoCodec: quality.videoCodec, source: 'telegram',
          telegramFileId: quality.telegramFileId, createdAt: DateTime.now(),
          status: DownloadStatus.failed,
          error: 'Wi-Fi Only mode is on. Connect to Wi-Fi to download.',
        );
        await _box.put(fakeTask.id, fakeTask);
        _scheduleNotify();
        return fakeTask;
      }
    }

    final id = _buildId(tmdbId, season, episode, quality.quality);

    // Avoid duplicate
    if (_box.containsKey(id)) {
      final existing = _box.get(id)!;
      if (existing.status != DownloadStatus.failed) return existing;
      await existing.delete();
    }

    final task = DownloadTask(
      id: id,
      tmdbId: tmdbId,
      imdbId: imdbId,
      title: title,
      mediaType: mediaType,
      season: season,
      episode: episode,
      episodeName: episodeName,
      quality: quality.quality,
      posterPath: posterPath,
      fileSizeBytes: quality.sizeBytes,
      audioChannels: quality.audioChannels,
      videoCodec: quality.videoCodec,
      source: 'telegram',
      telegramFileId: quality.telegramFileId,
      createdAt: DateTime.now(),
      status: DownloadStatus.queued,
    );
    await _box.put(id, task);
    _scheduleNotify();

    // Start immediately if under limit
    final activeCount = active.where((t) =>
        t.status == DownloadStatus.downloading ||
        t.status == DownloadStatus.searching ||
        t.status == DownloadStatus.converting).length;

    if (activeCount < _maxConcurrent) {
      _processTelegramTask(task, quality.telegramFileId);
    }
    return task;
  }

  /// Retry a failed task.
  Future<void> retryTask(String id) async {
    final task = _box.get(id);
    if (task == null || task.status != DownloadStatus.failed) return;
    task.status = DownloadStatus.queued;
    task.error = null;
    task.progress = 0;
    task.downloadedBytes = 0;
    await task.save();
    _scheduleNotify();
    _requeue(task);
  }

  /// Download from an HTTP stream URL (MP4 direct download).
  /// For HLS (.m3u8), we download the master playlist and pick the best quality segment list.
  Future<DownloadTask> startStreamDownload({
    required int tmdbId,
    required String imdbId,
    required String title,
    required String mediaType,
    required String streamUrl,
    required String quality,
    Map<String, String> headers = const {},
    int? season,
    int? episode,
    String? episodeName,
    String? posterPath,
  }) async {
    // Wi-Fi check
    if (_wifiOnly) {
      final conn = await Connectivity().checkConnectivity();
      if (!conn.contains(ConnectivityResult.wifi)) {
        final task = DownloadTask(
          id: _buildId(tmdbId, season, episode, 'stream_$quality'),
          tmdbId: tmdbId, imdbId: imdbId, title: title, mediaType: mediaType,
          season: season, episode: episode, episodeName: episodeName,
          quality: quality, posterPath: posterPath, source: 'stream',
          createdAt: DateTime.now(), status: DownloadStatus.failed,
          error: 'Wi-Fi Only mode is on.',
        );
        await _box.put(task.id, task);
        _scheduleNotify();
        return task;
      }
    }

    final id = _buildId(tmdbId, season, episode, 'stream_$quality');
    if (_box.containsKey(id)) {
      final existing = _box.get(id)!;
      if (existing.status != DownloadStatus.failed) return existing;
      await existing.delete();
    }

    final task = DownloadTask(
      id: id,
      tmdbId: tmdbId, imdbId: imdbId, title: title, mediaType: mediaType,
      season: season, episode: episode, episodeName: episodeName,
      quality: quality, posterPath: posterPath, source: 'stream',
      createdAt: DateTime.now(), status: DownloadStatus.downloading,
    );
    await _box.put(id, task);
    _scheduleNotify();

    // Run download in background
    _processHttpDownload(task, streamUrl, headers);
    return task;
  }

  /// HTTP download processor — handles MP4 direct downloads with progress.
  /// Supports HTTP Range-based resume for interrupted downloads.
  Future<void> _processHttpDownload(
    DownloadTask task, String url, Map<String, String> headers, {
    int maxRetries = 3,
  }) async {
    for (int attempt = 0; attempt <= maxRetries; attempt++) {
      try {
        final client = HttpClient();
        final request = await client.getUrl(Uri.parse(url));
        headers.forEach((k, v) => request.headers.set(k, v));

        // Build filename
        final safeTitle = task.title.replaceAll(RegExp(r'[^\w\s-]'), '').replaceAll(' ', '_');
        final ext = url.contains('.mkv') ? 'mkv' : 'mp4';
        final seasonTag = task.season != null ? '_S${task.season}E${task.episode}' : '';
        final dir = await _getDownloadDir();
        final filePath = '${dir.path}/$safeTitle${seasonTag}_${task.quality}.$ext';
        final file = File(filePath);

        // ── HTTP Range Resume ──
        // If partial file exists, resume from where we left off
        int startByte = 0;
        if (await file.exists()) {
          startByte = await file.length();
          if (startByte > 0) {
            request.headers.set('Range', 'bytes=$startByte-');
            debugPrint('[DownloadService] Resuming from byte $startByte');
          }
        }

        final response = await request.close();
        if (response.statusCode != 200 && response.statusCode != 206) {
          await _failTask(task, 'HTTP ${response.statusCode}');
          client.close();
          return;
        }

        // Get total size from Content-Range or Content-Length
        final contentRange = response.headers['content-range']?.first;
        int totalBytes;
        if (contentRange != null) {
          // Format: bytes 123-456/789
          final totalMatch = RegExp(r'/(\d+)').firstMatch(contentRange);
          totalBytes = int.tryParse(totalMatch?.group(1) ?? '') ?? -1;
        } else {
          totalBytes = response.contentLength + startByte;
        }
        if (totalBytes > 0) {
          task.fileSizeBytes = totalBytes;
        }

        // Open file in APPEND mode for resume, or WRITE for fresh start
        final sink = file.openWrite(mode: startByte > 0 ? FileMode.append : FileMode.write);

        int received = startByte;
        DateTime lastSpeedCheck = DateTime.now();
        int lastBytes = received;

        await for (final chunk in response) {
          if (task.status == DownloadStatus.paused) {
            await sink.close();
            client.close();
            return;
          }

          sink.add(chunk);
          received += chunk.length;

          // Calculate speed every 500ms
          final now = DateTime.now();
          final dt = now.difference(lastSpeedCheck).inMilliseconds;
          if (dt > 500) {
            final db = received - lastBytes;
            task.downloadSpeed = db / (dt / 1000.0);
            lastBytes = received;
            lastSpeedCheck = now;
          }

          task.downloadedBytes = received;
          task.progress = totalBytes > 0 ? received / totalBytes : 0;
          task.save();
          _scheduleNotify();
        }

        await sink.close();
        client.close();

        task.status = DownloadStatus.completed;
        task.filePath = filePath;
        task.progress = 1.0;
        task.downloadSpeed = 0;
        await task.save();
        _scheduleNotify();
        _processNextQueued();

        debugPrint('[DownloadService] Stream download complete: $filePath');
        return; // Success — exit retry loop
      } catch (e) {
        if (attempt < maxRetries) {
          // Exponential backoff: 2s, 4s, 8s
          final delay = Duration(seconds: (1 << attempt) * 2);
          debugPrint('[DownloadService] Retry ${attempt + 1}/$maxRetries in ${delay.inSeconds}s: $e');
          await Future.delayed(delay);
        } else {
          await _failTask(task, 'Stream download failed after ${maxRetries + 1} attempts: $e');
        }
      }
    }
  }

  Future<Directory> _getDownloadDir() async {
    // Use path_provider for reliable cross-device paths
    try {
      final extDirs = await getExternalStorageDirectories();
      if (extDirs != null && extDirs.isNotEmpty) {
        final dir = Directory('${extDirs.first.parent.parent.parent.parent.path}/Download/Atmos');
        if (!await dir.exists()) await dir.create(recursive: true);
        return dir;
      }
    } catch (_) {}
    // Fallback to app-specific directory
    final appDir = await getApplicationDocumentsDirectory();
    final dir = Directory('${appDir.path}/Atmos');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<void> pauseTask(String id) async {
    final task = _box.get(id);
    if (task == null) return;
    // Actually cancel the TDLib download to stop bandwidth waste
    if (task.telegramFileId != null && telegramService != null) {
      try {
        telegramService!.cancelDownload(task.telegramFileId!);
        debugPrint('[DownloadService] TDLib download cancelled for fileId: ${task.telegramFileId}');
      } catch (e) {
        debugPrint('[DownloadService] TDLib cancel failed (non-fatal): $e');
      }
    }
    task.status = DownloadStatus.paused;
    task.downloadSpeed = 0;
    await task.save();
    _scheduleNotify();
  }

  Future<void> resumeTask(String id) async {
    final task = _box.get(id);
    if (task == null || task.status != DownloadStatus.paused) return;

    if (task.telegramFileId == null || telegramService == null) {
      await _failTask(task, 'Telegram file ID missing — re-download needed');
      return;
    }
    task.status = DownloadStatus.downloading;
    await task.save();
    _scheduleNotify();
    telegramService!.downloadFile(task.telegramFileId!).catchError((e) async {
      await _failTask(task, 'Telegram resume failed: $e');
      return '';
    });
  }

  Future<void> deleteTask(String id) async {
    final task = _box.get(id);
    if (task == null) return;
    // Clean up speed tracker
    if (task.telegramFileId != null) {
      _telegramSpeedMap.remove(task.telegramFileId);
    }
    // Delete file
    if (task.filePath != null) {
      try { File(task.filePath!).deleteSync(); } catch (_) {}
    }
    await task.delete();
    _scheduleNotify();
  }

  // ── Season Batch Download ────────────────────────────────────────────────

  /// Download all episodes of a season. Queries AtmosIndex for the full
  /// episode list, resolves each to a TDLib file_id, and queues downloads.
  /// Returns list of queued DownloadTasks.
  Future<List<DownloadTask>> downloadSeason({
    required int tmdbId,
    required String imdbId,
    required String title,
    required int season,
    required int totalEpisodes,
    String? posterPath,
    String preferredQuality = '1080p',
  }) async {
    if (telegramService == null) return [];

    final indexClient = telegramService!.indexClient;
    if (!indexClient.isConfigured) {
      debugPrint('[DownloadService] AtmosIndex not configured for season download');
      return [];
    }

    debugPrint('[DownloadService] Starting season $season download: $title ($totalEpisodes episodes)');

    // 1. Get all episodes from the catalog
    final catalogResults = await indexClient.getSeason(title, season);
    debugPrint('[DownloadService] Catalog returned ${catalogResults.length} results for S$season');

    final tasks = <DownloadTask>[];

    // 2. For each episode, find best match and queue download
    for (int ep = 1; ep <= totalEpisodes; ep++) {
      // Skip already downloaded
      if (isDownloaded(tmdbId, season: season, episode: ep)) {
        debugPrint('[DownloadService] S${season}E$ep already downloaded, skipping');
        continue;
      }
      if (isDownloading(tmdbId, season: season, episode: ep)) {
        debugPrint('[DownloadService] S${season}E$ep already downloading, skipping');
        continue;
      }

      // Find best match for this episode
      final matches = catalogResults.where((r) => r.episode == ep).toList();
      if (matches.isEmpty) {
        debugPrint('[DownloadService] No catalog result for S${season}E$ep');
        continue;
      }

      // Prefer matching quality, fallback to first result
      final match = matches.firstWhere(
        (r) => r.quality == preferredQuality,
        orElse: () => matches.first,
      );

      // 3. Resolve channel+msgId to TDLib file_id
      final fileId = await telegramService!.resolveFileId(
        match.channelUsername,
        match.msgId,
      );

      if (fileId == null) {
        debugPrint('[DownloadService] Could not resolve file_id for S${season}E$ep');
        continue;
      }

      // 4. Queue the download
      final quality = QualityOption(
        quality: match.quality,
        hash: '',
        sizeBytes: match.fileSizeBytes,
        type: '@${match.channelUsername}',
        videoCodec: match.codec,
        audioChannels: match.audio,
        telegramFileId: fileId,
      );

      final task = await startDownload(
        tmdbId: tmdbId,
        imdbId: imdbId,
        title: title,
        mediaType: 'tv',
        quality: quality,
        season: season,
        episode: ep,
        posterPath: posterPath,
      );
      tasks.add(task);
      debugPrint('[DownloadService] Queued S${season}E$ep ($fileId)');
    }

    debugPrint('[DownloadService] Season download queued: ${tasks.length}/$totalEpisodes episodes');
    return tasks;
  }

  // ── Internal — Telegram download path ────────────────────────────────────

  void _processTelegramTask(DownloadTask task, int? fileId) {
    if (fileId == null || telegramService == null) {
      _failTask(task, 'Telegram engine not available or file ID missing');
      return;
    }
    _updateTask(task, status: DownloadStatus.downloading);
    telegramService!.downloadFile(fileId).catchError((e) async {
      await _failTask(task, 'Telegram download failed: $e');
      return '';
    });
  }

  /// Called by main.dart listener on every TelegramService.notifyListeners().
  /// Computes speed via delta bytes / delta time.
  void syncTelegramProgress(
      int fileId, double progress, int downloadedBytes, bool isComplete, String? path) {
    final task = allTasks.where((t) => t.telegramFileId == fileId).firstOrNull;
    if (task == null) return;

    if (task.status == DownloadStatus.paused || task.status == DownloadStatus.failed) return;

    // ── Compute instantaneous download speed ──────────────────────────────
    final now = DateTime.now();
    double speed = 0;
    final prev = _telegramSpeedMap[fileId];
    if (prev != null) {
      final dt = now.difference(prev.at).inMilliseconds;
      if (dt > 0) {
        final db = downloadedBytes - prev.bytes;
        speed = db / (dt / 1000.0); // bytes per second
      }
    }
    _telegramSpeedMap[fileId] = (bytes: downloadedBytes, at: now);

    task.progress = progress;
    task.downloadedBytes = downloadedBytes;
    task.downloadSpeed = speed < 0 ? 0 : speed;

    if (isComplete) {
      task.status = DownloadStatus.completed;
      task.filePath = path;
      task.downloadSpeed = 0;
      _telegramSpeedMap.remove(fileId);
      // Process next queued task
      _processNextQueued();
    } else {
      task.status = DownloadStatus.downloading;
    }
    task.save(); // fire-and-forget acceptable here; Hive queues writes
    _scheduleNotify();
  }

  // ── Queue management ──────────────────────────────────────────────────────

  void _processNextQueued() {
    final activeRunning = active.where((t) =>
        t.status == DownloadStatus.downloading ||
        t.status == DownloadStatus.searching ||
        t.status == DownloadStatus.converting).length;
    if (activeRunning >= _maxConcurrent) return;

    final next = allTasks.firstWhereOrNull(
      (t) => t.status == DownloadStatus.queued,
    );
    if (next == null) return;
    _requeue(next);
  }

  void _requeue(DownloadTask task) async {
    if (task.telegramFileId != null && telegramService != null) {
      await _updateTask(task, status: DownloadStatus.downloading);
      telegramService!.downloadFile(task.telegramFileId!).catchError((e) async {
        await _failTask(task, 'Telegram re-queue failed: $e');
        return '';
      });
    } else {
      await _failTask(task, 'Telegram source unavailable — file ID missing');
    }
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  /// Batch notify — coalesces rapid updates into one frame-aligned rebuild.
  void _scheduleNotify() {
    if (_pendingNotify) return;
    _pendingNotify = true;
    Future.microtask(() {
      _pendingNotify = false;
      notifyListeners();
    });
  }

  Future<void> _updateTask(DownloadTask task,
      {DownloadStatus? status, double? progress, String? filePath}) async {
    if (status != null) task.status = status;
    if (progress != null) task.progress = progress;
    if (filePath != null) task.filePath = filePath;
    await task.save();
    _scheduleNotify();
  }

  Future<void> _failTask(DownloadTask task, String error) async {
    task.status = DownloadStatus.failed;
    task.error = error;
    await task.save();
    _scheduleNotify();
    debugPrint('[DownloadService] FAILED ${task.id}: $error');
  }

  String _buildId(int tmdbId, int? season, int? episode, String quality) {
    final s = season != null ? 's${season}e$episode' : '';
    final q = quality.replaceAll('.', '-');
    return '${tmdbId}_${s}_$q';
  }
}

// ── Convenience extension (avoids importing collection package) ───────────────
extension _FirstWhereOrNull<T> on Iterable<T> {
  T? firstWhereOrNull(bool Function(T) test) {
    for (final e in this) {
      if (test(e)) return e;
    }
    return null;
  }
}
