import requests
import re
import urllib.parse

UA = "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36"

def inspect_media_signature(content):
    if len(content) < 8:
        return "Unknown/Too Small"
    if content.startswith(b"\xff\xd8\xff"):
        return "JPEG Image"
    if content.startswith(b"\x89PNG\r\n\x1a\n"):
        return "PNG Image"
    if b"<!DOCTYPE html" in content.lower() or b"<html" in content.lower():
        return "HTML Page"
    if content[0] == 0x47:
        if len(content) >= 189 and content[188] == 0x47:
            return "Proper MPEG-TS Video (Double-verified 0x47)"
        return "MPEG-TS Video (Sync byte 0x47 verified)"
    if content[4:8] == b"ftyp":
        return f"MP4 Video (ftyp box '{content[8:12].decode('ascii', errors='ignore')}')"
    # Check for sync byte offsets
    for offset in range(min(16, len(content) - 188)):
        if content[offset] == 0x47 and content[offset + 188] == 0x47:
            return f"MPEG-TS Video (Offset sync byte 0x47 at {offset})"
    return f"Binary (First 16 bytes: {content[:16].hex()})"

headers = {
    'User-Agent': UA,
    'Referer': 'https://anineko.to/'
}

# 1. Search
search_url = "https://anineko.to/browser?keyword=naruto-shippuden"
r = requests.get(search_url, headers=headers, timeout=10)
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
        print("AniNeko Master Playlist:")
        print(r_stream.text[:300])
        
        # Get first sub playlist
        sub = None
        for line in r_stream.text.splitlines():
            if line.strip() and not line.startswith('#'):
                sub = line.strip()
                break
        if sub:
            sub_url = urllib.parse.urljoin(stream_url, sub)
            r_sub = requests.get(sub_url, headers=vibe_headers, timeout=10)
            print("\nAniNeko Sub Playlist:")
            print("\n".join(r_sub.text.splitlines()[:20]))
            
            # Fetch and inspect first 5 segments
            lines = [l.strip() for l in r_sub.text.splitlines() if l.strip() and not l.startswith('#')]
            for idx, seg in enumerate(lines[:5]):
                seg_url = urllib.parse.urljoin(sub_url, seg)
                print(f"\n--- Segment {idx} ---")
                print(f"URL: {seg_url}")
                r_seg = requests.get(seg_url, headers=vibe_headers, timeout=10)
                print(f"Status: {r_seg.status_code}")
                print(f"Content-Type: {r_seg.headers.get('Content-Type')}")
                print(f"Length: {len(r_seg.content)} bytes")
                sig = inspect_media_signature(r_seg.content)
                print(f"Format Signature: {sig}")
                # Print hex snippet of first 64 bytes
                print(f"Hex dump (first 64 bytes): {r_seg.content[:64].hex()}")
else:
    print("Naruto Shippuden not found in search")
