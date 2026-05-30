import re
import requests

headers = {
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
}

url_movie = 'https://vegamovies.diamonds/4143-inception-2010-hindi-dual-audio-720p-bluray-900mb.html'
html = requests.get(url_movie, headers=headers).text

# Let's test a strictly bounded <a> tag parser
# This pattern matches <a ... href="URL" ...> ... Click Here To Download ... </a>
# We use (?!</a>) inside the middle group to make sure we stay within the same anchor tag!
pattern = re.compile(
    r'<a\s+[^>]*href=["\'](https?://[^"\']+)["\'][^>]*>\s*(?:(?!</a>)[\s\S])*?Click\s+Here\s+To\s+Download\s*(?:\[([^\]]+)\])?\s*(?:(?!</a>)[\s\S])*?</a>',
    re.I
)

links = []
for match in pattern.finditer(html):
    url = match.group(1)
    size = match.group(2) or None
    if size:
        size = size.strip()
        
    start_idx = match.start()
    context_before = html[max(0, start_idx - 1000):start_idx]
    
    # Look for resolution tags like 480p, 720p, 1080p, 2160p, 4k, etc.
    res_matches = list(re.finditer(r'\b(480p|720p|1080p|2160p|4K|360p)\b', context_before, re.I))
    quality = res_matches[-1].group(1).upper() if res_matches else 'HD'
        
    host = 'direct'
    url_lower = url.lower()
    if 'drive.google' in url_lower or 'docs.google' in url_lower:
        host = 'gdrive'
    elif 'pixeldrain' in url_lower:
        host = 'pixeldrain'
    elif 'hubcloud' in url_lower or 'hub.la' in url_lower or 'hubcdn' in url_lower:
        host = 'hubcloud'
    elif 'nexdrive' in url_lower:
        host = 'nexdrive'
    elif 'vgmlinks' in url_lower:
        host = 'vgmlinks'
    elif 'fast-dl' in url_lower:
        host = 'fast-dl'
        
    codec_match = re.search(r'\b(x265|HEVC|x264|AVC|AV1)\b', context_before, re.I)
    codec = codec_match.group(1).lower().replace('hevc', 'x265').replace('avc', 'x264') if codec_match else None
    
    lang_match = re.search(r'\b(Hindi|English|Tamil|Telugu|Malayalam|Dual Audio|Multi Audio|Dubbed)\b', context_before, re.I)
    language = lang_match.group(1) if lang_match else 'Hindi/English'
    
    links.append({
        'url': url,
        'host': host,
        'quality': quality,
        'size': size,
        'codec': codec,
        'language': language
    })

print("Parsed links:")
for l in links:
    print(l)
