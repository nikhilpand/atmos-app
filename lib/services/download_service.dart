import 'dart:async';
import 'dart:io';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:libtorrent_flutter/libtorrent_flutter.dart';
import '../models/download_model.dart';
import 'torrent_search_service.dart';
import 'telegram_service.dart';

/// Central download engine. Manages a queue of [DownloadTask]s and routes
/// each one through the best available download method:
///
///   1. libtorrent_flutter  — full in-app BitTorrent via YTS / EZTV magnets
///   2. Telegram CDN        — direct file download via TDLib
class DownloadService extends ChangeNotifier {
  static const _boxName = 'downloads_v1';

  late Box<DownloadTask> _box;
  final _torrentSearch = TorrentSearchService();
  bool _engineReady = false;
  int _maxConcurrent = 2;
  bool _wifiOnly = false;

  // Internal torrent-id → task-id mapping
  final _torrentMap = <int, String>{};
  StreamSubscription? _torrentSub;
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

    // Init libtorrent engine
    try {
      await LibtorrentFlutter.init(
        defaultSavePath: downloadDir,
        fetchTrackers: true,
        pollInterval: const Duration(milliseconds: 500),
      );
      _engineReady = true;

      // Listen to torrent progress updates
      _torrentSub = LibtorrentFlutter.instance.torrentUpdates.listen(_onTorrentUpdate);
    } catch (e) {
      debugPrint('[DownloadService] libtorrent init failed: $e');
      _engineReady = false;
    }

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
  Future<void> dispose() async {
    _torrentSub?.cancel();
    if (_engineReady) await LibtorrentFlutter.instance.dispose();
    await _box.close();
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
          t.status == DownloadStatus.failed)   // ← C4: failed tasks visible in Active
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
    // ── M2: Wi-Fi check
    if (_wifiOnly) {
      final conn = await Connectivity().checkConnectivity();
      if (!conn.contains(ConnectivityResult.wifi)) {
        final fakeTask = DownloadTask(
          id: _buildId(tmdbId, season, episode, quality.quality),
          tmdbId: tmdbId, imdbId: imdbId, title: title, mediaType: mediaType,
          season: season, episode: episode, episodeName: episodeName,
          quality: quality.quality, posterPath: posterPath,
          fileSizeBytes: quality.sizeBytes, audioChannels: quality.audioChannels,
          videoCodec: quality.videoCodec, source: quality.source,
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
      source: quality.source,
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
      if (task.source == 'telegram') {
        _processTelegramTask(task, quality.telegramFileId);
      } else {
        // Build magnet URI from hash if the caller didn't supply a full magnet
        final magnet = quality.magnet.isNotEmpty
            ? quality.magnet
            : _buildMagnet(quality.hash, task.title);
        _processTask(task, magnet);
      }
    }
    return task;
  }

  /// Build a magnet URI from an info-hash and title.
  /// Adds popular public trackers to maximise peer discovery.
  String _buildMagnet(String hash, String title) {
    if (hash.isEmpty) return '';
    final encoded = Uri.encodeComponent(title);
    const trackers = [
      'tr=udp%3A%2F%2Ftracker.opentrackr.org%3A1337%2Fannounce',
      'tr=udp%3A%2F%2Ftracker.openbittorrent.com%3A6969%2Fannounce',
      'tr=udp%3A%2F%2Fopen.stealth.si%3A80%2Fannounce',
    ];
    return 'magnet:?xt=urn:btih:$hash&dn=$encoded&${trackers.join('&')}';
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

  Future<void> pauseTask(String id) async {
    final task = _box.get(id);
    if (task == null) return;

    if (task.source == 'telegram') {
      // Pause Telegram: just mark paused — TDLib pauses automatically when we
      // stop consuming progress; we'll re-call downloadFile on resume.
      task.status = DownloadStatus.paused;
      await task.save();
      _scheduleNotify();
      return;
    }

    final torrentId = _torrentMap.entries
        .firstWhere((e) => e.value == id, orElse: () => const MapEntry(-1, ''))
        .key;
    if (torrentId >= 0 && _engineReady) {
      LibtorrentFlutter.instance.pauseTorrent(torrentId);
    }
    task.status = DownloadStatus.paused;
    await task.save();
    _scheduleNotify();
  }

  Future<void> resumeTask(String id) async {
    final task = _box.get(id);
    if (task == null || task.status != DownloadStatus.paused) return;

    // ── C2: Telegram resume — re-kick the download via TDLib
    if (task.source == 'telegram') {
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
      return;
    }

    final torrentId = _torrentMap.entries
        .firstWhere((e) => e.value == id, orElse: () => const MapEntry(-1, ''))
        .key;
    if (torrentId >= 0 && _engineReady) {
      LibtorrentFlutter.instance.resumeTorrent(torrentId);
      task.status = DownloadStatus.downloading;
      await task.save();
      _scheduleNotify();
    } else {
      // Torrent was lost from memory (app restart) — re-search
      _requeue(task);
    }
  }

  Future<void> deleteTask(String id) async {
    final task = _box.get(id);
    if (task == null) return;
    // Remove torrent
    final torrentId = _torrentMap.entries
        .firstWhere((e) => e.value == id, orElse: () => const MapEntry(-1, ''))
        .key;
    if (torrentId >= 0 && _engineReady) {
      LibtorrentFlutter.instance.removeTorrent(torrentId, deleteFiles: true);
      _torrentMap.remove(torrentId);
    }
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

  // ── Internal — Torrent path ───────────────────────────────────────────────

  void _processTask(DownloadTask task, String magnet) async {
    if (!_engineReady) {
      await _failTask(task, 'Torrent engine not available');
      return;
    }
    await _updateTask(task, status: DownloadStatus.downloading);

    try {
      final torrentId = LibtorrentFlutter.instance.addMagnet(magnet);
      _torrentMap[torrentId] = task.id;
    } catch (e) {
      await _failTask(task, 'Failed to add magnet: $e');
    }
  }

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
  /// H2: computes speed via delta bytes / delta time.
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

  void _onTorrentUpdate(Map<int, TorrentInfo> torrents) async {
    bool changed = false;

    for (final entry in torrents.entries) {
      final torrentId = entry.key;
      final info = entry.value;
      final taskId = _torrentMap[torrentId];
      if (taskId == null) continue;

      final task = _box.get(taskId);
      if (task == null) continue;

      // Skip paused tasks
      if (task.status == DownloadStatus.paused) continue;

      final newProgress = info.progress.clamp(0.0, 1.0);

      if (info.state.label == 'Seeding' || newProgress >= 1.0) {
        // Done — find the largest video file
        if (_engineReady) {
          final files = LibtorrentFlutter.instance.getFiles(torrentId);
          final videoFile = files
              .where((f) => _isVideoFile(f.name))
              .fold<FileInfo?>(null, (a, b) => a == null || b.size > a.size ? b : a);
          if (videoFile != null) {
            task.filePath = videoFile.path ?? task.filePath;
          }
        }
        task.status = DownloadStatus.completed;
        task.progress = 1.0;
        task.downloadSpeed = 0;
        await task.save();   // ← C7: awaited
        _torrentMap.remove(torrentId);
        changed = true;
        _processNextQueued();
      } else {
        task.progress = newProgress;
        task.downloadedBytes = info.totalDone;
        task.downloadSpeed = info.downloadRate.toDouble();
        task.fileSizeBytes = info.totalWanted > 0 ? info.totalWanted : task.fileSizeBytes;
        await task.save();   // ← C7: awaited
        changed = true;
      }
    }

    // ── H1: single notifyListeners() per poll cycle, not per torrent ─────
    if (changed) _scheduleNotify();
  }

  // ── Internal — FFmpeg / HLS path (placeholder) ───────────────────────────
  // Note: HLS→MP4 via FFmpeg is planned for a future release once a
  // maintained community fork of ffmpeg_kit is available for Flutter.

  void _processHlsTask(DownloadTask task, String m3u8Url) {
    _failTask(task, 'HLS download not yet available. Please use torrent sources.');
  }

  // ── Queue management ──────────────────────────────────────────────────────

  void _processNextQueued() {
    final activeRunning = active.where((t) =>
        t.status == DownloadStatus.downloading ||
        t.status == DownloadStatus.searching ||
        t.status == DownloadStatus.converting).length;
    if (activeRunning >= _maxConcurrent) return;  // ← H3: uses live setting

    // ── C6: use firstOrNull, not a phantom DownloadTask orElse
    final next = allTasks.firstWhereOrNull(
      (t) => t.status == DownloadStatus.queued,
    );
    if (next == null) return;
    _requeue(next);
  }

  void _requeue(DownloadTask task) async {
    await _updateTask(task, status: DownloadStatus.searching);

    // ── H4: route Telegram tasks back through Telegram
    if (task.source == 'telegram') {
      if (task.telegramFileId != null && telegramService != null) {
        await _updateTask(task, status: DownloadStatus.downloading);
        telegramService!.downloadFile(task.telegramFileId!).catchError((e) async {
          await _failTask(task, 'Telegram re-queue failed: $e');
          return '';
        });
      } else {
        await _failTask(task, 'Telegram source unavailable — file ID missing');
      }
      return;
    }

    // Torrent path — re-search for magnet
    List<QualityOption> options = [];
    if (task.mediaType == 'movie') {
      options = await _torrentSearch.searchMovie(
          task.imdbId.isNotEmpty ? task.imdbId : task.tmdbId.toString());
    } else if (task.season != null && task.episode != null) {
      options = await _torrentSearch.searchEpisode(
          task.imdbId, task.season!, task.episode!);
    }
    if (options.isEmpty) {
      await _failTask(task, 'No sources found');
      return;
    }
    final match = options.firstWhere(
      (o) => o.quality.toLowerCase().startsWith(task.quality.toLowerCase()),
      orElse: () => options.first,
    );
    _processTask(task, match.magnet);
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
    await task.save();  // ← C7: awaited
    _scheduleNotify();
  }

  Future<void> _failTask(DownloadTask task, String error) async {
    task.status = DownloadStatus.failed;
    task.error = error;
    await task.save();  // ← C7: awaited
    _scheduleNotify();
    debugPrint('[DownloadService] FAILED ${task.id}: $error');
  }

  String _buildId(int tmdbId, int? season, int? episode, String quality) {
    final s = season != null ? 's${season}e$episode' : '';
    final q = quality.replaceAll('.', '-');
    return '${tmdbId}_${s}_$q';
  }

  bool _isVideoFile(String name) {
    final ext = name.split('.').last.toLowerCase();
    return ['mkv', 'mp4', 'avi', 'mov', 'wmv', 'm4v'].contains(ext);
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
