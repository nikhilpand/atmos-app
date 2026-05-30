/**
 * Atmos Cloudflare Worker v2
 *
 * Engines:
 *   1. Stream Extraction  — per-provider API resolvers + proxy
 *   2. AtmosIndex         — Telegram content discovery
 *   3. VegaMovies DDL     — Indian content scraper with domain rotation
 *   4. Torrentio Proxy    — CORS-safe proxy for Stremio addon streams
 *
 * Deploy: wrangler deploy
 * Free tier: 100,000 requests/day + 5 cron triggers.
 */

import {
  handleSearch,
  handleSeasonSearch,
  handleStats,
  runCrawl,
} from './atmos-index.js';

const UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

// ─── Parallel race resolution utilities ───────────────────────────────────────
const timeoutPromise = (promise, ms, name) => {
  return Promise.race([
    promise,
    new Promise((_, reject) => setTimeout(() => reject(new Error(`${name} timed out`)), ms))
  ]);
};

async function raceResolvers(imdbId, tmdbId, type, season, episode) {
  const errors = [];
  const promises = RESOLVERS.map(async (resolver) => {
    try {
      console.log(`[Extract] Starting ${resolver.name}...`);
      const result = await timeoutPromise(
        resolver.resolve(imdbId, tmdbId, type, season, episode),
        6000,  // Increased from 4s→6s to reduce false timeouts on slow APIs
        resolver.name
      );
      if (result && result.url) {
        return { resolver, result };
      }
      throw new Error(`${resolver.name} returned empty result`);
    } catch (e) {
      console.log(`[Extract] ${resolver.name} failed: ${e.message}`);
      errors.push(`${resolver.name}: ${e.message}`);
      throw e;
    }
  });

  try {
    return await Promise.any(promises);
  } catch (err) {
    // All promises rejected
    return { errors };
  }
}

// ─── VegaMovies domain rotation list ─────────────────────────────────────────
// These are tried in order until one succeeds.
const VEGA_DOMAINS = [
  'vegamovies.nl',
  'vegamovies.day',
  'vegamovies.foo',
  'vegamovies.club',
];

// ─── Per-Provider API Resolvers ───────────────────────────────────────────────

const RESOLVERS = [
  {
    name: 'vidapi',
    async resolve(imdb, tmdb, type, season, episode) {
      const params = new URLSearchParams();
      if (imdb && imdb.startsWith('tt')) {
        params.append('imdb', imdb);
      } else if (tmdb) {
        params.append('tmdb', tmdb);
      } else {
        return null;
      }
      params.append('type', type === 'tv' ? 'tv' : 'movie');
      if (type === 'tv') {
        params.append('season', String(season));
        params.append('episode', String(episode));
      }

      const res = await fetch(`https://streamdata.vaplayer.ru/api.php?${params.toString()}`, {
        headers: {
          'User-Agent': UA,
          'Referer': 'https://brightpathsignals.com/',
          'Origin': 'https://brightpathsignals.com',
        },
      });
      if (!res.ok) return null;
      const data = await res.json();
      
      const file = data?.file || data?.url || data?.stream_url || data?.data?.file || data?.data?.url || data?.data?.stream_url;
      if (file && typeof file === 'string' && file.length > 0) {
        return { url: file, referer: 'https://brightpathsignals.com/' };
      }
      
      if (data?.data?.stream_urls && Array.isArray(data.data.stream_urls) && data.data.stream_urls.length > 0) {
        const url = data.data.stream_urls[0];
        if (url && (url.includes('.m3u8') || url.includes('.mp4'))) {
          return { url, referer: 'https://brightpathsignals.com/' };
        }
      }
      
      return null;
    }
  },
  {
    name: 'videasy',
    async resolve(imdb, tmdb, type, season, episode) {
      const path = type === 'tv'
        ? `/api/tv/${imdb}/${season}/${episode}`
        : `/api/movie/${imdb}`;
      const apiUrl = `https://player.videasy.net${path}`;
      const res = await fetch(apiUrl, {
        headers: {
          'User-Agent': UA,
          'Referer': 'https://player.videasy.net',
          'Origin': 'https://player.videasy.net',
          'Accept': 'application/json',
        },
      });
      if (!res.ok) return null;
      const data = await res.json();
      const url = data?.url || data?.source || data?.file
        || data?.sources?.[0]?.url || data?.sources?.[0]?.file
        || data?.data?.url || data?.data?.source;
      if (url && (url.includes('.m3u8') || url.includes('.mp4'))) {
        return { url, referer: 'https://player.videasy.net' };
      }
      return null;
    },
  },
  {
    name: 'vidsrc.vip',
    async resolve(imdb, tmdb, type, season, episode) {
      const path = type === 'tv'
        ? `/api/server?id=${imdb}&sr=${season}&ep=${episode}`
        : `/api/server?id=${imdb}`;
      const res = await fetch(`https://vidsrc.vip${path}`, {
        headers: { 'User-Agent': UA, 'Referer': 'https://vidsrc.vip', 'Accept': 'application/json' },
      });
      if (!res.ok) return null;
      const data = await res.json();
      const url = data?.data?.sources?.[0]?.url || data?.url || data?.source;
      if (url && (url.includes('.m3u8') || url.includes('.mp4'))) {
        return { url, referer: 'https://vidsrc.vip' };
      }
      return null;
    },
  },
  {
    name: 'vidsrc.me',
    async resolve(imdb, tmdb, type, season, episode) {
      const embedUrl = type === 'tv'
        ? `https://vidsrc.me/embed/tv?imdb=${imdb}&season=${season}&episode=${episode}`
        : `https://vidsrc.me/embed/movie?imdb=${imdb}`;
      const res = await fetch(embedUrl, {
        headers: { 'User-Agent': UA, 'Referer': 'https://vidsrc.me' },
        redirect: 'follow',
      });
      if (!res.ok) return null;
      const html = await res.text();
      const iframeSrc = extractIframeSrc(html);
      if (!iframeSrc) return null;
      const subRes = await fetch(iframeSrc, {
        headers: { 'User-Agent': UA, 'Referer': 'https://vidsrc.me' },
        redirect: 'follow',
      });
      if (!subRes.ok) return null;
      return extractFromHtml(await subRes.text(), 'https://vidsrc.me');
    },
  },
  {
    name: 'vidlink.pro',
    async resolve(imdb, tmdb, type, season, episode) {
      const id = tmdb || imdb;
      const embedUrl = type === 'tv'
        ? `https://vidlink.pro/tv/${id}/${season}/${episode}`
        : `https://vidlink.pro/movie/${id}`;
      const res = await fetch(embedUrl, {
        headers: { 'User-Agent': UA, 'Referer': 'https://vidlink.pro' },
        redirect: 'follow',
      });
      if (!res.ok) return null;
      return extractFromHtml(await res.text(), 'https://vidlink.pro');
    },
  },
  {
    name: 'autoembed',
    async resolve(imdb, tmdb, type, season, episode) {
      const embedUrl = type === 'tv'
        ? `https://autoembed.co/tv/tmdb/${tmdb}-${season}-${episode}`
        : `https://autoembed.co/movie/tmdb/${tmdb}`;
      const res = await fetch(embedUrl, {
        headers: { 'User-Agent': UA, 'Referer': 'https://autoembed.co' },
        redirect: 'follow',
      });
      if (!res.ok) return null;
      const html = await res.text();
      const iframeSrc = extractIframeSrc(html);
      if (iframeSrc) {
        const subRes = await fetch(iframeSrc, {
          headers: { 'User-Agent': UA, 'Referer': 'https://autoembed.co' },
          redirect: 'follow',
        });
        if (subRes.ok) {
          const result = extractFromHtml(await subRes.text(), 'https://autoembed.co');
          if (result) return result;
        }
      }
      return extractFromHtml(html, 'https://autoembed.co');
    },
  },
];

// ─── HTML extraction helpers ──────────────────────────────────────────────────

function extractIframeSrc(html) {
  const match = html.match(/<iframe[^>]+src=["']([^"']+)["']/i);
  if (!match) return null;
  let src = match[1];
  if (src.startsWith('//')) src = 'https:' + src;
  return src;
}

function extractFromHtml(html, referer) {
  const patterns = [
    /https?:\/\/[^\s"'\\]+\.m3u8[^\s"'\\]*/gi,
    /https?:\/\/[^\s"'\\]+\.mp4[^\s"'\\]*/gi,
    /"(https?:\/\/[^"]+(?:\.m3u8|\.mp4)[^"]*)"/gi,
    /(?:file|source|src)\s*:\s*["']?(https?:\/\/[^\s"'\\,}]+)/gi,
  ];
  const found = new Set();
  for (const pattern of patterns) {
    for (const match of html.matchAll(pattern)) {
      const url = match[1] || match[0];
      if (url.length < 500 && !url.includes('cdn.jsdelivr') && !url.includes('jquery')) {
        found.add(url.trim());
      }
    }
  }
  if (found.size === 0) return null;
  const urls = [...found];
  const primary = urls.find(u => u.includes('.m3u8')) || urls[0];
  return { url: primary, referer };
}

// ─── Proxy handler ────────────────────────────────────────────────────────────

async function proxyStream(targetUrl, referer) {
  const res = await fetch(targetUrl, {
    headers: {
      'User-Agent': UA,
      'Referer': referer || '',
      'Origin': referer ? new URL(referer).origin : '',
    },
  });
  const headers = new Headers(res.headers);
  headers.set('Access-Control-Allow-Origin', '*');
  headers.set('Access-Control-Allow-Headers', '*');
  return new Response(res.body, { status: res.status, headers });
}

// ─── VegaMovies Helpers ───────────────────────────────────────────────────────

/**
 * Try each VegaMovies domain until one succeeds.
 * Returns { html, domain } or null.
 */
async function fetchVegaPage(path) {
  for (const domain of VEGA_DOMAINS) {
    try {
      const url = `https://${domain}${path}`;
      const res = await fetch(url, {
        headers: { 'User-Agent': UA, 'Accept': 'text/html' },
        redirect: 'follow',
      });
      if (res.ok) {
        const html = await res.text();
        // Sanity check: real VegaMovies page has article or post class
        if (html.includes('article') || html.includes('class="post"') || html.includes('entry-title')) {
          return { html, domain };
        }
      }
    } catch (_) {}
  }
  return null;
}

/**
 * Parse VegaMovies search results from HTML.
 * VegaMovies uses WordPress — articles have h2.entry-title > a structure.
 */
function parseVegaSearchResults(html) {
  const results = [];
  // Match article blocks — each post is in an <article> tag
  const articleRegex = /<article[^>]*>([\s\S]*?)<\/article>/gi;
  let articleMatch;
  while ((articleMatch = articleRegex.exec(html)) !== null) {
    const block = articleMatch[1];

    // Extract post URL and title from h2.entry-title > a
    const titleLinkMatch = block.match(/<a[^>]+href="([^"]+)"[^>]*>([^<]+)<\/a>/i);
    if (!titleLinkMatch) continue;

    const postUrl = titleLinkMatch[1];
    const title = titleLinkMatch[2].trim();
    if (!postUrl || !title) continue;

    // Extract poster image
    const imgMatch = block.match(/src="([^"]+\.(jpg|jpeg|webp|png)[^"]*)"[^>]*class="[^"]*wp-post-image[^"]*"/i)
      || block.match(/class="[^"]*wp-post-image[^"]*"[^>]*src="([^"]+)"/i)
      || block.match(/<img[^>]+src="([^"]+\.(jpg|jpeg|webp|png)[^"]*)"/i);
    const posterUrl = imgMatch ? imgMatch[1] : null;

    // Extract quality tag if present
    const qualityMatch = block.match(/\b(4K|2160p|1080p|720p|480p|HDCAM|CAM)\b/i);
    const quality = qualityMatch ? qualityMatch[1].toUpperCase() : null;

    // Extract year
    const yearMatch = title.match(/\b(19|20)\d{2}\b/) || block.match(/\b(19|20)\d{2}\b/);
    const year = yearMatch ? yearMatch[0] : null;

    results.push({ title, post_url: postUrl, poster_url: posterUrl, quality, year });
  }
  return results;
}

/**
 * Parse download links from a VegaMovies post page.
 * Extracts GDrive, PixelDrain, HubCloud, and other DDL links.
 * Also parses quality/size/codec from surrounding text.
 */
function parseVegaLinks(html) {
  const links = [];
  const seen = new Set();

  // Find all download button sections — VegaMovies wraps them in <p> or <div> with specific text
  // Then look for anchor tags near quality/size indicators

  // Strategy: scan through all <a> tags, check href, extract context
  const anchorRegex = /<a\s[^>]*href="([^"]+)"[^>]*>([\s\S]*?)<\/a>/gi;
  let match;

  while ((match = anchorRegex.exec(html)) !== null) {
    const href = match[1];
    const linkText = match[2].replace(/<[^>]+>/g, '').trim();

    // Skip navigation, image, and non-download links
    if (!href || href === '#' || href.startsWith('javascript:')) continue;
    if (href.includes('/category/') || href.includes('/tag/') || href.includes('/author/')) continue;
    if (href.includes('vegamovies.') && !href.includes('/download')) continue;

    // Identify host
    let host = null;
    if (href.includes('drive.google.com') || href.includes('docs.google.com')) {
      host = 'gdrive';
    } else if (href.includes('pixeldrain.com')) {
      host = 'pixeldrain';
    } else if (href.includes('hubcloud') || href.includes('hub.la') || href.includes('hubcdn')) {
      host = 'hubcloud';
    } else if (href.includes('1drv.ms') || href.includes('onedrive.live.com')) {
      host = 'onedrive';
    } else if (href.includes('terabox') || href.includes('4shared') || href.includes('mediafire')) {
      host = 'other';
    }

    if (!host) continue;
    if (seen.has(href)) continue;
    seen.add(href);

    // Get surrounding context for quality/size/codec metadata
    // Look 500 chars before the anchor for quality indicators
    const startIdx = Math.max(0, match.index - 600);
    const context = html.slice(startIdx, match.index + match[0].length + 200);

    // Quality
    const qualMatch = context.match(/\b(4K|2160p|1080p|720p|480p|360p)\b/i);
    const quality = qualMatch ? qualMatch[1].replace('2160p', '4K') : (linkText.match(/\b(4K|2160p|1080p|720p|480p)\b/i)?.[1] ?? 'HD');

    // Size
    const sizeMatch = context.match(/(\d+(?:\.\d+)?)\s*(GB|MB|GiB|MiB)/i);
    const size = sizeMatch ? `${sizeMatch[1]} ${sizeMatch[2].toUpperCase()}` : null;

    // Codec
    const codecMatch = context.match(/\b(x265|HEVC|x264|AVC|AV1)\b/i);
    const codec = codecMatch ? codecMatch[1].toLowerCase().replace('hevc', 'x265').replace('avc', 'x264') : null;

    // Language
    const langMatch = context.match(/\b(Hindi|English|Tamil|Telugu|Malayalam|Dual Audio|Multi Audio|Dubbed)\b/i);
    const language = langMatch ? langMatch[1] : (linkText.match(/\b(Hindi|English|Dual|Multi)\b/i)?.[1] ?? 'Hindi/English');

    // Convert to direct URLs
    let directUrl = href;
    if (host === 'gdrive') {
      const fileIdMatch = href.match(/\/d\/([a-zA-Z0-9_-]+)/);
      if (fileIdMatch) {
        directUrl = `https://drive.google.com/uc?export=download&id=${fileIdMatch[1]}`;
      }
    } else if (host === 'pixeldrain') {
      const pdMatch = href.match(/\/u\/([a-zA-Z0-9]+)/);
      if (pdMatch) {
        directUrl = `https://pixeldrain.com/api/file/${pdMatch[1]}`;
      }
    }

    links.push({
      url: directUrl,
      original_url: href,
      host,
      quality: quality.toUpperCase(),
      language,
      size,
      codec,
      link_text: linkText.substring(0, 100),
    });
  }

  // Sort: GDrive first (most reliable), then pixeldrain, then others
  const hostOrder = { gdrive: 0, pixeldrain: 1, hubcloud: 2, onedrive: 3, other: 4 };
  const qualityOrder = { '4K': 0, '2160P': 0, '1080P': 1, '720P': 2, '480P': 3, 'HD': 4 };

  links.sort((a, b) => {
    const hostDiff = (hostOrder[a.host] ?? 5) - (hostOrder[b.host] ?? 5);
    if (hostDiff !== 0) return hostDiff;
    return (qualityOrder[a.quality] ?? 5) - (qualityOrder[b.quality] ?? 5);
  });

  return links;
}

// ─── Main worker ──────────────────────────────────────────────────────────────

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);

    // CORS preflight
    if (request.method === 'OPTIONS') {
      return new Response(null, {
        headers: {
          'Access-Control-Allow-Origin': '*',
          'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
          'Access-Control-Allow-Headers': '*',
        },
      });
    }

    const corsHeaders = {
      'Access-Control-Allow-Origin': '*',
      'Content-Type': 'application/json',
    };

    // ══════════════════════════════════════════════════════════════════════════
    // GET /extract?imdb=tt1234567&type=movie
    // GET /extract?imdb=tt1234567&tmdb=123&type=tv&season=1&episode=1
    // ══════════════════════════════════════════════════════════════════════════
    if (url.pathname === '/extract') {
      const imdbId = url.searchParams.get('imdb') || '';
      const tmdbId = url.searchParams.get('tmdb') || '';
      const type = url.searchParams.get('type') || 'movie';
      const season = url.searchParams.get('season') || '1';
      const episode = url.searchParams.get('episode') || '1';

      if (!imdbId && !tmdbId) {
        return new Response(JSON.stringify({ error: 'imdb or tmdb param required' }), {
          status: 400, headers: corsHeaders,
        });
      }

      const raceResult = await raceResolvers(imdbId, tmdbId, type, season, episode);
      if (raceResult && raceResult.resolver) {
        const { resolver, result } = raceResult;
        const proxyUrl = `${url.origin}/proxy?url=${encodeURIComponent(result.url)}&referer=${encodeURIComponent(result.referer || '')}`;
        console.log(`[Extract] ✅ ${resolver.name} won the race → ${result.url}`);
        return new Response(JSON.stringify({
          success: true,
          provider: resolver.name,
          url: result.url,
          proxyUrl,
          headers: { Referer: result.referer || '' },
          type: result.url.includes('.m3u8') ? 'hls' : 'mp4',
          imdbId, tmdbId,
        }), { headers: corsHeaders });
      }

      const errorDetails = raceResult?.errors || ['All providers returned empty results'];
      return new Response(JSON.stringify({
        success: false,
        error: 'All providers exhausted',
        details: errorDetails,
      }), {
        status: 404, headers: corsHeaders,
      });
    }

    // ══════════════════════════════════════════════════════════════════════════
    // GET /proxy?url=https://...&referer=https://...
    // ══════════════════════════════════════════════════════════════════════════
    if (url.pathname === '/proxy') {
      const targetUrl = url.searchParams.get('url');
      const referer = url.searchParams.get('referer') || '';
      if (!targetUrl) return new Response('url param required', { status: 400 });
      return proxyStream(decodeURIComponent(targetUrl), decodeURIComponent(referer));
    }

    // ══════════════════════════════════════════════════════════════════════════
    // GET /tmdb/... — Proxy TMDB API (bypass ISP blocks)
    // ══════════════════════════════════════════════════════════════════════════
    if (url.pathname.startsWith('/tmdb/')) {
      const targetPath = url.pathname.replace('/tmdb', '');
      const tmdbUrl = new URL(`https://api.themoviedb.org/3${targetPath}`);
      url.searchParams.forEach((value, key) => tmdbUrl.searchParams.append(key, value));
      try {
        const res = await fetch(tmdbUrl.toString(), {
          headers: { 'User-Agent': request.headers.get('User-Agent') || 'AtmosApp/1.0' }
        });
        const headers = new Headers(res.headers);
        headers.set('Access-Control-Allow-Origin', '*');
        return new Response(res.body, { status: res.status, headers });
      } catch (err) {
        return new Response(JSON.stringify({ error: err.message }), { status: 500, headers: corsHeaders });
      }
    }

    // ══════════════════════════════════════════════════════════════════════════
    // VegaMovies DDL Scraper — v2 with domain rotation
    // GET /vegamovies/search?q=Inception&year=2010
    // ══════════════════════════════════════════════════════════════════════════
    if (url.pathname === '/vegamovies/search') {
      const q = url.searchParams.get('q');
      const year = url.searchParams.get('year') || '';

      if (!q) {
        return new Response(JSON.stringify({ results: [] }), { headers: corsHeaders });
      }

      try {
        const searchQuery = year ? `${q} ${year}` : q;
        const searchPath = `/?s=${encodeURIComponent(searchQuery)}`;
        const page = await fetchVegaPage(searchPath);

        if (!page) {
          return new Response(JSON.stringify({
            results: [],
            error: 'All VegaMovies domains unreachable',
          }), { headers: corsHeaders });
        }

        const results = parseVegaSearchResults(page.html);
        console.log(`[VegaMovies] Search "${q}" → ${results.length} results via ${page.domain}`);

        return new Response(JSON.stringify({ results, domain: page.domain }), { headers: corsHeaders });
      } catch (e) {
        console.error('[VegaMovies] Search error:', e.message);
        return new Response(JSON.stringify({ results: [], error: e.message }), {
          status: 500, headers: corsHeaders,
        });
      }
    }

    // ══════════════════════════════════════════════════════════════════════════
    // GET /vegamovies/links?url=https://vegamovies.nl/some-post
    // ══════════════════════════════════════════════════════════════════════════
    if (url.pathname === '/vegamovies/links') {
      const target = url.searchParams.get('url');
      if (!target) return new Response(JSON.stringify({ links: [] }), { status: 400, headers: corsHeaders });

      try {
        // Fetch the post page directly (no domain rotation needed since we have the full URL)
        const res = await fetch(target, {
          headers: { 'User-Agent': UA, 'Accept': 'text/html' },
          redirect: 'follow',
        });

        if (!res.ok) {
          return new Response(JSON.stringify({ links: [], error: `HTTP ${res.status}` }), {
            headers: corsHeaders,
          });
        }

        const html = await res.text();
        const links = parseVegaLinks(html);

        console.log(`[VegaMovies] Links from ${target} → ${links.length} links`);
        return new Response(JSON.stringify({ links }), { headers: corsHeaders });
      } catch (e) {
        console.error('[VegaMovies] Links error:', e.message);
        return new Response(JSON.stringify({ links: [], error: e.message }), {
          status: 500, headers: corsHeaders,
        });
      }
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Torrentio CORS Proxy — avoids mobile CORS issues
    // GET /torrentio/streams?imdb=tt1234567&type=movie
    // GET /torrentio/streams?imdb=tt1234567&type=series&season=1&episode=1
    // ══════════════════════════════════════════════════════════════════════════
    if (url.pathname === '/torrentio/streams') {
      const imdb = url.searchParams.get('imdb') || '';
      const type = url.searchParams.get('type') || 'movie';
      const season = url.searchParams.get('season') || '1';
      const episode = url.searchParams.get('episode') || '1';

      if (!imdb) {
        return new Response(JSON.stringify({ streams: [] }), { status: 400, headers: corsHeaders });
      }

      const videoId = type === 'movie' ? imdb : `${imdb}:${season}:${episode}`;
      const contentType = type === 'movie' ? 'movie' : 'series';
      const torrentioUrl = `https://torrentio.strem.fun/stream/${contentType}/${videoId}.json`;

      try {
        const res = await fetch(torrentioUrl, {
          headers: { 'User-Agent': UA, 'Accept': 'application/json' },
        });

        if (!res.ok) {
          return new Response(JSON.stringify({ streams: [], error: `Torrentio HTTP ${res.status}` }), {
            headers: corsHeaders,
          });
        }

        const data = await res.json();
        return new Response(JSON.stringify(data), { headers: corsHeaders });
      } catch (e) {
        return new Response(JSON.stringify({ streams: [], error: e.message }), {
          status: 500, headers: corsHeaders,
        });
      }
    }

    // ══════════════════════════════════════════════════════════════════════════
    // AtmosIndex — Telegram Content Discovery
    // ══════════════════════════════════════════════════════════════════════════

    if (url.pathname === '/tg/search') return handleSearch(url, env);
    if (url.pathname === '/tg/season') return handleSeasonSearch(url, env);
    if (url.pathname === '/tg/stats') return handleStats(env);

    if (url.pathname === '/tg/crawl' && request.method === 'POST') {
      ctx.waitUntil(runCrawl(env));
      return new Response(JSON.stringify({ status: 'crawl_started' }), { headers: corsHeaders });
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Health check
    // ══════════════════════════════════════════════════════════════════════════
    if (url.pathname === '/health') {
      return new Response(JSON.stringify({
        status: 'ok',
        version: '2.0.0',
        resolvers: RESOLVERS.map(r => r.name),
        vega_domains: VEGA_DOMAINS,
        features: ['stream-extract', 'proxy', 'tmdb-proxy', 'vegamovies', 'torrentio-proxy', 'atmos-index'],
      }), { headers: corsHeaders });
    }

    return new Response('Not Found', { status: 404 });
  },

  // Cron handler — runs every 6 hours to crawl channels
  async scheduled(controller, env, ctx) {
    console.log(`[Cron] Triggered at ${new Date().toISOString()} — cron: ${controller.cron}`);
    await runCrawl(env);
  },
};
