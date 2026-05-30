import requests

headers = {
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
    'Referer': 'https://vibeplayer.site/'
}

url = 'https://vibeplayer.site/public/stream/e6693c8de8202fbe/master.m3u8'
print("Fetching:", url)
r = requests.get(url, headers=headers, timeout=10)
print("Status:", r.status_code)
print("Headers:", r.headers)
print("Content sample:")
print(r.text[:200])
