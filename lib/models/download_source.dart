/// Download source preference — Telegram CDN or HTTP (VegaMovies/Torrentio proxy).
enum DownloadSource {
  /// Telegram CDN — direct file download via TDLib.
  telegram,
  /// Direct HTTP download (VegaMovies, Torrentio via proxy).
  http,
}

extension DownloadSourceLabel on DownloadSource {
  String get label => switch (this) {
    DownloadSource.telegram => 'Telegram CDN',
    DownloadSource.http => 'HTTP Stream/Direct',
  };

  String get description => switch (this) {
    DownloadSource.telegram => 'Direct CDN downloads from Telegram channels',
    DownloadSource.http => 'Direct MP4/MKV downloads from web sources',
  };

  String get icon => switch (this) {
    DownloadSource.telegram => '⚡',
    DownloadSource.http => '🌐',
  };

  static DownloadSource fromString(String? value) {
    if (value == 'http') return DownloadSource.http;
    return DownloadSource.telegram;
  }
}
