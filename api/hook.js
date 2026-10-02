// Serves bin/lastcall-hook.sh (byte for byte, install.sh checks it against
// SHA256SUMS) and counts the download when it comes from the installer.
// Counting never blocks or breaks the download: it has a short time limit and
// any failure is logged and ignored.
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { isInstallerFetch, recordInstall } from './_count.js';

const HOOK = readFileSync(join(process.cwd(), 'bin', 'lastcall-hook.sh'));

export default async function handler(req, res) {
  if (req.method !== 'GET' && req.method !== 'HEAD') {
    res.setHeader('Allow', 'GET, HEAD');
    return res.status(405).send('Method not allowed\n');
  }
  if (req.method === 'GET' && isInstallerFetch(req)) {
    try {
      await Promise.race([
        recordInstall(req),
        new Promise((_, reject) => setTimeout(() => reject(new Error('timed out after 2s')), 2000)),
      ]);
    } catch (e) {
      console.error('install count: record failed:', e && e.message ? e.message : e);
    }
  }
  res.setHeader('Content-Type', 'text/plain; charset=utf-8');
  res.setHeader('Cache-Control', 'no-store');
  res.setHeader('Vercel-CDN-Cache-Control', 'no-store');
  res.setHeader('Content-Length', String(HOOK.length));
  return res.status(200).end(req.method === 'HEAD' ? undefined : HOOK);
}
