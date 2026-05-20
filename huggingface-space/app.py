import os
import sys
import time
import json
import logging
import subprocess
import threading
from datetime import datetime, timedelta, timezone
from typing import Dict, Any, Optional

import requests
import uvicorn
from fastapi import FastAPI, HTTPException, Request, Header
from fastapi.responses import StreamingResponse, JSONResponse
from fastapi.middleware.cors import CORSMiddleware
import gradio as gr

from google.oauth2 import service_account
from googleapiclient.discovery import build
from googleapiclient.http import MediaIoBaseDownload, MediaFileUpload

# Setup Logging
logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
logger = logging.getLogger("TorrentIndex")

# Initialize FastAPI
app = FastAPI(title="Atmos Torrent-to-Drive Proxy API")
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Global variables
GDRIVE_SERVICE_ACCOUNT_JSON = os.environ.get("GDRIVE_SERVICE_ACCOUNT", "")
CACHE_EXPIRY_HOURS = int(os.environ.get("CACHE_EXPIRY_HOURS", "24"))
DOWNLOAD_DIR = "/tmp/aria2"
os.makedirs(DOWNLOAD_DIR, exist_ok=True)

# Active tasks tracking (in-memory)
active_tasks: Dict[str, Dict[str, Any]] = {}

# Start aria2c daemon
aria2_process = None
def start_aria2():
    global aria2_process
    try:
        logger.info("Starting aria2c daemon...")
        aria2_process = subprocess.Popen([
            "aria2c",
            "--enable-rpc=true",
            "--rpc-listen-all=true",
            "--rpc-allow-origin-all=true",
            "--rpc-listen-port=6800",
            "--max-connection-per-server=16",
            "--split=16",
            "--seed-time=0",
            f"--dir={DOWNLOAD_DIR}",
            "--quiet=true"
        ])
        logger.info("aria2c started successfully.")
    except Exception as e:
        logger.error(f"Failed to start aria2c: {e}")

# Helper: Google Drive service client
def get_gdrive_service():
    if not GDRIVE_SERVICE_ACCOUNT_JSON:
        raise ValueError("GDRIVE_SERVICE_ACCOUNT environment variable is empty.")
    try:
        creds_dict = json.loads(GDRIVE_SERVICE_ACCOUNT_JSON)
        creds = service_account.Credentials.from_service_account_info(
            creds_dict,
            scopes=["https://www.googleapis.com/auth/drive"]
        )
        return build("drive", "v3", credentials=creds)
    except Exception as e:
        logger.error(f"Failed to initialize Google Drive client: {e}")
        raise

# Helper: Find or create Atmos Cache Folder on GDrive
def get_or_create_cache_folder(service):
    query = "name = 'Atmos-Cache' and mimeType = 'application/vnd.google-apps.folder' and trashed = false"
    results = service.files().list(q=query, fields="files(id)").execute()
    files = results.get("files", [])
    if files:
        return files[0]["id"]
    
    # Create folder
    folder_metadata = {
        "name": "Atmos-Cache",
        "mimeType": "application/vnd.google-apps.folder"
    }
    folder = service.files().create(body=folder_metadata, fields="id").execute()
    return folder["id"]

# Helper: Call aria2 JSON-RPC
def aria2_rpc(method: str, params: list = None) -> Any:
    url = "http://127.0.0.1:6800/jsonrpc"
    payload = {
        "jsonrpc": "2.0",
        "id": "torrentindex",
        "method": f"aria2.{method}",
        "params": params or []
    }
    try:
        r = requests.post(url, json=payload, timeout=5)
        if r.status_code == 200:
            return r.json().get("result")
        logger.error(f"aria2 RPC status error: {r.status_code} - {r.text}")
    except Exception as e:
        logger.error(f"aria2 RPC request failed: {e}")
    return None

# Task: Upload to Google Drive in background thread
def upload_task(task_id: str, local_path: str, filename: str):
    try:
        active_tasks[task_id]["status"] = "uploading"
        logger.info(f"Uploading {filename} to Google Drive...")
        
        service = get_gdrive_service()
        folder_id = get_or_create_cache_folder(service)
        
        file_metadata = {
            "name": filename,
            "parents": [folder_id]
        }
        
        media = MediaFileUpload(local_path, resumable=True)
        request = service.files().create(body=file_metadata, media_body=media, fields="id")
        
        response = None
        while response is None:
            status, response = request.next_chunk()
            if status:
                progress = int(status.progress() * 100)
                active_tasks[task_id]["progress"] = progress
                logger.info(f"Upload progress for {task_id}: {progress}%")
                
        file_id = response.get("id")
        logger.info(f"Successfully uploaded file to Google Drive. File ID: {file_id}")
        
        # Delete local file to free space
        if os.path.exists(local_path):
            os.remove(local_path)
            
        active_tasks[task_id].update({
            "status": "completed",
            "progress": 100,
            "file_id": file_id,
            "stream_url": f"/api/stream/{file_id}"
        })
    except Exception as e:
        logger.error(f"Upload task failed for {task_id}: {e}")
        active_tasks[task_id].update({
            "status": "failed",
            "error": str(e)
        })

# Background loop to monitor downloads
def monitor_downloads_loop():
    logger.info("Starting download monitor loop...")
    while True:
        try:
            # Query active downloads
            active = aria2_rpc("tellActive") or []
            waiting = aria2_rpc("tellWaiting", [0, 50]) or []
            
            all_downloads = active + waiting
            for dl in all_downloads:
                gid = dl.get("gid")
                status = dl.get("status")
                total_length = int(dl.get("totalLength", "0"))
                completed_length = int(dl.get("completedLength", "0"))
                
                # Try to extract filename
                files = dl.get("files", [])
                filename = "Unknown Torrent File"
                local_path = ""
                if files and files[0].get("path"):
                    local_path = files[0]["path"]
                    filename = os.path.basename(local_path)
                
                progress = int((completed_length / total_length) * 100) if total_length > 0 else 0
                
                if gid not in active_tasks:
                    active_tasks[gid] = {
                        "filename": filename,
                        "status": status,
                        "progress": progress,
                        "total_bytes": total_length
                    }
                else:
                    active_tasks[gid].update({
                        "status": status,
                        "progress": progress
                    })
            
            # Check completed downloads
            stopped = aria2_rpc("tellStopped", [0, 50]) or []
            for dl in stopped:
                gid = dl.get("gid")
                status = dl.get("status")
                files = dl.get("files", [])
                
                if files and files[0].get("path"):
                    local_path = files[0]["path"]
                    filename = os.path.basename(local_path)
                    
                    if status == "complete" and os.path.exists(local_path):
                        if gid not in active_tasks or active_tasks[gid]["status"] == "complete":
                            active_tasks[gid] = {
                                "filename": filename,
                                "status": "downloaded",
                                "progress": 100
                            }
                            # Spawn upload thread
                            threading.Thread(
                                target=upload_task,
                                args=(gid, local_path, filename),
                                daemon=True
                            ).start()
                            # Remove from aria2 to clear history
                            aria2_rpc("removeDownloadResult", [gid])
                    elif status == "error":
                        active_tasks[gid] = {
                            "filename": filename,
                            "status": "failed",
                            "error": "Aria2 download error"
                        }
                        aria2_rpc("removeDownloadResult", [gid])
                        
        except Exception as e:
            logger.error(f"Error in monitor loop: {e}")
        time.sleep(3)

# Background loop to cleanup old GDrive files (Auto-Expiry Cache)
def cleanup_old_files_loop():
    logger.info(f"Starting GDrive cleanup loop (expiry = {CACHE_EXPIRY_HOURS} hours)...")
    while True:
        try:
            if GDRIVE_SERVICE_ACCOUNT_JSON:
                service = get_gdrive_service()
                folder_id = get_or_create_cache_folder(service)
                
                # List files in the cache folder
                query = f"'{folder_id}' in parents and trashed = false"
                results = service.files().list(
                    q=query,
                    fields="files(id, name, createdTime)"
                ).execute()
                files = results.get("files", [])
                
                now = datetime.now(timezone.utc)
                for f in files:
                    file_id = f["id"]
                    file_name = f["name"]
                    created_time_str = f["createdTime"].replace("Z", "+00:00")
                    created_time = datetime.fromisoformat(created_time_str)
                    
                    age = now - created_time
                    if age > timedelta(hours=CACHE_EXPIRY_HOURS):
                        logger.info(f"Deleting expired file '{file_name}' ({file_id}) older than {CACHE_EXPIRY_HOURS}h...")
                        service.files().delete(fileId=file_id).execute()
        except Exception as e:
            logger.error(f"Error in cleanup loop: {e}")
        # Run every 30 minutes
        time.sleep(1800)

# ── FastAPI Routes ─────────────────────────────────────────────────────────────

@app.post("/api/torrent-to-drive")
async def start_torrent_to_drive(payload: Dict[str, str]):
    magnet = payload.get("magnet_link")
    if not magnet:
        raise HTTPException(status_code=400, detail="Missing magnet_link")
        
    # Check GDrive config
    if not GDRIVE_SERVICE_ACCOUNT_JSON:
        raise HTTPException(status_code=500, detail="GDrive service account credentials are not configured on Space Secrets.")
        
    # Add uri/magnet to aria2
    gid = aria2_rpc("addUri", [[magnet]])
    if not gid:
        raise HTTPException(status_code=500, detail="Failed to add download to aria2")
        
    active_tasks[gid] = {
        "filename": "Querying Torrent Metadata...",
        "status": "active",
        "progress": 0,
        "total_bytes": 0
    }
    return {"task_id": gid, "status": "active"}

@app.get("/api/status/{task_id}")
async def get_task_status(task_id: str):
    if task_id not in active_tasks:
        raise HTTPException(status_code=404, detail="Task not found")
    return active_tasks[task_id]

@app.get("/api/stream/{file_id}")
async def stream_gdrive_file(file_id: str, range: Optional[str] = Header(None)):
    """
    Proxies stream chunks directly from Google Drive with support for HTTP Range requests.
    This lets the Flutter player seek through the video without needing Google API keys.
    """
    try:
        service = get_gdrive_service()
        
        # Get metadata
        meta = service.files().get(fileId=file_id, fields="name, size, mimeType").execute()
        file_size = int(meta.get("size", 0))
        mime_type = meta.get("mimeType", "video/mp4")
        
        headers = {}
        if range:
            headers["Range"] = range
            
        # Call GDrive direct media download endpoint
        url = f"https://www.googleapis.com/drive/v3/files/{file_id}?alt=media"
        # Get OAuth token
        creds_dict = json.loads(GDRIVE_SERVICE_ACCOUNT_JSON)
        creds = service_account.Credentials.from_service_account_info(
            creds_dict,
            scopes=["https://www.googleapis.com/auth/drive"]
        )
        # Refresh credential to get access token
        creds.refresh(requests.Request())
        
        api_headers = {
            "Authorization": f"Bearer {creds.token}"
        }
        if range:
            api_headers["Range"] = range
            
        r = requests.get(url, headers=api_headers, stream=True, timeout=10)
        
        # Build response headers
        response_headers = {
            "Content-Type": mime_type,
            "Accept-Ranges": "bytes",
            "Access-Control-Allow-Origin": "*",
            "Content-Disposition": f'inline; filename="{meta.get("name")}"'
        }
        if "Content-Range" in r.headers:
            response_headers["Content-Range"] = r.headers["Content-Range"]
        if "Content-Length" in r.headers:
            response_headers["Content-Length"] = r.headers["Content-Length"]
            
        # Return StreamingResponse with chunks
        return StreamingResponse(
            r.iter_content(chunk_size=1024*1024), # 1MB chunk size
            status_code=r.status_code,
            headers=response_headers
        )
    except Exception as e:
        logger.error(f"Stream proxy failed: {e}")
        raise HTTPException(status_code=500, detail=str(e))

# ── Gradio Web UI ─────────────────────────────────────────────────────────────

def get_status_ui():
    out = []
    # System Status
    gdrive_status = "✅ Connected" if GDRIVE_SERVICE_ACCOUNT_JSON else "❌ Credentials Missing (Check Secret GDRIVE_SERVICE_ACCOUNT)"
    out.append(f"### Server Status\n- **Google Drive Integration**: {gdrive_status}\n- **Cache Expiry Duration**: {CACHE_EXPIRY_HOURS} Hours\n\n")
    
    # Active Tasks Table
    out.append("### Active Caching Operations\n")
    if not active_tasks:
        out.append("No active download or upload tasks.")
    else:
        for tid, details in active_tasks.items():
            prog = details.get("progress", 0)
            status = details.get("status", "unknown")
            filename = details.get("filename", "Unknown file")
            url = details.get("stream_url", "")
            
            # Make beautiful markdown rows
            prog_bar = "█" * (prog // 10) + "░" * (10 - (prog // 10))
            out.append(f"**Task ID**: `{tid}`\n")
            out.append(f"- File: `{filename}`\n")
            out.append(f"- Status: **{status.upper()}**\n")
            out.append(f"- Progress: `[{prog_bar}] {prog}%`\n")
            if url:
                out.append(f"- Stream Link: [Play Direct]({url})\n")
            out.append("\n---\n")
            
    return "".join(out)

def trigger_manual_download(magnet):
    if not magnet:
        return "Please input a valid magnet link."
    if not GDRIVE_SERVICE_ACCOUNT_JSON:
        return "Error: GDrive credentials are not configured."
    gid = aria2_rpc("addUri", [[magnet]])
    if not gid:
        return "Failed to add to aria2 queue."
    active_tasks[gid] = {
        "filename": "Querying Torrent Metadata...",
        "status": "active",
        "progress": 0,
        "total_bytes": 0
    }
    return f"Successfully queued download with Task ID: `{gid}`"

# Build Gradio block
with gr.Blocks(title="TorrentIndex Cache Admin") as demo:
    gr.Markdown("# Atmos Torrent Caching Server")
    gr.Markdown("This interface shows status of background torrent caching and allows manual uploads.")
    
    with gr.Tab("Downloads Status"):
        status_md = gr.Markdown()
        demo.load(get_status_ui, outputs=[status_md], every=5)
        
    with gr.Tab("Manual Cache Trigger"):
        magnet_input = gr.Textbox(label="Torrent Magnet Link / Torrent File URL")
        submit_btn = gr.Button("Start Caching")
        output_txt = gr.Textbox(label="Result")
        submit_btn.click(trigger_manual_download, inputs=[magnet_input], outputs=[output_txt])

# Mount FastAPI onto Gradio app
demo_app = gr.mount_gradio_app(app, demo, path="/")

# Start background daemon threads & server boot
if __name__ == "__main__":
    start_aria2()
    # Monitor threads
    threading.Thread(target=monitor_downloads_loop, daemon=True).start()
    threading.Thread(target=cleanup_old_files_loop, daemon=True).start()
    
    # Run Uvicorn
    uvicorn.run(demo_app, host="0.0.0.0", port=7860)
