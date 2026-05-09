import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:posthog_flutter/posthog_flutter.dart';
import 'package:media_kit/media_kit.dart';
import 'services/history_service.dart';
import 'services/download_service.dart';
import 'services/telegram_service.dart';
import 'services/recommendation_service.dart';
import 'services/watchlist_service.dart';
import 'services/tmdb_service.dart';
import 'models/download_source.dart';
import 'models/media_model.dart';
import 'providers/providers.dart';
import 'screens/home_screen.dart';
import 'screens/search_screen.dart';
import 'screens/details_screen.dart';
// import 'screens/player_screen.dart'; // DEPRECATED — unified native player
import 'screens/download_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/genre_screen.dart';
import 'screens/onboarding_screen.dart';
import 'screens/watchlist_screen.dart';
import 'screens/telegram_channel_browser.dart';
import 'screens/native_player_screen.dart';
import 'theme/app_theme.dart';
import 'widgets/responsive_layout.dart';
import 'package:flutter_skill/flutter_skill.dart';

void main() async {
  FlutterSkillBinding.ensureInitialized();
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized(); // ← native player init
  await SystemChrome.setPreferredOrientations(DeviceOrientation.values);
  await dotenv.load(fileName: '.env');
  await _requestPermissions();

  final extDir = await getExternalStorageDirectory();
  final downloadDir = extDir?.path ?? (await getApplicationDocumentsDirectory()).path;

  final historyService = HistoryService();
  await historyService.init();

  final downloadService = DownloadService();
  await downloadService.init(downloadDir);

  final telegramService = TelegramService();
  await telegramService.init();
  try {
    await telegramService.whenReady.timeout(const Duration(seconds: 5));
  } catch (e) {
    debugPrint('[Main] Telegram service ready timeout or error: $e');
  }
  // Recommendation service — taste profile engine
  final recommendationService = RecommendationService();
  await recommendationService.init();

  // Watchlist — bookmark service
  final watchlistService = WatchlistService();
  await watchlistService.init();

  // Init TMDB cache (Hive box for 6hr TTL responses)
  final tmdbService = TmdbService();
  await tmdbService.initCache();

  downloadService.telegramService = telegramService;
  telegramService.addListener(() {
    for (final progress in telegramService.activeDownloads.values) {
      downloadService.syncTelegramProgress(
        progress.fileId, progress.progress,
        progress.downloadedBytes, progress.isComplete, progress.localPath,
      );
    }
  });

  final prefs = await SharedPreferences.getInstance();
  final savedSource = DownloadSourceLabel.fromString(prefs.getString('dl_source'));
  final onboardingDone = prefs.getBool('onboarding_done') ?? false;

  final seedNotifier = SeedColorNotifier();
  await seedNotifier.load();

  // Wrap runApp with Sentry
  await SentryFlutter.init(
    (options) {
      options.dsn = dotenv.env['SENTRY_DSN'] ?? '';
      options.tracesSampleRate = 1.0;
    },
    appRunner: () => runApp(
      ProviderScope(
        overrides: [
          historyServiceProvider.overrideWithValue(historyService),
          tmdbServiceProvider.overrideWithValue(tmdbService),
          downloadServiceProvider.overrideWith((_) => downloadService),
          telegramServiceProvider.overrideWith((_) => telegramService),
          recommendationServiceProvider.overrideWithValue(recommendationService),
          watchlistServiceProvider.overrideWithValue(watchlistService),
          watchlistProvider.overrideWith((_) => watchlistService),
          downloadSourceProvider.overrideWith((ref) => savedSource),
          seedColorProvider.overrideWith((_) => seedNotifier),
        ],
        child: AtmosApp(onboardingDone: onboardingDone),
      ),
    ),
  );
}

Future<void> _requestPermissions() async {
  try {
    await Permission.notification.request();
    await Permission.storage.request();
    if (await Permission.manageExternalStorage.isGranted == false) {
      await Permission.manageExternalStorage.request();
    }
  } catch (_) {}
}

// ─── Router ───────────────────────────────────────────────────────────────────

final _rootNavigatorKey = GlobalKey<NavigatorState>();
final _shellNavigatorKey = GlobalKey<NavigatorState>();

GoRouter _buildRouter(bool onboardingDone, RecommendationService recService) {
  return GoRouter(
    navigatorKey: _rootNavigatorKey,
    initialLocation: onboardingDone ? '/' : '/onboarding',
    routes: [
      // Onboarding (outside shell — no nav bar)
      GoRoute(
        path: '/onboarding',
        parentNavigatorKey: _rootNavigatorKey,
        pageBuilder: (_, __) => MaterialPage(
          child: OnboardingScreen(recService: recService),
        ),
      ),

      // Telegram Channel Browser (outside shell)
      GoRoute(
        path: '/telegram-browser',
        parentNavigatorKey: _rootNavigatorKey,
        pageBuilder: (_, __) => const MaterialPage(child: TelegramChannelBrowserScreen()),
      ),

      // Main app shell
      ShellRoute(
        navigatorKey: _shellNavigatorKey,
        builder: (context, state, child) {
          int idx = 0;
          if (state.uri.path.startsWith('/search'))    idx = 1;
          if (state.uri.path.startsWith('/watchlist')) idx = 2;
          if (state.uri.path.startsWith('/downloads')) idx = 3;
          if (state.uri.path.startsWith('/settings'))  idx = 4;
          return AdaptiveShell(
            selectedIndex: idx,
            onDestinationSelected: (i) {
              switch (i) {
                case 0: context.go('/'); break;
                case 1: context.go('/search'); break;
                case 2: context.go('/watchlist'); break;
                case 3: context.go('/downloads'); break;
                case 4: context.go('/settings'); break;
              }
            },
            body: child,
          );
        },
        routes: [
          GoRoute(path: '/', pageBuilder: (_, __) => const NoTransitionPage(child: HomeScreen())),
          GoRoute(path: '/search', pageBuilder: (_, __) => const NoTransitionPage(child: SearchScreen())),
          GoRoute(path: '/watchlist', pageBuilder: (_, __) => const NoTransitionPage(child: WatchlistScreen())),
          GoRoute(path: '/downloads', pageBuilder: (_, __) => const NoTransitionPage(child: DownloadScreen())),
          GoRoute(path: '/settings', pageBuilder: (_, __) => const NoTransitionPage(child: SettingsScreen())),
        ],
      ),

      // Details (full-screen, no bottom nav)
      GoRoute(
        path: '/details/:type/:id',
        parentNavigatorKey: _rootNavigatorKey,
        pageBuilder: (context, state) {
          final type = state.pathParameters['type']!;
          final id = int.tryParse(state.pathParameters['id']!) ?? 0;
          return MaterialPage(child: DetailsScreen(mediaType: type, tmdbId: id));
        },
      ),

      // Player (legacy route → redirects to native)
      GoRoute(
        path: '/player',
        parentNavigatorKey: _rootNavigatorKey,
        pageBuilder: (context, state) {
          final args = Map<String, dynamic>.from(
              (state.extra as Map<String, dynamic>?) ?? const {});
          return MaterialPage(child: NativePlayerScreen(args: args));
        },
      ),

      // Player (native media_kit)
      GoRoute(
        path: '/native-player',
        parentNavigatorKey: _rootNavigatorKey,
        pageBuilder: (context, state) {
          final args = Map<String, dynamic>.from(
              (state.extra as Map<String, dynamic>?) ?? const {});
          return MaterialPage(child: NativePlayerScreen(args: args));
        },
      ),

      // Genre screen
      GoRoute(
        path: '/genre/:id',
        parentNavigatorKey: _rootNavigatorKey,
        pageBuilder: (context, state) {
          final genreId = int.tryParse(state.pathParameters['id']!) ?? 0;
          final extra = (state.extra as Map<String, dynamic>?) ?? {};
          final name = extra['name'] as String? ?? 'Genre';
          final emoji = extra['emoji'] as String? ?? '🎬';
          final typeStr = extra['type'] as String? ?? 'movie';
          final type = typeStr == 'tv' ? MediaType.tv : MediaType.movie;
          return MaterialPage(
            child: GenreScreen(
              genreId: genreId,
              genreName: name,
              genreEmoji: emoji,
              initialType: type,
            ),
          );
        },
      ),
    ],
    observers: [
      SentryNavigatorObserver(),
      PosthogObserver(),
    ],
  );
}

// ─── App Root ─────────────────────────────────────────────────────────────────

class AtmosApp extends ConsumerWidget {
  final bool onboardingDone;
  const AtmosApp({super.key, required this.onboardingDone});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final seed = ref.watch(seedColorProvider);
    final theme = AtmosTheme.build(seed);
    final recService = ref.read(recommendationServiceProvider);
    final router = _buildRouter(onboardingDone, recService);

    return MaterialApp.router(
      title: 'Atmos',
      debugShowCheckedModeBanner: false,
      theme: theme,
      scrollBehavior: const MaterialScrollBehavior(),
      routerConfig: router,
    );
  }
}
