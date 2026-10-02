// Public install count for the site. Cached at the edge for 5 minutes.
import { countInstalls, SINCE } from './_count.js';

export default async function handler(req, res) {
  try {
    const installs = await countInstalls();
    res.setHeader('Cache-Control', 'public, max-age=60');
    res.setHeader('Vercel-CDN-Cache-Control', 'public, s-maxage=300, stale-while-revalidate=600');
    return res.status(200).json({
      installs,
      since: SINCE,
      counted: 'installer runs: downloads of the hook by install.sh, one per network per day',
    });
  } catch (e) {
    console.error('install count: list failed:', e && e.message ? e.message : e);
    res.setHeader('Cache-Control', 'no-store');
    return res.status(503).json({ error: 'count unavailable' });
  }
}
