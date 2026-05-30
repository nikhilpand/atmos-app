import requests
import re
import urllib.parse
import json

UA = "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36"

# Test Content Definition
TEST_MOVIES = [
    {"title": "Inception", "tmdb": "27205", "imdb": "tt1375666"}
]

TEST_SHOWS = [
    {"title": "Breaking Bad", "tmdb": "1396", "imdb": "tt0903747", "season": 1, "episode": 1}
]

TEST_ANIME = [
    {"keyword": "naruto-shippuden", "episode": 1, "name": "Naruto Shippuden"},
    {"keyword": "shingeki-no-kyojin", "episode": 1, "name": "Attack on Titan"}
]

def inspect_media_signature(content):
    if len(content) < 8:
        return False, "Unknown/Too Small"
        
    # Check for JPEG/PNG
    if content.startswith(b"\xff\xd8\xff"):
        return False, "JPEG Image (Not a video file!)"
    if content.startswith(b"\x89PNG\r\n\x1a\n"):
        iend_marker = b"\x49\x45\x4e\x44\xae\x42\x60\x82"
        iend_idx = content.find(iend_marker)
        if iend_idx != -1:
            trailing = content[iend_idx + len(iend_marker):]
            for offset in range(min(200, len(trailing) - 188)):
                if trailing[offset] == 0x47 and trailing[offset + 188] == 0x47:
                    return True, f"Proper MPEG-TS Video inside Steganographic PNG (Offset sync byte 0x47 at offset {iend_idx + len(iend_marker) + offset})"
        return False, "PNG Image (Not a video file!)"
        
    # Check for HTML
    if b"<!DOCTYPE html" in content.lower() or b"<html" in content.lower():
        return False, "HTML Page (Likely a blockpage or redirect!)"
        
    # Check for MPEG-TS (Sync byte 0x47)
    if content[0] == 0x47:
        # Check if the next packets also start with 0x47 (188 bytes later)
        if len(content) >= 189 and content[188] == 0x47:
            return True, "Proper MPEG-TS Video (Double-verified packet sync byte 0x47)"
        return True, "MPEG-TS Video (Sync byte 0x47 verified)"
        
    # Check for MP4
    if len(content) >= 8 and content[4:8] == b"ftyp":
        return True, f"Proper MP4 Video (ftyp box '{content[8:12].decode('ascii', errors='ignore')}' found)"
        
    # Check if 0x47 resides near the start (sometimes there is custom header offset in obfuscated streams)
    for offset in range(min(16, len(content) - 188)):
        if content[offset] == 0x47 and content[offset + 188] == 0x47:
            return True, f"Proper MPEG-TS Video (Offset sync byte 0x47 at offset {offset})"
            
    return False, f"Unknown Binary Format (First 16 bytes: {content[:16].hex()})"

def verify_url_playability(url, headers=None, name="Stream"):
    print(f"\n  [Verifying {name}]")
    print(f"  URL: {url[:100]}...")
    
    # Custom headers
    req_headers = {
        "User-Agent": UA
    }
    if headers:
        req_headers.update(headers)
        
    try:
        # Step 1: Request the manifest/file
        r = requests.get(url, headers=req_headers, timeout=10, allow_redirects=True)
        print(f"  Response Status: {r.status_code}")
        
        if r.status_code not in [200, 206]:
            print(f"  ❌ FAILED: Received non-success status code {r.status_code}")
            return False
            
        content_type = r.headers.get("Content-Type", "")
        print(f"  Content-Type: {content_type}")
        
        # Step 2: Handle HLS Playlist (.m3u8)
        if "mpegurl" in content_type.lower() or "application/vnd.apple.mpegurl" in content_type.lower() or "#EXTM3U" in r.text:
            print("  Detected HLS Playlist (#EXTM3U)")
            
            # Find sub-playlists or segments
            lines = [line.strip() for line in r.text.splitlines() if line.strip()]
            is_master = any("#EXT-X-STREAM-INF" in line for line in lines)
            
            sub_url = None
            segment_url = None
            
            if is_master:
                # Find first sub-playlist URL
                for line in lines:
                    if not line.startswith("#"):
                        sub_url = urllib.parse.urljoin(r.url, line)
                        break
                if sub_url:
                    print(f"  Fetching sub-playlist: {sub_url[:100]}...")
                    r_sub = requests.get(sub_url, headers=req_headers, timeout=10)
                    print(f"  Sub-playlist response status: {r_sub.status_code}")
                    if r_sub.status_code == 200:
                        sub_lines = [line.strip() for line in r_sub.text.splitlines() if line.strip()]
                        for line in sub_lines:
                            if not line.startswith("#"):
                                segment_url = urllib.parse.urljoin(sub_url, line)
                                break
            else:
                # Direct media playlist, find first segment URL
                for line in lines:
                    if not line.startswith("#"):
                        segment_url = urllib.parse.urljoin(r.url, line)
                        break
            
            if segment_url:
                print(f"  Requesting first video segment: {segment_url[:100]}...")
                # Request first few bytes of the segment to verify it's working
                segment_headers = req_headers.copy()
                segment_headers["Range"] = "bytes=0-4096"
                
                r_seg = requests.get(segment_url, headers=segment_headers, timeout=10)
                print(f"  Segment Response Status: {r_seg.status_code}")
                if r_seg.status_code in [200, 206]:
                    is_valid_video, format_desc = inspect_media_signature(r_seg.content)
                    print(f"  Media Format Check: {format_desc}")
                    if is_valid_video:
                        print(f"  ✅ PLAYING: Verified proper video stream ({len(r_seg.content)} bytes)")
                        return True
                    else:
                        print(f"  ❌ FAILED: Invalid stream content detected: {format_desc}")
                        return False
                else:
                    print(f"  ❌ FAILED: Segment returned status code {r_seg.status_code}")
                    return False
            else:
                print("  ❌ FAILED: No playable segments found in HLS playlist")
                return False
                
        # Step 3: Handle direct MP4/MKV stream
        else:
            # Try a range request to see if streaming is supported
            range_headers = req_headers.copy()
            range_headers["Range"] = "bytes=0-4096"
            r_range = requests.get(r.url, headers=range_headers, timeout=10)
            if r_range.status_code in [200, 206]:
                is_valid_video, format_desc = inspect_media_signature(r_range.content)
                print(f"  Media Format Check: {format_desc}")
                if is_valid_video:
                    print(f"  ✅ PLAYING: Verified proper direct media stream ({len(r_range.content)} bytes)")
                    return True
                else:
                    print(f"  ❌ FAILED: Invalid stream content detected: {format_desc}")
                    return False
            else:
                print(f"  ❌ FAILED: Range request returned status code {r_range.status_code}")
                return False
                
    except Exception as e:
        print(f"  ❌ FAILED: Connection error: {e}")
        return False

# Test VidAPI
def test_vidapi(content, is_movie=True):
    content_name = content['title']
    if is_movie:
        print(f"\n--- Testing VidAPI Movie: {content_name} ---")
        url = f"https://streamdata.vaplayer.ru/api.php?tmdb={content['tmdb']}&type=movie"
    else:
        season, episode = content['season'], content['episode']
        print(f"\n--- Testing VidAPI TV: {content_name} S{season}E{episode} ---")
        url = f"https://streamdata.vaplayer.ru/api.php?tmdb={content['tmdb']}&type=tv&season={season}&episode={episode}"
        
    headers = {
        'Referer': 'https://brightpathsignals.com/',
        'Origin': 'https://brightpathsignals.com'
    }
    try:
        r = requests.get(url, headers=headers, timeout=10).json()
        print(f"  VidAPI response status: {r.get('status_code')}")
        if str(r.get('status_code')) == "200" and r.get('data', {}).get('stream_urls'):
            stream_url = r['data']['stream_urls'][0]
            name = f"VidAPI Movie ({content_name})" if is_movie else f"VidAPI TV ({content_name} S{season}E{episode})"
            return verify_url_playability(stream_url, headers, name)
        else:
            print("  ❌ FAILED: Invalid response structure or no stream_urls")
    except Exception as e:
        print("VidAPI error:", e)
    return False

# Test Videasy
def test_videasy(content, is_movie=True):
    content_name = content['title']
    headers = {
        'Referer': 'https://player.videasy.net/',
        'Origin': 'https://player.videasy.net'
    }
    try:
        if is_movie:
            print(f"\n--- Testing Videasy Movie: {content_name} ---")
            url = f"https://api.videasy.net/mb-flix/sources-with-title?title={content_name}&mediaType=movie&tmdbId={content['tmdb']}"
        else:
            season, episode = content['season'], content['episode']
            print(f"\n--- Testing Videasy TV: {content_name} S{season}E{episode} ---")
            url = f"https://api.videasy.net/mb-flix/sources-with-title?title={content_name}&mediaType=tv&tmdbId={content['tmdb']}&seasonId={season}&episodeId={episode}"
            
        enc = requests.get(url, headers=headers, timeout=10).text
        dec = requests.post("https://enc-dec.app/api/dec-videasy", json={"text": enc, "id": content['tmdb']}, timeout=10).json()
        if dec.get('status') == 200:
            result = dec['result']
            if isinstance(result, str):
                result = json.loads(result)
            srcs = result.get('sources', [])
            if srcs:
                stream_url = srcs[0]['url']
                name = f"Videasy Movie ({content_name})" if is_movie else f"Videasy TV ({content_name} S{season}E{episode})"
                return verify_url_playability(stream_url, headers, name)
            else:
                print("  ❌ FAILED: No sources found in decrypted Videasy response")
        else:
            print(f"  ❌ FAILED: Decryption returned status {dec.get('status')}")
    except Exception as e:
        print("Videasy error:", e)
    return False

# Test VidLink
def test_vidlink(content, is_movie=True):
    content_name = content['title']
    try:
        if is_movie:
            print(f"\n--- Testing VidLink Movie: {content_name} ---")
            enc_url = f"https://enc-dec.app/api/enc-vidlink?text={content['tmdb']}"
        else:
            season, episode = content['season'], content['episode']
            print(f"\n--- Testing VidLink TV: {content_name} S{season}E{episode} ---")
            enc_url = f"https://enc-dec.app/api/enc-vidlink?text={content['tmdb']}"
            
        enc = requests.get(enc_url, timeout=10).json()
        if enc.get('status') == 200:
            enc_id = enc['result']
            if is_movie:
                src_url = f"https://vidlink.pro/api/b/movie/{enc_id}"
            else:
                src_url = f"https://vidlink.pro/api/b/tv/{enc_id}/{season}/{episode}"
                
            headers = {
                'Origin': 'https://vidlink.pro',
                'Referer': 'https://vidlink.pro/'
            }
            res = requests.get(src_url, headers=headers, timeout=10).json()
            if 'stream' in res and 'playlist' in res['stream']:
                stream_url = res['stream']['playlist']
                name = f"VidLink Movie ({content_name})" if is_movie else f"VidLink TV ({content_name} S{season}E{episode})"
                return verify_url_playability(stream_url, headers, name)
            else:
                print("  ❌ FAILED: Invalid response structure (no stream/playlist)")
        else:
            print(f"  ❌ FAILED: Encryption helper returned status {enc.get('status')}")
    except Exception as e:
        print("VidLink error:", e)
    return False

# Test Consumet / AniNeko Emulator
def test_anineko(content):
    keyword = content['keyword']
    episode = content['episode']
    name_label = content['name']
    print(f"\n--- Testing AniNeko Anime: {name_label} Ep {episode} ---")
    headers = {
        'User-Agent': UA,
        'Referer': 'https://anineko.to/'
    }
    try:
        search_url = f"https://anineko.to/browser?keyword={keyword}"
        r = requests.get(search_url, headers=headers, timeout=10)
        watch_ids = re.findall(r'href="/watch/([^"]+)"', r.text)
        if watch_ids:
            anime_id = watch_ids[0]
            ep_url = f"https://anineko.to/watch/{anime_id}/ep-{episode}"
            r_ep = requests.get(ep_url, headers=headers, timeout=10)
            
            matches = re.findall(r'data-video="([^"]+)"', r_ep.text)
            vibe_id = None
            for match in matches:
                if 'vibeplayer.site' in match:
                    parsed = urllib.parse.urlparse(match)
                    vibe_id = parsed.path.strip('/')
                    break
            
            if vibe_id:
                stream_url = f"https://vibeplayer.site/public/stream/{vibe_id}/master.m3u8"
                vibe_headers = {
                    'User-Agent': UA,
                    'Referer': 'https://vibeplayer.site/'
                }
                return verify_url_playability(stream_url, vibe_headers, f"AniNeko Anime ({name_label})")
            else:
                print("  ❌ FAILED: Vibeplayer ID not found in page")
        else:
            print("  ❌ FAILED: Anime not found in search")
    except Exception as e:
        print("AniNeko error:", e)
    return False

# Test Torrentio
def test_torrentio(content, is_movie=True):
    content_name = content['title']
    try:
        if is_movie:
            print(f"\n--- Testing Torrentio Movie: {content_name} ---")
            url = f"https://torrentio.strem.fun/stream/movie/{content['imdb']}.json"
        else:
            season, episode = content['season'], content['episode']
            print(f"\n--- Testing Torrentio TV: {content_name} S{season}E{episode} ---")
            url = f"https://torrentio.strem.fun/stream/series/{content['imdb']}:{season}:{episode}.json"
            
        headers = {
            'User-Agent': UA
        }
        r = requests.get(url, headers=headers, timeout=10)
        print(f"  Torrentio Response Status: {r.status_code}")
        if r.status_code != 200:
            print(f"  ❌ FAILED: Torrentio returned status code {r.status_code}")
            return False
            
        data = r.json()
        streams = data.get('streams', [])
        if streams:
            top_stream = streams[0]
            name = f"Torrentio Movie ({content_name})" if is_movie else f"Torrentio TV ({content_name} S{season}E{episode})"
            if top_stream.get('url'):
                return verify_url_playability(top_stream['url'], name=name)
            elif top_stream.get('infoHash'):
                print(f"  Torrent source found (InfoHash: {top_stream['infoHash']})")
                print(f"  ✅ PLAYING: Torrent magnet for {name} resolved successfully.")
                return True
        else:
            print(f"  ❌ FAILED: No streams found for Torrentio ({content_name})")
    except Exception as e:
        print("Torrentio error:", e)
    return False

if __name__ == "__main__":
    movie = TEST_MOVIES[0]
    show = TEST_SHOWS[0]
    
    results = {}
    
    # Movie tests
    results['VidAPI (Movie)'] = test_vidapi(movie, is_movie=True)
    results['Videasy (Movie)'] = test_videasy(movie, is_movie=True)
    results['VidLink (Movie)'] = test_vidlink(movie, is_movie=True)
    results['Torrentio (Movie)'] = test_torrentio(movie, is_movie=True)
    
    # TV Show tests
    results['VidAPI (TV Show)'] = test_vidapi(show, is_movie=False)
    results['Videasy (TV Show)'] = test_videasy(show, is_movie=False)
    results['VidLink (TV Show)'] = test_vidlink(show, is_movie=False)
    results['Torrentio (TV Show)'] = test_torrentio(show, is_movie=False)
    
    # Anime tests
    for anime in TEST_ANIME:
        results[f"AniNeko Anime ({anime['name']})"] = test_anineko(anime)
        
    print("\n==============================")
    print("PLAYABILITY VERIFICATION SUMMARY")
    print("==============================")
    for name, success in results.items():
        status = "✅ PLAYING" if success else "❌ FAILED"
        print(f"{name}: {status}")
