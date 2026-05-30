import requests
import re
import urllib.parse

headers = {
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
}

def search_anime(query):
    encoded = urllib.parse.quote(query)
    url = f"https://anineko.to/browser?keyword={encoded}"
    print(f"Searching: {url}")
    r = requests.get(url, headers=headers, timeout=15)
    print("Status:", r.status_code)
    
    # Let's find links matching /anime/ID or similar
    # In anineko, let's see what links exist.
    html = r.text
    print("Length of search html:", len(html))
    
    # We can inspect titles and links
    # Let's extract links containing /anime/
    links = re.findall(r'href=["\'](/anime/[^"\']+)["\']', html)
    print("Found anime links:", set(links))
    
    # Let's also look for titles around those links
    # Typically: <a href="/anime/one-piece-sub">One Piece</a> or similar
    matches = re.findall(r'href=["\'](/anime/([^"\']+))["\'][^>]*>([\s\S]*?)</a>', html)
    results = []
    seen = set()
    for link, anime_id, title_html in matches:
        title = re.sub(r'<[^>]*>', '', title_html).strip()
        if not title or anime_id in seen:
            continue
        seen.add(anime_id)
        results.append({
            "id": anime_id,
            "title": title,
            "url": f"https://anineko.to/anime/{anime_id}"
        })
    return results

def get_episode_stream(anime_id, episode):
    url = f"https://anineko.to/watch/{anime_id}/ep-{episode}"
    print(f"Fetching episode: {url}")
    r = requests.get(url, headers=headers, timeout=15)
    print("Status:", r.status_code)
    html = r.text
    
    # Find all buttons with class nv-server-btn and attribute data-video
    # Pattern: <button class="[^"]*nv-server-btn[^"]*"[^>]*data-video=["\']([^"\']+)["\']
    # Or more general: data-video="URL" inside a button or tag
    video_links = re.findall(r'data-video=["\']([^"\']+)["\']', html)
    print("Found video links in data-video:")
    for v in video_links:
        print(" -", v)
        
    # Let's see if we can find server names
    # Pattern: <button[^>]*class="[^"]*nv-server-btn[^"]*"[^>]*data-video=["\']([^"\']+)["\'][^>]*>([\s\S]*?)</button>
    server_matches = re.findall(r'<button[^>]*class="[^"]*nv-server-btn[^"]*"[^>]*data-video=["\']([^"\']+)["\'][^>]*>([\s\S]*?)</button>', html)
    servers = []
    for video_url, btn_text in server_matches:
        name = re.sub(r'<[^>]*>', '', btn_text).strip()
        servers.append({
            "name": name,
            "url": video_url
        })
    return servers

# Test search
results = search_anime("One Piece")
print("Search Results:")
for r in results[:5]:
    print(r)

if results:
    anime_id = results[0]['id']
    servers = get_episode_stream(anime_id, 1)
    print(f"Streams for {anime_id} Ep 1:")
    for s in servers:
        print(s)
