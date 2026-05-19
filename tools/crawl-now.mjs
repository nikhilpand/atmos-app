/**
 * AtmosIndex — Direct Crawl Script
 *
 * Runs the same logic as the CF Worker cron but directly in Node.js.
 * Uses the live Supabase credentials from cloudflare-worker/.dev.vars
 *
 * Usage: node tools/crawl-now.mjs [--channels 5] [--pages 20]
 */

import { readFileSync, existsSync } from 'fs';
import { parseFilename, normalize, parseTelegramHTML } from '../cloudflare-worker/parser.js';

// ── Config ──────────────────────────────────────────────────────────────────

const DEV_VARS = new URL('../cloudflare-worker/.dev.vars', import.meta.url).pathname;
const vars = {};
readFileSync(DEV_VARS, 'utf-8').split('\n').forEach(line => {
  const [k, ...v] = line.split('=');
  if (k && v.length) vars[k.trim()] = v.join('=').trim();
});

const SUPABASE_URL = vars.SUPABASE_URL;
const ANON_KEY    = vars.SUPABASE_ANON_KEY;

if (!SUPABASE_URL || !ANON_KEY) {
  console.error('❌ Missing SUPABASE_URL or SUPABASE_ANON_KEY in .dev.vars');
  process.exit(1);
}

const USER_AGENT = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36';

// ── Verified seed channels — diverse content, public t.me/s/ ─────────────
const SEED_CHANNELS = [
  // Movies (English)
  { username: 'Movie_World_Official',    category: 'movies' },
  { username: 'TeleFilm',               category: 'movies' },
  { username: 'Movies4K',               category: 'movies' },
  { username: 'MoviesAndSeries4free',   category: 'movies' },
  { username: 'filmyzillaofficial',      category: 'movies' },
  { username: 'movies_and_series_hub',  category: 'movies' },
  // TV Series
  { username: 'SeriesMoviesSearch',     category: 'series' },
  { username: 'CinemaHub_Movies_Series',category: 'series' },
  { username: 'NetflixSeriesOfficial',  category: 'series' },
  // Bollywood / Hindi
  { username: 'Hollywood_Movies_Hindi_Dubbed_0', category: 'bollywood' },
  { username: 'BollywoodHub4K',         category: 'bollywood' },
  // Anime
  { username: 'Anime_Library_Updates',  category: 'anime' },
  { username: 'animepahe_org',          category: 'anime' },
  // Dual / Multi
  { username: 'dual_audio_movies_hub',  category: 'dual' },
  { username: 'Netflix_Movies_Series_HQ', category: 'movies' },
];

// Args
const args = process.argv.slice(2);
const maxChannels = parseInt(args[args.indexOf('--channels') + 1] || '0') || SEED_CHANNELS.length;
const maxPages    = parseInt(args[args.indexOf('--pages')    + 1] || '0') || 15;

const sleep = ms => new Promise(r => setTimeout(r, ms));

// ── Supabase helpers ─────────────────────────────────────────────────────────

function sbHeaders() {
  return {
    'apikey': ANON_KEY,
    'Authorization': `Bearer ${ANON_KEY}`,
    'Content-Type': 'application/json',
    'Prefer': 'resolution=merge-duplicates',
  };
}

async function sbQuery(table, params = '') {
  const res = await fetch(`${SUPABASE_URL}/rest/v1/${table}${params}`, {
    headers: sbHeaders(),
  });
  if (!res.ok) {
    const t = await res.text();
    console.error(`Supabase GET ${table} error: ${res.status} ${t.substring(0, 100)}`);
    return [];
  }
  return res.json();
}

async function sbUpsert(table, rows) {
  if (!rows.length) return 0;
  const res = await fetch(`${SUPABASE_URL}/rest/v1/${table}`, {
    method: 'POST',
    headers: { ...sbHeaders(), 'Prefer': 'resolution=merge-duplicates' },
    body: JSON.stringify(rows),
  });
  if (!res.ok) {
    const t = await res.text();
    console.error(`Supabase UPSERT error: ${res.status} ${t.substring(0, 120)}`);
    return 0;
  }
  return rows.length;
}

async function sbUpdate(table, match, data) {
  const params = Object.entries(match).map(([k, v]) => `${k}=eq.${encodeURIComponent(v)}`).join('&');
  const res = await fetch(`${SUPABASE_URL}/rest/v1/${table}?${params}`, {
    method: 'PATCH',
    headers: sbHeaders(),
    body: JSON.stringify(data),
  });
  if (!res.ok) console.error(`Supabase PATCH error: ${res.status}`);
}

// ── Junk filter ───────────────────────────────────────────────────────────────

const JUNK_PATTERNS = [
  /^#/,                        // hashtag-only rows like "#James Bond Join"
  /join\s+(us|our|here)/i,    // "Join our channel"
  /t\.me\//i,                  // telegram links
  /subscribe/i,
  /^[\s\d.\-_]+$/,            // only numbers/punctuation
  /\.(pdf|txt|zip|rar|jpg|png|gif|webp)$/i,  // non-video files
  /pdf$/i,
  /forward/i,
];

function isJunk(title, fileName) {
  const text = (title + ' ' + (fileName || '')).trim();
  if (!text || text.length < 2) return true;
  for (const pat of JUNK_PATTERNS) {
    if (pat.test(text)) return true;
  }
  return false;
}

// ── Seed channels into DB ────────────────────────────────────────────────────

async function seedChannels() {
  const existing = await sbQuery('tg_channels', '?select=username');
  const existingSet = new Set(existing.map(c => c.username));

  const toInsert = SEED_CHANNELS
    .filter(s => !existingSet.has(s.username))
    .map(s => ({
      username: s.username,
      title: s.username,
      category: s.category,
      is_seed: true,
      is_active: true,
      trust_score: 0.5,
    }));

  if (toInsert.length > 0) {
    await sbUpsert('tg_channels', toInsert);
    console.log(`✅ Seeded ${toInsert.length} new channels into tg_channels`);
  } else {
    console.log(`ℹ️  All channels already seeded (${existingSet.size} existing)`);
  }
}

// ── Crawl one channel ────────────────────────────────────────────────────────

async function crawlChannel(channel) {
  const username = channel.username;
  let cursor = channel.last_msg_id || 0;
  let totalAdded = 0;
  let emptyPages = 0;

  process.stdout.write(`  @${username} `);

  for (let page = 0; page < maxPages; page++) {
    try {
      let url = `https://t.me/s/${username}`;
      if (cursor > 0) url += `?before=${cursor}`;

      const res = await fetch(url, { headers: { 'User-Agent': USER_AGENT } });
      if (!res.ok) {
        process.stdout.write(`[${res.status}] `);
        break;
      }

      const html = await res.text();
      const messages = parseTelegramHTML(html, username);

      if (messages.length === 0) {
        emptyPages++;
        if (emptyPages >= 2) break;
        continue;
      }
      emptyPages = 0;

      const rows = [];
      for (const msg of messages) {
        const info = parseFilename(msg.parseName);

        // Skip junk
        if (isJunk(info.title, msg.fileName)) continue;
        if (!info.title || info.title.length < 3) continue;

        rows.push({
          channel_username: username,
          msg_id: msg.id,
          title: info.title,
          title_normalized: info.titleNormalized,
          year: info.year,
          season: info.season,
          episode: info.episode,
          episode_end: info.episodeEnd,
          quality: info.quality,
          source_tag: info.sourceTag,
          platform_tag: info.platformTag,
          codec: info.codec,
          audio: info.audio,
          file_size_bytes: msg.fileSize || 0,
          file_name: msg.fileName || '',
          is_season_pack: info.isSeasonPack,
        });
      }

      if (rows.length > 0) {
        await sbUpsert('tg_media', rows);
        totalAdded += rows.length;
        process.stdout.write(`.`);
      }

      // Move cursor to oldest message
      const oldestId = Math.min(...messages.map(m => m.id));
      cursor = oldestId;

      await sleep(400); // rate limit
    } catch (err) {
      process.stdout.write(`[ERR] `);
      break;
    }
  }

  // Update cursor + timestamp
  await sbUpdate('tg_channels', { username }, {
    last_msg_id: cursor,
    last_crawled_at: new Date().toISOString(),
  });

  console.log(` → ${totalAdded} items`);
  return totalAdded;
}

// ── Main ─────────────────────────────────────────────────────────────────────

async function main() {
  console.log(`\n╔════════════════════════════════════════════════════╗`);
  console.log(`║  AtmosIndex Direct Crawl                           ║`);
  console.log(`║  Supabase: ${SUPABASE_URL.substring(8, 40).padEnd(40)}║`);
  console.log(`╚════════════════════════════════════════════════════╝\n`);

  // 1. Seed channels
  await seedChannels();

  // 2. Get channels to crawl (oldest-crawled-first)
  const allChannels = await sbQuery(
    'tg_channels',
    '?is_active=eq.true&order=last_crawled_at.asc.nullsfirst'
  );

  const toProcess = allChannels.slice(0, maxChannels);
  console.log(`\n📡 Crawling ${toProcess.length} channels (${maxPages} pages each):\n`);

  let grandTotal = 0;
  for (const ch of toProcess) {
    const count = await crawlChannel(ch);
    grandTotal += count;
    await sleep(500);
  }

  // 3. Report final state
  const mediaCount = await sbQuery('tg_media', '?select=id&limit=1&order=id.desc');
  console.log(`\n╔════════════════════════════════════════════════════╗`);
  console.log(`║  Crawl Complete                                    ║`);
  console.log(`║  New rows indexed this run: ${String(grandTotal).padEnd(22)}║`);
  console.log(`║  Total catalog size (approx): ${String(mediaCount[0]?.id || 0).padEnd(20)}║`);
  console.log(`╚════════════════════════════════════════════════════╝\n`);
}

main().catch(err => {
  console.error('Fatal:', err.message);
  process.exit(1);
});
