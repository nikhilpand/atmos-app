---
title: Torrentindex
emoji: 🌖
colorFrom: gray
colorTo: blue
sdk: gradio
sdk_version: 6.14.0
python_version: "3.13"
app_file: app.py
pinned: false
---

# Atmos Backend Server

Unified backend for the Atmos streaming app:

- **Torrent Caching**: Downloads via aria2c → uploads to Google Drive → streams back over HTTP
- **Gemini AI**: Personalized recommendations and smart Netflix-style categories

## API Endpoints

| Endpoint | Method | Description |
|---|---|---|
| `/api/health` | GET | Server health check |
| `/api/torrent-to-drive` | POST | Submit magnet link |
| `/api/status/{task_id}` | GET | Check progress |
| `/api/stream/{file_id}` | GET | Stream cached file (Range supported) |
| `/api/gemini/recommend` | POST | AI recommendations |
| `/api/gemini/categorize` | POST | AI category generation |
