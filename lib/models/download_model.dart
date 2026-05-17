import 'package:hive/hive.dart';

part 'download_model.g.dart';

// ─── Download Status ──────────────────────────────────────────────────────────

@HiveType(typeId: 10)
enum DownloadStatus {
  @HiveField(0)
  queued,
  @HiveField(1)
  searching,   // fetching magnet from YTS/EZTV
  @HiveField(2)
  downloading, // active download
  @HiveField(3)
  converting,  // ffmpeg mux
  @HiveField(4)
  completed,
  @HiveField(5)
  failed,
  @HiveField(6)
  paused,
}

extension DownloadStatusLabel on DownloadStatus {
  String get label => switch (this) {
    DownloadStatus.queued => 'Queued',
    DownloadStatus.searching => 'Finding sources...',
    DownloadStatus.downloading => 'Downloading',
    DownloadStatus.converting => 'Converting',
    DownloadStatus.completed => 'Complete',
    DownloadStatus.failed => 'Failed',
    DownloadStatus.paused => 'Paused',
  };
}

// ─── Quality Option ───────────────────────────────────────────────────────────

@HiveType(typeId: 11)
class QualityOption extends HiveObject {
  @HiveField(0) String quality;   // '720p', '1080p', '2160p'
  @HiveField(1) String hash;      // torrent hash (empty for telegram)
  @HiveField(2) int sizeBytes;    // file size in bytes
  @HiveField(3) String? type;     // 'bluray', 'web', 'hdts'
  @HiveField(4) String? videoCodec;
  @HiveField(5) String? audioChannels;
  @HiveField(6) String source;    // 'torrent' or 'telegram'
  @HiveField(7) int seeders;      // torrent seeders (0 for telegram)
  @HiveField(8) int? telegramFileId; // TDLib file ID (null for torrent)
  @HiveField(9) String? channelName; // Telegram channel name
  @HiveField(10) String? fileName;   // original filename from Telegram

  QualityOption({
    required this.quality,
    required this.hash,
    required this.sizeBytes,
    this.type,
    this.videoCodec,
    this.audioChannels,
    this.source = 'telegram',
    this.seeders = 0,
    this.telegramFileId,
    this.channelName,
    this.fileName,
  });

  String get sizeFormatted {
    if (sizeBytes <= 0) return 'Unknown size';
    if (sizeBytes < 1024 * 1024 * 1024) {
      return '${(sizeBytes / (1024 * 1024)).toStringAsFixed(0)} MB';
    }
    return '${(sizeBytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  // magnet getter removed — torrent engine was removed from the app.
  // Torrentio provides infoHash which is resolved via Webtor.io to HTTP.
}

// ─── Download Task ────────────────────────────────────────────────────────────

@HiveType(typeId: 12)
class DownloadTask extends HiveObject {
  @HiveField(0)  String id;           // unique: tmdbId-season-episode-quality
  @HiveField(1)  int tmdbId;
  @HiveField(2)  String title;
  @HiveField(3)  String mediaType;    // 'movie' | 'tv'
  @HiveField(4)  int? season;
  @HiveField(5)  int? episode;
  @HiveField(6)  String? episodeName;
  @HiveField(7)  String quality;      // '720p', '1080p', '2160p'
  @HiveField(8)  String? posterPath;
  @HiveField(9)  DownloadStatus status;
  @HiveField(10) double progress;     // 0.0 – 1.0
  @HiveField(11) String? filePath;    // final file location
  @HiveField(12) String? error;
  @HiveField(13) DateTime createdAt;
  @HiveField(14) int fileSizeBytes;
  @HiveField(15) String? audioChannels;
  @HiveField(16) String? videoCodec;
  @HiveField(17) int downloadedBytes;
  @HiveField(18) String imdbId;
  @HiveField(19) String source;          // 'torrent' or 'telegram'
  @HiveField(20) int? telegramFileId;    // TDLib file ID for telegram downloads
  @HiveField(21) double downloadSpeed;   // bytes/sec — for UI display
  @HiveField(22) int retryCount;         // number of retry attempts so far
  @HiveField(23) String? httpStreamUrl;   // fallback HTTP stream URL (Torrentio/VegaMovies)

  DownloadTask({
    required this.id,
    required this.tmdbId,
    required this.title,
    required this.mediaType,
    this.season,
    this.episode,
    this.episodeName,
    required this.quality,
    this.posterPath,
    this.status = DownloadStatus.queued,
    this.progress = 0.0,
    this.filePath,
    this.error,
    required this.createdAt,
    this.fileSizeBytes = 0,
    this.audioChannels,
    this.videoCodec,
    this.downloadedBytes = 0,
    this.imdbId = '',
    this.source = 'telegram',
    this.telegramFileId,
    this.downloadSpeed = 0,
    this.retryCount = 0,
    this.httpStreamUrl,
  });

  // Human-readable display title
  String get displayTitle {
    if (mediaType == 'tv' && season != null && episode != null) {
      final ep = 'S${season.toString().padLeft(2, '0')}'
                 'E${episode.toString().padLeft(2, '0')}';
      return '$title — $ep${episodeName != null ? ': $episodeName' : ''}';
    }
    return title;
  }

  String get downloadedFormatted {
    if (downloadedBytes < 1024 * 1024) return '${(downloadedBytes / 1024).toStringAsFixed(0)} KB';
    if (downloadedBytes < 1024 * 1024 * 1024) return '${(downloadedBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(downloadedBytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  String get totalFormatted {
    if (fileSizeBytes <= 0) return '';
    if (fileSizeBytes < 1024 * 1024 * 1024) return '${(fileSizeBytes / (1024 * 1024)).toStringAsFixed(0)} MB';
    return '${(fileSizeBytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  /// e.g. '3.2 MB/s' or '' when speed is 0 / unknown.
  String get speedFormatted {
    if (downloadSpeed <= 0) return '';
    if (downloadSpeed < 1024 * 1024) {
      return '${(downloadSpeed / 1024).toStringAsFixed(0)} KB/s';
    }
    return '${(downloadSpeed / (1024 * 1024)).toStringAsFixed(1)} MB/s';
  }

  /// e.g. '4 min remaining', '< 1 min' or '' when unknown.
  String get etaFormatted {
    if (downloadSpeed <= 0 || fileSizeBytes <= 0) return '';
    final remaining = fileSizeBytes - downloadedBytes;
    if (remaining <= 0) return '';
    final seconds = remaining / downloadSpeed;
    if (seconds < 60) return '< 1 min';
    final mins = (seconds / 60).round();
    if (mins < 60) return '$mins min remaining';
    final hrs = (mins / 60).floor();
    final rem = mins % 60;
    return rem == 0 ? '$hrs hr remaining' : '$hrs hr $rem min remaining';
  }
}
