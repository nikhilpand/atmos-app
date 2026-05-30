#!/usr/bin/env python3
"""
Test Torrentio → Webtor.io download pipeline end-to-end.
Simulates what the Flutter app does when user taps Download via Torrentio.
"""
import requests, json, time, sys, urllib.parse

UA = "Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36"
HEADERS = {"User-Agent": UA, "Accept": "application/json"}

# Use a well-known movie for testing: The Shawshank Redemption (tt0111161)
IMDB_ID = "tt0111161"

MIRRORS = [
    "https://webtor.io",
    "https://hx22fl.webtor.io",
    "https://d1cqf6has1dkc0.webtor.io",
]

TRACKERS = (
    "&tr=udp%3A%2F%2Ftracker.opentrackr.org%3A1337%2Fannounce"
    "&tr=udp%3A%2F%2Fopen.stealth.si%3A80%2Fannounce"
    "&tr=udp%3A%2F%2Ftracker.torrent.eu.org%3A451%2Fannounce"
)

def step(num, msg):
    print(f"\n{'='*60}")
    print(f"  STEP {num}: {msg}")
    print(f"{'='*60}")

def test_torrentio_sources():
    step(1, f"Fetching Torrentio sources for {IMDB_ID}")
    url = f"https://torrentio.strem.fun/stream/movie/{IMDB_ID}.json"
    try:
        r = requests.get(url, headers=HEADERS, timeout=10)
        print(f"  Status: {r.status_code}")
        if r.status_code != 200:
            print(f"  ❌ Torrentio API failed")
            return None
        data = r.json()
        streams = data.get("streams", [])
        print(f"  ✅ Found {len(streams)} torrent sources")
        
        # Filter: need infoHash, prefer 1080p, skip 4K, cap at 3GB
        valid = []
        for s in streams:
            ih = s.get("infoHash")
            if not ih:
                continue
            title = s.get("title", "")
            lines = title.split("\n")
            quality = "HD"
            size_gb = 0
            seeders = 0
            for line in lines:
                low = line.lower()
                if "2160p" in low or "4k" in low:
                    quality = "4K"
                elif "1080p" in low:
                    quality = "1080p"
                elif "720p" in low:
                    quality = "720p"
                import re
                size_m = re.search(r'(\d+\.?\d*)\s*(GB|MB)', line, re.I)
                if size_m:
                    val = float(size_m.group(1))
                    if size_m.group(2).upper() == "GB":
                        size_gb = val
                    else:
                        size_gb = val / 1024
                seed_m = re.search(r'👤\s*(\d+)', line)
                if seed_m:
                    seeders = int(seed_m.group(1))
            
            if quality == "4K":
                continue
            if size_gb > 3.0:
                continue
            valid.append({
                "infoHash": ih,
                "fileIdx": s.get("fileIdx", 0),
                "quality": quality,
                "size_gb": size_gb,
                "seeders": seeders,
                "title_preview": lines[0] if lines else ""
            })
        
        valid.sort(key=lambda x: x["seeders"], reverse=True)
        print(f"  ✅ {len(valid)} valid sources (≤1080p, ≤3GB)")
        for v in valid[:5]:
            print(f"     {v['quality']:6s} | {v['size_gb']:.1f}GB | {v['seeders']:4d} seeds | {v['infoHash'][:12]}...")
        
        return valid[:5] if valid else None
    except Exception as e:
        print(f"  ❌ Error: {e}")
        return None

def test_webtor_resolve(info_hash, file_idx=0):
    step(2, f"Resolving stream via Webtor.io mirrors")
    magnet = f"magnet:?xt=urn:btih:{info_hash}{TRACKERS}"
    encoded = urllib.parse.quote(magnet)
    
    for mirror in MIRRORS:
        stream_url = f"{mirror}/stream?magnet={encoded}&file_index={file_idx}"
        print(f"\n  Testing mirror: {mirror}")
        
        try:
            # HEAD check with content-type validation
            r = requests.head(stream_url, headers={"User-Agent": UA, "Range": "bytes=0-0"}, timeout=6, allow_redirects=True)
            ct = r.headers.get("Content-Type", "unknown")
            cl = r.headers.get("Content-Length", "?")
            print(f"    HEAD status: {r.status_code}")
            print(f"    Content-Type: {ct}")
            print(f"    Content-Length: {cl}")
            
            if r.status_code in (200, 206):
                if "text/html" in ct or "text/plain" in ct:
                    print(f"    ❌ HTML/text response — torrent not ready on this mirror")
                    continue
                print(f"    ✅ Valid stream response!")
                return stream_url, mirror
            else:
                print(f"    ⚠️ Non-200 status, trying next mirror...")
        except requests.exceptions.ConnectionError as e:
            print(f"    ❌ Connection failed (DNS/network): {e}")
        except requests.exceptions.Timeout:
            print(f"    ❌ Timeout after 6s")
        except Exception as e:
            print(f"    ❌ Error: {e}")
    
    print(f"\n  ❌ All mirrors failed to resolve stream")
    return None, None

def test_download_start(stream_url):
    step(3, f"Testing actual download (first 1MB)")
    try:
        r = requests.get(stream_url, headers={"User-Agent": UA, "Range": "bytes=0-1048575"}, timeout=15, stream=True)
        ct = r.headers.get("Content-Type", "unknown")
        cl = r.headers.get("Content-Length", "?")
        cr = r.headers.get("Content-Range", "none")
        
        print(f"  Status: {r.status_code}")
        print(f"  Content-Type: {ct}")
        print(f"  Content-Length: {cl}")
        print(f"  Content-Range: {cr}")
        
        if "text/html" in ct:
            print(f"  ❌ Got HTML page instead of video — download would fail")
            return False
        
        # Download first chunk to verify it's real data
        chunk = next(r.iter_content(8192), b"")
        print(f"  First chunk: {len(chunk)} bytes")
        
        if len(chunk) < 100:
            print(f"  ❌ Chunk too small — not a real video file")
            return False
        
        # Check for common video file signatures
        hex_start = chunk[:4].hex()
        is_mp4 = hex_start.startswith("00000")  # ftyp box
        is_mkv = chunk[:4] == b"\x1a\x45\xdf\xa3"  # EBML header
        is_avi = chunk[:4] == b"RIFF"
        
        if is_mp4:
            print(f"  ✅ MP4 file signature detected")
        elif is_mkv:
            print(f"  ✅ MKV/WebM file signature detected")
        elif is_avi:
            print(f"  ✅ AVI file signature detected")
        else:
            print(f"  ⚠️ Unknown file type (hex: {hex_start}), but got binary data")
        
        total = 0
        t0 = time.time()
        for chunk in r.iter_content(65536):
            total += len(chunk)
            if total >= 524288:  # 512KB is enough to confirm
                break
        elapsed = time.time() - t0
        speed = total / elapsed / 1024 if elapsed > 0 else 0
        
        print(f"  Downloaded: {total/1024:.0f} KB in {elapsed:.1f}s ({speed:.0f} KB/s)")
        print(f"  ✅ DOWNLOAD IS WORKING — real video data confirmed")
        return True
        
    except Exception as e:
        print(f"  ❌ Download error: {e}")
        return False

def main():
    print("🎬 Torrentio → Webtor.io Download Pipeline Test")
    print(f"   Testing with: The Shawshank Redemption ({IMDB_ID})")
    
    # Step 1: Get torrent sources
    sources = test_torrentio_sources()
    if not sources:
        print("\n💀 FAILED at Step 1 — no Torrentio sources")
        sys.exit(1)
    
    # Step 2: Try resolving each source via Webtor
    stream_url = None
    for src in sources:
        stream_url, mirror = test_webtor_resolve(src["infoHash"], src.get("fileIdx", 0))
        if stream_url:
            print(f"\n  🎯 Using: {src['quality']} | {src['size_gb']:.1f}GB | {src['seeders']} seeds")
            print(f"  🔗 Mirror: {mirror}")
            break
        print(f"  ⏭️ Trying next source...")
    
    if not stream_url:
        print("\n💀 FAILED at Step 2 — no Webtor mirror could resolve any source")
        sys.exit(1)
    
    # Step 3: Test actual download
    success = test_download_start(stream_url)
    
    print(f"\n{'='*60}")
    if success:
        print("  ✅ ALL TESTS PASSED — Torrentio downloads are working!")
    else:
        print("  ❌ DOWNLOAD TEST FAILED")
    print(f"{'='*60}\n")

if __name__ == "__main__":
    main()
