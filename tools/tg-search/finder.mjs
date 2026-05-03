/**
 * ═══════════════════════════════════════════════════════════════════════════════
 * ATMOS FINDER v2 — Instant Telegram File Discovery via Bot Network
 * ═══════════════════════════════════════════════════════════════════════════════
 *
 * Uses Telegram search bots (inline + direct) to find ANY file instantly.
 * No channel crawling. No guessing. Bots have already indexed millions of files.
 *
 * Strategy:
 *   1. Query multiple inline bots simultaneously (instant results)
 *   2. Query direct message bots (callback button results)
 *   3. Fallback to global MTProto search
 *   4. Deduplicate, parse, rank, display
 *
 * Usage:
 *   node finder.mjs "My Hero Academia" --season 1
 *   node finder.mjs "Inception 2010"
 *   node finder.mjs "Breaking Bad" --season 3 --quality 1080p
 */

import { TelegramClient, Api } from 'telegram';
import { StringSession } from 'telegram/sessions/index.js';
import { readFileSync, writeFileSync, existsSync } from 'fs';
import { parseFilename, normalize } from '../../cloudflare-worker/parser.js';

const SESSION_FILE = new URL('./session.txt', import.meta.url).pathname;
const CONFIG_FILE  = new URL('./config.json', import.meta.url).pathname;
const RESULTS_FILE = new URL('./last_results.json', import.meta.url).pathname;

const sleep = ms => new Promise(r => setTimeout(r, ms));

function connect() {
  const config = JSON.parse(readFileSync(CONFIG_FILE, 'utf-8'));
  const session = new StringSession(readFileSync(SESSION_FILE, 'utf-8').trim());
  return new TelegramClient(session, config.apiId, config.apiHash, { connectionRetries: 5 });
}

// ═══════════════════════════════════════════════════════════════════════════════
// INLINE BOTS — instant results, no messaging needed
// ═══════════════════════════════════════════════════════════════════════════════

const INLINE_BOTS = [
  'SearchMoviesBot',
  'TVSeriesSearchBot',
  'TGMovies3Bot',
  'SK_Movies1_bot',
  'Series_Movies_Search_Bot',
  'FilesSearchBot',
  'YourFindBot',
  'Movies_Series_Find_RoBot',
];

// Extra bots discovered per genre — tried in Phase 2 if Phase 1 yields < 5
const ANIME_BOTS = ['Anime4kaSearchBot'];
const MOVIE_BOTS = ['AiMovieMY_Bot', 'mr_robot_movies_bot'];

async function queryInlineBot(client, botUsername, query) {
  try {
    const bot = await client.getEntity(botUsername);
    const result = await client.invoke(new Api.messages.GetInlineBotResults({
      bot,
      peer: new Api.InputPeerSelf(),
      query,
      offset: '',
    }));

    const results = [];
    for (const r of (result.results || [])) {
      // Extract info from inline result
      const title = r.title || '';
      const description = r.description || '';
      const fullText = `${title} ${description}`;

      // Parse the title/description for metadata
      const parsed = parseFilename(description || title);

      // Extract size from description (e.g. "1.4 GB" or "534.0 MB")
      const sizeMatch = fullText.match(/([\d.]+)\s*(GB|MB|TB)/i);
      let sizeBytes = 0;
      if (sizeMatch) {
        const num = parseFloat(sizeMatch[1]);
        const unit = sizeMatch[2].toUpperCase();
        sizeBytes = unit === 'TB' ? num * 1e12 : unit === 'GB' ? num * 1e9 : num * 1e6;
      }

      // The inline result contains a document we can send
      const doc = r.document;
      const fileId = doc?.id ? String(doc.id.value ?? doc.id) : '';
      let fileName = '';
      if (doc) {
        for (const attr of (doc.attributes || [])) {
          if (attr.fileName) fileName = attr.fileName;
        }
      }

      results.push({
        fileName: fileName || description,
        title: parsed.title || title,
        description,
        sizeBytes: Math.round(sizeBytes),
        sizeMB: Math.round(sizeBytes / 1e6),
        fileId,
        botUsername,
        inlineResultId: r.id,
        season: parsed.season,
        episode: parsed.episode,
        quality: parsed.quality || (fullText.includes('1080p') ? '1080p' : fullText.includes('720p') ? '720p' : fullText.includes('480p') ? '480p' : fullText.includes('4K') ? '4K' : 'HD'),
        codec: parsed.codec || (fullText.includes('HEVC') || fullText.includes('h265') ? 'HEVC' : fullText.includes('h264') ? 'AVC' : ''),
        audio: parsed.audio || (fullText.includes('Dual') ? 'Dual' : ''),
        isSeasonPack: parsed.isSeasonPack || /complete|pack|all.ep/i.test(fullText),
        source: `@${botUsername}`,
        searchQuery: query,  // Preserve so --get can re-query
      });
    }

    return results;
  } catch (e) {
    return [];
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// DIRECT BOTS — send message, get button responses with files
// ═══════════════════════════════════════════════════════════════════════════════

const DIRECT_BOTS = [
  'cinemagic_hd_bot',
];

async function queryDirectBot(client, botUsername, query) {
  const results = [];
  try {
    const bot = await client.getEntity(botUsername);

    // Send query
    await client.sendMessage(bot, { message: query });
    await sleep(3000); // Wait for bot to respond

    // Get bot replies
    const hist = await client.invoke(new Api.messages.GetHistory({
      peer: bot, offsetId: 0, offsetDate: 0, addOffset: 0,
      limit: 10, maxId: 0, minId: 0, hash: BigInt(0),
    }));

    for (const msg of (hist.messages || [])) {
      // Skip our own messages
      if (msg.out) continue;

      const rows = msg.replyMarkup?.rows || [];
      if (rows.length === 0) continue;

      for (const row of rows) {
        for (const btn of row.buttons) {
          const text = btn.text || '';
          // Skip non-content buttons
          if (/language|back|close|cancel|join|group/i.test(text)) continue;

          // These are episode/file buttons
          const parsed = parseFilename(text);
          results.push({
            fileName: text,
            title: text,
            description: msg.message?.substring(0, 100) || '',
            sizeBytes: 0,
            sizeMB: 0,
            fileId: '',
            botUsername,
            buttonData: btn.data ? Buffer.from(btn.data).toString('base64') : '',
            season: parsed.season,
            episode: parsed.episode || extractEpisodeFromButton(text),
            quality: parsed.quality,
            codec: parsed.codec,
            audio: parsed.audio,
            isSeasonPack: false,
            source: `@${botUsername}`,
            searchQuery: query,
          });
        }
      }
    }
  } catch (e) {
    // Bot failed, skip
  }
  return results;
}

function extractEpisodeFromButton(text) {
  // "📼 1. Izuku Midoriya: Origin" → episode 1
  const m = text.match(/(\d+)\.\s/);
  return m ? parseInt(m[1]) : null;
}

// ═══════════════════════════════════════════════════════════════════════════════
// GLOBAL SEARCH — MTProto fallback for files bots miss
// ═══════════════════════════════════════════════════════════════════════════════

async function globalSearch(client, query) {
  const results = [];
  try {
    const result = await client.invoke(new Api.messages.SearchGlobal({
      q: query,
      filter: new Api.InputMessagesFilterDocument(),
      minDate: 0, maxDate: 0, offsetRate: 0,
      offsetPeer: new Api.InputPeerEmpty(),
      offsetId: 0, limit: 50,
    }));

    for (const msg of (result.messages || [])) {
      const doc = msg.media?.document;
      if (!doc) continue;

      let fileName = '';
      for (const attr of (doc.attributes || [])) {
        if (attr.fileName) fileName = attr.fileName;
      }

      const sizeBytes = Number(doc.size || 0);
      if (sizeBytes < 5 * 1024 * 1024) continue;

      const mime = doc.mimeType || '';
      if (mime.includes('pdf') || mime.includes('image')) continue;

      const parsed = parseFilename(fileName || msg.message || '');

      // Resolve source
      let source = '';
      const pid = msg.peerId;
      if (pid?.channelId) {
        const cid = String(pid.channelId?.value ?? pid.channelId);
        const ch = result.chats?.find(c => String(c.id?.value ?? c.id) === cid);
        source = ch?.username ? `@${ch.username}` : ch?.title || '';
      } else if (pid?.userId) {
        const uid = String(pid.userId?.value ?? pid.userId);
        const u = result.users?.find(u => String(u.id?.value ?? u.id) === uid);
        source = u?.username ? `@${u.username}` : '';
      }

      const fileId = doc.id ? String(doc.id.value ?? doc.id) : '';

      results.push({
        fileName,
        title: parsed.title,
        description: fileName,
        sizeBytes,
        sizeMB: Math.round(sizeBytes / 1e6),
        fileId,
        botUsername: '',
        messageId: msg.id,
        season: parsed.season,
        episode: parsed.episode,
        quality: parsed.quality,
        codec: parsed.codec,
        audio: parsed.audio,
        isSeasonPack: parsed.isSeasonPack,
        source,
        link: source.startsWith('@')
          ? `https://t.me/${source.slice(1)}/${msg.id}`
          : `tg://msg?id=${msg.id}`,
      });
    }
  } catch (e) {}
  return results;
}

// ═══════════════════════════════════════════════════════════════════════════════
// DEDUPLICATE & RANK
// ═══════════════════════════════════════════════════════════════════════════════

function deduplicateAndRank(allResults, title, seasonNum) {
  // Title relevance filter
  const normTitle = normalize(title);
  const titleWords = normTitle.split(/\s+/).filter(w => w.length > 1);

  let filtered = allResults.filter(r => {
    const text = [
      normalize(r.fileName || ''),
      normalize(r.title || ''),
      normalize(r.description || ''),
    ].join(' ');
    const matchCount = titleWords.filter(w => text.includes(w)).length;
    return matchCount >= titleWords.length * 0.4;
  });

  // Season filter
  if (seasonNum !== null) {
    filtered = filtered.filter(r => {
      if (r.season === null) return true; // Keep untagged
      return r.season === seasonNum;
    });
  }

  // Deduplicate by fileId
  const byFile = new Map();
  for (const r of filtered) {
    const key = r.fileId || `${r.fileName}:${r.sizeBytes}`;
    if (!byFile.has(key) || (r.sizeBytes > 0 && byFile.get(key).sizeBytes === 0)) {
      byFile.set(key, r);
    }
  }

  const unique = [...byFile.values()];

  // Quality ranking
  const qualRank = { '4K': 5, '1080p': 4, '720p': 3, '480p': 2, 'HD': 1, '360p': 0 };
  unique.sort((a, b) => {
    // Season packs first
    if (a.isSeasonPack !== b.isSeasonPack) return a.isSeasonPack ? -1 : 1;
    // Then by episode
    const epA = a.episode ?? 999;
    const epB = b.episode ?? 999;
    if (epA !== epB) return epA - epB;
    // Then by quality
    return (qualRank[b.quality] ?? 1) - (qualRank[a.quality] ?? 1);
  });

  return unique;
}

// ═══════════════════════════════════════════════════════════════════════════════
// CHANNEL DISCOVERY — fallback when bots return thin results
// ═══════════════════════════════════════════════════════════════════════════════

async function discoverAndSearchChannels(client, title, seasonNum) {
  const results = [];
  const queries = [
    title,
    `${title} season ${seasonNum || ''}`.trim(),
    `${title} 1080p`,
    `${title} all seasons`,
  ];

  const channelMap = new Map();
  for (const q of queries) {
    try {
      const r = await client.invoke(new Api.contacts.Search({ q, limit: 15 }));
      for (const ch of (r.chats || [])) {
        if (!ch.username) continue;
        const members = Number(ch.participantsCount || 0);
        if (!channelMap.has(ch.username) || members > channelMap.get(ch.username).members) {
          channelMap.set(ch.username, { username: ch.username, members });
        }
      }
    } catch (_) {}
    await sleep(200);
  }

  const channels = [...channelMap.values()].sort((a, b) => b.members - a.members).slice(0, 8);

  for (const ch of channels) {
    try {
      const entity = await client.getEntity(ch.username);
      const padSeason = seasonNum ? String(seasonNum).padStart(2, '0') : null;
      const searchQs = [''];
      if (padSeason) searchQs.push(`S${padSeason}`);

      const seenIds = new Set();
      for (const q of searchQs) {
        try {
          const searchResult = await client.invoke(new Api.messages.Search({
            peer: entity, q,
            filter: new Api.InputMessagesFilterDocument(),
            minDate: 0, maxDate: 0, offsetId: 0, addOffset: 0,
            limit: 50, maxId: 0, minId: 0, hash: BigInt(0),
          }));

          for (const msg of (searchResult.messages || [])) {
            if (seenIds.has(msg.id)) continue;
            seenIds.add(msg.id);

            const doc = msg.media?.document;
            if (!doc) continue;

            let fileName = '';
            for (const attr of (doc.attributes || [])) {
              if (attr.fileName) fileName = attr.fileName;
            }

            const sizeBytes = Number(doc.size || 0);
            if (sizeBytes < 5e6) continue;

            const mime = doc.mimeType || '';
            if (mime.includes('pdf') || mime.includes('image')) continue;
            const ext = (fileName.split('.').pop() || '').toLowerCase();
            if (['pdf', 'jpg', 'png', 'srt', 'ass', 'zip', 'rar', 'txt'].includes(ext)) continue;

            const parsed = parseFilename(fileName || msg.message || '');
            const normTitle = normalize(title);
            const searchText = normalize(fileName) + ' ' + normalize(msg.message || '');
            const titleWords = normTitle.split(/\s+/).filter(w => w.length > 1);
            const matchCount = titleWords.filter(w => searchText.includes(w)).length;
            if (matchCount < titleWords.length * 0.4) continue;

            if (seasonNum !== null && parsed.season !== null && parsed.season !== seasonNum) continue;

            const fileId = doc.id ? String(doc.id.value ?? doc.id) : '';

            results.push({
              fileName, title: parsed.title, description: fileName,
              sizeBytes, sizeMB: Math.round(sizeBytes / 1e6), fileId,
              botUsername: '', messageId: msg.id,
              season: parsed.season, episode: parsed.episode,
              quality: parsed.quality, codec: parsed.codec, audio: parsed.audio,
              isSeasonPack: parsed.isSeasonPack, source: `@${ch.username}`,
              link: `https://t.me/${ch.username}/${msg.id}`,
              searchQuery: title,
            });
          }
        } catch (_) {}
        await sleep(300);
      }
    } catch (_) {}
  }

  return results;
}

// ═══════════════════════════════════════════════════════════════════════════════
// SUPABASE INDEXING
// ═══════════════════════════════════════════════════════════════════════════════

async function indexToSupabase(results) {
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

  if (!vars.SUPABASE_URL || !vars.SUPABASE_ANON_KEY) {
    console.log('⚠️  Missing Supabase credentials in .dev.vars');
    return;
  }

  const rows = results.filter(r => r.fileName).map(r => ({
    channel_username: r.source?.replace('@', '') || r.botUsername || '',
    msg_id: r.messageId || 0,
    title: r.title || r.fileName,
    title_normalized: normalize(r.title || r.fileName),
    season: r.season,
    episode: r.episode,
    quality: r.quality,
    codec: r.codec,
    audio: r.audio,
    file_size_bytes: r.sizeBytes,
    file_name: r.fileName,
    is_season_pack: r.isSeasonPack || false,
  }));

  if (rows.length === 0) return;

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
    console.log(`\n✅ Indexed ${rows.length} results to Supabase catalog`);
  } else {
    const body = await resp.text();
    console.log(`⚠️  Supabase index failed: ${resp.status} ${body.substring(0, 100)}`);
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// DISPLAY
// ═══════════════════════════════════════════════════════════════════════════════

function display(results, title, seasonNum) {
  if (results.length === 0) {
    console.log('\n  ❌ No files found.\n');
    return;
  }

  const seasonLabel = seasonNum ? ` — Season ${seasonNum}` : '';
  console.log(`\n╔══════════════════════════════════════════════════════════════════╗`);
  console.log(`║  ${title}${seasonLabel}`.padEnd(66) + '║');
  console.log(`║  ${results.length} files found`.padEnd(66) + '║');
  console.log(`╚══════════════════════════════════════════════════════════════════╝\n`);

  // Season packs
  const packs = results.filter(r => r.isSeasonPack);
  if (packs.length > 0) {
    console.log('  📦 SEASON PACKS');
    for (const r of packs.slice(0, 5)) {
      const size = r.sizeBytes >= 1e9 ? `${(r.sizeBytes / 1e9).toFixed(1)}GB` : r.sizeBytes > 0 ? `${r.sizeMB}MB` : '?';
      console.log(`    ${(r.quality || 'HD').padEnd(6)} ${r.codec || ''} ${r.audio ? `[${r.audio}]` : ''} | ${size.padStart(7)} | ${r.source}`);
      console.log(`      ${r.fileName?.substring(0, 65) || r.description?.substring(0, 65)}`);
    }
    console.log('');
  }

  // Episodes
  const episodes = results.filter(r => r.episode !== null && !r.isSeasonPack);
  if (episodes.length > 0) {
    const grouped = new Map();
    for (const r of episodes) {
      const key = r.episode;
      if (!grouped.has(key)) grouped.set(key, []);
      grouped.get(key).push(r);
    }

    const epNums = [...grouped.keys()].sort((a, b) => a - b);
    console.log(`  📺 EPISODES (${epNums.length} found)`);
    for (const ep of epNums) {
      const files = grouped.get(ep);
      const best = files[0];
      const size = best.sizeBytes >= 1e9 ? `${(best.sizeBytes / 1e9).toFixed(1)}GB` : best.sizeBytes > 0 ? `${best.sizeMB}MB` : '?';
      const qual = (best.quality || 'HD').padEnd(6);
      const extras = files.length > 1 ? ` (+${files.length - 1} more)` : '';
      console.log(`    E${String(ep).padStart(2, '0')} │ ${qual} │ ${size.padStart(7)} │ ${best.source}${extras}`);
    }
    console.log('');
  }

  // Standalone
  const standalone = results.filter(r => r.episode === null && !r.isSeasonPack);
  if (standalone.length > 0) {
    console.log('  🎬 FILES');
    for (const r of standalone.slice(0, 10)) {
      const size = r.sizeBytes >= 1e9 ? `${(r.sizeBytes / 1e9).toFixed(1)}GB` : r.sizeBytes > 0 ? `${r.sizeMB}MB` : '?';
      const name = (r.fileName || r.description || r.title || '').substring(0, 55);
      console.log(`    ${(r.quality || 'HD').padEnd(6)} │ ${size.padStart(7)} │ ${name}`);
      console.log(`    ${''.padEnd(6)} │ ${''.padStart(7)} │ ${r.source}`);
    }
    console.log('');
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// MAIN
// ═══════════════════════════════════════════════════════════════════════════════

async function main() {
  const args = process.argv.slice(2);

  if (args.length === 0 || args.includes('--help')) {
    console.log(`
╔═══════════════════════════════════════════════════════════════╗
║  ATMOS FINDER v2 — Instant search via bot network            ║
╚═══════════════════════════════════════════════════════════════╝

  node finder.mjs "My Hero Academia" --season 1
  node finder.mjs "Inception 2010"
  node finder.mjs "Breaking Bad" --season 3
  node finder.mjs "Avengers Endgame" --quality 4K

  # Download to Saved Messages:
  node finder.mjs --get 3                 # get result #3 from last search
  node finder.mjs --get-all               # get ALL episodes from last search
`);
    return;
  }

  // Parse args
  const flagArgs = new Set();
  const positional = [];
  for (let i = 0; i < args.length; i++) {
    if (args[i] === '--season' || args[i] === '--quality') {
      flagArgs.add(args[i]);
      flagArgs.add(args[i + 1]);
      i++;
    } else if (args[i] === '--get') {
      flagArgs.add(args[i]);
      flagArgs.add(args[i + 1]);
      i++;
    } else if (args[i].startsWith('--')) {
      flagArgs.add(args[i]);
    } else {
      positional.push(args[i]);
    }
  }

  const client = connect();
  await client.connect();

  // ── GET command: send file to Saved Messages ──
  if (args.includes('--get-all') || args.includes('--get')) {
    const lastResults = JSON.parse(readFileSync(RESULTS_FILE, 'utf-8'));

    if (args.includes('--get-all')) {
      // Send all episode files to Saved Messages
      const episodes = lastResults.filter(r => r.episode !== null && !r.isSeasonPack);
      const bestPerEp = new Map();
      for (const r of episodes) {
        if (!bestPerEp.has(r.episode) && r.inlineResultId && r.botUsername) {
          bestPerEp.set(r.episode, r);
        }
      }

      console.log(`\n📥 Sending ${bestPerEp.size} episodes to Saved Messages...\n`);
      for (const [ep, r] of [...bestPerEp.entries()].sort((a, b) => a[0] - b[0])) {
        try {
          const bot = await client.getEntity(r.botUsername);
          const inlineResult = await client.invoke(new Api.messages.GetInlineBotResults({
            bot, peer: new Api.InputPeerSelf(),
            query: r.searchQuery || r.fileName || r.description || '',
            offset: '',
          }));

          // Match by ID first, then by description, then first result
          let match = inlineResult.results?.find(ir => ir.id === r.inlineResultId);
          if (!match && r.description) {
            const targetDesc = normalize(r.description).substring(0, 30);
            match = inlineResult.results?.find(ir =>
              normalize(ir.description || '').includes(targetDesc)
            );
          }
          if (!match && inlineResult.results?.length > 0) {
            match = inlineResult.results[0];
          }
          if (match) {
            await client.invoke(new Api.messages.SendInlineBotResult({
              peer: new Api.InputPeerSelf(),
              queryId: inlineResult.queryId,
              id: match.id,
              randomId: BigInt(Math.floor(Math.random() * 1e18)),
            }));
            console.log(`  ✅ E${String(ep).padStart(2, '0')} → Saved Messages`);
          } else {
            console.log(`  ⚠️  E${String(ep).padStart(2, '0')}: no match found`);
          }
        } catch (e) {
          console.log(`  ❌ E${String(ep).padStart(2, '0')}: ${e.message.substring(0, 50)}`);
        }
        await sleep(1000);
      }
      console.log('\n📱 Open Telegram → Saved Messages to download\n');

    } else {
      // Send specific result by index
      const idx = parseInt(args[args.indexOf('--get') + 1]) - 1;
      const r = lastResults[idx];
      if (!r) { console.error('Invalid index'); process.exit(1); }

      console.log(`\n📥 Sending: ${r.fileName?.substring(0, 60) || r.description?.substring(0, 60)}`);

      if (r.botUsername) {
        const bot = await client.getEntity(r.botUsername);
        const inlineResult = await client.invoke(new Api.messages.GetInlineBotResults({
          bot, peer: new Api.InputPeerSelf(),
          query: r.searchQuery || r.fileName || r.description || '',
          offset: '',
        }));

        // Match by ID first, then by description fuzzy match
        let match = inlineResult.results?.find(ir => ir.id === r.inlineResultId);
        if (!match && r.description) {
          const targetDesc = normalize(r.description).substring(0, 30);
          match = inlineResult.results?.find(ir =>
            normalize(ir.description || '').includes(targetDesc)
          );
        }
        if (!match && inlineResult.results?.length > 0) {
          // Last resort: just send the first result
          match = inlineResult.results[0];
        }

        if (match) {
          await client.invoke(new Api.messages.SendInlineBotResult({
            peer: new Api.InputPeerSelf(),
            queryId: inlineResult.queryId,
            id: match.id,
            randomId: BigInt(Math.floor(Math.random() * 1e18)),
          }));
          console.log('✅ Sent to Saved Messages — open Telegram to download\n');
        } else {
          console.log('❌ Could not find matching file from bot\n');
        }
      } else if (r.link) {
        console.log(`📎 Direct link: ${r.link}\n`);
      } else {
        console.log('❌ No downloadable link for this result\n');
      }
    }

    await client.disconnect();
    return;
  }

  // ── SEARCH ──
  const title = positional.join(' ');
  const seasonIdx = args.indexOf('--season');
  const seasonNum = seasonIdx !== -1 ? parseInt(args[seasonIdx + 1]) : null;
  const qualIdx = args.indexOf('--quality');
  const qualityFilter = qualIdx !== -1 ? args[qualIdx + 1] : null;

  if (!title) {
    console.error('Usage: node finder.mjs "Title" [--season N] [--quality 1080p]');
    process.exit(1);
  }

  const searchQuery = seasonNum
    ? `${title} S${String(seasonNum).padStart(2, '0')}`
    : title;

  console.log(`\n🔍 "${title}"${seasonNum ? ` Season ${seasonNum}` : ''}${qualityFilter ? ` [${qualityFilter}]` : ''}\n`);

  let allResults = [];

  // ── Phase 1: Inline bots (instant) ──
  console.log(`  ⚡ Querying ${INLINE_BOTS.length} inline bots...`);
  const inlinePromises = INLINE_BOTS.map(async bot => {
    const r = await queryInlineBot(client, bot, searchQuery);
    if (r.length > 0) process.stdout.write(`    @${bot}: ${r.length} results\n`);
    return r;
  });

  // Also try broader query
  const broadPromises = INLINE_BOTS.slice(0, 3).map(async bot => {
    const r = await queryInlineBot(client, bot, title);
    return r;
  });

  const inlineResults = (await Promise.all([...inlinePromises, ...broadPromises])).flat();
  console.log(`    Total: ${inlineResults.length} inline results`);
  allResults.push(...inlineResults);

  // ── Phase 1.5: Genre-specific bots if results are thin ──
  if (inlineResults.length < 10) {
    const isAnime = /anime|hero|naruto|one piece|dragon ball|jujutsu|demon slayer|attack on titan/i.test(title);
    const extraBots = isAnime ? ANIME_BOTS : MOVIE_BOTS;
    console.log(`  🎯 Trying ${extraBots.length} genre-specific bots...`);
    const extraPromises = extraBots.map(async bot => {
      const r = await queryInlineBot(client, bot, searchQuery);
      if (r.length > 0) console.log(`    @${bot}: ${r.length} results`);
      return r;
    });
    const extraResults = (await Promise.all(extraPromises)).flat();
    allResults.push(...extraResults);
  }

  // ── Phase 2: Direct bots (callback buttons) ──
  console.log(`\n  🤖 Querying ${DIRECT_BOTS.length} direct bots...`);
  for (const bot of DIRECT_BOTS) {
    const r = await queryDirectBot(client, bot, seasonNum
      ? `${title} Season ${seasonNum}`
      : title);
    if (r.length > 0) console.log(`    @${bot}: ${r.length} results`);
    allResults.push(...r);
  }

  // ── Phase 2.5: Channel discovery (if bot results are thin) ──
  if (allResults.length < 10) {
    console.log('\n  📡 Discovering channels...');
    const channelResults = await discoverAndSearchChannels(client, title, seasonNum);
    if (channelResults.length > 0) {
      console.log(`    Found ${channelResults.length} files from channels`);
      allResults.push(...channelResults);
    }
  }

  // ── Phase 3: Global MTProto search ──
  process.stdout.write('  🌐 Global search...');
  const globalResults = await globalSearch(client, searchQuery);
  console.log(` ${globalResults.length} results`);
  allResults.push(...globalResults);

  // ── Phase 4: Deduplicate & rank ──
  const final = deduplicateAndRank(allResults, title, seasonNum);

  // Quality filter
  const displayed = qualityFilter
    ? final.filter(r => r.quality === qualityFilter)
    : final;

  // ── Display ──
  display(displayed, title, seasonNum);

  // Save
  writeFileSync(RESULTS_FILE, JSON.stringify(final, null, 2));
  console.log(`💾 ${final.length} results → last_results.json`);

  // --index: push to Supabase
  if (args.includes('--index')) {
    await indexToSupabase(final);
  }

  // --json: output raw JSON for API
  if (args.includes('--json')) {
    console.log(JSON.stringify(final, null, 2));
  } else {
    console.log(`\n💡 To download: node finder.mjs --get 1        (get result #1)`);
    console.log(`                node finder.mjs --get-all      (get all episodes)`);
    console.log(`                node finder.mjs --index ...     (save to Supabase)\n`);
  }

  await client.disconnect();
}

main().catch(err => {
  console.error('Fatal:', err.message);
  process.exit(1);
});
