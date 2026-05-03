# Graph Report - /home/nikhil/Desktop/atmos-app  (2026-05-03)

## Corpus Check
- 61 files · ~50,441 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 591 nodes · 799 edges · 28 communities detected
- Extraction: 94% EXTRACTED · 6% INFERRED · 0% AMBIGUOUS · INFERRED: 44 edges (avg confidence: 0.8)
- Token cost: 0 input · 0 output

## Community Hubs (Navigation)
- [[_COMMUNITY_Flutter UI Core|Flutter UI Core]]
- [[_COMMUNITY_Dart Platform Layer|Dart Platform Layer]]
- [[_COMMUNITY_Atmos Index Client|Atmos Index Client]]
- [[_COMMUNITY_Finder Bot Engine|Finder Bot Engine]]
- [[_COMMUNITY_Design Tokens & Theme|Design Tokens & Theme]]
- [[_COMMUNITY_Media Providers|Media Providers]]
- [[_COMMUNITY_Navigation & Routing|Navigation & Routing]]
- [[_COMMUNITY_Search & Discovery|Search & Discovery]]
- [[_COMMUNITY_Player & Playback|Player & Playback]]
- [[_COMMUNITY_State Management|State Management]]
- [[_COMMUNITY_Async Data Layer|Async Data Layer]]
- [[_COMMUNITY_Content Models|Content Models]]
- [[_COMMUNITY_CloudFlare Worker|CloudFlare Worker]]
- [[_COMMUNITY_Download Pipeline|Download Pipeline]]
- [[_COMMUNITY_Auth & Session|Auth & Session]]
- [[_COMMUNITY_App Config|App Config]]
- [[_COMMUNITY_Worker Utils|Worker Utils]]
- [[_COMMUNITY_Test Parser|Test Parser]]
- [[_COMMUNITY_Schema & DB|Schema & DB]]
- [[_COMMUNITY_Seed Channels|Seed Channels]]
- [[_COMMUNITY_Integration Tests|Integration Tests]]
- [[_COMMUNITY_Build Config|Build Config]]
- [[_COMMUNITY_Android Native|Android Native]]
- [[_COMMUNITY_Stream Extraction|Stream Extraction]]
- [[_COMMUNITY_Bot Discovery|Bot Discovery]]
- [[_COMMUNITY_Supabase Index|Supabase Index]]
- [[_COMMUNITY_Parser Core|Parser Core]]
- [[_COMMUNITY_Channel Crawler|Channel Crawler]]

## God Nodes (most connected - your core abstractions)
1. `package:flutter/material.dart` - 21 edges
2. `../theme/app_theme.dart` - 15 edges
3. `fetch()` - 14 edges
4. `package:flutter_riverpod/flutter_riverpod.dart` - 14 edges
5. `../models/media_model.dart` - 14 edges
6. `main()` - 12 edges
7. `parseFilename()` - 11 edges
8. `../providers/providers.dart` - 11 edges
9. `supabaseQuery()` - 10 edges
10. `package:go_router/go_router.dart` - 10 edges

## Surprising Connections (you probably didn't know these)
- `Supabase Indexing` --writes_to--> `Supabase Catalog (tg_media)`  [EXTRACTED]
  tools/tg-search/finder.mjs → cloudflare-worker/schema.sql
- `queryDirectBot()` --calls--> `toString`  [INFERRED]
  /home/nikhil/Desktop/atmos-app/tools/tg-search/finder.mjs → /home/nikhil/Desktop/atmos-app/lib/services/stream_extractor_service.dart
- `indexToSupabase()` --calls--> `fetch()`  [INFERRED]
  /home/nikhil/Desktop/atmos-app/tools/tg-search/finder.mjs → /home/nikhil/Desktop/atmos-app/cloudflare-worker/worker.js
- `indexToSupabase()` --calls--> `Text`  [INFERRED]
  /home/nikhil/Desktop/atmos-app/tools/tg-search/finder.mjs → /home/nikhil/Desktop/atmos-app/lib/widgets/download_filter_sheet.dart
- `indexToSupabase()` --calls--> `fetch()`  [INFERRED]
  /home/nikhil/Desktop/atmos-app/tools/tg-search/search.mjs → /home/nikhil/Desktop/atmos-app/cloudflare-worker/worker.js

## Communities

### Community 0 - "Flutter UI Core"
Cohesion: 0.04
Nodes (58): build, _buildEmpty, _buildSkeletonGrid, Center, dispose, GenreScreen, _GenreScreenState, GestureDetector (+50 more)

### Community 1 - "Dart Platform Layer"
Cohesion: 0.04
Nodes (49): dart:ffi, dart:io, _ActionButton, build, _CardHeader, _CardMeta, _CardProgress, Center (+41 more)

### Community 2 - "Atmos Index Client"
Cohesion: 0.04
Nodes (44): atmos_index_client.dart, dart:isolate, _buildId, DownloadService, _failTask, isDownloaded, isDownloading, _processNextQueued (+36 more)

### Community 3 - "Finder Bot Engine"
Cohesion: 0.1
Nodes (34): connect(), deduplicateAndRank(), discoverAndSearchChannels(), display(), extractEpisodeFromButton(), globalSearch(), indexToSupabase(), main() (+26 more)

### Community 4 - "Design Tokens & Theme"
Cohesion: 0.05
Nodes (38): app_tokens.dart, _AppearanceSection, build, _confirmClearHistory, dispose, Function, _getTelegramSubtitle, initState (+30 more)

### Community 5 - "Media Providers"
Cohesion: 0.06
Nodes (36): AdaptiveShell, AtmosApp, build, _buildRouter, GoRouter, main, MaterialPage, _requestPermissions (+28 more)

### Community 6 - "Navigation & Routing"
Cohesion: 0.05
Nodes (36): build, Column, Container, _ContinueWatchingRow, dispose, _ErrorBanner, _ErrorRow, _FilterChips (+28 more)

### Community 7 - "Search & Discovery"
Cohesion: 0.05
Nodes (36): _BackdropHeader, _Badge, build, _CastRow, Column, Container, CustomScrollView, _DetailsContent (+28 more)

### Community 8 - "Player & Playback"
Cohesion: 0.06
Nodes (35): _advanceEpisode, build, _buildUrl, dispose, Divider, DraggableScrollableSheet, Function, GestureDetector (+27 more)

### Community 9 - "State Management"
Cohesion: 0.07
Nodes (28): AnimatedBuilder, build, Column, dispose, Focus, Function, initState, MediaCard (+20 more)

### Community 10 - "Async Data Layer"
Cohesion: 0.08
Nodes (24): dart:async, dart:convert, AtmosIndexClient, IndexedMedia, jsonDecode, toString, warmUp, ExtractedStream (+16 more)

### Community 11 - "Content Models"
Cohesion: 0.08
Nodes (25): _advanceEpisode, build, Column, Container, _ControlsOverlay, dispose, _fmt, GestureDetector (+17 more)

### Community 12 - "CloudFlare Worker"
Cohesion: 0.21
Nodes (21): buildSearchQueries(), crawlChannel(), handleSearch(), handleSeasonSearch(), handleStats(), json(), liveScrapeSearch(), runCrawl() (+13 more)

### Community 13 - "Download Pipeline"
Cohesion: 0.08
Nodes (23): build, _color, Container, copyWith, Divider, DownloadFilters, DownloadFilterSheet, _DownloadFilterSheetState (+15 more)

### Community 14 - "Auth & Session"
Cohesion: 0.11
Nodes (18): _Badge, build, Card, Center, dispose, _EmptyPrompt, _ErrorView, _formatSize (+10 more)

### Community 15 - "App Config"
Cohesion: 0.15
Nodes (11): DownloadTask, QualityOption, Cast, Episode, Genre, Season, StreamResult, TmdbDetails (+3 more)

### Community 16 - "Worker Utils"
Cohesion: 0.25
Nodes (7): DownloadStatusAdapter, DownloadTask, DownloadTaskAdapter, QualityOption, QualityOptionAdapter, read, write

### Community 17 - "Test Parser"
Cohesion: 0.33
Nodes (6): Cron Crawler, Search API, Bot Network Search, Channel Discovery Fallback, Supabase Indexing, Supabase Catalog (tg_media)

### Community 18 - "Schema & DB"
Cohesion: 1.0
Nodes (2): ask(), main()

### Community 19 - "Seed Channels"
Cohesion: 0.67
Nodes (2): main, package:flutter_test/flutter_test.dart

### Community 20 - "Integration Tests"
Cohesion: 0.67
Nodes (2): TelegramSearchResult, toString

### Community 21 - "Build Config"
Cohesion: 1.0
Nodes (0): 

### Community 22 - "Android Native"
Cohesion: 1.0
Nodes (1): MainActivity

### Community 23 - "Stream Extraction"
Cohesion: 1.0
Nodes (1): fromString

### Community 24 - "Bot Discovery"
Cohesion: 1.0
Nodes (0): 

### Community 25 - "Supabase Index"
Cohesion: 1.0
Nodes (0): 

### Community 26 - "Parser Core"
Cohesion: 1.0
Nodes (0): 

### Community 27 - "Channel Crawler"
Cohesion: 1.0
Nodes (1): Stream Extraction

## Knowledge Gaps
- **440 isolated node(s):** `main`, `package:flutter_test/flutter_test.dart`, `MainActivity`, `AtmosApp`, `main` (+435 more)
  These have ≤1 connection - possible missing edges or undocumented components.
- **Thin community `Build Config`** (2 nodes): `fetch()`, `cloudflare_worker.js`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Android Native`** (2 nodes): `MainActivity.kt`, `MainActivity`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Stream Extraction`** (2 nodes): `download_source.dart`, `fromString`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Bot Discovery`** (1 nodes): `build.gradle.kts`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Supabase Index`** (1 nodes): `settings.gradle.kts`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Parser Core`** (1 nodes): `build.gradle.kts`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Channel Crawler`** (1 nodes): `Stream Extraction`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `package:flutter/material.dart` connect `Design Tokens & Theme` to `Flutter UI Core`, `Dart Platform Layer`, `Media Providers`, `Navigation & Routing`, `Search & Discovery`, `Player & Playback`, `State Management`, `Async Data Layer`, `Content Models`, `Download Pipeline`, `Auth & Session`?**
  _High betweenness centrality (0.264) - this node is a cross-community bridge._
- **Why does `../models/media_model.dart` connect `Flutter UI Core` to `Atmos Index Client`, `Design Tokens & Theme`, `Media Providers`, `Navigation & Routing`, `Search & Discovery`, `State Management`, `Async Data Layer`?**
  _High betweenness centrality (0.145) - this node is a cross-community bridge._
- **Why does `../theme/app_theme.dart` connect `State Management` to `Flutter UI Core`, `Dart Platform Layer`, `Design Tokens & Theme`, `Media Providers`, `Navigation & Routing`, `Search & Discovery`, `Player & Playback`, `Download Pipeline`, `Auth & Session`?**
  _High betweenness centrality (0.119) - this node is a cross-community bridge._
- **Are the 11 inferred relationships involving `fetch()` (e.g. with `indexToSupabase()` and `indexToSupabase()`) actually correct?**
  _`fetch()` has 11 INFERRED edges - model-reasoned connections that need verification._
- **What connects `main`, `package:flutter_test/flutter_test.dart`, `MainActivity` to the rest of the system?**
  _440 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `Flutter UI Core` be split into smaller, more focused modules?**
  _Cohesion score 0.04 - nodes in this community are weakly interconnected._
- **Should `Dart Platform Layer` be split into smaller, more focused modules?**
  _Cohesion score 0.04 - nodes in this community are weakly interconnected._