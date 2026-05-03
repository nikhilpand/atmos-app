/**
 * ═══════════════════════════════════════════════════════════════════════════════
 * tg-search: Master Telegram File Finder
 * ═══════════════════════════════════════════════════════════════════════════════
 *
 * Uses Telegram MTProto API (same as the Telegram app) to search across
 * ALL public channels globally. Not limited to a predefined channel list.
 *
 * Usage:
 *   node search.mjs "Game of Thrones S01E01"          # search globally
 *   node search.mjs --season "Game of Thrones" 1      # full season
 *   node search.mjs --channel "@channelname" "query"  # search specific channel
 *   node search.mjs --index "Game of Thrones" 1       # index season → Supabase
 *
 * First run: node auth.mjs (one-time phone login)
 */

import { TelegramClient, Api } from 'telegram';
import { StringSession } from 'telegram/sessions/index.js';
import { readFileSync, existsSync, writeFileSync } from 'fs';
import { parseFilename, normalize } from '../../cloudflare-worker/parser.js';

// ── Config ──────────────────────────────────────────────────────────────────

const SESSION_FILE = new URL('./session.txt', import.meta.url).pathname;
const CONFIG_FILE  = new URL('./config.json', import.meta.url).pathname;
const RESULTS_FILE = new URL('./last_results.json', import.meta.url).pathname;

const MIN_FILE_SIZE = 50 * 1024 * 1024;  // 50 MB min for movies
const MAX_RESULTS   = 100;

// ── Client setup ────────────────────────────────────────────────────────────

function loadClient() {
  if (!existsSync(CONFIG_FILE) || !existsSync(SESSION_FILE)) {
    console.error('❌ Not authenticated. Run: node auth.mjs');
    process.exit(1);
  }
  const config = JSON.parse(readFileSync(CONFIG_FILE, 'utf-8'));
  const session = new StringSession(readFileSync(SESSION_FILE, 'utf-8').trim());
  return new TelegramClient(session, config.apiId, config.apiHash, {
    connectionRetries: 5,
  });
}

// ── Global Search ───────────────────────────────────────────────────────────

/**
 * Search across ALL public Telegram channels for files matching a query.
 * This is the same API the Telegram app uses when you search in "Channels" tab.
 */
async function globalSearch(client, query, opts = {}) {
  const {
    limit = MAX_RESULTS,
    minSize = MIN_FILE_SIZE,
    filterType = 'document', // 'document' | 'video' | 'all'
  } = opts;

  console.log(`\n🔍 Global search: "${query}" (min ${Math.round(minSize / 1e6)}MB)\n`);

  const filter = filterType === 'video'
    ? new Api.InputMessagesFilterVideo()
    : filterType === 'all'
      ? new Api.InputMessagesFilterEmpty()
      : new Api.InputMessagesFilterDocument();

  const allResults = [];
  let offsetId = 0;
  let offsetPeer = new Api.InputPeerEmpty();
  let offsetRate = 0;
  let page = 0;

  while (allResults.length < limit && page < 10) {
    page++;
    try {
      const result = await client.invoke(
        new Api.messages.SearchGlobal({
          q: query,
          filter,
          minDate: 0,
          maxDate: 0,
          offsetRate,
          offsetPeer,
          offsetId,
          limit: Math.min(50, limit - allResults.length),
        })
      );

      if (!result.messages || result.messages.length === 0) break;

      for (const msg of result.messages) {
        const file = extractFileInfo(msg, result);
        if (!file) continue;
        if (file.sizeBytes < minSize) continue;

        // Parse filename first, fall back to caption
        const parsedFn = parseFilename(file.fileName || '');
        const parsedCap = file.caption ? parseFilename(file.caption) : null;
        // Use whichever has a better title
        const parsed = (parsedFn.title && parsedFn.title.length > 3) ? parsedFn 
          : (parsedCap && parsedCap.title.length > parsedFn.title.length) ? parsedCap 
          : parsedFn;
        
        allResults.push({
          // File metadata
          fileName: file.fileName,
          caption: file.caption,
          sizeBytes: file.sizeBytes,
          sizeMB: Math.round(file.sizeBytes / 1e6),
          sizeGB: (file.sizeBytes / 1e9).toFixed(2),
          mimeType: file.mimeType,

          // Channel info
          channelTitle: file.channelTitle,
          channelUsername: file.channelUsername,
          channelId: file.channelId,
          messageId: msg.id,
          date: new Date(msg.date * 1000).toISOString(),

          // Parsed info (from best source)
          title: parsed.title,
          year: parsed.year,
          season: parsed.season || parsedFn.season,
          episode: parsed.episode || parsedFn.episode,
          quality: parsed.quality !== 'HD' ? parsed.quality : parsedFn.quality,
          codec: parsed.codec || parsedFn.codec,
          sourceTag: parsed.sourceTag || parsedFn.sourceTag,
          audio: parsed.audio || parsedFn.audio,
          isSeasonPack: parsed.isSeasonPack || parsedFn.isSeasonPack,

          // Download links
          telegramLink: file.channelUsername
            ? `https://t.me/${file.channelUsername}/${msg.id}`
            : `tg://privatepost?channel=${file.channelId}&post=${msg.id}`,
          deepLink: file.channelUsername 
            ? `tg://resolve?domain=${file.channelUsername}&post=${msg.id}`
            : `tg://privatepost?channel=${file.channelId}&post=${msg.id}`,
        });
      }

      // Update pagination cursor
      const lastMsg = result.messages[result.messages.length - 1];
      offsetId = lastMsg.id;
      offsetRate = result.nextRate || 0;

      // Resolve the peer of the last message for pagination
      if (lastMsg.peerId?.channelId) {
        const chat = result.chats?.find(c => 
          c.id?.value === lastMsg.peerId.channelId?.value ||
          c.id === lastMsg.peerId.channelId
        );
        if (chat) {
          offsetPeer = new Api.InputPeerChannel({
            channelId: chat.id,
            accessHash: chat.accessHash,
          });
        }
      }

      process.stdout.write(`  Page ${page}: found ${result.messages.length} messages (${allResults.length} total matches)\r`);
    } catch (err) {
      console.error(`\n  Page ${page} error: ${err.message}`);
      if (err.message.includes('FLOOD')) {
        console.log('  ⏳ Rate limited. Waiting 10s...');
        await sleep(10000);
        continue;
      }
      break;
    }

    await sleep(500); // Rate limit respect
  }

  console.log(`\n\n📦 Found ${allResults.length} files\n`);
  return allResults;
}

// ── Season Search ───────────────────────────────────────────────────────────

/**
 * Search for all episodes of a specific season.
 * Runs multiple targeted queries to maximize coverage.
 */
async function seasonSearch(client, title, seasonNum) {
  const padSeason = String(seasonNum).padStart(2, '0');
  
  // Multi-query strategy to catch all naming formats
  const queries = [
    `${title} S${padSeason}`,
    `${title} Season ${seasonNum}`,
    `${title} S${padSeason}E`,
    `${title} ${seasonNum}x`,
  ];

  console.log(`\n🎬 Season search: "${title}" Season ${seasonNum}`);
  console.log(`   Running ${queries.length} query variants...\n`);

  const seen = new Set();
  const allResults = [];

  for (const q of queries) {
    const results = await globalSearch(client, q, { limit: 50, minSize: 20 * 1024 * 1024 });
    
    for (const r of results) {
      const key = `${r.channelUsername || r.channelId}:${r.messageId}`;
      if (seen.has(key)) continue;
      seen.add(key);

      // Filter: must match the season
      if (r.season !== null && r.season !== seasonNum) continue;
      
      // Fuzzy title match — check against fileName, title, AND caption
      const normTitle = normalize(title);
      const candidates = [
        normalize(r.title || ''),
        normalize(r.fileName || ''),
        normalize(r.caption || ''),
      ].join(' ');
      
      const titleWords = normTitle.split(/\s+/);
      const matches = titleWords.filter(w => candidates.includes(w));
      if (matches.length < titleWords.length * 0.5) continue; // relaxed: 50% match

      allResults.push(r);
    }
  }

  // Sort by episode number
  allResults.sort((a, b) => (a.episode || 999) - (b.episode || 999));

  // Group by episode
  const episodes = {};
  for (const r of allResults) {
    const ep = r.episode || (r.isSeasonPack ? 'PACK' : 'unknown');
    if (!episodes[ep]) episodes[ep] = [];
    episodes[ep].push(r);
  }

  return { episodes, allResults };
}

// ── Channel Search ──────────────────────────────────────────────────────────

/**
 * Search within a specific channel.
 */
async function channelSearch(client, channelUsername, query) {
  const username = channelUsername.replace('@', '');
  
  console.log(`\n🔍 Searching @${username} for "${query}"\n`);

  const entity = await client.getEntity(username);
  
  const result = await client.invoke(
    new Api.messages.Search({
      peer: entity,
      q: query,
      filter: new Api.InputMessagesFilterDocument(),
      minDate: 0,
      maxDate: 0,
      offsetId: 0,
      addOffset: 0,
      limit: 100,
      maxId: 0,
      minId: 0,
      hash: BigInt(0),
    })
  );

  const results = [];
  for (const msg of (result.messages || [])) {
    const file = extractFileInfo(msg, result);
    if (!file) continue;

    const parsed = parseFilename(file.fileName || file.caption || '');
    results.push({
      fileName: file.fileName,
      sizeBytes: file.sizeBytes,
      sizeMB: Math.round(file.sizeBytes / 1e6),
      messageId: msg.id,
      channelUsername: username,
      title: parsed.title,
      quality: parsed.quality,
      season: parsed.season,
      episode: parsed.episode,
      codec: parsed.codec,
      telegramLink: `https://t.me/${username}/${msg.id}`,
    });
  }

  return results;
}

// ── Helpers ─────────────────────────────────────────────────────────────────

function extractFileInfo(msg, result) {
  const media = msg.media;
  if (!media) return null;

  let fileName = '', sizeBytes = 0, mimeType = '';

  if (media.document) {
    const doc = media.document;
    sizeBytes = Number(doc.size || 0);
    mimeType = doc.mimeType || '';
    
    // Get filename from attributes
    for (const attr of (doc.attributes || [])) {
      if (attr.fileName) fileName = attr.fileName;
    }
  } else if (media.video) {
    sizeBytes = Number(media.video.size || 0);
    mimeType = media.video.mimeType || 'video/mp4';
  } else {
    return null;
  }

  // Get channel info — handle BigInt comparison
  let channelTitle = '', channelUsername = '', channelId = '';
  if (msg.peerId?.channelId) {
    const peerChannelId = String(msg.peerId.channelId?.value ?? msg.peerId.channelId);
    channelId = peerChannelId;
    
    const chat = result.chats?.find(c => {
      const cid = String(c.id?.value ?? c.id);
      return cid === peerChannelId;
    });
    if (chat) {
      channelTitle = chat.title || '';
      channelUsername = chat.username || '';
    }
  } else if (msg.peerId?.userId) {
    // Files from bots/users (e.g. @uploadtogdrivebot)
    const peerUserId = String(msg.peerId.userId?.value ?? msg.peerId.userId);
    channelId = peerUserId;
    
    const user = result.users?.find(u => {
      const uid = String(u.id?.value ?? u.id);
      return uid === peerUserId;
    });
    if (user) {
      channelTitle = [user.firstName, user.lastName].filter(Boolean).join(' ') || '';
      channelUsername = user.username || '';
    }
  }

  // Get caption
  const caption = msg.message || '';

  return { fileName, sizeBytes, mimeType, channelTitle, channelUsername, channelId, caption };
}

function formatSize(bytes) {
  if (bytes >= 1e9) return `${(bytes / 1e9).toFixed(2)} GB`;
  return `${Math.round(bytes / 1e6)} MB`;
}

function sleep(ms) {
  return new Promise(r => setTimeout(r, ms));
}

// ── Display ─────────────────────────────────────────────────────────────────

function displayResults(results) {
  if (results.length === 0) {
    console.log('  No results found.\n');
    return;
  }

  console.log('┌─────┬──────────────────────────────────────────────┬──────────┬─────────┬───────┬──────────────────────────┐');
  console.log('│  #  │ File Name                                    │ Quality  │  Size   │ Codec │ Channel                  │');
  console.log('├─────┼──────────────────────────────────────────────┼──────────┼─────────┼───────┼──────────────────────────┤');

  results.forEach((r, i) => {
    const num = String(i + 1).padStart(3);
    const name = (r.fileName || r.title || '').substring(0, 44).padEnd(44);
    const qual = (r.quality || 'HD').padEnd(8);
    const size = formatSize(r.sizeBytes).padStart(7);
    const codec = (r.codec || '').padEnd(5);
    const ch = ('@' + (r.channelUsername || '?')).substring(0, 24).padEnd(24);
    console.log(`│ ${num} │ ${name} │ ${qual} │ ${size} │ ${codec} │ ${ch} │`);
  });

  console.log('└─────┴──────────────────────────────────────────────┴──────────┴─────────┴───────┴──────────────────────────┘');
  console.log('');
}

function displaySeason(seasonData, title, seasonNum) {
  const { episodes, allResults } = seasonData;
  const epKeys = Object.keys(episodes).sort((a, b) => {
    if (a === 'PACK') return -1;
    if (b === 'PACK') return 1;
    return Number(a) - Number(b);
  });

  console.log(`\n╔══════════════════════════════════════════════════════════════╗`);
  console.log(`║  ${title} — Season ${seasonNum}`.padEnd(62) + '║');
  console.log(`║  ${allResults.length} files found across ${epKeys.length} episodes`.padEnd(62) + '║');
  console.log(`╚══════════════════════════════════════════════════════════════╝\n`);

  for (const ep of epKeys) {
    const files = episodes[ep];
    const label = ep === 'PACK' ? '📦 SEASON PACK' : ep === 'unknown' ? '❓ Unknown Episode' : `📺 Episode ${ep}`;
    console.log(`  ${label} (${files.length} sources)`);
    
    for (const f of files) {
      const size = formatSize(f.sizeBytes);
      const qual = f.quality || 'HD';
      const codec = f.codec ? ` ${f.codec}` : '';
      const audio = f.audio ? ` ${f.audio}` : '';
      console.log(`    ${qual}${codec}${audio} │ ${size} │ @${f.channelUsername || '?'} │ ${f.telegramLink}`);
    }
    console.log('');
  }
}

// ── Index to Supabase ───────────────────────────────────────────────────────

async function indexToSupabase(results) {
  // Read supabase config from worker's .dev.vars
  const devVarsPath = new URL('../../cloudflare-worker/.dev.vars', import.meta.url).pathname;
  if (!existsSync(devVarsPath)) {
    console.log('⚠️  No .dev.vars found — skipping Supabase indexing');
    return;
  }

  const vars = {};
  readFileSync(devVarsPath, 'utf-8').split('\n').forEach(line => {
    const [k, ...v] = line.split('=');
    if (k && v.length) vars[k.trim()] = v.join('=').trim();
  });

  if (!vars.SUPABASE_URL || !vars.SUPABASE_ANON_KEY) return;

  const rows = results.map(r => ({
    channel_username: r.channelUsername,
    msg_id: r.messageId,
    title: r.title || r.fileName,
    title_normalized: normalize(r.title || r.fileName),
    year: r.year,
    season: r.season,
    episode: r.episode,
    quality: r.quality,
    source_tag: r.sourceTag,
    codec: r.codec,
    audio: r.audio,
    file_size_bytes: r.sizeBytes,
    file_name: r.fileName,
    is_season_pack: r.isSeasonPack || false,
  }));

  const resp = await fetch(`${vars.SUPABASE_URL}/rest/v1/tg_media`, {
    method: 'POST',
    headers: {
      'apikey': vars.SUPABASE_ANON_KEY,
      'Authorization': `Bearer ${vars.SUPABASE_ANON_KEY}`,
      'Content-Type': 'application/json',
      'Prefer': 'resolution=merge-duplicates',
    },
    body: JSON.stringify(rows),
  });

  if (resp.ok) {
    console.log(`✅ Indexed ${rows.length} results to Supabase catalog`);
  } else {
    console.log(`⚠️  Supabase index failed: ${resp.status}`);
  }
}

// ── CLI ─────────────────────────────────────────────────────────────────────

async function main() {
  const args = process.argv.slice(2);
  
  if (args.length === 0 || args[0] === '--help') {
    console.log(`
╔══════════════════════════════════════════════════════════════╗
║              tg-search — Master Telegram File Finder         ║
╚══════════════════════════════════════════════════════════════╝

Usage:
  node search.mjs "Inception 2010"                  # global search
  node search.mjs "Inception 2010" --min-size 500   # min size in MB
  node search.mjs --season "Game of Thrones" 1      # full season
  node search.mjs --channel @channelname "query"    # channel-specific
  node search.mjs --index "Breaking Bad" 1          # season → Supabase

First run: node auth.mjs
`);
    return;
  }

  const client = loadClient();
  await client.connect();
  console.log('✅ Connected to Telegram\n');

  try {
    if (args[0] === '--season') {
      // Season search
      const title = args[1];
      const season = parseInt(args[2]);
      if (!title || isNaN(season)) {
        console.error('Usage: node search.mjs --season "Title" SEASON_NUM');
        return;
      }
      
      const data = await seasonSearch(client, title, season);
      displaySeason(data, title, season);

      // Save results
      writeFileSync(RESULTS_FILE, JSON.stringify(data.allResults, null, 2));
      console.log(`Results saved to last_results.json`);

    } else if (args[0] === '--index') {
      // Season search + index to Supabase
      const title = args[1];
      const season = parseInt(args[2]);
      if (!title || isNaN(season)) {
        console.error('Usage: node search.mjs --index "Title" SEASON_NUM');
        return;
      }

      const data = await seasonSearch(client, title, season);
      displaySeason(data, title, season);
      await indexToSupabase(data.allResults);

      writeFileSync(RESULTS_FILE, JSON.stringify(data.allResults, null, 2));

    } else if (args[0] === '--channel') {
      // Channel-specific search
      const channel = args[1];
      const query = args.slice(2).join(' ');
      if (!channel || !query) {
        console.error('Usage: node search.mjs --channel @username "query"');
        return;
      }

      const results = await channelSearch(client, channel, query);
      displayResults(results);
      writeFileSync(RESULTS_FILE, JSON.stringify(results, null, 2));

    } else {
      // Global search
      const query = args.filter(a => !a.startsWith('--')).join(' ');
      const minSizeArg = args.indexOf('--min-size');
      const minSize = minSizeArg !== -1 ? parseInt(args[minSizeArg + 1]) * 1e6 : MIN_FILE_SIZE;

      const results = await globalSearch(client, query, { minSize });
      displayResults(results);

      writeFileSync(RESULTS_FILE, JSON.stringify(results, null, 2));
      console.log(`Results saved to last_results.json`);
    }
  } finally {
    await client.disconnect();
  }
}

main().catch(err => {
  console.error('Fatal:', err.message);
  process.exit(1);
});
