// Install counter shared by api/hook.js and api/count.js.
//
// What is counted: downloads of bin/lastcall-hook.sh by curl. Only install.sh
// downloads that file (uninstall.sh never does), so each one is an installer run.
// Dedupe: one per network per UTC day. The marker name is a salted SHA-256 of
// day + IP; the IP itself is never stored, and the marker holds no other data.
import { createHash } from 'node:crypto';
import { put, list } from '@vercel/blob';

// Live counting started 2026-10-02; backfill.json covers launch up to then.
export const LIVE_SINCE = '2026-10-02';
// Previews count into their own folder so testing never touches the public number.
const PREFIX = process.env.VERCEL_ENV === 'production' ? 'installs/' : 'preview-installs/';

function clientIp(req) {
  const fwd = String(req.headers['x-forwarded-for'] || '').split(',')[0].trim();
  return fwd || String(req.headers['x-real-ip'] || '').trim();
}

export function isInstallerFetch(req) {
  return /^curl\//i.test(String(req.headers['user-agent'] || ''));
}

export async function recordInstall(req) {
  const salt = process.env.COUNT_SALT;
  if (!salt) { console.error('install count: COUNT_SALT is not set, not recording'); return false; }
  const ip = clientIp(req);
  if (!ip) { console.error('install count: no client IP, not recording'); return false; }
  // Our own build and test networks (env COUNT_EXCLUDE_IPS, comma separated,
  // kept out of the public repo) never count.
  const own = String(process.env.COUNT_EXCLUDE_IPS || '').split(',').map((x) => x.trim()).filter(Boolean);
  if (own.includes(ip)) return false;
  const day = new Date().toISOString().slice(0, 10);
  const key = createHash('sha256').update(salt + '|' + day + '|' + ip).digest('hex').slice(0, 40);
  // Same network, same day: same name, so the write overwrites instead of adding.
  await put(PREFIX + day + '/' + key, '1', {
    access: 'public', addRandomSuffix: false, allowOverwrite: true, contentType: 'text/plain',
  });
  return true;
}

export async function countInstalls() {
  let n = 0, cursor;
  do {
    const page = await list({ prefix: PREFIX, limit: 1000, cursor });
    n += page.blobs.length;
    cursor = page.hasMore ? page.cursor : undefined;
  } while (cursor);
  return n;
}
