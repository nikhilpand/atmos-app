/**
 * Universal Telegram Filename Parser
 *
 * Handles 30+ naming formats found in the wild:
 *   Scene:     Movie.Title.2024.1080p.WEB-DL.x265-GROUP
 *   P2P:       Movie Name (2024) [1080p] [WEB-DL].mkv
 *   Hindi:     MovieName 2024 Hindi 1080p NF WEB-DL DD+5.1 H.265.mkv
 *   Bot:       @ChannelName - Movie Title 2024 1080p.mkv
 *   Casual:    Movie Title 2024.mp4
 */

// ── Episode patterns (ordered: most specific first) ─────────────────────────

const EPISODE_PATTERNS = [
  // S01E01-E03  or  S01E01E02E03  (multi-episode)
  { re: /[Ss](\d{1,2})[Ee](\d{1,3})(?:[-._\s]?[Ee](\d{1,3}))/, multi: true },
  // S01E01, S1E1, s01e01
  { re: /[Ss](\d{1,2})[Ee](\d{1,3})/ },
  // S01.E01, S01_E01, S01-E01, S01 E01
  { re: /[Ss](\d{1,2})[\s._-][Ee](\d{1,3})/ },
  // 1x01, 01x01
  { re: /\b(\d{1,2})[xX](\d{2,3})\b/ },
  // Season 1 Episode 3
  { re: /(?:Season|SEASON)\s*(\d{1,2})\s*(?:Episode|EPISODE|Ep\.?)\s*(\d{1,3})/i },
  // EP.1, Ep01, EP01
  { re: /\b(?:EP|Ep)\.?\s*(\d{1,3})\b/, epOnly: true },
  // E01 (standalone, not part of HEVC etc)
  { re: /(?<![A-Za-z])[Ee](\d{2,3})(?![0-9])/, epOnly: true },
  // Episode 1, Episode.1
  { re: /Episode[\s._-]*(\d{1,3})/i, epOnly: true },
];

const SEASON_PACK_PATTERNS = [
  /[Ss](\d{1,2})[\s._-]*(?:COMPLETE|Complete|complete)/,
  /(?:Season|SEASON|season)\s*(\d{1,2})\s*(?:COMPLETE|Complete|complete|FULL|Full)/,
  /(?:COMPLETE|Complete)\s*(?:Season|SEASON)\s*(\d{1,2})/,
  /[Ss](\d{1,2})[\s._-]*(?:FULL|Full)\b/,
];

// ── Quality / Source / Codec / Platform / Audio tag maps ────────────────────

const QUALITY_KEYS = [
  ['2160p', '4K'], ['4k', '4K'], ['uhd', '4K'],
  ['1080p', '1080p'], ['1080', '1080p'],
  ['720p', '720p'], ['720', '720p'],
  ['480p', '480p'], ['480', '480p'],
  ['360p', '360p'],
];

const SOURCE_PATTERNS = [
  [/\bblu-?ray|bdri?p|brri?p/i, 'BluRay'],
  [/\bweb-?dl\b/i, 'WEB-DL'],
  [/\bwebri?p\b/i, 'WEBRip'],
  [/\bhdtv\b/i, 'HDTV'],
  [/\bdvdri?p\b/i, 'DVDRip'],
  [/\bremux\b/i, 'REMUX'],
];

const CODEC_PATTERNS = [
  [/\bx\.?265\b|\bh\.?265\b|\bhevc\b/i, 'HEVC'],
  [/\bx\.?264\b|\bh\.?264\b|\bavc\b/i, 'AVC'],
  [/\bav1\b/i, 'AV1'],
  [/\bvp9\b/i, 'VP9'],
];

const PLATFORM_TAGS = [
  'NFLX', 'NF', 'AMZN', 'AZ', 'DSNP', 'DP', 'HMAX', 'HM', 'HBOM',
  'ATVP', 'PMTP', 'PCOK', 'HULU', 'SHO', 'CRAV', 'STAN',
  'BCORE', 'MA', 'VUDU', 'ROKU', 'WODC', 'MNGO', 'iT',
];

const AUDIO_PATTERNS = [
  [/dual[\s._-]?audio/i, 'Dual Audio'],
  [/multi[\s._-]?audio|multi[\s._-]?lang/i, 'Multi Audio'],
  [/\bhindi\b|\bhin\b/i, 'Hindi'],
  [/\btamil\b|\btam\b/i, 'Tamil'],
  [/\btelugu\b|\btel\b/i, 'Telugu'],
  [/\bmalayalam\b|\bmal\b/i, 'Malayalam'],
  [/\bkannada\b|\bkan\b/i, 'Kannada'],
  [/\bbengali\b|\bben\b/i, 'Bengali'],
  [/\bpunjabi\b|\bpun\b/i, 'Punjabi'],
  [/\bjapanese\b|\bjpn\b/i, 'Japanese'],
  [/\bkorean\b|\bkor\b/i, 'Korean'],
  [/\benglish\b|\beng\b/i, 'English'],
];

// ── Main parser ─────────────────────────────────────────────────────────────

export function parseFilename(raw) {
  let text = (raw || '').trim();
  if (!text) return _empty();

  // 1. Strip channel tags, emoji, brackets
  text = text.replace(/@[\w]+/g, '');
  text = text.replace(/^\[.*?\]\s*/g, '');
  text = text.replace(/[✅❤️🔥⭐🎬📽️🎥💿📀🆕🔴🟢]+/gu, '');
  text = text.replace(/\s+/g, ' ').trim();

  // 2. Year
  const yearMatch = text.match(/[\(\[\s._-]((?:19|20)\d{2})[\)\]\s._-]/);
  const year = yearMatch ? parseInt(yearMatch[1]) : null;

  // 3. Season pack?
  let season = null, episode = null, episodeEnd = null, isSeasonPack = false;
  for (const pat of SEASON_PACK_PATTERNS) {
    const m = text.match(pat);
    if (m) { season = parseInt(m[1]); isSeasonPack = true; break; }
  }

  // 4. Episode info
  if (!isSeasonPack) {
    for (const { re, multi, epOnly } of EPISODE_PATTERNS) {
      const m = text.match(re);
      if (m) {
        if (epOnly) {
          episode = parseInt(m[1]);
        } else {
          season = parseInt(m[1]);
          episode = parseInt(m[2]);
          if (multi && m[3]) episodeEnd = parseInt(m[3]);
        }
        break;
      }
    }
  }

  // 5. Quality
  const upper = text.toUpperCase();
  let quality = 'HD';
  for (const [key, val] of QUALITY_KEYS) {
    if (upper.includes(key.toUpperCase())) { quality = val; break; }
  }

  // 6. Source
  let sourceTag = null;
  for (const [pat, val] of SOURCE_PATTERNS) {
    if (pat.test(text)) { sourceTag = val; break; }
  }

  // 7. Codec
  let codec = null;
  for (const [pat, val] of CODEC_PATTERNS) {
    if (pat.test(text)) { codec = val; break; }
  }

  // 8. Platform
  const platformTag = PLATFORM_TAGS.find(t => {
    const re = new RegExp(`\\b${t}\\b`, 'i');
    return re.test(text);
  }) || null;

  // 9. Audio / Language
  let audio = null;
  for (const [pat, val] of AUDIO_PATTERNS) {
    if (pat.test(text)) { audio = val; break; }
  }

  // 10. Clean title: everything before the first technical tag
  const cutMarkers = [
    yearMatch ? yearMatch.index : -1,
    text.search(/[Ss]\d{1,2}[Ee]/),
    text.search(/\d{3,4}p\b/i),
    text.search(/\b(?:WEB|BluRay|HDTV|REMUX|HEVC|x26[45]|AVC)\b/i),
    text.search(/\b(?:NF|NFLX|AMZN|DSNP|HMAX|ATVP)\b/),
    text.search(/\b(?:Hindi|Dual|Tamil|Telugu|English)\b/i),
    text.search(/\b(?:Season|SEASON)\s*\d/),
    text.search(/\b\d{1,2}[xX]\d{2,3}\b/),
  ].filter(i => i > 0);

  let title = text;
  if (cutMarkers.length > 0) {
    title = text.substring(0, Math.min(...cutMarkers));
  }
  // Strip extension
  title = title.replace(/\.(mkv|mp4|avi|mov|wmv|flv|webm|ts)$/i, '');
  // Normalize separators
  title = title.replace(/[._-]+/g, ' ').replace(/\s+/g, ' ').trim();
  // Remove trailing junk
  title = title.replace(/[\s\-_.]+$/, '');

  return {
    title: title || raw,
    titleNormalized: normalize(title || raw),
    year, season, episode, episodeEnd,
    quality, sourceTag, platformTag, codec, audio,
    isSeasonPack,
  };
}

/** Lowercase, no special chars — for FTS matching */
export function normalize(title) {
  return (title || '')
    .toLowerCase()
    .replace(/[^a-z0-9\s]/g, '')
    .replace(/\s+/g, ' ')
    .trim();
}

function _empty() {
  return {
    title: '', titleNormalized: '', year: null, season: null,
    episode: null, episodeEnd: null, quality: 'HD', sourceTag: null,
    platformTag: null, codec: null, audio: null, isSeasonPack: false,
  };
}

// ── t.me/s/ HTML message parser ─────────────────────────────────────────────

/**
 * Parse messages from t.me/s/{channel} HTML.
 * Returns array of { id, fileName, caption, fileSize, hasFile }
 */
export function parseTelegramHTML(html, channelUsername) {
  const messages = [];

  // Split by message blocks — each starts with data-post=
  const blocks = html.split(/data-post="/g).slice(1);

  for (const block of blocks) {
    try {
      // Extract message ID: "channelname/12345"
      const postMatch = block.match(/^[^"]*\/(\d+)/);
      if (!postMatch) continue;
      const msgId = parseInt(postMatch[1]);

      // Check for video or document
      const hasVideo = block.includes('tgme_widget_message_video') ||
                       block.includes('message_video_player');
      const hasDoc = block.includes('tgme_widget_message_document');
      if (!hasVideo && !hasDoc) continue;

      // Extract document title (filename)
      let fileName = '';
      const titleMatch = block.match(
        /tgme_widget_message_document_title[^>]*>([^<]+)/
      );
      if (titleMatch) fileName = titleMatch[1].trim();

      // Extract caption text
      let caption = '';
      const captionMatch = block.match(
        /tgme_widget_message_text[^>]*>([\s\S]*?)<\/div>/
      );
      if (captionMatch) {
        caption = captionMatch[1]
          .replace(/<[^>]+>/g, ' ')  // strip HTML tags
          .replace(/&amp;/g, '&')
          .replace(/&lt;/g, '<')
          .replace(/&gt;/g, '>')
          .replace(/\s+/g, ' ')
          .trim();
      }

      // Extract file size from document extra
      let fileSize = 0;
      const sizeMatch = block.match(
        /tgme_widget_message_document_extra[^>]*>([^<]+)/
      );
      if (sizeMatch) {
        fileSize = parseSizeString(sizeMatch[1].trim());
      }

      // Use filename if available, fallback to caption for parsing
      const parseName = fileName || caption;
      if (!parseName) continue;

      messages.push({
        id: msgId,
        channelUsername,
        fileName,
        caption,
        fileSize,
        hasFile: true,
        parseName,
      });
    } catch (_) {
      // Skip malformed blocks
    }
  }

  return messages;
}

/** Parse "1.2 GB", "850 MB" etc. to bytes */
function parseSizeString(str) {
  const m = str.match(/([\d.]+)\s*(GB|MB|KB|TB)/i);
  if (!m) return 0;
  const val = parseFloat(m[1]);
  const unit = m[2].toUpperCase();
  const multiplier = { TB: 1e12, GB: 1e9, MB: 1e6, KB: 1e3 };
  return Math.round(val * (multiplier[unit] || 0));
}
