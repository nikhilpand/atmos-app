import requests
import re

headers = {
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
}

url = 'https://anineko.to/watch/one-piece/ep-1'
print("Fetching:", url)
r = requests.get(url, headers=headers, timeout=15)
print("Status:", r.status_code)
html = r.text
print("Length:", len(html))

# Let's search for "nv-server" or "data-video" or similar things in the HTML
print("Occurrences of nv-server:", len(re.findall(r'nv-server', html)))
print("Occurrences of data-video:", len(re.findall(r'data-video', html)))
print("Occurrences of iframe:", len(re.findall(r'<iframe', html)))

# Print any lines that contain data-video or nv-server
lines = html.splitlines()
matching_lines = [l.strip() for l in lines if 'data-video' in l or 'nv-server' in l][:30]
print("Matching lines:")
for l in matching_lines:
    print(l)
