// Public install count for the site: live count plus the recorded backfill.
// Cached at the edge for 30 seconds (at most about a minute stale).
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { countInstalls, LIVE_SINCE } from './_count.js';

// backfill.json: installer runs before live counting, from recorded request
// metrics only. Read once; a missing or broken file fails the request rather
// than silently showing a smaller number.
const BACKFILL = JSON.parse(readFileSync(join(process.cwd(), 'backfill.json'), 'utf8'));
if (!Number.isInteger(BACKFILL.installs) || BACKFILL.installs < 0) throw new Error('backfill.json: installs must be a non-negative integer');

export default async function handler(req, res) {
  try {
    const live = await countInstalls();
    res.setHeader('Cache-Control', 'public, max-age=0, must-revalidate');
    res.setHeader('Vercel-CDN-Cache-Control', 'public, s-maxage=30, stale-while-revalidate=30');
    return res.status(200).json({
      installs: BACKFILL.installs + live,
      since: '2026-09-26',
      live: { installs: live, since: LIVE_SINCE },
      backfill: { installs: BACKFILL.installs, from: BACKFILL.from, to: BACKFILL.to, source: 'Vercel request metrics', file: 'backfill.json' },
      counted: 'installer runs: downloads of the hook by install.sh, one per network per day, our own test machines excluded',
    });
  } catch (e) {
    console.error('install count: list failed:', e && e.message ? e.message : e);
    res.setHeader('Cache-Control', 'no-store');
    return res.status(503).json({ error: 'count unavailable' });
  }
}
