import requests
import re

headers = {
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
}

url = 'https://anineko.to/watch/one-piece'
print("Fetching:", url)
r = requests.get(url, headers=headers, timeout=15)
print("Status:", r.status_code)
html = r.text
print("Length:", len(html))

# Let's search for "ep-" or "episode" or nv-server-btn in the HTML
print("Occurrences of ep-:", len(re.findall(r'ep-', html)))
print("Occurrences of episode:", len(re.findall(r'episode', html, re.I)))
print("Occurrences of nv-server-btn:", len(re.findall(r'nv-server-btn', html)))

# Let's inspect some links in the HTML
all_links = re.findall(r'href=["\']([^"\']+)["\']', html)
watch_links = [l for l in all_links if '/watch/' in l]
print("Found watch links:", len(watch_links))
for l in watch_links[:30]:
    print(" -", l)

# Let's see some occurrences of class names containing episode/ep
ep_divs = [l.strip() for l in html.splitlines() if 'ep-' in l][:30]
print("Lines with ep-:")
for l in ep_divs:
    print(l)
