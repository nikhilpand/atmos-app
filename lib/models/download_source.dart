/// Download source preference — Telegram CDN only.
///
/// The enum is kept for backward compatibility with Hive-persisted
/// SharedPreferences values. `auto` and `torrent` now both resolve
/// to Telegram downloads.
enum DownloadSource {
  /// Telegram CDN — direct file download via TDLib.
  telegram,
}

extension DownloadSourceLabel on DownloadSource {
  String get label => switch (this) {
    DownloadSource.telegram => 'Telegram CDN',
  };

  String get description => switch (this) {
    DownloadSource.telegram => 'Direct CDN downloads from Telegram channels',
  };

  String get icon => switch (this) {
    DownloadSource.telegram => '⚡',
  };

  static DownloadSource fromString(String? value) {
    return DownloadSource.telegram;
  }
}
