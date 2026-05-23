import os
import time
import json
import logging
import subprocess
import threading
from datetime import datetime, timedelta, timezone
from typing import Dict, Any, Optional
import re
import html
import urllib.parse

import requests
import uvicorn
from fastapi import FastAPI, HTTPException, Header
from fastapi.responses import StreamingResponse, JSONResponse, RedirectResponse
from fastapi.middleware.cors import CORSMiddleware
import gradio as gr

from google.oauth2 import service_account
from google.auth.transport.requests import Request as GoogleAuthRequest
from googleapiclient.discovery import build
from googleapiclient.http import MediaFileUpload

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
logger = logging.getLogger("TorrentIndex")

app = FastAPI(title="Atmos Backend API")
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_credentials=True, allow_methods=["*"], allow_headers=["*"])

# ── Config ────────────────────────────────────────────────────────────────────
GDRIVE_SERVICE_ACCOUNT_JSON = os.environ.get("GDRIVE_SERVICE_ACCOUNT", "")
GEMINI_API_KEY = os.environ.get("GEMINI_API_KEY", "")
CACHE_EXPIRY_HOURS = int(os.environ.get("CACHE_EXPIRY_HOURS", "24"))
MAX_FILE_SIZE_GB = float(os.environ.get("MAX_FILE_SIZE_GB", "3"))
DOWNLOAD_DIR = "/tmp/aria2"
os.makedirs(DOWNLOAD_DIR, exist_ok=True)

_tasks_lock = threading.Lock()
active_tasks: Dict[str, Dict[str, Any]] = {}
_creds_lock = threading.Lock()
_cached_creds: Optional[service_account.Credentials] = None

# ── aria2c ────────────────────────────────────────────────────────────────────
aria2_process = None
def start_aria2():
    global aria2_process
    try:
        aria2_process = subprocess.Popen([
            "aria2c", "--enable-rpc=true", "--rpc-listen-all=true",
            "--rpc-allow-origin-all=true", "--rpc-listen-port=6800",
            "--max-connection-per-server=16", "--split=16", "--seed-time=0",
            f"--max-overall-download-limit={int(MAX_FILE_SIZE_GB * 1024)}M",
            f"--dir={DOWNLOAD_DIR}", "--quiet=true"
        ])
        logger.info("aria2c started.")
    except Exception as e:
        logger.error(f"aria2c start failed: {e}")

# ── Google Drive helpers ──────────────────────────────────────────────────────
def _get_credentials() -> service_account.Credentials:
    global _cached_creds
    with _creds_lock:
        if _cached_creds is not None and _cached_creds.valid:
            return _cached_creds
        if not GDRIVE_SERVICE_ACCOUNT_JSON:
            raise ValueError("GDRIVE_SERVICE_ACCOUNT not set")
        creds = service_account.Credentials.from_service_account_info(
            json.loads(GDRIVE_SERVICE_ACCOUNT_JSON),
            scopes=["https://www.googleapis.com/auth/drive"]
        )
        creds.refresh(GoogleAuthRequest())
        _cached_creds = creds
        return creds

def get_gdrive_service():
    return build("drive", "v3", credentials=_get_credentials())

def get_or_create_cache_folder(service):
    q = "name = 'Atmos-Cache' and mimeType = 'application/vnd.google-apps.folder' and trashed = false"
    files = service.files().list(q=q, fields="files(id)").execute().get("files", [])
    if files: return files[0]["id"]
    return service.files().create(
        body={"name": "Atmos-Cache", "mimeType": "application/vnd.google-apps.folder"}, fields="id"
    ).execute()["id"]

def aria2_rpc(method: str, params: list = None) -> Any:
    try:
        r = requests.post("http://127.0.0.1:6800/jsonrpc", json={
            "jsonrpc": "2.0", "id": "atmos", "method": f"aria2.{method}", "params": params or []
        }, timeout=5)
        if r.status_code == 200: return r.json().get("result")
    except: pass
    return None

# ── Background tasks ──────────────────────────────────────────────────────────
def upload_task(task_id, local_path, filename):
    try:
        with _tasks_lock: active_tasks[task_id]["status"] = "uploading"
        service = get_gdrive_service()
        folder_id = get_or_create_cache_folder(service)
        media = MediaFileUpload(local_path, resumable=True)
        req = service.files().create(body={"name": filename, "parents": [folder_id]}, media_body=media, fields="id")
        resp = None
        while resp is None:
            st, resp = req.next_chunk()
            if st:
                with _tasks_lock: active_tasks[task_id]["progress"] = int(st.progress() * 100)
        file_id = resp.get("id")
        if os.path.exists(local_path): os.remove(local_path)
        with _tasks_lock:
            active_tasks[task_id].update({"status": "completed", "progress": 100, "file_id": file_id, "stream_url": f"/api/stream/{file_id}"})
    except Exception as e:
        with _tasks_lock: active_tasks[task_id].update({"status": "failed", "error": str(e)})

def monitor_downloads_loop():
    time.sleep(3)
    while True:
        try:
            for dl in (aria2_rpc("tellActive") or []) + (aria2_rpc("tellWaiting", [0, 50]) or []):
                gid = dl["gid"]
                total = int(dl.get("totalLength", "0"))
                done = int(dl.get("completedLength", "0"))
                files = dl.get("files", [])
                fname = os.path.basename(files[0]["path"]) if files and files[0].get("path") else "Unknown"
                prog = int(done / total * 100) if total > 0 else 0
                with _tasks_lock:
                    active_tasks.setdefault(gid, {}).update({"filename": fname, "status": dl.get("status"), "progress": prog, "total_bytes": total})
            for dl in (aria2_rpc("tellStopped", [0, 50]) or []):
                gid, files = dl["gid"], dl.get("files", [])
                if files and files[0].get("path"):
                    path, fname = files[0]["path"], os.path.basename(files[0]["path"])
                    if dl["status"] == "complete" and os.path.exists(path):
                        do_upload = False
                        with _tasks_lock:
                            if gid not in active_tasks or active_tasks[gid].get("status") == "complete":
                                active_tasks[gid] = {"filename": fname, "status": "downloaded", "progress": 100}
                                do_upload = True
                        if do_upload:
                            threading.Thread(target=upload_task, args=(gid, path, fname), daemon=True).start()
                            aria2_rpc("removeDownloadResult", [gid])
                    elif dl["status"] == "error":
                        with _tasks_lock: active_tasks[gid] = {"filename": fname, "status": "failed", "error": "aria2 error"}
                        aria2_rpc("removeDownloadResult", [gid])
        except Exception as e: logger.error(f"Monitor: {e}")
        time.sleep(3)

def cleanup_loop():
    time.sleep(30)
    while True:
        try:
            if GDRIVE_SERVICE_ACCOUNT_JSON:
                svc = get_gdrive_service()
                fid = get_or_create_cache_folder(svc)
                now = datetime.now(timezone.utc)
                for f in svc.files().list(q=f"'{fid}' in parents and trashed = false", fields="files(id,name,createdTime)").execute().get("files", []):
                    created = datetime.fromisoformat(f["createdTime"].replace("Z", "+00:00"))
                    if now - created > timedelta(hours=CACHE_EXPIRY_HOURS):
                        logger.info(f"Deleting expired: {f['name']}")
                        svc.files().delete(fileId=f["id"]).execute()
        except Exception as e: logger.error(f"Cleanup: {e}")
        time.sleep(1800)

# ── Startup ───────────────────────────────────────────────────────────────────
# Start background threads immediately at import time (HF Spaces pattern)
start_aria2()
threading.Thread(target=monitor_downloads_loop, daemon=True).start()
threading.Thread(target=cleanup_loop, daemon=True).start()
logger.info("All background threads started.")

# ── Torrent Cache API ─────────────────────────────────────────────────────────
@app.get("/api/health")
async def health():
    return {
        "status": "ok" if aria2_rpc("getVersion") and GDRIVE_SERVICE_ACCOUNT_JSON else "degraded",
        "aria2": aria2_rpc("getVersion") is not None,
        "gdrive": bool(GDRIVE_SERVICE_ACCOUNT_JSON),
        "gemini": bool(GEMINI_API_KEY),
        "cache_expiry_hours": CACHE_EXPIRY_HOURS,
    }

@app.post("/api/torrent-to-drive")
async def torrent_to_drive(payload: Dict[str, str]):
    magnet = payload.get("magnet_link")
    if not magnet: raise HTTPException(400, "Missing magnet_link")
    if not GDRIVE_SERVICE_ACCOUNT_JSON: raise HTTPException(500, "GDrive not configured")
    gid = aria2_rpc("addUri", [[magnet]])
    if not gid: raise HTTPException(500, "aria2 failed")
    with _tasks_lock: active_tasks[gid] = {"filename": "Querying...", "status": "active", "progress": 0}
    return {"task_id": gid, "status": "active"}

@app.get("/api/status/{task_id}")
async def task_status(task_id: str):
    with _tasks_lock:
        if task_id not in active_tasks: raise HTTPException(404, "Not found")
        return dict(active_tasks[task_id])

@app.get("/api/stream/{file_id}")
async def stream_file(file_id: str, range_header: Optional[str] = Header(None, alias="range")):
    try:
        svc = get_gdrive_service()
        meta = svc.files().get(fileId=file_id, fields="name,size,mimeType").execute()
        creds = _get_credentials()
        hdrs = {"Authorization": f"Bearer {creds.token}"}
        if range_header: hdrs["Range"] = range_header
        r = requests.get(f"https://www.googleapis.com/drive/v3/files/{file_id}?alt=media", headers=hdrs, stream=True, timeout=30)
        resp_hdrs = {"Content-Type": meta.get("mimeType", "video/mp4"), "Accept-Ranges": "bytes", "Access-Control-Allow-Origin": "*"}
        if "Content-Range" in r.headers: resp_hdrs["Content-Range"] = r.headers["Content-Range"]
        if "Content-Length" in r.headers: resp_hdrs["Content-Length"] = r.headers["Content-Length"]
        return StreamingResponse(r.iter_content(1024*1024), status_code=r.status_code, headers=resp_hdrs)
    except Exception as e:
        raise HTTPException(500, str(e))

# ── Gemini AI API ─────────────────────────────────────────────────────────────
@app.post("/api/gemini/recommend")
async def gemini_recommend(payload: Dict[str, Any]):
    """Personalized content recommendations based on watch history."""
    if not GEMINI_API_KEY: raise HTTPException(500, "GEMINI_API_KEY not configured")
    prompt = f"""You are a movie/TV show recommendation engine.
Based on the user's viewing history and preferences, suggest 20 personalized recommendations.

Watch History (most recent first): {json.dumps(payload.get("watch_history", [])[:20])}
Recent Searches: {json.dumps(payload.get("search_history", [])[:10])}
Preferred Genres: {json.dumps(payload.get("preferred_genres", []))}
Preferred Language: {payload.get("preferred_lang", "English")}

Return a JSON array of objects with:
- "title": exact movie/show title
- "tmdb_id": TMDB ID if known, else 0
- "type": "movie" or "tv"
- "reason": 1-line explanation
- "category": one of "Because You Watched", "Trending in Your Taste", "Hidden Gems", "New Releases", "Genre Deep Dive"
- "confidence": 0.0-1.0

Prioritize quality hidden gems over obvious mainstream picks.
Return ONLY valid JSON array."""
    try:
        r = requests.post(
            f"https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key={GEMINI_API_KEY}",
            json={"contents": [{"parts": [{"text": prompt}]}], "generationConfig": {"responseMimeType": "application/json"}},
            timeout=15
        )
        if r.status_code != 200: raise HTTPException(502, f"Gemini {r.status_code}")
        text = r.json().get("candidates", [{}])[0].get("content", {}).get("parts", [{}])[0].get("text", "[]")
        return {"recommendations": json.loads(text.strip())}
    except json.JSONDecodeError: raise HTTPException(502, "Gemini returned invalid JSON")
    except HTTPException: raise
    except Exception as e: raise HTTPException(500, str(e))

@app.post("/api/gemini/categorize")
async def gemini_categorize(payload: Dict[str, Any]):
    """AI-generated Netflix-style category names for home screen."""
    if not GEMINI_API_KEY: raise HTTPException(500, "GEMINI_API_KEY not configured")
    prompt = f"""Create 8 personalized content category names for a streaming app home screen.
User watches: {json.dumps(payload.get("watch_history", [])[:15])}
Preferred genres: {json.dumps(payload.get("preferred_genres", []))}

Return JSON array with:
- "category_name": creative Netflix-style name
- "description": what belongs here
- "tmdb_genre_ids": array of TMDB genre IDs
- "sort_by": "popularity.desc" or "vote_average.desc" or "release_date.desc"

Good examples: "Mind-Bending Thrillers", "Anime After Dark", "Feel-Good Weekend Picks"
Return ONLY valid JSON."""
    try:
        r = requests.post(
            f"https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key={GEMINI_API_KEY}",
            json={"contents": [{"parts": [{"text": prompt}]}], "generationConfig": {"responseMimeType": "application/json"}},
            timeout=15
        )
        if r.status_code != 200: raise HTTPException(502, f"Gemini {r.status_code}")
        text = r.json().get("candidates", [{}])[0].get("content", {}).get("parts", [{}])[0].get("text", "[]")
        return {"categories": json.loads(text.strip())}
    except json.JSONDecodeError: raise HTTPException(502, "Gemini returned invalid JSON")
    except HTTPException: raise
    except Exception as e: raise HTTPException(500, str(e))

# ── VegaMovies & Consumet Scrapers ────────────────────────────────────────────
ANINEKO_HEADERS = {
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
    'Referer': 'https://anineko.to/'
}

def clean_anime_title(title: str) -> str:
    return html.unescape(title).strip()

@app.get("/vegamovies/search")
async def vegamovies_search(q: str, year: Optional[int] = None, quality: Optional[str] = None):
    url = "https://vegamovies.diamonds/index.php?do=search"
    data = {
        "do": "search",
        "subaction": "search",
        "story": q
    }
    headers = {
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
        "Referer": "https://vegamovies.diamonds/"
    }
    try:
        r = requests.post(url, data=data, headers=headers, timeout=10)
        if r.status_code != 200:
            return {"results": []}
        
        html_content = r.text
        articles = re.findall(r'<article class="post-item site__col">[\s\S]*?</article>', html_content)
        results = []
        for art in articles:
            url_m = re.search(r'href="(https://vegamovies\.diamonds/\d+-[^"]+\.html)"', art)
            title_m = re.search(r'title="([^"]+)"', art)
            img_m = re.search(r'src="([^"]+)"', art)
            
            if url_m and title_m:
                post_url = url_m.group(1)
                title = html.unescape(title_m.group(1))
                poster = img_m.group(1) if img_m else None
                if poster and poster.startswith('/'):
                    poster = 'https://vegamovies.diamonds' + poster
                
                year_m = re.search(r'\((\d{4})\)', title)
                item_year = year_m.group(1) if year_m else None
                
                qual_m = re.search(r'\b(480p|720p|1080p|2160p|4k|HDR)\b', title, re.I)
                item_quality = qual_m.group(1).upper() if qual_m else 'HD'
                
                lang_m = re.search(r'\b(Hindi|English|Tamil|Telugu|Dual Audio|Multi Audio)\b', title, re.I)
                language = lang_m.group(1) if lang_m else 'Hindi/English'
                
                if year and item_year and str(year) != item_year:
                    continue
                if quality and quality.lower() not in title.lower():
                    continue
                    
                results.append({
                    "title": title,
                    "post_url": post_url,
                    "poster_url": poster,
                    "year": item_year,
                    "quality": item_quality,
                    "language": language
                })
        return {"results": results}
    except Exception as e:
        logger.error(f"VegaMovies search error: {e}")
        return {"results": []}

@app.get("/vegamovies/links")
async def vegamovies_links(url: str):
    headers = {
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
        "Referer": "https://vegamovies.diamonds/"
    }
    try:
        r = requests.get(url, headers=headers, timeout=10)
        if r.status_code != 200:
            return {"links": []}
        
        html_content = r.text
        links = []
        pattern = re.compile(
            r'href=["\'](https?://[^"\']+)["\'](?:(?!<a\b)[\s\S])*?Click Here To Download\s*(?:\[([^\]]+)\])?',
            re.I
        )
        
        for match in pattern.finditer(html_content):
            dl_url = match.group(1)
            size = match.group(2) or None
            if size:
                size = size.strip()
                
            start_idx = match.start()
            context_before = html_content[max(0, start_idx - 1000):start_idx]
            
            res_matches = list(re.finditer(r'\b(480p|720p|1080p|2160p|4K|360p)\b', context_before, re.I))
            quality = res_matches[-1].group(1).upper() if res_matches else 'HD'
            
            host = 'direct'
            url_lower = dl_url.lower()
            if 'drive.google' in url_lower or 'docs.google' in url_lower:
                host = 'gdrive'
            elif 'pixeldrain' in url_lower:
                host = 'pixeldrain'
            elif 'hubcloud' in url_lower or 'hub.la' in url_lower or 'hubcdn' in url_lower:
                host = 'hubcloud'
            elif 'nexdrive' in url_lower:
                host = 'nexdrive'
            elif 'vgmlinks' in url_lower:
                host = 'vgmlinks'
            elif 'fast-dl' in url_lower:
                host = 'fast-dl'
            elif 'onedrive' in url_lower or '1drv.ms' in url_lower:
                host = 'onedrive'
                
            codec_match = re.search(r'\b(x265|HEVC|x264|AVC|AV1)\b', context_before, re.I)
            codec = codec_match.group(1).lower().replace('hevc', 'x265').replace('avc', 'x264') if codec_match else None
            
            lang_match = re.search(r'\b(Hindi|English|Tamil|Telugu|Malayalam|Dual Audio|Multi Audio|Dubbed)\b', context_before, re.I)
            language = lang_match.group(1) if lang_match else 'Hindi/English'
            
            links.append({
                'url': dl_url,
                'host': host,
                'quality': quality,
                'size': size,
                'codec': codec,
                'language': language
            })
        return {"links": links}
    except Exception as e:
        logger.error(f"VegaMovies links error: {e}")
        return {"links": []}

@app.get("/anime/{provider}/{title}")
async def anime_search(provider: str, title: str):
    encoded = urllib.parse.quote(title)
    url = f"https://anineko.to/browser?keyword={encoded}"
    try:
        r = requests.get(url, headers=ANINEKO_HEADERS, timeout=10)
        if r.status_code != 200:
            return {"results": []}
        
        cards = re.findall(r'<a class="nv-anime-thumb nv-browse-thumb"[\s\S]*?</a>', r.text)
        results = []
        for card in cards:
            id_m = re.search(r'href="/watch/([^"]+)"', card)
            img_m = re.search(r'src="([^"]+)"', card)
            alt_m = re.search(r'alt="([^"]+)"', card)
            type_m = re.search(r'<span class="nv-badge-new">([^<]+)</span>', card)
            
            if id_m:
                anime_id = id_m.group(1)
                anime_title = clean_anime_title(alt_m.group(1)) if alt_m else anime_id.replace('-', ' ').title()
                image = img_m.group(1) if img_m else ""
                anime_type = type_m.group(1) if type_m else "TV"
                
                results.append({
                    "id": anime_id,
                    "title": anime_title,
                    "image": image,
                    "type": anime_type
                })
        return {"results": results}
    except Exception as e:
        logger.error(f"Anime search error: {e}")
        return {"results": []}

@app.get("/anime/{provider}/info/{anime_id:path}")
async def anime_info(provider: str, anime_id: str):
    anime_id = anime_id.lstrip('/')
    url = f"https://anineko.to/watch/{anime_id}"
    try:
        r = requests.get(url, headers=ANINEKO_HEADERS, timeout=10)
        if r.status_code != 200:
            raise HTTPException(status_code=404, detail="Anime not found")
        
        html_content = r.text
        title_m = re.search(r'<h1>(.*?)</h1>', html_content)
        title = clean_anime_title(title_m.group(1)) if title_m else anime_id.replace('-', ' ').title()
        
        pattern = re.compile(
            r'<a class="nv-info-episode-main" href="(?P<href>/watch/[^"]+/ep-(?P<num>\d+))">\s*'
            r'<strong>Episode \d+</strong>\s*'
            r'<span>(?P<title>[^<]+)</span>\s*'
            r'</a>',
            re.I
        )
        
        episodes = []
        for match in pattern.finditer(html_content):
            ep_href = match.group('href').replace('/watch/', '')
            ep_num = int(match.group('num'))
            ep_title = clean_anime_title(match.group('title'))
            episodes.append({
                "id": ep_href,
                "number": ep_num,
                "title": ep_title
            })
            
        episodes.sort(key=lambda x: x['number'])
        return {
            "id": anime_id,
            "title": title,
            "episodes": episodes
        }
    except Exception as e:
        logger.error(f"Anime info error: {e}")
        raise HTTPException(status_code=500, detail=str(e))

@app.get("/anime/{provider}/watch/{episode_id:path}")
async def anime_watch(provider: str, episode_id: str):
    episode_id = episode_id.lstrip('/')
    url = f"https://anineko.to/watch/{episode_id}"
    try:
        r = requests.get(url, headers=ANINEKO_HEADERS, timeout=10)
        if r.status_code != 200:
            raise HTTPException(status_code=404, detail="Episode not found")
            
        html_content = r.text
        sources = []
        subtitles = []
        
        for btn in re.finditer(r'<button[^>]+data-video="(?P<url>[^"]+)"[^>]*>', html_content):
            btn_html = btn.group(0)
            video_url = btn.group('url')
            
            if 'vibeplayer.site' in video_url:
                tab_match = re.search(r'data-tab="([^"]+)"', btn_html)
                tab = tab_match.group(1) if tab_match else 'tab_1'
                
                tab_label = "Sub"
                if tab == 'tab_0':
                    tab_label = "Hardsub"
                elif tab == 'tab_2':
                    tab_label = "Dub"
                    
                parsed = urllib.parse.urlparse(video_url)
                vibe_id = parsed.path.strip('/')
                
                qs = urllib.parse.parse_qs(parsed.query)
                sub_url = qs.get('sub', [None])[0]
                if sub_url:
                    subtitles.append({
                        "url": sub_url,
                        "lang": "English"
                    })
                
                direct_stream = f"https://vibeplayer.site/public/stream/{vibe_id}/master.m3u8"
                tag_end = html_content.find('>', btn.start())
                btn_end = html_content.find('</button>', tag_end)
                btn_text = html_content[tag_end+1:btn_end].strip() if tag_end != -1 and btn_end != -1 else "HD"
                btn_text = re.sub(r'<[^>]+>', '', btn_text).strip()
                btn_text = ' '.join(btn_text.split())
                
                quality_label = f"{tab_label} ({btn_text})"
                sources.append({
                    "url": direct_stream,
                    "quality": quality_label,
                    "isM3U8": True
                })
        
        if not sources:
            direct_matches = re.findall(r'vibeplayer\.site/([a-zA-Z0-9]+)', html_content)
            for vibe_id in set(direct_matches):
                sources.append({
                    "url": f"https://vibeplayer.site/public/stream/{vibe_id}/master.m3u8",
                    "quality": "Backup HD",
                    "isM3U8": True
                })
        
        return {
            "sources": sources,
            "subtitles": subtitles,
            "headers": {
                "User-Agent": ANINEKO_HEADERS['User-Agent'],
                "Referer": "https://vibeplayer.site/"
            }
        }
    except Exception as e:
        logger.error(f"Anime watch error: {e}")
        raise HTTPException(status_code=500, detail=str(e))

# ── Gradio UI ─────────────────────────────────────────────────────────────────
def get_status_ui():
    lines = [f"### Status\n- **GDrive**: {'✅' if GDRIVE_SERVICE_ACCOUNT_JSON else '❌'}\n- **Gemini**: {'✅' if GEMINI_API_KEY else '❌'}\n- **Cache TTL**: {CACHE_EXPIRY_HOURS}h\n\n### Tasks\n"]
    with _tasks_lock: snap = dict(active_tasks)
    if not snap: lines.append("No active tasks.")
    for tid, d in snap.items():
        p = d.get("progress", 0)
        lines.append(f"`{tid}` | {d.get('filename','?')} | **{d.get('status','?').upper()}** | `[{'█'*(p//10)}{'░'*(10-p//10)}] {p}%`\n")
    return "".join(lines)

def manual_dl(magnet):
    if not magnet: return "Enter a magnet link."
    gid = aria2_rpc("addUri", [[magnet]])
    if not gid: return "Failed."
    with _tasks_lock: active_tasks[gid] = {"filename": "Querying...", "status": "active", "progress": 0}
    return f"Queued: `{gid}`"

# ── Build the Gradio Blocks and mount onto FastAPI ────────────────────────────
# Gradio is mounted at "/" so its assets are served correctly.
# Our /api/* routes are registered first, so they take priority over Gradio's catch-all.
with gr.Blocks(title="Atmos Backend") as demo:
    gr.Markdown("# Atmos Backend — Torrent Cache + AI")
    with gr.Tab("Status"):
        md = gr.Markdown()
        demo.load(get_status_ui, outputs=[md])
        timer = gr.Timer(5)
        timer.tick(get_status_ui, outputs=[md])
    with gr.Tab("Manual Cache"):
        inp = gr.Textbox(label="Magnet Link")
        btn = gr.Button("Start")
        out = gr.Textbox(label="Result")
        btn.click(manual_dl, inputs=[inp], outputs=[out])

@app.get("/")
async def root_redirect():
    return RedirectResponse(url="/dashboard")

# Mount Gradio at /dashboard — this must come AFTER all /api/* route registrations
# so FastAPI matches our API routes first before falling through to Gradio.
app = gr.mount_gradio_app(app, demo, path="/dashboard")

if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=7860)
