import requests
import re

headers = {
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
    'Referer': 'https://anineko.to/'
}

url = 'https://vibeplayer.site/aac165bfc862642b'
print("Fetching:", url)
r = requests.get(url, headers=headers, timeout=15)
print("Status:", r.status_code)
html = r.text
print("Length:", len(html))

# Let's search for m3u8 or mp4 or source or file or tracks
print("Occurrences of m3u8:", len(re.findall(r'm3u8', html, re.I)))
print("Occurrences of mp4:", len(re.findall(r'mp4', html, re.I)))
print("Occurrences of setup:", len(re.findall(r'jwplayer|player|setup|sources', html, re.I)))

# Print any script tags or lines that look like configuration
lines = html.splitlines()
matching_lines = [l.strip() for l in lines if 'file' in l or 'source' in l or 'm3u8' in l or 'mp4' in l][:30]
print("Matching lines:")
for l in matching_lines:
    print(l)
