import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'package:flutter/widgets.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:path_provider/path_provider.dart';
import 'package:handy_tdlib/handy_tdlib.dart' as td;
import '../models/telegram_search_result.dart';
import '../models/download_model.dart';
import 'atmos_index_client.dart';
import 'alias_database.dart';

// ════════════════════════════════════════════════════════════════════════════════
// TDLib Auth States
// ════════════════════════════════════════════════════════════════════════════════

enum TelegramAuthState {
  uninitialized,
  waitingForPhone,
  waitingForOtp,
  waitingFor2fa,
  ready,
  loggingOut,
  error,
}

// ════════════════════════════════════════════════════════════════════════════════
// Telegram Download Progress
// ════════════════════════════════════════════════════════════════════════════════

class TelegramDownloadProgress {
  final int fileId;
  final int downloadedBytes;
  final int totalBytes;
  final bool isComplete;
  final String? localPath;

  double get progress => totalBytes > 0 ? downloadedBytes / totalBytes : 0;
  double get progressPercent => progress * 100;

  const TelegramDownloadProgress({
    required this.fileId,
    required this.downloadedBytes,
    required this.totalBytes,
    required this.isComplete,
    this.localPath,
  });
}

// ════════════════════════════════════════════════════════════════════════════════
// Telegram Service
// ════════════════════════════════════════════════════════════════════════════════
//
// Wraps TDLib (via handy_tdlib) to provide:
//   • Authentication (phone → OTP → optional 2FA)
//   • Global video search across ALL public Telegram channels
//   • File download with progress tracking
//
// TDLib runs on a background isolate to keep UI smooth.

class TelegramService extends ChangeNotifier with WidgetsBindingObserver {
  // Auto-reconnect tracking
  bool _reconnecting = false;
  int _reconnectAttempts = 0;
  static const _maxReconnectAttempts = 3;
  Timer? _reconnectTimer;
  // AtmosIndex catalog client (works without TDLib login)
  final AtmosIndexClient _indexClient = AtmosIndexClient();
  AtmosIndexClient get indexClient => _indexClient;

  // Auth
  TelegramAuthState _authState = TelegramAuthState.uninitialized;
  String? _phone;
  String? _errorMessage;

  // TDLib client
  int? _clientId;
  bool _isInitialized = false;
  String? _tdLibPath;

  // Isolate communication
  Isolate? _receiveIsolate;
  ReceivePort? _mainReceivePort;

  // Download tracking
  final _downloadProgress = <int, TelegramDownloadProgress>{};
  final _downloadCompleter = <int, Completer<String>>{}; // fileId → completer

  // Search result cache (title → results, expires after 1 hour)
  final _searchCache = <String, _CachedSearch>{};

  // Inline bot search tracking
  final _pendingInlineQueries = <int, Completer<List<TelegramSearchResult>>>{};
  static final _botIdCache = <String, int>{};

  // Wait for initial auth state resolution
  final Completer<void> _readyCompleter = Completer<void>();
  Future<void> get whenReady => _readyCompleter.future;

  // ── Getters ───────────────────────────────────────────────────────────────

  TelegramAuthState get authState => _authState;
  bool get isLoggedIn => _authState == TelegramAuthState.ready;
  bool get isInitialized => _isInitialized;
  String? get phone => _phone;
  String? get errorMessage => _errorMessage;

  TelegramDownloadProgress? getDownloadProgress(int fileId) =>
      _downloadProgress[fileId];

  Map<int, TelegramDownloadProgress> get activeDownloads => _downloadProgress;

  // ── Init / Dispose ────────────────────────────────────────────────────────

  Future<void> init() async {
    if (_isInitialized) return;

    try {
      final dir = await getApplicationSupportDirectory();
      _tdLibPath = '${dir.path}/tdlib';

      WidgetsBinding.instance.addObserver(this);

      td.TdPlugin.initialize();
      _clientId = td.TdPlugin.instance.tdCreateClientId();
      if (_clientId == null) {
        debugPrint('[Telegram] Failed to create TDLib client');
        return;
      }

      // ── Silence TDLib's own C++ logs (level 0 = fatal only).
      // Without this, TDLib prints every packet/ping at logcat level D/I
      // which floods the log bus and causes apparent UI unresponsiveness.
      td.TdPlugin.instance.tdSend(
        0,
        jsonEncode({
          '@type': 'setLogVerbosityLevel',
          'new_verbosity_level': 0,
        }),
      );

      // Start receiver isolate
      await _startReceiver();

      _isInitialized = true;
      debugPrint('[Telegram] TDLib initialized in support directory: $_tdLibPath, clientId: $_clientId');
    } catch (e) {
      debugPrint('[Telegram] Init error: $e');
      _errorMessage = e.toString();
      _authState = TelegramAuthState.error;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (_clientId != null) {
      _send(const td.Close());
    }
    // Give it a tiny bit of time to send the close command before killing the isolate
    Future.delayed(const Duration(milliseconds: 300), () {
      _receiveIsolate?.kill(priority: Isolate.immediate);
      _mainReceivePort?.close();
    });
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    debugPrint('[Telegram] AppLifecycleState changed to: $state');
    if (state == AppLifecycleState.detached) {
      debugPrint('[Telegram] App detached, initiating clean TDLib database close...');
      if (_clientId != null) {
        _send(const td.Close());
      }
    } else if (state == AppLifecycleState.resumed) {
      // Auto-reconnect on app resume if TDLib disconnected while in background
      if (!_isInitialized || _authState == TelegramAuthState.uninitialized || _authState == TelegramAuthState.error) {
        debugPrint('[Telegram] App resumed — TDLib disconnected, attempting auto-reconnect...');
        _attemptReconnect();
      }
    }
  }

  /// Attempt to re-initialize TDLib connection with exponential backoff.
  Future<void> _attemptReconnect() async {
    if (_reconnecting) return;
    _reconnecting = true;
    _reconnectAttempts = 0;

    while (_reconnectAttempts < _maxReconnectAttempts) {
      if (isLoggedIn || (_authState != TelegramAuthState.uninitialized && _authState != TelegramAuthState.error && _reconnectAttempts > 0)) {
        break;
      }
      _reconnectAttempts++;
      debugPrint('[Telegram] Reconnect attempt $_reconnectAttempts/$_maxReconnectAttempts...');
      try {
        _isInitialized = false;
        final oldState = _authState;
        _authState = TelegramAuthState.uninitialized;

        // Release database lock on the old client first
        if (_clientId != null) {
          try {
            _send(const td.Close());
            await Future.delayed(const Duration(seconds: 1));
          } catch (_) {}
        }

        // Kill old isolate
        _receiveIsolate?.kill(priority: Isolate.immediate);
        _mainReceivePort?.close();

        // Re-create client
        _clientId = td.TdPlugin.instance.tdCreateClientId();
        if (_clientId == null) {
          debugPrint('[Telegram] Reconnect: Failed to create client');
          _authState = oldState;
          continue;
        }

        // Silence TDLib logs
        td.TdPlugin.instance.tdSend(0, jsonEncode({'@type': 'setLogVerbosityLevel', 'new_verbosity_level': 0}));

        await _startReceiver();
        _isInitialized = true;
        debugPrint('[Telegram] Reconnect: TDLib re-initialized');

        // Wait up to 5 seconds for auth to settle to a stable state
        for (int i = 0; i < 10; i++) {
          await Future.delayed(const Duration(milliseconds: 500));
          if (_authState != TelegramAuthState.uninitialized && _authState != TelegramAuthState.error) {
            break;
          }
        }

        if (_authState != TelegramAuthState.uninitialized && _authState != TelegramAuthState.error) {
          debugPrint('[Telegram] ✅ Reconnect successful! AuthState: $_authState');
          _reconnectAttempts = 0;
          break;
        }
      } catch (e) {
        debugPrint('[Telegram] Reconnect attempt $_reconnectAttempts failed: $e');
      }
      // Exponential backoff: 2s, 4s, 8s
      if (_reconnectAttempts < _maxReconnectAttempts) {
        await Future.delayed(Duration(seconds: 1 << _reconnectAttempts));
      }
    }
    _reconnecting = false;
    notifyListeners();
  }

  /// Check if TDLib connection is healthy. If not, trigger reconnect.
  /// Call this before operations that require an active connection.
  Future<bool> ensureConnected() async {
    if (isLoggedIn) return true;
    if (_reconnecting) {
      // Wait up to 10 seconds for reconnect to complete
      for (int i = 0; i < 20; i++) {
        await Future.delayed(const Duration(milliseconds: 500));
        if (isLoggedIn) return true;
      }
      return false;
    }
    await _attemptReconnect();
    return isLoggedIn;
  }

  // ── Authentication ────────────────────────────────────────────────────────

  /// Step 1: Send phone number.
  Future<void> sendPhoneNumber(String phone) async {
    _phone = phone;
    _send(td.SetAuthenticationPhoneNumber(
      phoneNumber: phone,
      settings: const td.PhoneNumberAuthenticationSettings(
        allowFlashCall: false,
        allowMissedCall: false,
        isCurrentPhoneNumber: false,
        hasUnknownPhoneNumber: false,
        allowSmsRetrieverApi: true,
        firebaseAuthenticationSettings: null,
        authenticationTokens: [],
      ),
    ));
  }

  /// Step 2: Verify OTP code.
  Future<void> verifyOtp(String code) async {
    _send(td.CheckAuthenticationCode(code: code));
  }

  /// Step 3 (if needed): Enter 2FA password.
  Future<void> verify2fa(String password) async {
    _send(td.CheckAuthenticationPassword(password: password));
  }

  /// Logout.
  Future<void> logout() async {
    _authState = TelegramAuthState.loggingOut;
    notifyListeners();
    _send(const td.LogOut());
  }

  // ── Global Search (Hybrid: AtmosIndex catalog + TDLib) ────────────────────

  /// Search for videos — works WITHOUT Telegram login via AtmosIndex catalog.
  /// If the user IS logged in, also runs TDLib search in parallel and merges.
  /// [preferLang]: optional language to boost in result ranking (e.g. 'Hindi', 'Dual Audio').
  Future<List<TelegramSearchResult>> searchVideos(
    String title, {
    int? year,
    String? mediaType,
    int? season,
    int? episode,
    String? preferLang,  // ← bound to filter picker
    String? baseTitle,
  }) async {
    final base = title.trim();
    if (base.isEmpty) return [];
    final matchTitle = baseTitle ?? base;

    // Auto-reconnect if disconnected — non-blocking for catalog path
    if (!isLoggedIn && _isInitialized) {
      ensureConnected(); // fire-and-forget, catalog will still work
    }

    final cacheKey = '${base.toLowerCase()}_${season ?? ''}_${episode ?? ''}_${preferLang ?? ''}';
    final cached = _searchCache[cacheKey];
    if (cached != null && cached.isValid) {
      debugPrint('[Telegram] Cache hit: ${cached.results.length} results for "$base"');
      return cached.results;
    }

    // ── Stage 1: AtmosIndex catalog (anonymous, no login needed) ────────────
    final catalogFuture = _indexClient.isConfigured
        ? _indexClient.search(base, year: year, season: season, episode: episode)
        : Future.value(<IndexedMedia>[]);

    // ── Stage 2: TDLib direct search (only if logged in) ───────────────────
    final tdlibFuture = isLoggedIn
        ? _searchViaTdlib(base, year: year, mediaType: mediaType, season: season, episode: episode, baseTitle: matchTitle)
        : Future.value(<TelegramSearchResult>[]);

    // ── Stage 3: Inline Bots search (only if logged in) ───────────────────
    final inlineBotsFuture = isLoggedIn
        ? _searchViaInlineBots(base, season: season, episode: episode, baseTitle: matchTitle)
        : Future.value(<TelegramSearchResult>[]);

    // Run all in parallel
    final results = await Future.wait([catalogFuture, tdlibFuture, inlineBotsFuture]);
    final catalogResults = results[0] as List<IndexedMedia>;
    final tdlibResults = results[1] as List<TelegramSearchResult>;
    final inlineResults = results[2] as List<TelegramSearchResult>;

    // Convert catalog results to TelegramSearchResult format
    final catalogConverted = catalogResults.map((r) => TelegramSearchResult(
      fileId: 0, // Will be resolved via resolveFileId before download
      fileSize: r.fileSizeBytes,
      fileName: r.fileName,
      caption: '',
      channelTitle: '@${r.channelUsername}',
      channelId: 0,
      messageId: r.msgId,
      quality: r.quality,
      videoCodec: r.codec,
      audioInfo: r.audio,
      uploadDate: DateTime.now(),
    )).toList();

    // Merge: TDLib results first (have file_id), then inline bot results, then catalog results
    final seen = <String>{};
    final merged = <TelegramSearchResult>[];

    for (final r in tdlibResults) {
      final key = '${r.fileId}';
      if (seen.add(key)) merged.add(r);
    }
    for (final r in inlineResults) {
      final key = '${r.fileId}';
      if (seen.add(key)) merged.add(r);
    }
    for (final r in catalogConverted) {
      // Dedupe by channelTitle+messageId
      final key = '${r.channelTitle}:${r.messageId}';
      if (seen.add(key)) merged.add(r);
    }

    merged.sort((a, b) => _scoreResult(b, preferLang: preferLang).compareTo(_scoreResult(a, preferLang: preferLang))); // descending

    _searchCache[cacheKey] = _CachedSearch(merged);
    debugPrint('[Telegram] Hybrid search: ${catalogConverted.length} catalog + ${tdlibResults.length} TDLib + ${inlineResults.length} InlineBots = ${merged.length} merged for "$base"');
    return merged;
  }

  /// TDLib-only search path (original logic, requires login).
  Future<List<TelegramSearchResult>> _searchViaTdlib(
    String title, {
    int? year,
    String? mediaType,
    int? season,
    int? episode,
    String? baseTitle,
  }) async {
    final matchTitle = baseTitle ?? title;
    final titleVariations = await AliasDatabase.getSearchVariations(matchTitle);
    final queries = <String>{};

    for (final variant in titleVariations) {
      queries.add(variant);
      if (year != null) queries.add('$variant $year');
      queries.add('$variant 1080p');
      queries.add('$variant 720p');
      if (year != null) queries.add('$variant $year 1080p');

      if (mediaType == 'tv' && season != null && episode != null) {
        queries.add('$variant S${season.toString().padLeft(2, "0")}E${episode.toString().padLeft(2, "0")}');
        queries.add('$variant S${season.toString().padLeft(2, "0")}');
        queries.add('$variant Season $season Episode $episode');
      }
    }

    debugPrint('[Telegram] TDLib searching ${queries.length} variants for "$matchTitle" (Variations: $titleVariations)');

    try {
      final futures = queries.map((q) => _searchOnce(q, season, episode, titleVariations)).toList();
      final allLists = await Future.wait(futures);

      final seen = <int>{};
      final merged = <TelegramSearchResult>[];
      for (final list in allLists) {
        for (final r in list) {
          if (seen.add(r.fileId)) merged.add(r);
        }
      }
      return merged;
    } catch (e) {
      debugPrint('[Telegram] TDLib search error: $e');
      return [];
    }
  }

  // ── File Resolution ────────────────────────────────────────────────────────

  /// Resolve a channel_username + msg_id (from AtmosIndex catalog) to a
  /// TDLib file_id that can be used with downloadFile().
  /// Requires TDLib login.
  Future<int?> resolveFileId(String channelUsername, int messageId) async {
    if (!isLoggedIn) return null;

    try {
      // Step 1: Resolve channel username → chat_id
      final chatId = await _resolveChatId(channelUsername.replaceAll('@', ''));
      if (chatId == null) return null;

      // Step 2: Get the specific message
      final c = Completer<int?>();
      final id = _nextExtra();
      _pendingResolves[id] = c;
      _send(td.GetMessage(chatId: chatId, messageId: messageId), extra: id);

      return c.future.timeout(const Duration(seconds: 15), onTimeout: () {
        _pendingResolves.remove(id);
        return null;
      });
    } catch (e) {
      debugPrint('[Telegram] resolveFileId error: $e');
      return null;
    }
  }

  Future<int?> _resolveChatId(String username) async {
    final c = Completer<int?>();
    final id = _nextExtra();
    _pendingChatResolves[id] = c;
    _send(td.SearchPublicChat(username: username), extra: id);
    return c.future.timeout(const Duration(seconds: 10), onTimeout: () {
      _pendingChatResolves.remove(id);
      return null;
    });
  }

  // Pending resolution completers
  final _pendingResolves = <int, Completer<int?>>{};        // extra → fileId
  final _pendingChatResolves = <int, Completer<int?>>{};    // extra → chatId

  /// Single TDLib SearchMessages call — tries both Document and Video filters
  /// then merges deduped results.
  Future<List<TelegramSearchResult>> _searchOnce(String query, int? season, int? episode, List<String> variations) async {
    Future<List<TelegramSearchResult>> fire(td.SearchMessagesFilter filter) {
      final c = Completer<List<TelegramSearchResult>>();
      // Use atomic counter so concurrent calls never share an extra ID
      final id = _nextExtra();
      _pendingSearches[id] = _PendingSearch(c, season, episode, variations);
      _send(td.SearchMessages(
        chatList: null,
        onlyInChannels: true,
        query: query,
        offset: '',
        limit: 50,
        filter: filter,
        minDate: 0,
        maxDate: 0,
      ), extra: id);
      // 8 s timeout — complete with empty list if TDLib never responds
      return c.future.timeout(const Duration(seconds: 8), onTimeout: () {
        _pendingSearches.remove(id);
        return [];
      });
    }

    // Fire Document + Video searches in PARALLEL for 2x speed
    final results = await Future.wait([
      fire(const td.SearchMessagesFilterDocument()),
      fire(const td.SearchMessagesFilterVideo()),
    ]);
    final seen = <int>{};
    return [...results[0], ...results[1]].where((r) => seen.add(r.fileId)).toList();
  }

  /// Convert Telegram search results to QualityOptions for the unified picker.
  List<QualityOption> toQualityOptions(List<TelegramSearchResult> results) {
    return results.map((r) => QualityOption(
      quality: r.quality,
      hash: '', // no torrent hash
      sizeBytes: r.fileSize,
      type: r.channelTitle,
      videoCodec: r.videoCodec,
      audioChannels: r.audioInfo,
      source: 'telegram',
      seeders: 0,
      telegramFileId: r.fileId,
      channelName: r.channelTitle,
      fileName: r.fileName.isNotEmpty ? r.fileName : null,
    )).toList();
  }

  // Global counter for unique @extra IDs — avoids microsecond collisions
  static int _extraCounter = 0;
  static int _nextExtra() => ++_extraCounter;

  final _pendingSearches = <int, _PendingSearch>{};

  // ── File Download ─────────────────────────────────────────────────────────

  /// Download a file by TDLib file ID. Returns the local file path when done.
  /// Automatically attempts to reconnect if TDLib is disconnected.
  Future<String> downloadFile(int fileId, {int priority = 1}) async {
    // Auto-reconnect if disconnected
    if (!isLoggedIn) {
      final connected = await ensureConnected();
      if (!connected) {
        throw Exception('Telegram disconnected and reconnect failed. Please check your connection.');
      }
    }

    // If already has a completer, return the existing future
    if (_downloadCompleter.containsKey(fileId)) {
      return _downloadCompleter[fileId]!.future;
    }

    final completer = Completer<String>();
    _downloadCompleter[fileId] = completer;

    _downloadProgress[fileId] = TelegramDownloadProgress(
      fileId: fileId,
      downloadedBytes: 0,
      totalBytes: 0,
      isComplete: false,
    );
    notifyListeners();

    _send(td.DownloadFile(
      fileId: fileId,
      priority: priority,
      offset: 0,
      limit: 0,
      synchronous: false,
    ));

    // Safety timeout — don't hang forever if TDLib stops responding
    return completer.future.timeout(
      const Duration(minutes: 30),
      onTimeout: () {
        _downloadCompleter.remove(fileId);
        _downloadProgress.remove(fileId);
        notifyListeners();
        throw Exception('Download timed out after 30 minutes');
      },
    );
  }

  /// Cancel an active download.
  void cancelDownload(int fileId) {
    _send(td.CancelDownloadFile(
      fileId: fileId,
      onlyIfPending: false,
    ));
    _downloadProgress.remove(fileId);
    _downloadCompleter.remove(fileId);
    notifyListeners();
  }

  // ── TDLib Isolate ─────────────────────────────────────────────────────────

  static void _isolateReceiver(SendPort sendPort) async {
    await td.TdPlugin.initialize();
    while (true) {
      try {
        final response = td.TdPlugin.instance.tdReceive(1.0);
        if (response != null) {
          sendPort.send(response);
        }
      } catch (e) {
        // ignore
      }
    }
  }

  Future<void> _startReceiver() async {
    _mainReceivePort = ReceivePort();
    _mainReceivePort!.listen((response) {
      if (response is String) {
        // ── Extract @extra BEFORE converting to typed object ─────────────
        // TDLib echoes @extra on the response JSON. We read it from the raw
        // map so we can route FoundMessages to the right completer.
        int? extraId;
        try {
          final raw = jsonDecode(response) as Map<String, dynamic>?;
          if (raw != null && raw.containsKey('@extra')) {
            extraId = raw['@extra'] as int?;
          }
        } catch (_) {}

        final obj = td.convertJsonToObject(response);
        if (obj != null) {
          _handleTdUpdate(obj, extra: extraId);
        }
      }
    });

    _receiveIsolate = await Isolate.spawn(_isolateReceiver, _mainReceivePort!.sendPort);
  }

  void _send(td.TdFunction fn, {int? extra}) {
    if (_clientId == null) return;
    final json = fn.toJson();
    if (extra != null) json['@extra'] = extra;
    td.TdPlugin.instance.tdSend(_clientId!, jsonEncode(json));
  }

  // ── Update Handler ────────────────────────────────────────────────────────

  void _handleTdUpdate(dynamic obj, {int? extra}) {
    if (obj == null) return;

    // ── Errors with pending search/resolution cleanup ──────────────────
    if (obj is td.TdError) {
      const ignorableCodes = {401, 404, 406, 420};
      if (ignorableCodes.contains(obj.code)) {
        debugPrint('[Telegram] Non-fatal error ${obj.code}: ${obj.message}');
        if (extra != null) {
          final p = _pendingSearches.remove(extra);
          if (p != null && !p.completer.isCompleted) p.completer.complete([]);

          final c = _pendingChatResolves.remove(extra);
          if (c != null && !c.isCompleted) c.complete(null);

          final r = _pendingResolves.remove(extra);
          if (r != null && !r.isCompleted) r.complete(null);

          final i = _pendingInlineQueries.remove(extra);
          if (i != null && !i.isCompleted) i.complete([]);
        }
        return;
      }
      debugPrint('[Telegram] Error ${obj.code}: ${obj.message}');
      if (extra != null) {
        final p = _pendingSearches.remove(extra);
        if (p != null && !p.completer.isCompleted) p.completer.complete([]);

        final c = _pendingChatResolves.remove(extra);
        if (c != null && !c.isCompleted) c.complete(null);

        final r = _pendingResolves.remove(extra);
        if (r != null && !r.isCompleted) r.complete(null);

        final i = _pendingInlineQueries.remove(extra);
        if (i != null && !i.isCompleted) i.complete([]);
      }
      _errorMessage = obj.message;
      _authState = TelegramAuthState.error;
      notifyListeners();
      return;
    }

    // ── Auth state changes ──────────────────────────────────────────────
    if (obj is td.UpdateAuthorizationState) {
      _handleAuthState(obj.authorizationState);
      return;
    }

    // ── File download progress ──────────────────────────────────────────
    if (obj is td.UpdateFile) {
      _handleFileUpdate(obj.file);
      return;
    }

    // ── Search results (FoundMessages) ──────────────────────────────────
    if (obj is td.FoundMessages) {
      _handleSearchResults(obj, extraId: extra);
      return;
    }

    // ── Chat resolution (Chat) ──────────────────────────────────────────
    if (obj is td.Chat) {
      if (extra != null && _pendingChatResolves.containsKey(extra)) {
        final c = _pendingChatResolves.remove(extra);
        c?.complete(obj.id);
      }
      return;
    }

    // ── Message resolution (Message) ────────────────────────────────────
    if (obj is td.Message) {
      if (extra != null && _pendingResolves.containsKey(extra)) {
        final c = _pendingResolves.remove(extra);
        final content = obj.content;
        int? fileId;
        if (content is td.MessageVideo) {
          fileId = content.video.video.id;
        } else if (content is td.MessageDocument) {
          fileId = content.document.document.id;
        }
        c?.complete(fileId);
      }
      return;
    }

    // ── Inline Query results (InlineQueryResults) ──────────────────────
    if (obj is td.InlineQueryResults) {
      _handleInlineQueryResults(obj, extraId: extra);
      return;
    }

    // Everything else silently ignored.
    return;
  }

  void _handleAuthState(td.AuthorizationState state) {
    debugPrint('[Telegram] AuthState changed: ${state.runtimeType}');
    switch (state) {
      case td.AuthorizationStateWaitTdlibParameters():
        _send(td.SetTdlibParameters(
          apiId: int.tryParse(dotenv.env['TELEGRAM_API_ID'] ?? '') ?? 0,
          apiHash: dotenv.env['TELEGRAM_API_HASH'] ?? '',
          databaseDirectory: '$_tdLibPath/db',
          filesDirectory: '$_tdLibPath/downloads',
          useTestDc: false,
          useSecretChats: false,
          useMessageDatabase: true,
          useFileDatabase: true,
          useChatInfoDatabase: true,
          systemLanguageCode: 'en',
          deviceModel: 'Atmos App',
          systemVersion: 'Android',
          applicationVersion: '2.0.0',
          databaseEncryptionKey: '',
        ));
        break;
      case td.AuthorizationStateWaitPhoneNumber():
        _authState = TelegramAuthState.waitingForPhone;
        if (!_readyCompleter.isCompleted) _readyCompleter.complete();
        break;
      case td.AuthorizationStateWaitCode():
        _authState = TelegramAuthState.waitingForOtp;
        break;
      case td.AuthorizationStateWaitPassword():
        _authState = TelegramAuthState.waitingFor2fa;
        break;
      case td.AuthorizationStateReady():
        _authState = TelegramAuthState.ready;
        debugPrint('[Telegram] ✅ Logged in!');
        if (!_readyCompleter.isCompleted) _readyCompleter.complete();
        break;
      case td.AuthorizationStateLoggingOut():
        _authState = TelegramAuthState.loggingOut;
        break;
      case td.AuthorizationStateClosed():
        _authState = TelegramAuthState.uninitialized;
        _isInitialized = false;
        debugPrint('[Telegram] ⚠️ TDLib session closed — will auto-reconnect on next operation');
        // Schedule auto-reconnect after a brief delay
        _reconnectTimer?.cancel();
        _reconnectTimer = Timer(const Duration(seconds: 2), () {
          if (!isLoggedIn && !_reconnecting) {
            debugPrint('[Telegram] Auto-reconnecting after AuthorizationStateClosed...');
            _attemptReconnect();
          }
        });
        break;
      default:
        break;
    }
    notifyListeners();
  }

  void _handleFileUpdate(td.File file) {
    final fileId = file.id;
    final local = file.local;
    final expectedSize = file.expectedSize > 0
        ? file.expectedSize
        : file.size;

    final progress = TelegramDownloadProgress(
      fileId: fileId,
      downloadedBytes: local.downloadedSize,
      totalBytes: expectedSize,
      isComplete: local.isDownloadingCompleted,
      localPath: local.isDownloadingCompleted ? local.path : null,
    );

    _downloadProgress[fileId] = progress;
    notifyListeners();

    // Complete the download future
    if (local.isDownloadingCompleted && _downloadCompleter.containsKey(fileId)) {
      _downloadCompleter[fileId]!.complete(local.path);
      _downloadCompleter.remove(fileId);
      debugPrint('[Telegram] ✅ Download complete: ${local.path}');
    }
  }

  void _handleSearchResults(td.FoundMessages found, {int? extraId}) {
    const minBytes = 50 * 1024 * 1024;                 // 50 MB — skip trailers / fakes
    const maxBytes = 15 * 1024 * 1024 * 1024;            // 15 GB

    final results = <TelegramSearchResult>[];
    
    final pendingSearch = extraId != null ? _pendingSearches[extraId] : null;
    final targetSeason = pendingSearch?.season;
    final targetEpisode = pendingSearch?.episode;

    for (final msg in found.messages) {
      final content = msg.content;
      td.Video? video;
      td.Document? doc;

      if (content is td.MessageVideo) {
        video = content.video;
      } else if (content is td.MessageDocument) {
        doc = content.document;
        final mime = doc.mimeType.toLowerCase();
        if (!mime.contains('video') &&
            !mime.contains('matroska') &&
            !mime.contains('mp4')) {
          continue;
        }
      } else {
        continue;
      }

      final fileId   = video?.video.id          ?? doc?.document.id          ?? 0;
      final fileSize = video?.video.expectedSize ?? doc?.document.expectedSize ?? 0;
      final fileName = video?.fileName           ?? doc?.fileName             ?? '';
      final caption  = switch (content) {
        td.MessageVideo(:final caption)    => caption.text,
        td.MessageDocument(:final caption) => caption.text,
        _                                  => '',
      };

      if (fileSize < minBytes) {
        continue;
      }
      if (fileSize > maxBytes) {
        continue;
      }

      // Strict season/episode filtering
      if (targetSeason != null && targetEpisode != null) {
        if (!_matchesEpisode(fileName, caption, targetSeason, targetEpisode)) {
          continue;
        }
      }

      // Title matching verification using variations
      if (pendingSearch != null && pendingSearch.variations.isNotEmpty) {
        if (!_matchesTitle(fileName, caption, pendingSearch.variations)) {
          continue;
        }
      }

      final quality  = _parseQuality(fileName, caption);
      final codec    = _parseVideoCodec(fileName, caption);
      final audio    = _parseAudio(fileName, caption);
      final partInfo = _detectMultiPart(fileName, caption);

      results.add(TelegramSearchResult(
        fileId:       fileId,
        fileSize:     fileSize,
        fileName:     fileName,
        caption:      caption,
        channelTitle: '',
        channelId:    msg.chatId,
        messageId:    msg.id,
        quality:      quality,
        videoCodec:   codec,
        audioInfo:    audio,
        uploadDate:   DateTime.fromMillisecondsSinceEpoch(msg.date * 1000),
        isMultiPart:  partInfo.$1,
        partNumber:   partInfo.$2,
        totalParts:   partInfo.$3,
      ));
    }

    results.sort((a, b) => _scoreResult(b).compareTo(_scoreResult(a)));

    // Route to the correct completer by @extra ID, fall back to FIFO.
    if (extraId != null && _pendingSearches.containsKey(extraId)) {
      final p = _pendingSearches.remove(extraId)!;
      if (!p.completer.isCompleted) p.completer.complete(results);
    } else if (_pendingSearches.isNotEmpty) {
      final entry = _pendingSearches.entries.first;
      if (!entry.value.completer.isCompleted) entry.value.completer.complete(results);
      _pendingSearches.remove(entry.key);
    }
  }

  void _handleInlineQueryResults(td.InlineQueryResults results, {int? extraId}) {
    if (extraId == null || !_pendingInlineQueries.containsKey(extraId)) return;
    final c = _pendingInlineQueries.remove(extraId);

    final list = <TelegramSearchResult>[];
    const minBytes = 50 * 1024 * 1024; // 50 MB
    const maxBytes = 15 * 1024 * 1024 * 1024; // 15 GB

    for (final r in results.results) {
      td.Video? video;
      td.Document? doc;
      String? title;
      String? desc;

      if (r is td.InlineQueryResultDocument) {
        doc = r.document;
        title = r.title;
        desc = r.description;
      } else if (r is td.InlineQueryResultVideo) {
        video = r.video;
        title = r.title;
        desc = r.description;
      } else if (r is td.InlineQueryResultArticle) {
        title = r.title;
        desc = r.description;
      }

      final fileId = video?.video.id ?? doc?.document.id ?? 0;
      final fileSize = video?.video.expectedSize ?? doc?.document.expectedSize ?? 0;
      final fileName = video?.fileName ?? doc?.fileName ?? title ?? desc ?? '';
      final caption = desc ?? '';

      if (fileId == 0) continue;
      if (fileSize < minBytes) continue;
      if (fileSize > maxBytes) continue;

      final quality = _parseQuality(fileName, caption);
      final codec = _parseVideoCodec(fileName, caption);
      final audio = _parseAudio(fileName, caption);
      final partInfo = _detectMultiPart(fileName, caption);

      list.add(TelegramSearchResult(
        fileId: fileId,
        fileSize: fileSize,
        fileName: fileName,
        caption: caption,
        channelTitle: 'Telegram Bot',
        channelId: 0,
        messageId: 0,
        quality: quality,
        videoCodec: codec,
        audioInfo: audio,
        uploadDate: DateTime.now(),
        isMultiPart: partInfo.$1,
        partNumber: partInfo.$2,
        totalParts: partInfo.$3,
      ));
    }

    list.sort((a, b) => _scoreResult(b).compareTo(_scoreResult(a)));
    c?.complete(list);
  }

  Future<List<TelegramSearchResult>> _searchViaInlineBots(
    String query, {
    int? season,
    int? episode,
    String? baseTitle,
  }) async {
    const botUsernames = [
      'SearchMoviesBot',
      'TVSeriesSearchBot',
      'TGMovies3Bot',
      'SK_Movies1_bot',
      'Series_Movies_Search_Bot',
      'FilesSearchBot',
      'YourFindBot',
      'Movies_Series_Find_RoBot',
      'Anime4kaSearchBot',
      'AiMovieMY_Bot',
      'mr_robot_movies_bot',
      'iPopcornBot',
      'Olamovie_search_bot',
      'LinkzMoviesBot',
      'HDMoviesXBot',
      'FilmifyBot',
      'PostFinderBot',
    ];

    final results = <TelegramSearchResult>[];
    final matchTitle = baseTitle ?? query;
    final titleVariations = await AliasDatabase.getSearchVariations(matchTitle);

    // Build query variants to maximize find rate:
    // Use at most the top 2 variations of the title to avoid bot rate limits
    final activeTitleVariations = titleVariations.take(2).toList();
    final queries = <String>[];
    for (final variant in activeTitleVariations) {
      if (season != null && episode != null) {
        queries.add('$variant S${season.toString().padLeft(2, '0')}E${episode.toString().padLeft(2, '0')}');
        queries.add('$variant S${season.toString().padLeft(2, '0')}');
      } else if (season != null) {
        queries.add('$variant S${season.toString().padLeft(2, '0')}');
      } else {
        queries.add(variant);
      }
    }

    final futures = botUsernames.map((username) async {
      try {
        int? botUserId = _botIdCache[username];
        if (botUserId == null) {
          botUserId = await _resolveChatId(username);
          if (botUserId != null) {
            _botIdCache[username] = botUserId;
          }
        }

        if (botUserId == null) return;

        // Query all variants in parallel for this bot
        final botResults = await Future.wait<List<TelegramSearchResult>>(
          queries.map((q) async {
            final res = await _getInlineQueryResults(
              botUserId: botUserId!,
              query: q,
            );
            return res ?? <TelegramSearchResult>[];
          }),
        );

        for (final inlineResults in botResults) {
          Iterable<TelegramSearchResult> filtered = inlineResults;
          if (season != null && episode != null) {
            filtered = inlineResults.where((r) =>
                _matchesEpisode(r.fileName, r.caption, season, episode));
          }
          // Filter by title variations to prevent false positives
          filtered = filtered.where((r) =>
              _matchesTitle(r.fileName, r.caption, titleVariations));
          results.addAll(filtered);
        }
      } catch (e) {
        debugPrint('[Telegram] Inline bot @$username search failed: $e');
      }
    });

    await Future.wait(futures);

    // Deduplicate results by fileName and fileSize
    final uniqueResults = <TelegramSearchResult>[];
    final seen = <String>{};
    for (final r in results) {
      final key = '${r.fileName}_${r.fileSize}';
      if (seen.add(key)) {
        uniqueResults.add(r);
      }
    }
    return uniqueResults;
  }

  Future<List<TelegramSearchResult>?> _getInlineQueryResults({
    required int botUserId,
    required String query,
  }) async {
    final c = Completer<List<TelegramSearchResult>>();
    final id = _nextExtra();
    _pendingInlineQueries[id] = c;

    _send(
      td.GetInlineQueryResults(
        botUserId: botUserId,
        chatId: botUserId,
        userLocation: null,
        query: query,
        offset: '',
      ),
      extra: id,
    );

    return c.future.timeout(const Duration(seconds: 6), onTimeout: () {
      _pendingInlineQueries.remove(id);
      return [];
    });
  }

  // ── Parsers ───────────────────────────────────────────────────────────────

  bool _matchesEpisode(String fileName, String caption, int season, int episode) {
    final text = '$fileName $caption'.toUpperCase();
    
    // Exact standard matches: S01E01, S01.E01, S01_E01, S01-E01, S01 E01, S01EP01
    final standardRegex = RegExp('S0*$season[\\s._-]*EP?0*$episode\\b', caseSensitive: false);
    if (standardRegex.hasMatch(text)) return true;
    
    // Also match 1x01, 1x1, 01x01 formats
    final crossRegex = RegExp('0*$season[\\s]*[xX][\\s]*0*$episode\\b', caseSensitive: false);
    if (crossRegex.hasMatch(text)) return true;
    
    // Match "Season 1 Episode 1"
    final writtenRegex = RegExp('SEASON\\s*0*$season\\s*EPISODE\\s*0*$episode\\b', caseSensitive: false);
    if (writtenRegex.hasMatch(text)) return true;
    
    // Strict exact match fallback
    final genericRegex = RegExp('\\b0*$season[._-]0*$episode\\b', caseSensitive: false);
    if (genericRegex.hasMatch(text)) return true;

    // Season 1 fallback when no season indicator is in the filename (e.g. anime "Show - 01.mkv", "Show [01].mkv")
    if (season == 1 && !text.contains(RegExp('S\\d|SEASON\\s*\\d', caseSensitive: false))) {
      final epRegex = RegExp('(\\bEP?|\\s-|\\s\\[|\\s_)\\s*0*$episode\\b', caseSensitive: false);
      if (epRegex.hasMatch(text)) return true;
    }
    
    return false;
  }

  bool _matchesTitle(String fileName, String caption, List<String> variations) {
    final text = '$fileName $caption'.toLowerCase();
    // Strip telegram bot/channel names and punctuation
    final cleanText = text.replaceAll(RegExp(r'@\w+'), '').replaceAll(RegExp(r'[^\w\s]'), ' ');
    final words = cleanText.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toSet();

    for (final variant in variations) {
      final cleanVariant = variant.toLowerCase().replaceAll(RegExp(r'[^\w\s]'), '');
      if (cleanVariant.isEmpty) continue;

      if (cleanVariant.length <= 4) {
        // Short abbreviations (e.g. bb, got) must be distinct words to prevent false positives
        if (words.contains(cleanVariant)) return true;
      } else {
        final variantNoSpaces = cleanVariant.replaceAll(' ', '');
        // Substring matches are safe for longer names
        if (cleanText.contains(cleanVariant) || cleanText.replaceAll(' ', '').contains(variantNoSpaces)) {
          return true;
        }
      }
    }
    return false;
  }

  String _parseQuality(String fileName, String caption) {
    final combined = '$fileName $caption'.toUpperCase();
    if (combined.contains('2160P') || combined.contains('4K') || combined.contains('UHD')) {
      if (combined.contains('DV') || combined.contains('DOLBY VISION')) return '4K DV';
      if (combined.contains('HDR')) return '4K HDR';
      return '4K';
    }
    if (combined.contains('1080P') || combined.contains('1080')) {
      if (combined.contains('BLURAY') || combined.contains('BLU-RAY')) return '1080p BluRay';
      if (combined.contains('WEB-DL') || combined.contains('WEBDL')) return '1080p WEB-DL';
      return '1080p';
    }
    if (combined.contains('720P') || combined.contains('720')) return '720p';
    if (combined.contains('480P') || combined.contains('480')) return '480p';
    // Guess from file size
    return 'HD'; // default if we can't parse
  }

  String? _parseVideoCodec(String fileName, String caption) {
    final t = '$fileName $caption'.toUpperCase();
    if (t.contains('X265') || t.contains('H.265') || t.contains('H265') || t.contains('HEVC')) return 'HEVC';
    if (t.contains('X264') || t.contains('H.264') || t.contains('H264') || t.contains('AVC')) return 'AVC';
    if (t.contains('AV1')) return 'AV1';
    return null;
  }

  /// Detect audio language from filename + caption.
  /// Returns a canonical language string that matches LanguageFilter tokens,
  /// or null if no language tag is found (= Original).
  String? _parseAudio(String fileName, String caption) {
    final t = '$fileName $caption'.toUpperCase();

    // ── Dual / multi-language ────────────────────────────────────────────
    if (t.contains('DUAL AUDIO') || t.contains('DUAL-AUDIO') ||
        t.contains('DUAL.AUDIO') || RegExp(r'\bDUAL\b').hasMatch(t)) {
      return 'Dual Audio';
    }
    if (t.contains('MULTI') || t.contains('MULTI AUDIO') ||
        t.contains('MULTILANG') || t.contains('MULTI LANG')) {
      return 'Dual Audio'; // treat multi as dual for filter purposes
    }

    // ── Indian languages (check before generic ENG so ORG/ORIGIN doesn't match)
    if (t.contains('HINDI') || t.contains(' HIN ') || t.contains('.HIN.') ||
        t.contains('-HIN-') || t.contains('[HIN]')) {
      return 'Hindi';
    }
    if (t.contains('TAMIL') || t.contains(' TAM ') || t.contains('.TAM.') ||
        t.contains('-TAM-') || t.contains('[TAM]')) {
      return 'Tamil';
    }
    if (t.contains('TELUGU') || t.contains(' TEL ') || t.contains('.TEL.') ||
        t.contains('-TEL-') || t.contains('[TEL]')) {
      return 'Telugu';
    }
    if (t.contains('MALAYALAM') || t.contains(' MAL ') || t.contains('.MAL.') ||
        t.contains('-MAL-') || t.contains('[MAL]')) {
      return 'Malayalam';
    }
    if (t.contains('KANNADA') || t.contains(' KAN ') || t.contains('.KAN.') ||
        t.contains('-KAN-') || t.contains('[KAN]')) {
      return 'Kannada';
    }
    if (t.contains('BENGALI') || t.contains(' BEN ') || t.contains('.BEN.') ||
        t.contains('-BEN-') || t.contains('[BEN]')) {
      return 'Bengali';
    }
    if (t.contains('PUNJABI') || t.contains(' PUN ') || t.contains('.PUN.') ||
        t.contains('-PUN-') || t.contains('[PUN]')) {
      return 'Punjabi';
    }

    // ── English (explicit tag only — don't default to English)
    if (t.contains(' ENGLISH ') || t.contains('.ENGLISH.') ||
        t.contains(' ENG ') || t.contains('.ENG.') ||
        t.contains('-ENG-') || t.contains('[ENG]')) {
      return 'English';
    }

    // ── No language tag detected — return null (= Original / unknown)
    return null;
  }

  /// Detect "Part 1", "Part 2", ".001", ".002" etc.
  (bool, int, int) _detectMultiPart(String fileName, String caption) {
    final combined = '$fileName $caption';
    // Match "Part 1 of 3", "Part.1", "Part1", ".001", etc.
    final partMatch = RegExp(
      r'(?:part|pt)[\s._-]*(\d+)(?:\s*(?:of|/)\s*(\d+))?',
      caseSensitive: false,
    ).firstMatch(combined);

    if (partMatch != null) {
      final partNum = int.tryParse(partMatch.group(1) ?? '') ?? 1;
      final totalParts = int.tryParse(partMatch.group(2) ?? '') ?? 0;
      return (true, partNum, totalParts > 0 ? totalParts : 2);
    }

    // Match ".001", ".002" style splits
    final splitMatch = RegExp(r'\.(\d{3})$').firstMatch(fileName);
    if (splitMatch != null) {
      final partNum = int.tryParse(splitMatch.group(1) ?? '') ?? 1;
      return (true, partNum, 0); // unknown total
    }

    return (false, 1, 1);
  }

  /// Comprehensive smart ranking score. HIGHER = better.
  /// Factors: quality tier, file size (bigger=better within reason), codec
  /// efficiency, audio language, and recency.
  /// Pass [preferLang] to boost a specific language (e.g. 'Hindi', 'Dual Audio').
  int _scoreResult(TelegramSearchResult r, {String? preferLang}) {
    int score = 0;

    // ── Quality tier (primary) ──────────────────────────────────────────────
    final q = r.quality.toLowerCase();
    if (q.contains('1080')) {
      score += q.contains('bluray') ? 5000 : 4500; // BluRay > WEB-DL
    } else if (q.contains('720')) {
      score += 3000;
    } else if (q.contains('4k') || q.contains('2160')) {
      // 4K still scored but lower than 1080p (streaming platform — not for downloading)
      score += 2000;
    } else if (q.contains('480')) {
      score += 1000;
    } else {
      score += 500; // Unknown / HD
    }

    // ── File size (bigger within range = better quality encode) ────────────
    final sizeMB = r.fileSize / (1024 * 1024);
    if (sizeMB > 200 && sizeMB <= 2000) {
      score += (sizeMB * 0.5).round(); // up to +1000 for 2GB
    } else if (sizeMB > 2000 && sizeMB <= 4000) {
      score += 1000; // plateau at 2-4GB
    } else if (sizeMB > 4000) {
      score -= 500; // penalise enormous files on streaming platform
    }

    // ── Video codec ─────────────────────────────────────────────────────────
    final codec = r.videoCodec?.toUpperCase() ?? '';
    if (codec == 'HEVC') score += 400; // smaller file, same quality
    if (codec == 'AV1') score += 300;  // even smaller
    // AVC gets no bonus (it's the default/worst)

    // ── Audio language preference ────────────────────────────────────────────
    final audio = r.audioInfo?.toLowerCase() ?? '';
    if (preferLang != null) {
      final pref = preferLang.toLowerCase();
      if (audio.contains(pref)) {
        score += 2000; // strong boost for preferred language
      }
    }
    // General language scoring
    if (audio.contains('dual') || audio.contains('multi')) {
      score += 600;
    } else if (audio.contains('hindi')) {
      score += 400;
    } else if (audio.contains('english')) {
      score += 200;
    }

    // ── Recency (newer uploads are better encodes/sources) ──────────────────
    final ageHours = DateTime.now().difference(r.uploadDate).inHours;
    if (ageHours < 24) {
      score += 300;       // uploaded today
    } else if (ageHours < 168) {
      score += 150;       // within a week
    } else if (ageHours < 720) {
      score += 50;        // within a month
    }

    // ── Multi-part penalty (single-file preferred for streaming) ───────────
    if (r.isMultiPart) score -= 500;

    return score;
  }
}


// ── Cache ────────────────────────────────────────────────────────────────────

class _PendingSearch {
  final Completer<List<TelegramSearchResult>> completer;
  final int? season;
  final int? episode;
  final List<String> variations;
  _PendingSearch(this.completer, this.season, this.episode, this.variations);
}

class _CachedSearch {
  final List<TelegramSearchResult> results;
  final DateTime created;

  _CachedSearch(this.results) : created = DateTime.now();

  bool get isValid =>
      DateTime.now().difference(created) < const Duration(hours: 1);
}
