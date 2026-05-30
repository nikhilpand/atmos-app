import requests
import re

headers = {
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
    'Referer': 'https://vegamovies.diamonds/'
}

url = 'https://vegamovies.diamonds/index.php?do=search'
payload = {
    'do': 'search',
    'subaction': 'search',
    'story': 'Inception'
}

print("Searching VegaMovies via POST...")
r = requests.post(url, headers=headers, data=payload, timeout=15)
print("Status:", r.status_code)
html = r.text
print("Length:", len(html))

# Let's search for links in the HTML that look like posts
# DLE posts usually have URLs like https://vegamovies.diamonds/1234-post-title.html
post_links = re.findall(r'href=["\'](https://vegamovies\.diamonds/\d+-[^"\']+\.html)["\']', html)
print("Total post links found:", len(post_links))

# Let's inspect the unique post links and try to match titles
unique_links = list(set(post_links))
print("Unique post links:")
for l in unique_links[:10]:
    print(" -", l)

# Let's try to match title and URL together
# For example, <h2 class="entry-title"><a href="URL">TITLE</a></h2> or similar
# Let's search for "Inception" and see its surrounding markup
inception_matches = [m.start() for m in re.finditer('Inception', html, re.I)]
print("\nInception matches in search result HTML:")
for idx in inception_matches[:3]:
    print(html[max(0, idx-150):idx+150])
    print("-" * 50)
