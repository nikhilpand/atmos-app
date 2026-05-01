/**
 * Atmos Extraction Cloudflare Worker
 * 
 * Bypasses Cloudflare bot detection on streaming providers by acting as
 * a trusted browser-like proxy. Implements a multi-source waterfall with
 * automatic retries and Referer header injection.
 * 
 * Deploy: wrangler deploy
 * Free tier: 100,000 requests/day — more than enough.
 */

const PROVIDERS = [
  {
    name: 'vidsrc.xyz',
    movieUrl: (id) => `https://vidsrc.xyz/embed/movie?imdb=${id}`,
    tvUrl: (id, s, e) => `https://vidsrc.xyz/embed/tv?imdb=${id}&season=${s}&episode=${e}`,
    referer: 'https://vidsrc.xyz',
  },
  {
    name: 'vidsrc.me',
    movieUrl: (id) => `https://vidsrc.me/embed/movie?imdb=${id}`,
    tvUrl: (id, s, e) => `https://vidsrc.me/embed/tv?imdb=${id}&season=${s}&episode=${e}`,
    referer: 'https://vidsrc.me',
  },
  {
    name: 'embed.su',
    movieUrl: (id) => `https://embed.su/embed/movie/${id}`,
    tvUrl: (id, s, e) => `https://embed.su/embed/tv/${id}/${s}/${e}`,
    referer: 'https://embed.su',
  },
  {
    name: 'autoembed.cc',
    movieUrl: (id) => `https://autoembed.cc/embed/movie/${id}`,
    tvUrl: (id, s, e) => `https://autoembed.cc/embed/tv/${id}/${s}/${e}`,
    referer: 'https://autoembed.cc',
  },
  {
    name: 'multiembed.mov',
    movieUrl: (id) => `https://multiembed.mov/directstream.php?imdb_id=${id}`,
    tvUrl: (id, s, e) => `https://multiembed.mov/directstream.php?imdb_id=${id}&s=${s}&e=${e}`,
    referer: 'https://multiembed.mov',
  },
];

// Extracts m3u8/mp4 stream URLs from provider HTML
function extractStreamUrls(html) {
  const patterns = [
    // HLS streams
    /https?:\/\/[^\s"'\\]+\.m3u8[^\s"'\\]*/gi,
    // MP4 streams
    /https?:\/\/[^\s"'\\]+\.mp4[^\s"'\\]*/gi,
    // Source URLs in JSON
    /"(https?:\/\/[^"]+(?:\.m3u8|\.mp4)[^"]*)"/gi,
    // file: or source: patterns common in video embeds
    /(?:file|source|src)\s*:\s*["']?(https?:\/\/[^\s"'\\,}]+)/gi,
  ];

  const found = new Set();
  for (const pattern of patterns) {
    const matches = html.matchAll(pattern);
    for (const match of matches) {
      const url = match[1] || match[0];
      // Filter out obvious non-stream URLs
      if (!url.includes('cdn.jsdelivr') && !url.includes('jquery') && url.length < 500) {
        found.add(url.trim());
      }
    }
  }
  return [...found];
}

async function fetchProvider(provider, url) {
  try {
    const res = await fetch(url, {
      headers: {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
        'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8',
        'Accept-Language': 'en-US,en;q=0.9',
        'Accept-Encoding': 'gzip, deflate, br',
        'Referer': provider.referer,
        'Origin': provider.referer,
        'Sec-Fetch-Dest': 'iframe',
        'Sec-Fetch-Mode': 'navigate',
        'Sec-Fetch-Site': 'cross-site',
        'Cache-Control': 'no-cache',
      },
      redirect: 'follow',
    });

    if (!res.ok) return null;

    const html = await res.text();
    const streams = extractStreamUrls(html);

    if (streams.length > 0) {
      return {
        provider: provider.name,
        streams,
        // Prefer HLS over MP4
        primary: streams.find(s => s.includes('.m3u8')) || streams[0],
        referer: provider.referer,
      };
    }
    return null;
  } catch (err) {
    console.error(`Provider ${provider.name} failed:`, err.message);
    return null;
  }
}

// Proxy a video stream segment (solves HLS .ts segment CORS blocking)
async function proxyStream(targetUrl, referer) {
  const res = await fetch(targetUrl, {
    headers: {
      'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)',
      'Referer': referer || '',
      'Origin': referer || '',
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

export default {
  async fetch(request) {
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

    // GET /extract?imdb=tt1234567&type=movie
    // GET /extract?imdb=tt1234567&type=tv&season=1&episode=1
    if (url.pathname === '/extract') {
      const imdbId = url.searchParams.get('imdb');
      const type = url.searchParams.get('type') || 'movie';
      const season = url.searchParams.get('season') || '1';
      const episode = url.searchParams.get('episode') || '1';

      if (!imdbId) {
        return new Response(JSON.stringify({ error: 'imdb param required' }), {
          status: 400, headers: corsHeaders,
        });
      }

      // Try providers in order (waterfall)
      for (const provider of PROVIDERS) {
        const embedUrl = type === 'tv'
          ? provider.tvUrl(imdbId, season, episode)
          : provider.movieUrl(imdbId);

        const result = await fetchProvider(provider, embedUrl);
        if (result) {
          return new Response(JSON.stringify({
            success: true,
            imdbId,
            type,
            ...result,
          }), { headers: corsHeaders });
        }
      }

      return new Response(JSON.stringify({
        success: false,
        error: 'All providers exhausted. Stream unavailable.',
      }), { status: 404, headers: corsHeaders });
    }

    // GET /proxy?url=https://...&referer=https://...
    // Proxies HLS segments to bypass CDN referer checks
    if (url.pathname === '/proxy') {
      const targetUrl = url.searchParams.get('url');
      const referer = url.searchParams.get('referer') || '';
      if (!targetUrl) {
        return new Response('url param required', { status: 400 });
      }
      return proxyStream(decodeURIComponent(targetUrl), decodeURIComponent(referer));
    }

    // GET /tmdb/...
    // Proxies requests to TMDB to bypass ISP blocking (e.g. Jio in India)
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

    // Health check
    if (url.pathname === '/health') {
      return new Response(JSON.stringify({ status: 'ok', providers: PROVIDERS.length }), {
        headers: corsHeaders,
      });
    }

    return new Response('Not Found', { status: 404 });
  },
};
