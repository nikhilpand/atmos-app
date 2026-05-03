/**
 * AtmosIndex — Telegram Content Discovery Engine
 *
 * • Crawls t.me/s/ pages anonymously (no login)
 * • Stores parsed media in Supabase PostgreSQL
 * • Provides search API with FTS + live fallback
 * • Manages seed channels + auto-discovery
 *
 * Env vars required:
 *   SUPABASE_URL      — e.g. https://xxx.supabase.co
 *   SUPABASE_ANON_KEY — public anon key
 */

import { parseFilename, normalize, parseTelegramHTML } from './parser.js';

// ── Seed channels — verified active public channels ─────────────────────────

const SEED_CHANNELS = [
  // Movies (English, high quality)
  { username: 'IMDbFilms', category: 'movies' },
  { username: 'WEB_x264', category: 'movies' },
  { username: 'MovieHubOfficials', category: 'movies' },
  { username: 'request_movies_bot_group', category: 'movies' },
  { username: 'Ikinopoisk', category: 'movies' },
  // Hindi / Bollywood
  { username: 'Aborek', category: 'bollywood' },
  { username: 'HDHub4u_Movies', category: 'bollywood' },
  { username: 'HindiDualAudio', category: 'bollywood' },
  // TV Series / Web Series
  { username: 'WebSeriesHDX', category: 'series' },
  { username: 'TVSeriesProMax', category: 'series' },
  { username: 'NetflixSeriesHD', category: 'series' },
  // Anime
  { username: 'Anime480pTo1080p', category: 'anime' },
  // HEVC / Compressed
  { username: 'HEVCx265', category: 'hevc' },
  { username: 'x265_HEVC_Movies', category: 'hevc' },
  // Dual Audio / Multi
  { username: 'MultiAudioMovies', category: 'dual' },
  // 4K / High quality
  { username: 'UHD4KMovies', category: '4k' },
];

const USER_AGENT =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36';

// ── Supabase REST helpers ───────────────────────────────────────────────────

function supabaseHeaders(env) {
  return {
    'apikey': env.SUPABASE_ANON_KEY,
    'Authorization': `Bearer ${env.SUPABASE_ANON_KEY}`,
    'Content-Type': 'application/json',
    'Prefer': 'resolution=merge-duplicates',
  };
}

async function supabaseQuery(env, table, params = '') {
  const url = `${env.SUPABASE_URL}/rest/v1/${table}${params}`;
  const res = await fetch(url, { headers: supabaseHeaders(env) });
  if (!res.ok) {
    const body = await res.text();
    console.error(`Supabase GET ${table} failed: ${res.status} ${body}`);
    return [];
  }
  return res.json();
}

async function supabaseUpsert(env, table, rows) {
  if (!rows.length) return;
  const url = `${env.SUPABASE_URL}/rest/v1/${table}`;
  const res = await fetch(url, {
    method: 'POST',
    headers: {
      ...supabaseHeaders(env),
      'Prefer': 'resolution=merge-duplicates',
    },
    body: JSON.stringify(rows),
  });
  if (!res.ok) {
    const body = await res.text();
    console.error(`Supabase UPSERT ${table} failed: ${res.status} ${body}`);
  }
}

async function supabaseUpdate(env, table, match, data) {
  const params = Object.entries(match)
    .map(([k, v]) => `${k}=eq.${encodeURIComponent(v)}`)
    .join('&');
  const url = `${env.SUPABASE_URL}/rest/v1/${table}?${params}`;
  const res = await fetch(url, {
    method: 'PATCH',
    headers: supabaseHeaders(env),
    body: JSON.stringify(data),
  });
  if (!res.ok) {
    console.error(`Supabase UPDATE ${table} failed: ${res.status}`);
  }
}

// ── Search API ──────────────────────────────────────────────────────────────

export async function handleSearch(url, env) {
  const title = url.searchParams.get('title') || '';
  const year = url.searchParams.get('year');
  const season = url.searchParams.get('s');
  const episode = url.searchParams.get('e');
  const quality = url.searchParams.get('quality');

  if (!title.trim()) {
    return json({ error: 'title param required', results: [] }, 400);
  }

  // Build FTS query: "breaking bad" → "breaking & bad"
  const ftsQuery = normalize(title).split(/\s+/).filter(Boolean).join(' & ');

  let queryParams = `?fts=ilike.%25${encodeURIComponent(normalize(title))}%25`;
  // Actually use proper FTS:
  queryParams = `?or=(title_normalized.ilike.*${encodeURIComponent(normalize(title))}*)`;
  queryParams += '&order=uploaded_at.desc';
  queryParams += '&limit=50';

  if (year) queryParams += `&year=eq.${year}`;
  if (season) queryParams += `&season=eq.${season}`;
  if (episode) queryParams += `&episode=eq.${episode}`;
  if (quality) queryParams += `&quality=eq.${quality}`;

  let results = await supabaseQuery(env, 'tg_media', queryParams);

  // Live fallback: if catalog has < 3 results, scrape t.me/s/ on-demand
  if (results.length < 3) {
    const liveResults = await liveScrapeSearch(title, year, season, episode);
    // Merge, dedupe by channel+msgId
    const seen = new Set(results.map(r => `${r.channel_username}:${r.msg_id}`));
    for (const r of liveResults) {
      const key = `${r.channel_username}:${r.msg_id}`;
      if (!seen.has(key)) {
        seen.add(key);
        results.push(r);
      }
    }
    // Background: index the live results into Supabase for future
    if (liveResults.length > 0) {
      const rows = liveResults.map(r => ({
        channel_username: r.channel_username,
        msg_id: r.msg_id,
        title: r.title,
        title_normalized: r.title_normalized,
        year: r.year,
        season: r.season,
        episode: r.episode,
        quality: r.quality,
        source_tag: r.source_tag,
        platform_tag: r.platform_tag,
        codec: r.codec,
        audio: r.audio,
        file_size_bytes: r.file_size_bytes,
        file_name: r.file_name,
        is_season_pack: r.is_season_pack,
      }));
      // Fire-and-forget upsert
      supabaseUpsert(env, 'tg_media', rows).catch(() => {});
    }
  }

  // Score and sort results
  results = scoreResults(results);

  return json({ results, total: results.length });
}

export async function handleSeasonSearch(url, env) {
  const title = url.searchParams.get('title') || '';
  const season = url.searchParams.get('s');

  if (!title.trim() || !season) {
    return json({ error: 'title and s params required', results: [] }, 400);
  }

  const norm = normalize(title);
  let queryParams = `?title_normalized=ilike.*${encodeURIComponent(norm)}*`;
  queryParams += `&season=eq.${season}`;
  queryParams += '&order=episode.asc';
  queryParams += '&limit=100';

  const results = await supabaseQuery(env, 'tg_media', queryParams);
  return json({ results, total: results.length });
}

export async function handleStats(env) {
  const channels = await supabaseQuery(env, 'tg_channels', '?select=id&limit=1000');
  const mediaCount = await supabaseQuery(
    env, 'tg_media', '?select=id&limit=1&order=id.desc'
  );
  return json({
    channels: channels.length,
    estimated_media: mediaCount[0]?.id || 0,
    seeds: SEED_CHANNELS.length,
  });
}

// ── Live fallback scraper ───────────────────────────────────────────────────

async function liveScrapeSearch(title, year, season, episode) {
  // Build search queries for t.me/s/ pages of seed channels
  const queries = buildSearchQueries(title, year, season, episode);
  const allResults = [];

  // Scrape top 5 seed channels with the first query
  const channels = SEED_CHANNELS.slice(0, 5);
  const promises = channels.map(async (ch) => {
    try {
      for (const query of queries.slice(0, 2)) {
        const searchUrl =
          `https://t.me/s/${ch.username}?q=${encodeURIComponent(query)}`;
        const res = await fetch(searchUrl, {
          headers: { 'User-Agent': USER_AGENT },
        });
        if (!res.ok) continue;
        const html = await res.text();
        const messages = parseTelegramHTML(html, ch.username);

        for (const msg of messages) {
          const info = parseFilename(msg.parseName);
          // Filter: must reasonably match the title
          if (!fuzzyMatch(normalize(title), info.titleNormalized)) continue;

          allResults.push({
            channel_username: ch.username,
            msg_id: msg.id,
            title: info.title,
            title_normalized: info.titleNormalized,
            year: info.year,
            season: info.season,
            episode: info.episode,
            quality: info.quality,
            source_tag: info.sourceTag,
            platform_tag: info.platformTag,
            codec: info.codec,
            audio: info.audio,
            file_size_bytes: msg.fileSize,
            file_name: msg.fileName,
            is_season_pack: info.isSeasonPack,
          });
        }
      }
    } catch (_) { /* skip failed channels */ }
  });

  await Promise.allSettled(promises);
  return allResults;
}

function buildSearchQueries(title, year, season, episode) {
  const base = title.trim();
  const queries = [base];
  if (year) queries.push(`${base} ${year}`);
  if (season && episode) {
    const s = String(season).padStart(2, '0');
    const e = String(episode).padStart(2, '0');
    queries.push(`${base} S${s}E${e}`);
    queries.push(`${base} Season ${season} Episode ${episode}`);
  }
  queries.push(`${base} 1080p`);
  queries.push(`${base} 720p`);
  return queries;
}

function fuzzyMatch(query, candidate) {
  if (!query || !candidate) return false;
  // All query words must appear in candidate
  const words = query.split(/\s+/);
  return words.every(w => candidate.includes(w));
}

// ── Crawler ─────────────────────────────────────────────────────────────────

export async function runCrawl(env) {
  console.log('[AtmosIndex] Cron crawl started');

  // 1. Ensure seed channels exist in DB
  await seedChannels(env);

  // 2. Get next channel to crawl (round-robin by last_crawled_at)
  const channels = await supabaseQuery(
    env,
    'tg_channels',
    '?is_active=eq.true&order=last_crawled_at.asc.nullsfirst&limit=3'
  );

  if (!channels.length) {
    console.log('[AtmosIndex] No channels to crawl');
    return;
  }

  let totalIndexed = 0;
  for (const ch of channels) {
    const count = await crawlChannel(ch, env);
    totalIndexed += count;
  }

  console.log(`[AtmosIndex] Crawl done. Indexed ${totalIndexed} new media items.`);
}

async function seedChannels(env) {
  const existing = await supabaseQuery(env, 'tg_channels', '?select=username');
  const existingSet = new Set(existing.map(c => c.username));

  const newChannels = SEED_CHANNELS
    .filter(s => !existingSet.has(s.username))
    .map(s => ({
      username: s.username,
      title: s.username,
      category: s.category,
      is_seed: true,
      is_active: true,
      trust_score: 0.5,
    }));

  if (newChannels.length > 0) {
    await supabaseUpsert(env, 'tg_channels', newChannels);
    console.log(`[AtmosIndex] Seeded ${newChannels.length} new channels`);
  }
}

async function crawlChannel(channel, env) {
  const username = channel.username;
  let cursor = channel.last_msg_id || 0;
  let totalAdded = 0;
  let emptyPages = 0;
  const MAX_PAGES = 10; // Per cron invocation per channel

  console.log(`[AtmosIndex] Crawling @${username} from msg ${cursor}`);

  for (let page = 0; page < MAX_PAGES; page++) {
    try {
      let url = `https://t.me/s/${username}`;
      if (cursor > 0) url += `?before=${cursor}`;

      const res = await fetch(url, {
        headers: { 'User-Agent': USER_AGENT },
      });

      if (!res.ok) {
        console.warn(`[AtmosIndex] @${username} returned ${res.status}`);
        break;
      }

      const html = await res.text();
      const messages = parseTelegramHTML(html, username);

      if (messages.length === 0) {
        emptyPages++;
        if (emptyPages >= 2) break; // No more content
        continue;
      }

      // Parse and prepare rows
      const rows = [];
      for (const msg of messages) {
        const info = parseFilename(msg.parseName);
        if (!info.title || info.title.length < 2) continue;

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
          file_size_bytes: msg.fileSize,
          file_name: msg.fileName || '',
          is_season_pack: info.isSeasonPack,
        });
      }

      if (rows.length > 0) {
        await supabaseUpsert(env, 'tg_media', rows);
        totalAdded += rows.length;
      }

      // Move cursor to oldest message on this page
      const oldestId = Math.min(...messages.map(m => m.id));
      cursor = oldestId;

      // Rate limit: small delay between pages
      await sleep(300);
    } catch (err) {
      console.error(`[AtmosIndex] Crawl error @${username}: ${err.message}`);
      break;
    }
  }

  // Update channel cursor
  await supabaseUpdate(env, 'tg_channels', { username }, {
    last_msg_id: cursor,
    last_crawled_at: new Date().toISOString(),
  });

  console.log(`[AtmosIndex] @${username}: ${totalAdded} items indexed`);
  return totalAdded;
}

// ── Result scoring ──────────────────────────────────────────────────────────

function scoreResults(results) {
  const QUALITY_SCORE = { '4K': 10, '1080p': 8, '720p': 5, '480p': 3, 'HD': 4 };
  const CODEC_SCORE = { 'HEVC': 10, 'AV1': 9, 'AVC': 6 };

  return results
    .map(r => ({
      ...r,
      _score:
        (QUALITY_SCORE[r.quality] || 3) * 3 +
        (CODEC_SCORE[r.codec] || 3) * 2 +
        (r.file_size_bytes > 500e6 && r.file_size_bytes < 5e9 ? 5 : 0) +
        (r.source_tag === 'WEB-DL' ? 3 : r.source_tag === 'BluRay' ? 5 : 0),
    }))
    .sort((a, b) => b._score - a._score);
}

// ── Helpers ─────────────────────────────────────────────────────────────────

function json(data, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      'Content-Type': 'application/json',
      'Access-Control-Allow-Origin': '*',
    },
  });
}

function sleep(ms) {
  return new Promise(r => setTimeout(r, ms));
}
