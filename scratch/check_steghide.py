import requests

UA = "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36"
url = "https://p16-ad-sg.ibyteimg.com/obj/ad-site-i18n/202603235d0d505426ec77e84cc880f0"
headers = {
    'User-Agent': UA,
    'Referer': 'https://vibeplayer.site/'
}

r = requests.get(url, headers=headers, timeout=10)
content = r.content
print("Downloaded content length:", len(content))

# Look for PNG IEND marker: 49 45 4E 44 AE 42 60 82
iend = b"\x49\x45\x4e\x44\xae\x42\x60\x82"
offset = content.find(iend)
if offset != -1:
    real_video_offset = offset + len(iend)
    print(f"PNG IEND found at offset {offset}.")
    print(f"Bytes after PNG IEND (length {len(content) - real_video_offset}):")
    after_bytes = content[real_video_offset:]
    print("First 32 bytes after PNG IEND in hex:", after_bytes[:32].hex())
    if len(after_bytes) > 0:
        if after_bytes[0] == 0x47:
            print("Sync byte 0x47 found immediately after PNG IEND!")
            if len(after_bytes) >= 189 and after_bytes[188] == 0x47:
                print("Double-verified MPEG-TS Sync byte (at 0 and 188) after PNG IEND!")
        else:
            # Let's search if 0x47 appears nearby
            for o in range(min(16, len(after_bytes) - 188)):
                if after_bytes[o] == 0x47 and after_bytes[o + 188] == 0x47:
                    print(f"MPEG-TS Sync byte found at offset {o} after PNG IEND!")
                    break
else:
    print("PNG IEND marker not found.")
