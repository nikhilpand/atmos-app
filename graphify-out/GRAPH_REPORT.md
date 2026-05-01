# Graph Report - /home/nikhil/Desktop/atmos-app  (2026-04-30)

## Corpus Check
- 35 files · ~26,197 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 380 nodes · 437 edges · 25 communities detected
- Extraction: 100% EXTRACTED · 0% INFERRED · 0% AMBIGUOUS · INFERRED: 2 edges (avg confidence: 0.8)
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
- [[_COMMUNITY_Community 24|Community 24]]

## God Nodes (most connected - your core abstractions)
1. `package:flutter/material.dart` - 13 edges
2. `../theme/app_theme.dart` - 11 edges
3. `../models/media_model.dart` - 9 edges
4. `package:flutter_riverpod/flutter_riverpod.dart` - 8 edges
5. `package:go_router/go_router.dart` - 7 edges
6. `../providers/providers.dart` - 6 edges
7. `../models/download_model.dart` - 5 edges
8. `fetchProvider()` - 4 edges
9. `fetch()` - 4 edges
10. `package:flutter/services.dart` - 4 edges

## Surprising Connections (you probably didn't know these)
- `fetchProvider()` --calls--> `Text`  [INFERRED]
  /home/nikhil/Desktop/atmos-app/cloudflare-worker/worker.js → /home/nikhil/Desktop/atmos-app/lib/widgets/download_filter_sheet.dart
- `fetch()` --calls--> `toString`  [INFERRED]
  /home/nikhil/Desktop/atmos-app/cloudflare-worker/worker.js → /home/nikhil/Desktop/atmos-app/lib/models/telegram_search_result.dart

## Communities

### Community 0 - "Community 0"
Cohesion: 0.05
Nodes (39): dart:async, dart:io, dart:isolate, main, _buildId, DownloadService, _failTask, isDownloaded (+31 more)

### Community 1 - "Community 1"
Cohesion: 0.06
Nodes (33): build, Column, Container, _ContinueWatchingRow, dispose, _ErrorBanner, _ErrorRow, _FilterChips (+25 more)

### Community 2 - "Community 2"
Cohesion: 0.06
Nodes (34): _ActionButton, build, _CardHeader, _CardMeta, _CardProgress, Center, _confirmDelete, Container (+26 more)

### Community 3 - "Community 3"
Cohesion: 0.06
Nodes (32): _BackdropHeader, _Badge, build, _CastRow, Column, Container, CustomScrollView, _DetailsContent (+24 more)

### Community 4 - "Community 4"
Cohesion: 0.08
Nodes (27): AdaptiveShell, AtmosApp, build, main, MaterialPage, _requestPermissions, ContinueWatchingNotifier, refresh (+19 more)

### Community 5 - "Community 5"
Cohesion: 0.07
Nodes (28): dart:typed_data, build, _buildUrl, dispose, GestureDetector, Icon, initState, _isAd (+20 more)

### Community 6 - "Community 6"
Cohesion: 0.08
Nodes (24): build, EpisodeTile, _EpisodeTileState, Focus, SizedBox, AnimatedBuilder, build, Column (+16 more)

### Community 7 - "Community 7"
Cohesion: 0.08
Nodes (24): _AppearanceSection, build, _clearCache, _confirmClearHistory, dispose, Function, _getTelegramSubtitle, initState (+16 more)

### Community 8 - "Community 8"
Cohesion: 0.08
Nodes (23): build, _color, Container, copyWith, Divider, DownloadFilters, DownloadFilterSheet, _DownloadFilterSheetState (+15 more)

### Community 9 - "Community 9"
Cohesion: 0.09
Nodes (21): app_tokens.dart, AtmosTheme, build, heroGradient, primaryGradient, ThemeData, AdaptiveShell, _BottomBarLayout (+13 more)

### Community 10 - "Community 10"
Cohesion: 0.13
Nodes (14): dart:convert, _normalizeImdbId, _parseSeeders, _parseSizeBytes, _parseSource, _parseTorrentioQuality, QualityOption, _qualityOrder (+6 more)

### Community 11 - "Community 11"
Cohesion: 0.16
Nodes (11): buildProxiedUrl, ExtractorService, _buildKey, getHistory, HistoryService, _parseResults, TmdbService, ../models/media_model.dart (+3 more)

### Community 12 - "Community 12"
Cohesion: 0.15
Nodes (11): DownloadTask, QualityOption, Cast, Episode, Genre, Season, StreamResult, TmdbDetails (+3 more)

### Community 13 - "Community 13"
Cohesion: 0.31
Nodes (7): TelegramSearchResult, toString, Text, extractStreamUrls(), fetch(), fetchProvider(), proxyStream()

### Community 14 - "Community 14"
Cohesion: 0.25
Nodes (7): DownloadStatusAdapter, DownloadTask, DownloadTaskAdapter, QualityOption, QualityOptionAdapter, read, write

### Community 15 - "Community 15"
Cohesion: 0.4
Nodes (4): read, WatchHistory, WatchHistoryAdapter, write

### Community 16 - "Community 16"
Cohesion: 0.67
Nodes (2): main, package:flutter_test/flutter_test.dart

### Community 17 - "Community 17"
Cohesion: 0.67
Nodes (1): GeneratedPluginRegistrant

### Community 18 - "Community 18"
Cohesion: 1.0
Nodes (1): MainActivity

### Community 19 - "Community 19"
Cohesion: 1.0
Nodes (1): fromString

### Community 20 - "Community 20"
Cohesion: 1.0
Nodes (0): 

### Community 21 - "Community 21"
Cohesion: 1.0
Nodes (0): 

### Community 22 - "Community 22"
Cohesion: 1.0
Nodes (0): 

### Community 23 - "Community 23"
Cohesion: 1.0
Nodes (0): 

### Community 24 - "Community 24"
Cohesion: 1.0
Nodes (0): 

## Knowledge Gaps
- **310 isolated node(s):** `main`, `package:flutter_test/flutter_test.dart`, `MainActivity`, `AtmosApp`, `main` (+305 more)
  These have ≤1 connection - possible missing edges or undocumented components.
- **Thin community `Community 18`** (2 nodes): `MainActivity.kt`, `MainActivity`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Community 19`** (2 nodes): `download_source.dart`, `fromString`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Community 20`** (1 nodes): `replace_all.py`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Community 21`** (1 nodes): `replace.py`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Community 22`** (1 nodes): `build.gradle.kts`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Community 23`** (1 nodes): `settings.gradle.kts`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Community 24`** (1 nodes): `build.gradle.kts`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `package:flutter/material.dart` connect `Community 9` to `Community 1`, `Community 2`, `Community 3`, `Community 4`, `Community 5`, `Community 6`, `Community 7`, `Community 8`?**
  _High betweenness centrality (0.215) - this node is a cross-community bridge._
- **Why does `../theme/app_theme.dart` connect `Community 6` to `Community 1`, `Community 2`, `Community 3`, `Community 4`, `Community 5`, `Community 7`, `Community 8`, `Community 9`?**
  _High betweenness centrality (0.168) - this node is a cross-community bridge._
- **Why does `../models/download_model.dart` connect `Community 10` to `Community 0`, `Community 2`, `Community 3`?**
  _High betweenness centrality (0.143) - this node is a cross-community bridge._
- **What connects `main`, `package:flutter_test/flutter_test.dart`, `MainActivity` to the rest of the system?**
  _310 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `Community 0` be split into smaller, more focused modules?**
  _Cohesion score 0.05 - nodes in this community are weakly interconnected._
- **Should `Community 1` be split into smaller, more focused modules?**
  _Cohesion score 0.06 - nodes in this community are weakly interconnected._
- **Should `Community 2` be split into smaller, more focused modules?**
  _Cohesion score 0.06 - nodes in this community are weakly interconnected._