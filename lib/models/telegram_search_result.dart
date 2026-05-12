/// Represents a video file found via TDLib's global search across
/// all public Telegram channels.
class TelegramSearchResult {
  /// TDLib internal file ID — used with `downloadFile()`.
  final int fileId;

  /// Expected file size in bytes.
  final int fileSize;

  /// Original filename from the video/document metadata.
  final String fileName;

  /// Message caption (often contains quality, codec, audio info).
  final String caption;

  /// Name of the channel where this was found.
  final String channelTitle;

  /// Numeric channel ID for caching.
  final int channelId;

  /// Message ID within the channel.
  final int messageId;

  /// Parsed quality: "4K", "1080p", "720p", etc.
  final String quality;

  /// Parsed video codec from filename/caption.
  final String? videoCodec;

  /// Parsed audio info from filename/caption.
  final String? audioInfo;

  /// When the message was posted.
  final DateTime uploadDate;

  /// Whether this is part of a multi-part split upload.
  final bool isMultiPart;

  /// Part number if multi-part (1, 2, 3...).
  final int partNumber;

  /// Total parts if multi-part.
  final int totalParts;

  /// Related part file IDs (for auto-merge).
  final List<int> relatedFileIds;

  const TelegramSearchResult({
    required this.fileId,
    required this.fileSize,
    required this.fileName,
    this.caption = '',
    this.channelTitle = '',
    this.channelId = 0,
    this.messageId = 0,
    required this.quality,
    this.videoCodec,
    this.audioInfo,
    required this.uploadDate,
    this.isMultiPart = false,
    this.partNumber = 1,
    this.totalParts = 1,
    this.relatedFileIds = const [],
  });

  /// Total size across all parts.
  int get totalSize => isMultiPart
      ? fileSize * totalParts // approximate
      : fileSize;

  /// Human-readable size string.
  String get sizeFormatted {
    final size = totalSize;
    if (size < 1024 * 1024 * 1024) {
      return '${(size / (1024 * 1024)).toStringAsFixed(0)} MB';
    }
    return '${(size / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  /// Display label for the quality picker.
  String get displayLabel {
    final parts = <String>[quality];
    if (videoCodec != null) parts.add(videoCodec!);
    if (audioInfo != null) parts.add(audioInfo!);
    if (isMultiPart) parts.add('$totalParts parts');
    return parts.join(' • ');
  }

  @override
  String toString() =>
      'TelegramSearchResult($quality, $sizeFormatted, $channelTitle, file:$fileId)';
}
