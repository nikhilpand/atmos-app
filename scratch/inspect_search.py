import requests

headers = {
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
}

r = requests.get('https://anineko.to/browser?keyword=One%20Piece', headers=headers)
print("Status:", r.status_code)
html = r.text
print("Length:", len(html))

# Let's search for "One Piece" or "Piece" or "/anime/" case-insensitively in the HTML
import re
print("Occurrences of one piece:", len(re.findall(r'one piece', html, re.I)))
print("Occurrences of /anime/:", len(re.findall(r'/anime/', html, re.I)))

# Print any lines containing "/anime/" or "Piece"
lines = html.splitlines()
matching_lines = [l.strip() for l in lines if 'one piece' in l.lower() or '/anime/' in l.lower()][:30]
print("Matching lines:")
for l in matching_lines:
    print(l)
