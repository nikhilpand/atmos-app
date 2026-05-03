-- ══════════════════════════════════════════════════════════════════════════════
-- AtmosIndex — Supabase Schema
-- ══════════════════════════════════════════════════════════════════════════════
--
-- Run this in Supabase Dashboard > SQL Editor > New Query
-- This creates the media catalog tables for the AtmosIndex engine.

-- ── Channels table ──────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS tg_channels (
    id BIGSERIAL PRIMARY KEY,
    username TEXT UNIQUE NOT NULL,
    title TEXT,
    category TEXT DEFAULT 'general',
    member_count INT DEFAULT 0,
    last_crawled_at TIMESTAMPTZ,
    last_msg_id BIGINT DEFAULT 0,
    is_seed BOOLEAN DEFAULT TRUE,
    is_active BOOLEAN DEFAULT TRUE,
    trust_score REAL DEFAULT 0.5,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- ── Media table ─────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS tg_media (
    id BIGSERIAL PRIMARY KEY,
    channel_username TEXT NOT NULL,
    msg_id BIGINT NOT NULL,
    title TEXT NOT NULL,
    title_normalized TEXT NOT NULL,
    year INT,
    season INT,
    episode INT,
    episode_end INT,
    quality TEXT,
    source_tag TEXT,
    platform_tag TEXT,
    codec TEXT,
    audio TEXT,
    file_size_bytes BIGINT DEFAULT 0,
    file_name TEXT DEFAULT '',
    is_season_pack BOOLEAN DEFAULT FALSE,
    uploaded_at TIMESTAMPTZ,
    indexed_at TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(channel_username, msg_id)
);

-- ── Indexes ─────────────────────────────────────────────────────────────────

CREATE INDEX IF NOT EXISTS idx_media_title_norm ON tg_media(title_normalized);
CREATE INDEX IF NOT EXISTS idx_media_year ON tg_media(year);
CREATE INDEX IF NOT EXISTS idx_media_season_ep ON tg_media(season, episode);
CREATE INDEX IF NOT EXISTS idx_media_quality ON tg_media(quality);
CREATE INDEX IF NOT EXISTS idx_media_channel ON tg_media(channel_username);

-- ── Row Level Security (required for Supabase REST access) ──────────────────

ALTER TABLE tg_channels ENABLE ROW LEVEL SECURITY;
ALTER TABLE tg_media ENABLE ROW LEVEL SECURITY;

-- Allow anon key to read and write (our CF Worker uses anon key)
CREATE POLICY "Allow all access" ON tg_channels FOR ALL USING (true) WITH CHECK (true);
CREATE POLICY "Allow all access" ON tg_media FOR ALL USING (true) WITH CHECK (true);

-- ══════════════════════════════════════════════════════════════════════════════
-- Done! After running this:
--   1. Copy your Supabase URL from Settings > API > Project URL
--   2. Copy your anon key from Settings > API > Project API keys > anon
--   3. Set them in Cloudflare:
--        wrangler secret put SUPABASE_URL
--        wrangler secret put SUPABASE_ANON_KEY
-- ══════════════════════════════════════════════════════════════════════════════
