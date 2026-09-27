import { execFileSync } from 'node:child_process';
import { readFile, writeFile, stat, lstat } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';

const root = fileURLToPath(new URL('../../', import.meta.url));
const git = args => execFileSync('git', args, { cwd: root }).toString().split('\0').filter(Boolean);
const tracked = git(['ls-files', '-z']);
const additions = git(['ls-files', '--others', '--exclude-standard', '-z']);
const changes = git(['diff', '--name-only', '-z']);
const staged = git(['diff', '--cached', '--name-only', '-z']);
for (const path of new Set([...additions, ...changes, ...staged])) {
  if (!/^(web|dist|docs)\//.test(path)) throw Error(`Out of scope: ${path}`);
  if (path.includes('/.') && path !== 'web/.gitignore') throw Error(`Unbudgeted dotfile: ${path}`);
  if (/(^|\/)(node_modules|\.cache|\.npm|\.vite)(\/|$)/.test(path) || path.endsWith('.tgz')) throw Error(`Dependency/cache artifact: ${path}`);
  if ((await lstat(`${root}${path}`)).isSymbolicLink()) throw Error(`Symlink: ${path}`);
}
if (git(['ls-files', '--stage', '-z']).some(line => line.startsWith('160000 '))) throw Error('Git submodule present');
let rawBytes = 0;
for (const path of new Set([...tracked, ...additions])) rawBytes += (await stat(`${root}${path}`)).size;
if (rawBytes >= 7_000_000) throw Error('Insufficient room below 8 MiB bundle budget');
const manifestBytes = await readFile(`${root}dist/imd-deployment.json`);
const manifest = JSON.parse(manifestBytes);
let exportedBytes = manifestBytes.length;
for (const asset of manifest.assets) {
  const bytes = await readFile(`${root}dist/${asset.path}`);
  if (createHash('sha256').update(bytes).digest('hex') !== asset.sha256) throw Error(`Hash mismatch: ${asset.path}`);
  exportedBytes += bytes.length;
}
const evidence = {
  checkedAt: new Date().toISOString(), allowedPaths: ['web/**', 'dist/**', 'docs/**', 'web/.gitignore'],
  ignoreFileBudget: ['web/.gitignore'], trackedBaselineFiles: tracked.length, additions: additions.length,
  protectedTrackedFilesChanged: [...changes, ...staged].filter(p => !/^(web|dist|docs)\//.test(p)),
  baselinePlusDeliveryRawBytes: rawBytes, bundleBudgetBytes: 8388608, rawHeadroomBytes: 8388608 - rawBytes,
  assetCountExcludingManifest: manifest.assets.length, exportedBytesIncludingManifest: exportedBytes,
  noDependencyCachesOrArchives: true, noSubmodulesOrNewSymlinks: true,
  gitRecording: 'git add web dist docs failed: .git/index.lock is on a read-only filesystem. Files are delivered in the working tree; no commit or exact Git bundle could be created here.',
  sizeNote: 'Raw current tracked tree plus all nonignored additions is a conservative size check, not a measured Git bundle. Almost 4 MB remains for Git metadata/history overhead.',
};
await writeFile(`${root}docs/evidence/submission-audit.json`, JSON.stringify(evidence, null, 2) + '\n');
console.log(JSON.stringify(evidence, null, 2));
