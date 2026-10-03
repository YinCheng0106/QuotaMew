// Optional read-only cross-check against the actual website parser using Bun.
// All GitHub facts below are synthetic; no network calls or website writes.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

const [website, fixtures] = process.argv.slice(2);
assert.ok(website && fixtures, 'Usage: bun check_website_contract.ts <website-repo> <fixtures.json>');
const { mergeManifest, githubFacts, manifestFilename } = await import(
  pathToFileURL(join(resolve(website), 'scripts/releases/contract.ts')).href
);
assert.equal(manifestFilename, 'quotamew-release-manifest.json');
const candidates = JSON.parse(readFileSync(fixtures, 'utf8'));
for (const m of candidates) {
  const base = 'https://github.com/YinCheng0106/QuotaMew/releases';
  const facts = githubFacts({
    tag_name: m.tag, draft: false, prerelease: m.channel === 'preview',
    html_url: `${base}/tag/${m.tag}`, published_at: '2026-01-01T00:00:00Z',
    assets: [{ name: m.artifact.filename, size: 1, digest: `sha256:${'0'.repeat(64)}`,
      browser_download_url: `${base}/download/${m.tag}/${m.artifact.filename}` }],
  }, m.channel);
  const accepted = mergeManifest(m, facts);
  for (const key of ['schemaVersion', 'tag', 'version', 'build', 'channel', 'minimumMacOS', 'bundleID', 'signing']) {
    assert.deepEqual(accepted[key], m[key]);
  }
  for (const mutate of [
    (d: any) => { d.schemaVersion = 2; },
    (d: any) => { d.generatedAt = 'forbidden'; },
    (d: any) => { d.channel = d.channel === 'preview' ? 'stable' : 'preview'; },
    (d: any) => { d.version = '9.9.9'; },
    (d: any) => { d.bundleID = 'dev.quotapulse.development.app'; },
    (d: any) => { d.artifact.filename = 'wrong.dmg'; },
    (d: any) => { d.signing.type = 'ad-hoc'; },
    (d: any) => { d.signing.extra = true; },
  ]) {
    const invalid = structuredClone(m);
    mutate(invalid);
    assert.throws(() => mergeManifest(invalid, facts));
  }
}
console.log(`Website v1 parser compatibility: ${candidates.length} candidates passed`);
