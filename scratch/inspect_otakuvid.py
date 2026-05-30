import requests
import re

headers = {
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
    'Referer': 'https://anineko.to/'
}

url = 'https://otakuvid.online/embed/7l4w52u2ganf'
r = requests.get(url, headers=headers)
html = r.text

# find any lines with m3u8
lines = html.splitlines()
for l in lines:
    if 'm3u8' in l or 'file' in l or 'src' in l or 'setup' in l:
        print(l.strip())
