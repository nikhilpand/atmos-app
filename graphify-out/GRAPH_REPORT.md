# Graph Report - /home/nikhil/Desktop/atmos-app  (2026-05-02)

## Corpus Check
- 45 files · ~43,203 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 549 nodes · 679 edges · 24 communities detected
- Extraction: 99% EXTRACTED · 1% INFERRED · 0% AMBIGUOUS · INFERRED: 5 edges (avg confidence: 0.8)
- Token cost: 0 input · 0 output

## Community Hubs (Navigation)
- [[_COMMUNITY_Community 0|Community 0]]
- [[_COMMUNITY_Community 1|Community 1]]
- [[_COMMUNITY_Community 2|Community 2]]
- [[_COMMUNITY_Community 3|Community 3]]
- [[_COMMUNITY_Community 4|Community 4]]
- [[_COMMUNITY_Community 5|Community 5]]
- [[_COMMUNITY_Community 6|Community 6]]
- [[_COMMUNITY_Community 7|Community 7]]
- [[_COMMUNITY_Community 8|Community 8]]
- [[_COMMUNITY_Community 9|Community 9]]
- [[_COMMUNITY_Community 10|Community 10]]
- [[_COMMUNITY_Community 11|Community 11]]
- [[_COMMUNITY_Community 12|Community 12]]
- [[_COMMUNITY_Community 13|Community 13]]
- [[_COMMUNITY_Community 14|Community 14]]
- [[_COMMUNITY_Community 15|Community 15]]
- [[_COMMUNITY_Community 16|Community 16]]
- [[_COMMUNITY_Community 17|Community 17]]
- [[_COMMUNITY_Community 18|Community 18]]
- [[_COMMUNITY_Community 19|Community 19]]
- [[_COMMUNITY_Community 20|Community 20]]
- [[_COMMUNITY_Community 21|Community 21]]
- [[_COMMUNITY_Community 22|Community 22]]
- [[_COMMUNITY_Community 23|Community 23]]

## God Nodes (most connected - your core abstractions)
1. `package:flutter/material.dart` - 21 edges
2. `../models/media_model.dart` - 15 edges
3. `../theme/app_theme.dart` - 15 edges
4. `package:flutter_riverpod/flutter_riverpod.dart` - 14 edges
5. `../providers/providers.dart` - 11 edges
6. `package:go_router/go_router.dart` - 10 edges
7. `package:flutter_animate/flutter_animate.dart` - 10 edges
8. `../theme/app_tokens.dart` - 7 edges
9. `../models/download_model.dart` - 6 edges
10. `fetch()` - 5 edges

## Surprising Connections (you probably didn't know these)
- `extractStreamUrls()` --calls--> `add`  [INFERRED]
  /home/nikhil/Desktop/atmos-app/cloudflare-worker/worker.js → /home/nikhil/Desktop/atmos-app/lib/services/watchlist_service.dart
- `fetch()` --calls--> `toString`  [INFERRED]
  /home/nikhil/Desktop/atmos-app/cloudflare-worker/worker.js → /home/nikhil/Desktop/atmos-app/lib/services/stream_extractor_service.dart
- `fetch()` --calls--> `toString`  [INFERRED]
  /home/nikhil/Desktop/atmos-app/cloudflare-worker/worker.js → /home/nikhil/Desktop/atmos-app/lib/models/telegram_search_result.dart
- `fetchProvider()` --calls--> `Text`  [INFERRED]
  /home/nikhil/Desktop/atmos-app/cloudflare-worker/worker.js → /home/nikhil/Desktop/atmos-app/lib/widgets/download_filter_sheet.dart

## Communities

### Community 0 - "Community 0"
Cohesion: 0.04
Nodes (53): AdaptiveShell, AtmosApp, build, _buildRouter, GoRouter, main, MaterialPage, _requestPermissions (+45 more)

### Community 1 - "Community 1"
Cohesion: 0.05
Nodes (46): build, _buildEmpty, _buildSkeletonGrid, Center, dispose, GenreScreen, _GenreScreenState, GestureDetector (+38 more)

### Community 2 - "Community 2"
Cohesion: 0.04
Nodes (44): dart:async, dart:convert, dart:isolate, ExtractedStream, isVideo, MutationObserver, report, StreamExtractorService (+36 more)

### Community 3 - "Community 3"
Cohesion: 0.05
Nodes (34): GeneratedPluginRegistrant, DownloadTask, QualityOption, Cast, Episode, Genre, Season, StreamResult (+26 more)

### Community 4 - "Community 4"
Cohesion: 0.05
Nodes (38): _ActionButton, build, _CardHeader, _CardMeta, _CardProgress, Center, _confirmDelete, Container (+30 more)

### Community 5 - "Community 5"
Cohesion: 0.05
Nodes (36): _BackdropHeader, _Badge, build, _CastRow, Column, Container, CustomScrollView, _DetailsContent (+28 more)

### Community 6 - "Community 6"
Cohesion: 0.06
Nodes (35): _advanceEpisode, build, _buildUrl, dispose, Divider, DraggableScrollableSheet, Function, GestureDetector (+27 more)

### Community 7 - "Community 7"
Cohesion: 0.06
Nodes (34): app_tokens.dart, _advanceEpisode, build, Column, Container, _ControlsOverlay, dispose, _fmt (+26 more)

### Community 8 - "Community 8"
Cohesion: 0.06
Nodes (33): _AppearanceSection, build, _confirmClearHistory, dispose, Function, _getTelegramSubtitle, initState, _onAuthChange (+25 more)

### Community 9 - "Community 9"
Cohesion: 0.06
Nodes (31): TelegramSearchResult, toString, toString, build, _color, Container, copyWith, Divider (+23 more)

### Community 10 - "Community 10"
Cohesion: 0.06
Nodes (31): dart:ffi, dart:io, main, _buildId, _buildMagnet, DownloadService, _failTask, isDownloaded (+23 more)

### Community 11 - "Community 11"
Cohesion: 0.07
Nodes (26): build, Column, Container, _ContinueWatchingRow, dispose, _ErrorBanner, _ErrorRow, _FilterChips (+18 more)

### Community 12 - "Community 12"
Cohesion: 0.11
Nodes (18): _Badge, build, Card, Center, dispose, _EmptyPrompt, _ErrorView, _formatSize (+10 more)

### Community 13 - "Community 13"
Cohesion: 0.12
Nodes (16): AnimatedBuilder, build, Column, dispose, Focus, Function, initState, MediaCard (+8 more)

### Community 14 - "Community 14"
Cohesion: 0.15
Nodes (12): AdaptiveShell, _BottomBarLayout, build, Center, _ExtendedRailLayout, Function, NavDestination, PageFrame (+4 more)

### Community 15 - "Community 15"
Cohesion: 0.25
Nodes (7): DownloadStatusAdapter, DownloadTask, DownloadTaskAdapter, QualityOption, QualityOptionAdapter, read, write

### Community 16 - "Community 16"
Cohesion: 0.4
Nodes (4): read, WatchHistory, WatchHistoryAdapter, write

### Community 17 - "Community 17"
Cohesion: 0.67
Nodes (2): main, package:flutter_test/flutter_test.dart

### Community 18 - "Community 18"
Cohesion: 1.0
Nodes (0): 

### Community 19 - "Community 19"
Cohesion: 1.0
Nodes (1): MainActivity

### Community 20 - "Community 20"
Cohesion: 1.0
Nodes (1): fromString

### Community 21 - "Community 21"
Cohesion: 1.0
Nodes (0): 

### Community 22 - "Community 22"
Cohesion: 1.0
Nodes (0): 

### Community 23 - "Community 23"
Cohesion: 1.0
Nodes (0): 

## Knowledge Gaps
- **454 isolated node(s):** `main`, `package:flutter_test/flutter_test.dart`, `MainActivity`, `AtmosApp`, `main` (+449 more)
  These have ≤1 connection - possible missing edges or undocumented components.
- **Thin community `Community 18`** (2 nodes): `fetch()`, `cloudflare_worker.js`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Community 19`** (2 nodes): `MainActivity.kt`, `MainActivity`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Community 20`** (2 nodes): `download_source.dart`, `fromString`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Community 21`** (1 nodes): `build.gradle.kts`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Community 22`** (1 nodes): `settings.gradle.kts`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Community 23`** (1 nodes): `build.gradle.kts`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `package:flutter/material.dart` connect `Community 7` to `Community 0`, `Community 1`, `Community 2`, `Community 4`, `Community 5`, `Community 6`, `Community 8`, `Community 9`, `Community 10`, `Community 11`, `Community 12`, `Community 13`, `Community 14`?**
  _High betweenness centrality (0.254) - this node is a cross-community bridge._
- **Why does `../models/media_model.dart` connect `Community 3` to `Community 0`, `Community 1`, `Community 5`, `Community 11`, `Community 13`?**
  _High betweenness centrality (0.132) - this node is a cross-community bridge._
- **Why does `../theme/app_theme.dart` connect `Community 1` to `Community 0`, `Community 4`, `Community 5`, `Community 6`, `Community 8`, `Community 9`, `Community 11`, `Community 12`, `Community 13`, `Community 14`?**
  _High betweenness centrality (0.117) - this node is a cross-community bridge._
- **What connects `main`, `package:flutter_test/flutter_test.dart`, `MainActivity` to the rest of the system?**
  _454 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `Community 0` be split into smaller, more focused modules?**
  _Cohesion score 0.04 - nodes in this community are weakly interconnected._
- **Should `Community 1` be split into smaller, more focused modules?**
  _Cohesion score 0.05 - nodes in this community are weakly interconnected._
- **Should `Community 2` be split into smaller, more focused modules?**
  _Cohesion score 0.04 - nodes in this community are weakly interconnected._