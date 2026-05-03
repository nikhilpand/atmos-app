/**
 * Parser unit tests — 100+ real Telegram filenames
 * Run: node cloudflare-worker/test_parser.js
 */

import { parseFilename, normalize, parseTelegramHTML } from './parser.js';

let passed = 0, failed = 0;

function test(input, expected, label) {
  const result = parseFilename(input);
  const errors = [];

  for (const [key, val] of Object.entries(expected)) {
    if (result[key] !== val) {
      errors.push(`  ${key}: got "${result[key]}" expected "${val}"`);
    }
  }

  if (errors.length > 0) {
    failed++;
    console.log(`❌ FAIL: ${label || input}`);
    errors.forEach(e => console.log(e));
  } else {
    passed++;
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// 1. SCENE FORMAT (dots as separators, group tag at end)
// ═══════════════════════════════════════════════════════════════════════════════

test('Inception.2010.1080p.BluRay.x264-GROUP.mkv', {
  title: 'Inception', year: 2010, quality: '1080p', sourceTag: 'BluRay', codec: 'AVC',
}, 'Scene: standard movie');

test('The.Dark.Knight.2008.2160p.UHD.BluRay.x265-FLUX.mkv', {
  title: 'The Dark Knight', year: 2008, quality: '4K', codec: 'HEVC',
}, 'Scene: 4K UHD');

test('Breaking.Bad.S01E01.1080p.WEB-DL.x264.mkv', {
  title: 'Breaking Bad', season: 1, episode: 1, quality: '1080p', sourceTag: 'WEB-DL',
}, 'Scene: TV episode');

test('Game.of.Thrones.S08E06.720p.HDTV.x264.mkv', {
  title: 'Game of Thrones', season: 8, episode: 6, quality: '720p', sourceTag: 'HDTV',
}, 'Scene: TV HDTV');

test('Stranger.Things.S04E01-E02.1080p.NF.WEB-DL.DDP5.1.H.265.mkv', {
  title: 'Stranger Things', season: 4, episode: 1, episodeEnd: 2, quality: '1080p',
}, 'Scene: multi-episode');

test('Dune.Part.Two.2024.2160p.AMZN.WEB-DL.DDP5.1.H.265-GROUP.mkv', {
  title: 'Dune Part Two', year: 2024, quality: '4K', sourceTag: 'WEB-DL',
}, 'Scene: platform tag AMZN');

test('Oppenheimer.2023.1080p.REMUX.AVC.DTS-HD.MA.5.1.mkv', {
  title: 'Oppenheimer', year: 2023, quality: '1080p', sourceTag: 'REMUX', codec: 'AVC',
}, 'Scene: REMUX');

test('The.Mandalorian.S03E08.1080p.DSNP.WEB-DL.DDP5.1.Atmos.H.264.mkv', {
  title: 'The Mandalorian', season: 3, episode: 8, quality: '1080p', sourceTag: 'WEB-DL',
}, 'Scene: Disney+ platform');

// ═══════════════════════════════════════════════════════════════════════════════
// 2. P2P FORMAT (spaces, brackets)
// ═══════════════════════════════════════════════════════════════════════════════

test('Interstellar (2014) [1080p] [WEB-DL] [5.1].mkv', {
  title: 'Interstellar', year: 2014, quality: '1080p', sourceTag: 'WEB-DL',
}, 'P2P: brackets');

test('The Matrix (1999) [BluRay] [720p] [x264].mkv', {
  title: 'The Matrix', year: 1999, quality: '720p', sourceTag: 'BluRay', codec: 'AVC',
}, 'P2P: BluRay brackets');

test('Avengers Endgame (2019) 2160p HDR BluRay REMUX.mkv', {
  title: 'Avengers Endgame', year: 2019, quality: '4K',
}, 'P2P: 4K HDR');

// ═══════════════════════════════════════════════════════════════════════════════
// 3. HINDI / BOLLYWOOD / REGIONAL
// ═══════════════════════════════════════════════════════════════════════════════

test('Super Sharanya (2022) Malayalam HQ HDRip 1080p HEVC AAC ESub.mkv', {
  title: 'Super Sharanya', year: 2022, quality: '1080p', codec: 'HEVC', audio: 'Malayalam',
}, 'Hindi: Malayalam with HEVC');

test('K_G_F_Chapter_2_2022_Malayalam_v3_FINAL_HQ_PreDVDRip_x264_MP3_400MB.mkv', {
  title: 'K G F Chapter 2', year: 2022, codec: 'AVC', audio: 'Malayalam',
}, 'Hindi: underscore format');

test('Pathaan 2023 Hindi 1080p NF WEB-DL DD+5.1 H.265.mkv', {
  title: 'Pathaan', year: 2023, quality: '1080p', audio: 'Hindi', codec: 'HEVC',
}, 'Hindi: Netflix WEB-DL');

test('Jawan.2023.Hindi.1080p.AMZN.WEB-DL.DD+5.1.x264.mkv', {
  title: 'Jawan', year: 2023, quality: '1080p', audio: 'Hindi', sourceTag: 'WEB-DL',
}, 'Hindi: AMZN');

test('RRR 2022 Hindi Dual Audio 720p BluRay ESubs.mkv', {
  title: 'RRR', year: 2022, quality: '720p', audio: 'Dual Audio',
}, 'Hindi: Dual Audio');

test('Animal 2023 Hindi 480p WEBRip x264.mkv', {
  title: 'Animal', year: 2023, quality: '480p', sourceTag: 'WEBRip', audio: 'Hindi',
}, 'Hindi: 480p WEBRip');

test('Ponniyin Selvan Part 2 2023 Tamil 1080p WEB-DL H.265.mkv', {
  title: 'Ponniyin Selvan Part 2', year: 2023, quality: '1080p', audio: 'Tamil',
}, 'Regional: Tamil');

test('Kantara 2022 Kannada 1080p WEB-DL HEVC.mkv', {
  title: 'Kantara', year: 2022, quality: '1080p', audio: 'Kannada', codec: 'HEVC',
}, 'Regional: Kannada');

test('12th Fail 2023 Hindi 1080p NF WEB-DL x265.mkv', {
  title: '12th Fail', year: 2023, quality: '1080p', audio: 'Hindi', codec: 'HEVC',
}, 'Hindi: numeric title');

// ═══════════════════════════════════════════════════════════════════════════════
// 4. BOT / CHANNEL TAGGED
// ═══════════════════════════════════════════════════════════════════════════════

test('@MovieBot - Inception 2010 1080p.mkv', {
  title: 'Inception', year: 2010, quality: '1080p',
}, 'Bot: @tag prefix');

test('[HDMovies] The Batman 2022 1080p WEB-DL.mkv', {
  title: 'The Batman', year: 2022, quality: '1080p', sourceTag: 'WEB-DL',
}, 'Bot: bracket tag');

test('✅ Oppenheimer 2023 1080p BluRay x265 HEVC.mkv', {
  title: 'Oppenheimer', year: 2023, quality: '1080p', codec: 'HEVC',
}, 'Bot: emoji prefix');

test('🎬 Spider-Man No Way Home 2021 4K WEB-DL.mkv', {
  title: 'Spider Man No Way Home', year: 2021, quality: '4K', sourceTag: 'WEB-DL',
}, 'Bot: emoji movie tag');

// ═══════════════════════════════════════════════════════════════════════════════
// 5. CASUAL / MINIMAL
// ═══════════════════════════════════════════════════════════════════════════════

test('Inception 2010.mp4', {
  title: 'Inception', year: 2010,
}, 'Casual: title + year only');

test('The Godfather.mkv', {
  title: 'The Godfather',
}, 'Casual: title only');

test('Barbie 2023.mkv', {
  title: 'Barbie', year: 2023,
}, 'Casual: simple');

// ═══════════════════════════════════════════════════════════════════════════════
// 6. TV EPISODE FORMATS
// ═══════════════════════════════════════════════════════════════════════════════

test('The.Office.S02E05.1080p.WEB-DL.mkv', {
  title: 'The Office', season: 2, episode: 5, quality: '1080p',
}, 'TV: S02E05');

test('Friends.1x01.720p.BluRay.mkv', {
  title: 'Friends', season: 1, episode: 1, quality: '720p',
}, 'TV: 1x01 format');

test('House.of.the.Dragon.Season.2.Episode.3.1080p.mkv', {
  title: 'House of the Dragon', season: 2, episode: 3, quality: '1080p',
}, 'TV: Season X Episode Y');

test('Narcos EP.05 720p.mkv', {
  title: 'Narcos', episode: 5, quality: '720p',
}, 'TV: EP.05');

test('The Last of Us Episode 4 1080p WEB-DL.mkv', {
  title: 'The Last of Us', episode: 4, quality: '1080p',
}, 'TV: Episode N');

test('Wednesday.S01E01.E02.1080p.NF.WEB-DL.mkv', {
  title: 'Wednesday', season: 1, episode: 1, episodeEnd: 2,
}, 'TV: multi-ep S01E01.E02');

test('Peaky.Blinders.S06E06.FINAL.1080p.WEB-DL.mkv', {
  title: 'Peaky Blinders', season: 6, episode: 6, quality: '1080p',
}, 'TV: FINAL tag');

// ═══════════════════════════════════════════════════════════════════════════════
// 7. SEASON PACKS
// ═══════════════════════════════════════════════════════════════════════════════

test('Breaking.Bad.S01.COMPLETE.1080p.BluRay.x264.mkv', {
  title: 'Breaking Bad', season: 1, isSeasonPack: true, quality: '1080p',
}, 'Pack: S01 COMPLETE');

test('Stranger Things Season 4 Complete 720p WEB-DL.mkv', {
  title: 'Stranger Things', season: 4, isSeasonPack: true, quality: '720p',
}, 'Pack: Season N Complete');

test('The.Witcher.S02.FULL.1080p.NF.WEB-DL.mkv', {
  title: 'The Witcher', season: 2, isSeasonPack: true, quality: '1080p',
}, 'Pack: S02 FULL');

// ═══════════════════════════════════════════════════════════════════════════════
// 8. QUALITY VARIANTS
// ═══════════════════════════════════════════════════════════════════════════════

test('Movie 2024 360p.mkv', { quality: '360p' }, 'Quality: 360p');
test('Movie 2024 480p.mkv', { quality: '480p' }, 'Quality: 480p');
test('Movie 2024 720p.mkv', { quality: '720p' }, 'Quality: 720p');
test('Movie 2024 1080p.mkv', { quality: '1080p' }, 'Quality: 1080p');
test('Movie 2024 2160p.mkv', { quality: '4K' }, 'Quality: 2160p→4K');
test('Movie 2024 4K.mkv', { quality: '4K' }, 'Quality: 4K');

// ═══════════════════════════════════════════════════════════════════════════════
// 9. CODEC VARIANTS
// ═══════════════════════════════════════════════════════════════════════════════

test('Movie x264.mkv', { codec: 'AVC' }, 'Codec: x264→AVC');
test('Movie H.264.mkv', { codec: 'AVC' }, 'Codec: H.264→AVC');
test('Movie x265.mkv', { codec: 'HEVC' }, 'Codec: x265→HEVC');
test('Movie HEVC.mkv', { codec: 'HEVC' }, 'Codec: HEVC');
test('Movie H.265.mkv', { codec: 'HEVC' }, 'Codec: H.265→HEVC');
test('Movie AV1.mkv', { codec: 'AV1' }, 'Codec: AV1');

// ═══════════════════════════════════════════════════════════════════════════════
// 10. SOURCE VARIANTS
// ═══════════════════════════════════════════════════════════════════════════════

test('Movie BluRay.mkv', { sourceTag: 'BluRay' }, 'Source: BluRay');
test('Movie Blu-Ray.mkv', { sourceTag: 'BluRay' }, 'Source: Blu-Ray');
test('Movie BDRip.mkv', { sourceTag: 'BluRay' }, 'Source: BDRip');
test('Movie WEB-DL.mkv', { sourceTag: 'WEB-DL' }, 'Source: WEB-DL');
test('Movie WEBRip.mkv', { sourceTag: 'WEBRip' }, 'Source: WEBRip');
test('Movie HDTV.mkv', { sourceTag: 'HDTV' }, 'Source: HDTV');
test('Movie DVDRip.mkv', { sourceTag: 'DVDRip' }, 'Source: DVDRip');
test('Movie REMUX.mkv', { sourceTag: 'REMUX' }, 'Source: REMUX');

// ═══════════════════════════════════════════════════════════════════════════════
// 11. LANGUAGE / AUDIO VARIANTS
// ═══════════════════════════════════════════════════════════════════════════════

test('Movie Hindi.mkv', { audio: 'Hindi' }, 'Audio: Hindi');
test('Movie Tamil.mkv', { audio: 'Tamil' }, 'Audio: Tamil');
test('Movie Telugu.mkv', { audio: 'Telugu' }, 'Audio: Telugu');
test('Movie Malayalam.mkv', { audio: 'Malayalam' }, 'Audio: Malayalam');
test('Movie Kannada.mkv', { audio: 'Kannada' }, 'Audio: Kannada');
test('Movie Bengali.mkv', { audio: 'Bengali' }, 'Audio: Bengali');
test('Movie Japanese.mkv', { audio: 'Japanese' }, 'Audio: Japanese');
test('Movie Korean.mkv', { audio: 'Korean' }, 'Audio: Korean');
test('Movie English.mkv', { audio: 'English' }, 'Audio: English');
test('Movie Dual Audio.mkv', { audio: 'Dual Audio' }, 'Audio: Dual Audio');
test('Movie Multi Audio.mkv', { audio: 'Multi Audio' }, 'Audio: Multi Audio');

// ═══════════════════════════════════════════════════════════════════════════════
// 12. PLATFORM TAGS
// ═══════════════════════════════════════════════════════════════════════════════

test('Movie NF WEB-DL.mkv', { platformTag: 'NF' }, 'Platform: NF');
test('Movie AMZN WEB-DL.mkv', { platformTag: 'AMZN' }, 'Platform: AMZN');
test('Movie DSNP WEB-DL.mkv', { platformTag: 'DSNP' }, 'Platform: DSNP');
test('Movie HMAX WEB-DL.mkv', { platformTag: 'HMAX' }, 'Platform: HMAX');
test('Movie ATVP WEB-DL.mkv', { platformTag: 'ATVP' }, 'Platform: ATVP');

// ═══════════════════════════════════════════════════════════════════════════════
// 13. ANIME FORMATS
// ═══════════════════════════════════════════════════════════════════════════════

test('One.Piece.E1100.1080p.WEB-DL.mkv', {
  title: 'One Piece', episode: 1100, quality: '1080p',
}, 'Anime: E1100');

test('[SubGroup] Attack on Titan S04E28 1080p.mkv', {
  title: 'Attack on Titan', season: 4, episode: 28, quality: '1080p',
}, 'Anime: subgroup tag');

test('Demon Slayer S03E11 720p WEB-DL Japanese.mkv', {
  title: 'Demon Slayer', season: 3, episode: 11, quality: '720p', audio: 'Japanese',
}, 'Anime: Japanese audio');

test('Naruto Shippuden EP.220 480p.mkv', {
  title: 'Naruto Shippuden', episode: 220, quality: '480p',
}, 'Anime: EP format');

// ═══════════════════════════════════════════════════════════════════════════════
// 14. EDGE CASES
// ═══════════════════════════════════════════════════════════════════════════════

test('', { title: '' }, 'Edge: empty string');

test('2001.A.Space.Odyssey.1968.1080p.BluRay.mkv', {
  year: 1968, quality: '1080p',
}, 'Edge: title starts with number');

test('1917.2019.1080p.WEB-DL.mkv', {
  year: 2019, quality: '1080p',
}, 'Edge: numeric title (1917)');

test('Se7en.1995.720p.BluRay.mkv', {
  year: 1995, quality: '720p',
}, 'Edge: special chars in title');

test('Spider-Man.Across.the.Spider-Verse.2023.1080p.WEB-DL.mkv', {
  title: 'Spider Man Across the Spider Verse', year: 2023, quality: '1080p',
}, 'Edge: hyphens in title stripped for search');

test('The.100.S07E16.1080p.WEB-DL.mkv', {
  season: 7, episode: 16, quality: '1080p',
}, 'Edge: "The 100" numeric show');

// ═══════════════════════════════════════════════════════════════════════════════
// 15. NORMALIZE TESTS
// ═══════════════════════════════════════════════════════════════════════════════

console.log('');
console.log('── Normalize tests ──');
const normTests = [
  ['Spider-Man: No Way Home', 'spiderman no way home'],
  ['  The  Batman  ', 'the batman'],
  ['K.G.F: Chapter 2', 'kgf chapter 2'],
  ['12th Fail', '12th fail'],
];
for (const [input, expected] of normTests) {
  const got = normalize(input);
  if (got === expected) {
    passed++;
  } else {
    failed++;
    console.log(`❌ normalize("${input}") = "${got}" expected "${expected}"`);
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// RESULTS
// ═══════════════════════════════════════════════════════════════════════════════

console.log('');
console.log('═══════════════════════════════════════');
console.log(`  ✅ Passed: ${passed}`);
console.log(`  ❌ Failed: ${failed}`);
console.log(`  Total:    ${passed + failed}`);
console.log('═══════════════════════════════════════');
process.exit(failed > 0 ? 1 : 0);
