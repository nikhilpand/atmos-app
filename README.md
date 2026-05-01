# Atmos — Flutter Streaming App

Premium streaming app for **Android Mobile** and **Android TV / Smart TV**.

## 🏗️ Architecture

```
atmos-app/
├── cloudflare-worker/      ← Extraction proxy (deploy once, free)
│   ├── worker.js           ← 5-provider waterfall + HLS segment proxy
│   └── wrangler.toml
├── lib/
│   ├── main.dart           ← Entry point, routing (GoRouter)
│   ├── models/             ← Data models (TmdbMedia, WatchHistory…)
│   ├── services/           ← TMDB API, Extractor, History (Hive)
│   ├── providers/          ← Riverpod state management
│   ├── screens/            ← Home, Search, Details, Player
│   ├── widgets/            ← MediaCard, EpisodeTile, ResponsiveLayout
│   └── theme/              ← AtmosTheme (dark, Outfit font)
└── android/
    └── AndroidManifest.xml ← Mobile + TV (Leanback) launcher
```

## 🚀 Quick Start

### Step 1 — Get API Keys

1. **TMDB API Key** (free): https://www.themoviedb.org/settings/api
2. **Cloudflare account** (free): https://cloudflare.com

### Step 2 — Deploy the Cloudflare Worker

```bash
cd cloudflare-worker
npm install -g wrangler
wrangler login
wrangler deploy
# Copy the output URL: https://atmos-extractor.<your-subdomain>.workers.dev
```

### Step 3 — Configure .env

Edit `.env` in the project root:

```env
TMDB_API_KEY=your_actual_tmdb_key_here
EXTRACTOR_WORKER_URL=https://atmos-extractor.your-subdomain.workers.dev
```

### Step 4 — Run the App

```bash
flutter pub get
flutter run                    # Mobile emulator/device
flutter run -d <tv-device-id>  # Android TV device
```

### Step 5 — Build APK

```bash
# Mobile APK
flutter build apk --release

# Android TV APK (same APK, Leanback intent in manifest handles TV launcher)
flutter build apk --release --target-platform android-arm64
```

## 📺 TV Setup

The same APK works on:
- **Android TV** (Chromecast with Google TV, Nvidia Shield, Sony/TCL TVs)
- **Amazon Fire Stick** (sideload via adb)
- **Any Android-based TV box**

**D-Pad Controls in Player:**
| Remote Button | Action |
|---|---|
| OK / Select | Play / Pause |
| ← Left | Rewind 10s |
| → Right | Forward 10s |
| Back / Escape | Exit player (saves progress) |

## ⚙️ How Streaming Works

```
Flutter App
    │ context.push('/player', extra: {imdbId: 'tt...', type: 'movie'})
    ▼
PlayerScreen._extractStream()
    │ GET https://atmos-extractor.workers.dev/extract?imdb=tt...
    ▼
Cloudflare Worker (waterfall)
    │ Try vidsrc.xyz → vidsrc.me → embed.su → autoembed.cc → multiembed.mov
    │ Returns: { primary: "https://...stream.m3u8", referer: "https://vidsrc.xyz" }
    ▼
media_kit Player
    │ Media(streamUrl, httpHeaders: { Referer: ..., User-Agent: ... })
    │ Seek to resume position (from Hive)
    ▼
Playback ✅
```

## 🔧 Key Technical Decisions

| Decision | Choice | Why |
|---|---|---|
| Player | `media_kit` (libmpv) | Handles complex HLS, actively maintained |
| State | Riverpod 2.x | Scoped, testable, async-first |
| Extraction | Cloudflare Worker | Bypasses CORS + bot detection, free tier |
| Local storage | Hive | Fast, typed, no native dependencies |
| Navigation | GoRouter | Declarative, TV back-stack works correctly |

## 🐛 Troubleshooting

**Black screen / 403 on stream:**
- Check that `EXTRACTOR_WORKER_URL` is set correctly in `.env`
- Check the Worker logs in Cloudflare dashboard
- The provider might be temporarily down — the worker tries 5 providers automatically

**TV remote not working:**
- Ensure you're on an Android TV device (not a phone/tablet emulator)
- The `KeyboardListener` in `PlayerScreen` handles D-Pad events

**TMDB images not loading:**
- Verify your `TMDB_API_KEY` is valid at https://api.themoviedb.org/3/movie/popular?api_key=YOUR_KEY
