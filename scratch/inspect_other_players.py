import requests
import re

headers = {
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
    'Referer': 'https://anineko.to/'
}

# 1. Otakuvid
url1 = 'https://otakuvid.online/embed/7l4w52u2ganf'
print("Fetching:", url1)
try:
    r = requests.get(url1, headers=headers, timeout=10)
    print("Otakuvid Status:", r.status_code)
    html = r.text
    print("Otakuvid m3u8 count:", len(re.findall(r'm3u8', html, re.I)))
    print("Otakuvid mp4 count:", len(re.findall(r'mp4', html, re.I)))
    # find files/sources
    sources = re.findall(r'["\']?(?:file|src|url)["\']?\s*:\s*["\']([^"\']+\.m3u8|[^"\']+\.mp4[^"\']*)["\']', html)
    print("Otakuvid parsed sources:", sources)
except Exception as e:
    print("Otakuvid error:", e)

# 2. Playmogo
url2 = 'https://playmogo.com/e/aq0tokcwb64v'
print("\nFetching:", url2)
try:
    r = requests.get(url2, headers=headers, timeout=10)
    print("Playmogo Status:", r.status_code)
    html = r.text
    print("Playmogo m3u8 count:", len(re.findall(r'm3u8', html, re.I)))
    print("Playmogo mp4 count:", len(re.findall(r'mp4', html, re.I)))
    sources = re.findall(r'["\']?(?:file|src|url)["\']?\s*:\s*["\']([^"\']+\.m3u8|[^"\']+\.mp4[^"\']*)["\']', html)
    print("Playmogo parsed sources:", sources)
except Exception as e:
    print("Playmogo error:", e)
