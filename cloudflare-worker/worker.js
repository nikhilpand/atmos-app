/**
 * Atmos Cloudflare Worker
 *
 * Two engines in one worker:
 *   1. Stream Extraction — per-provider API resolvers + proxy
 *   2. AtmosIndex — Telegram content discovery (search, crawl, index)
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

// ─── Per-Provider API Resolvers ──────────────────────────────────────────────
// Each resolver tries the provider's INTERNAL API or embed pattern to extract
// the m3u8/mp4 URL directly — no regex-on-HTML guessing.

const RESOLVERS = [
  {
    name: 'videasy',
    async resolve(imdb, tmdb, type, season, episode) {
      // Videasy serves an embed page that fetches from its own API.
      // The embed page JS calls: fetch(`/api/${type}/${imdbId}/${s}/${e}`)
      // which returns JSON with source URLs.
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

      // Response shape varies — look for sources/url/file
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
      // VidSrc VIP has a known API pattern
      const path = type === 'tv'
        ? `/api/server?id=${imdb}&sr=${season}&ep=${episode}`
        : `/api/server?id=${imdb}`;
      const apiUrl = `https://vidsrc.vip${path}`;

      const res = await fetch(apiUrl, {
        headers: {
          'User-Agent': UA,
          'Referer': 'https://vidsrc.vip',
          'Accept': 'application/json',
        },
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
      // VidSrc.me embed page → find the inner iframe src → follow to sub-provider
      const embedUrl = type === 'tv'
        ? `https://vidsrc.me/embed/tv?imdb=${imdb}&season=${season}&episode=${episode}`
        : `https://vidsrc.me/embed/movie?imdb=${imdb}`;

      const res = await fetch(embedUrl, {
        headers: { 'User-Agent': UA, 'Referer': 'https://vidsrc.me' },
        redirect: 'follow',
      });
      if (!res.ok) return null;
      const html = await res.text();

      // VidSrc.me loads an iframe pointing to a sub-provider
      // Try to extract the iframe src and follow it
      const iframeSrc = extractIframeSrc(html);
      if (!iframeSrc) return null;

      const subRes = await fetch(iframeSrc, {
        headers: { 'User-Agent': UA, 'Referer': 'https://vidsrc.me' },
        redirect: 'follow',
      });
      if (!subRes.ok) return null;
      const subHtml = await subRes.text();

      return extractFromHtml(subHtml, 'https://vidsrc.me');
    },
  },
  {
    name: 'vidlink.pro',
    async resolve(imdb, tmdb, type, season, episode) {
      // VidLink uses tmdbId for routing
      const id = tmdb || imdb;
      const embedUrl = type === 'tv'
        ? `https://vidlink.pro/tv/${id}/${season}/${episode}`
        : `https://vidlink.pro/movie/${id}`;

      const res = await fetch(embedUrl, {
        headers: { 'User-Agent': UA, 'Referer': 'https://vidlink.pro' },
        redirect: 'follow',
      });
      if (!res.ok) return null;
      const html = await res.text();

      return extractFromHtml(html, 'https://vidlink.pro');
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

      // AutoEmbed often has an iframe chain
      const iframeSrc = extractIframeSrc(html);
      if (iframeSrc) {
        const subRes = await fetch(iframeSrc, {
          headers: { 'User-Agent': UA, 'Referer': 'https://autoembed.co' },
          redirect: 'follow',
        });
        if (subRes.ok) {
          const subHtml = await subRes.text();
          const result = extractFromHtml(subHtml, 'https://autoembed.co');
          if (result) return result;
        }
      }

      return extractFromHtml(html, 'https://autoembed.co');
    },
  },
];

// ─── HTML extraction helpers ─────────────────────────────────────────────────

function extractIframeSrc(html) {
  const match = html.match(/<iframe[^>]+src=["']([^"']+)["']/i);
  if (!match) return null;
  let src = match[1];
  if (src.startsWith('//')) src = 'https:' + src;
  return src;
}

function extractFromHtml(html, referer) {
  // Try multiple patterns to find stream URLs in HTML/JS
  const patterns = [
    // Direct m3u8/mp4 URLs
    /https?:\/\/[^\s"'\\]+\.m3u8[^\s"'\\]*/gi,
    /https?:\/\/[^\s"'\\]+\.mp4[^\s"'\\]*/gi,
    // JSON source patterns
    /"(https?:\/\/[^"]+(?:\.m3u8|\.mp4)[^"]*)"/gi,
    // file: or source: patterns in JS
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

// ─── Proxy handler ───────────────────────────────────────────────────────────

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

  return new Response(res.body, {
    status: res.status,
    headers,
  });
}

// ─── Main worker ─────────────────────────────────────────────────────────────

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

      // Try each resolver sequentially
      for (const resolver of RESOLVERS) {
        try {
          console.log(`[Extract] Trying ${resolver.name}...`);
          const result = await resolver.resolve(imdbId, tmdbId, type, season, episode);
          if (result && result.url) {
            const workerBase = url.origin;
            const proxyUrl = `${workerBase}/proxy?url=${encodeURIComponent(result.url)}&referer=${encodeURIComponent(result.referer || '')}`;

            console.log(`[Extract] ✅ ${resolver.name} → ${result.url}`);
            return new Response(JSON.stringify({
              success: true,
              provider: resolver.name,
              url: result.url,
              proxyUrl,
              headers: { Referer: result.referer || '' },
              type: result.url.includes('.m3u8') ? 'hls' : 'mp4',
              imdbId,
              tmdbId,
            }), { headers: corsHeaders });
          }
        } catch (err) {
          console.error(`[Extract] ${resolver.name} error:`, err.message);
        }
      }

      return new Response(JSON.stringify({
        success: false,
        error: 'All providers exhausted',
      }), { status: 404, headers: corsHeaders });
    }

    // ══════════════════════════════════════════════════════════════════════════
    // GET /proxy?url=https://...&referer=https://...
    // Proxies HLS segments / manifests to bypass CDN referer checks
    // ══════════════════════════════════════════════════════════════════════════
    if (url.pathname === '/proxy') {
      const targetUrl = url.searchParams.get('url');
      const referer = url.searchParams.get('referer') || '';
      if (!targetUrl) {
        return new Response('url param required', { status: 400 });
      }
      return proxyStream(decodeURIComponent(targetUrl), decodeURIComponent(referer));
    }

    // ══════════════════════════════════════════════════════════════════════════
    // GET /tmdb/... — Proxy TMDB API (bypass ISP blocks)
    // ══════════════════════════════════════════════════════════════════════════
    if (url.pathname.startsWith('/tmdb/')) {
      const targetPath = url.pathname.replace('/tmdb', '');
      const tmdbUrl = new URL(`https://api.themoviedb.org/3${targetPath}`);
      url.searchParams.forEach((value, key) => {
        tmdbUrl.searchParams.append(key, value);
      });

      try {
        const res = await fetch(tmdbUrl.toString(), {
          headers: { 'User-Agent': request.headers.get('User-Agent') || 'AtmosApp/1.0' }
        });

        const headers = new Headers(res.headers);
        headers.set('Access-Control-Allow-Origin', '*');

        return new Response(res.body, {
          status: res.status,
          headers,
        });
      } catch (err) {
        return new Response(JSON.stringify({ error: err.message }), { status: 500, headers: corsHeaders });
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
      return new Response(JSON.stringify({ status: 'crawl_started' }), {
        headers: corsHeaders,
      });
    }

    // Health check
    if (url.pathname === '/health') {
      return new Response(JSON.stringify({
        status: 'ok',
        resolvers: RESOLVERS.map(r => r.name),
        engine: 'atmos-index',
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
