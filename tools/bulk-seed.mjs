#!/usr/bin/env node
/**
 * AtmosIndex Bulk Seeder
 * Searches many popular titles via finder.mjs --index and seeds Supabase catalog.
 * Run: node tools/bulk-seed.mjs
 */

import { execSync } from 'child_process';
import { existsSync } from 'fs';

const FINDER = new URL('./tg-search/finder.mjs', import.meta.url).pathname;

if (!existsSync(FINDER)) {
  console.error('finder.mjs not found at', FINDER);
  process.exit(1);
}

// ── Seed list: popular movies + TV shows across genres ───────────────────────
const QUERIES = [
  // TV Shows (season-specific)
  { q: 'Breaking Bad',     args: '--season 1' },
  { q: 'Breaking Bad',     args: '--season 2' },
  { q: 'Stranger Things',  args: '--season 1' },
  { q: 'Stranger Things',  args: '--season 4' },
  { q: 'Game of Thrones',  args: '--season 1' },
  { q: 'The Last of Us',   args: '--season 1' },
  { q: 'Peaky Blinders',   args: '--season 1' },
  { q: 'Squid Game',       args: '--season 1' },
  { q: 'Wednesday',        args: '--season 1' },
  { q: 'The Boys',         args: '--season 1' },
  { q: 'House of the Dragon', args: '--season 1' },
  { q: 'The Mandalorian',  args: '--season 1' },
  // Movies
  { q: 'Inception 2010',   args: '' },
  { q: 'Interstellar',     args: '' },
  { q: 'Oppenheimer 2023', args: '' },
  { q: 'Avengers Endgame', args: '' },
  { q: 'The Dark Knight',  args: '' },
  { q: 'Dune 2021',        args: '' },
  { q: 'Dune Part Two 2024', args: '' },
  // Bollywood
  { q: 'KGF Chapter 2',    args: '' },
  { q: 'Pathaan 2023',     args: '' },
  { q: 'Jawan 2023',       args: '' },
  { q: 'Animal 2023',      args: '' },
  { q: 'RRR 2022',         args: '' },
  // Anime
  { q: 'Attack on Titan',  args: '--season 4' },
  { q: 'Demon Slayer',     args: '--season 3' },
  { q: 'One Piece',        args: '' },
  { q: 'Jujutsu Kaisen',   args: '--season 2' },
  { q: 'My Hero Academia', args: '--season 5' },
  // More TV
  { q: 'Money Heist',      args: '--season 1' },
  { q: 'Narcos',           args: '--season 1' },
  { q: 'Ozark',            args: '--season 1' },
  { q: 'The Witcher',      args: '--season 1' },
  { q: 'Black Mirror',     args: '--season 1' },
];

const sleep = ms => new Promise(r => setTimeout(r, ms));

async function main() {
  console.log(`\n╔═══════════════════════════════════════════════════╗`);
  console.log(`║  AtmosIndex Bulk Seeder — ${QUERIES.length} queries          ║`);
  console.log(`╚═══════════════════════════════════════════════════╝\n`);

  let totalIndexed = 0;

  for (let i = 0; i < QUERIES.length; i++) {
    const { q, args } = QUERIES[i];
    const label = `[${i + 1}/${QUERIES.length}]`;
    process.stdout.write(`${label} "${q}" ${args} ... `);

    try {
      const cmd = `node "${FINDER}" "${q}" ${args} --index 2>&1`;
      const output = execSync(cmd, {
        cwd: new URL('./tg-search', import.meta.url).pathname,
        timeout: 60000,
        encoding: 'utf-8',
      });

      // Extract indexed count
      const match = output.match(/Indexed (\d+)\/(\d+)/);
      if (match) {
        const count = parseInt(match[1]);
        totalIndexed += count;
        console.log(`✅ ${count} rows`);
      } else if (output.includes('No indexable')) {
        console.log('⚠️  nothing to index');
      } else {
        console.log('❓ done');
      }
    } catch (err) {
      if (err.stdout) {
        const match = err.stdout.match(/Indexed (\d+)\/(\d+)/);
        if (match) {
          totalIndexed += parseInt(match[1]);
          console.log(`✅ ${match[1]} rows`);
        } else {
          console.log(`⚠️  ${err.message?.substring(0, 60) || 'error'}`);
        }
      } else {
        console.log(`❌ ${err.message?.substring(0, 60)}`);
      }
    }

    // Pause between queries to avoid Telegram rate limits
    await sleep(3000);
  }

  console.log(`\n╔═══════════════════════════════════════════════════╗`);
  console.log(`║  Done! Total rows indexed: ${String(totalIndexed).padEnd(21)}║`);
  console.log(`╚═══════════════════════════════════════════════════╝\n`);
}

main().catch(err => {
  console.error('Fatal:', err.message);
  process.exit(1);
});
