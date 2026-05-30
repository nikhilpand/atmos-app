import requests
import urllib.parse
import json

UA = "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36"

def inspect_vidapi():
    print("\n=== Inspecting VidAPI ===")
    url = "https://streamdata.vaplayer.ru/api.php?tmdb=27205&type=movie"
    headers = {
        'User-Agent': UA,
        'Referer': 'https://brightpathsignals.com/',
        'Origin': 'https://brightpathsignals.com'
    }
    r = requests.get(url, headers=headers, timeout=10)
    print("Status:", r.status_code)
    print("Headers:", r.headers)
    print("Response Body Sample (first 500 chars):")
    print(r.text[:500])

def inspect_videasy():
    print("\n=== Inspecting Videasy ===")
    headers = {
        'User-Agent': UA,
        'Referer': 'https://player.videasy.net/',
        'Origin': 'https://player.videasy.net'
    }
    # Get encrypted
    enc = requests.get("https://api.videasy.net/mb-flix/sources-with-title?title=Inception&mediaType=movie&tmdbId=27205", headers=headers, timeout=10).text
    # Decrypt
    dec = requests.post("https://enc-dec.app/api/dec-videasy", json={"text": enc, "id": "27205"}, timeout=10).json()
    print("Decrypted Videasy response keys:", dec.keys() if dec else None)
    if dec.get('status') == 200:
        result = dec['result']
        if isinstance(result, str):
            result = json.loads(result)
        srcs = result.get('sources', [])
        if srcs:
            stream_url = srcs[0]['url']
            print("Stream URL:", stream_url)
            r_stream = requests.get(stream_url, headers=headers, timeout=10)
            print("Stream Status:", r_stream.status_code)
            print("Stream Content Sample:")
            print(r_stream.text[:500])

def inspect_vidlink():
    print("\n=== Inspecting VidLink ===")
    enc = requests.get("https://enc-dec.app/api/enc-vidlink?text=27205", timeout=10).json()
    if enc.get('status') == 200:
        enc_id = enc['result']
        src_url = f"https://vidlink.pro/api/b/movie/{enc_id}"
        headers = {
            'User-Agent': UA,
            'Origin': 'https://vidlink.pro',
            'Referer': 'https://vidlink.pro/'
        }
        res = requests.get(src_url, headers=headers, timeout=10).json()
        print("VidLink API keys:", res.keys())
        if 'stream' in res and 'playlist' in res['stream']:
            stream_url = res['stream']['playlist']
            print("VidLink Stream URL:", stream_url)
            r_stream = requests.get(stream_url, headers=headers, timeout=10)
            print("VidLink Stream Status:", r_stream.status_code)
            print("VidLink Master Playlist Sample:")
            print(r_stream.text[:500])
            
            # If sub-playlist exists, fetch it
            sub = None
            for line in r_stream.text.splitlines():
                if line.strip() and not line.startswith('#'):
                    sub = line.strip()
                    break
            if sub:
                sub_url = urllib.parse.urljoin(stream_url, sub)
                print("Fetching VidLink Sub Playlist:", sub_url)
                r_sub = requests.get(sub_url, headers=headers, timeout=10)
                print("Sub Playlist Status:", r_sub.status_code)
                print("Sub Playlist Sample:")
                print(r_sub.text[:500])

def inspect_anineko():
    print("\n=== Inspecting AniNeko ===")
    headers = {
        'User-Agent': UA,
        'Referer': 'https://anineko.to/'
    }
    search_url = "https://anineko.to/browser?keyword=naruto-shippuden"
    r = requests.get(search_url, headers=headers, timeout=10)
    import re
    watch_ids = re.findall(r'href="/watch/([^"]+)"', r.text)
    if watch_ids:
        anime_id = watch_ids[0]
        ep_url = f"https://anineko.to/watch/{anime_id}/ep-1"
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
            r_stream = requests.get(stream_url, headers=vibe_headers, timeout=10)
            print("AniNeko Stream Status:", r_stream.status_code)
            print("AniNeko Master Playlist Sample:")
            print(r_stream.text[:500])
            
            sub = None
            for line in r_stream.text.splitlines():
                if line.strip() and not line.startswith('#'):
                    sub = line.strip()
                    break
            if sub:
                sub_url = urllib.parse.urljoin(stream_url, sub)
                print("Fetching AniNeko Sub Playlist:", sub_url)
                r_sub = requests.get(sub_url, headers=vibe_headers, timeout=10)
                print("Sub Playlist Status:", r_sub.status_code)
                print("Sub Playlist Sample:")
                print(r_sub.text[:500])

def inspect_torrentio():
    print("\n=== Inspecting Torrentio ===")
    headers = {
        'User-Agent': UA
    }
    r = requests.get("https://torrentio.strem.fun/stream/movie/tt1375666.json", headers=headers, timeout=10)
    print("Status:", r.status_code)
    print("Headers:", r.headers)
    print("Response Body Sample (first 500 chars):")
    print(r.text[:500])

if __name__ == "__main__":
    inspect_vidapi()
    inspect_videasy()
    inspect_vidlink()
    inspect_anineko()
    inspect_torrentio()
