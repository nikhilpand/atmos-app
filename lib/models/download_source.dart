/// Download source preference — controls which engine(s) to query.
enum DownloadSource {
  /// Search both Telegram + Torrent in parallel, rank by speed & quality.
  auto,

  /// Torrentio API → libtorrent P2P only.
  torrent,

  /// TDLib global search → Telegram CDN only.
  telegram,
}

extension DownloadSourceLabel on DownloadSource {
  String get label => switch (this) {
    DownloadSource.auto => 'Auto (Best of Both)',
    DownloadSource.torrent => 'Torrent Only',
    DownloadSource.telegram => 'Telegram Only',
  };

  String get description => switch (this) {
    DownloadSource.auto => 'Searches torrents and Telegram simultaneously',
    DownloadSource.torrent => 'P2P downloads via Torrentio + libtorrent',
    DownloadSource.telegram => 'Direct CDN downloads from Telegram channels',
  };

  String get icon => switch (this) {
    DownloadSource.auto => '🔄',
    DownloadSource.torrent => '🔗',
    DownloadSource.telegram => '⚡',
  };

  static DownloadSource fromString(String? value) {
    switch (value) {
      case 'torrent': return DownloadSource.torrent;
      case 'telegram': return DownloadSource.telegram;
      default: return DownloadSource.auto;
    }
  }
}
