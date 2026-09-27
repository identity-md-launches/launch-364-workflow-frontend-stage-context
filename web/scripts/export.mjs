import { readFile, writeFile, mkdir, readdir, stat } from 'node:fs/promises';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { keccak256, toHex } from 'viem';

const root = fileURLToPath(new URL('../../', import.meta.url));
const handoff = JSON.parse(await readFile(`${root}web/deployment/handoff.json`));
const network = JSON.parse(await readFile(`${root}web/deployment/network.json`));
const canonical = (v) => JSON.stringify(sort(v));
function sort(v) {
  if (Array.isArray(v)) return v.map(sort);
  if (v && typeof v === 'object') return Object.fromEntries(Object.keys(v).sort().map(k => [k, sort(v[k])]));
  return v;
}
const check = process.argv.includes('--check');
const contracts = [];
if (handoff.chainId !== network.network.chainId || Number(BigInt(network.walletAddChain.chainId)) !== handoff.chainId) throw Error('Chain mismatch');
for (const contract of handoff.contracts) {
  if (!/^[A-Za-z0-9_]+$/.test(contract.name)) throw Error('Invalid contract name');
  const bytes = execFileSync('git', ['show', `${handoff.sourceCommit}:docs/abi/${contract.name}.json`], { cwd: root });
  const abi = JSON.parse(bytes);
  const hash = keccak256(toHex(canonical(abi))).slice(2);
  if (!Array.isArray(abi) || hash !== contract.abiHash) throw Error(`Pinned ABI hash mismatch: ${contract.name} (${hash})`);
  const abiPath = `abi/${contract.name}.json`;
  if (check) {
    if (!(await readFile(`${root}dist/${abiPath}`)).equals(bytes)) throw Error(`Exported ABI differs: ${abiPath}`);
  } else {
    await mkdir(`${root}dist/abi`, { recursive: true });
    await writeFile(`${root}dist/${abiPath}`, bytes);
  }
  contracts.push({ name: contract.name, address: contract.address, abiHash: contract.abiHash, abiPath });
  console.log(`Verified pinned ABI ${contract.name}: ${hash}`);
}
async function files(dir, prefix = '') {
  const entries = await readdir(dir, { withFileTypes: true });
  const found = [];
  for (const e of entries) {
    const path = prefix + e.name;
    if (e.isSymbolicLink()) throw Error('No symlinks in export');
    if (e.isDirectory()) found.push(...await files(`${dir}/${e.name}`, `${path}/`));
    else if (path !== 'imd-deployment.json') found.push(path);
  }
  return found.sort();
}
const paths = await files(`${root}dist`);
if (paths.length > 128 || !paths.includes('index.html')) throw Error('Invalid asset count/entrypoint');
let total = 0;
const assets = [];
for (const path of paths) {
  const bytes = await readFile(`${root}dist/${path}`);
  if ((await stat(`${root}dist/${path}`)).size > 8388608) throw Error(`Asset too large: ${path}`);
  total += bytes.length;
  assets.push({ path, sha256: createHash('sha256').update(bytes).digest('hex') });
}
if (total > 8_000_000) throw Error('Export exceeds submission budget');
const manifest = {
  version: 1, launchId: handoff.launchId, chainId: handoff.chainId,
  sourceCommit: handoff.sourceCommit, attestationHash: handoff.attestationHash,
  contracts, assets, network: network.network, walletAddChain: network.walletAddChain,
  pool: handoff.manifest.pool,
};
if (check) {
  const actual = JSON.parse(await readFile(`${root}dist/imd-deployment.json`));
  if (canonical(actual) !== canonical(manifest)) throw Error('Manifest does not match final export and handoff');
} else await writeFile(`${root}dist/imd-deployment.json`, JSON.stringify(manifest, null, 2) + '\n');
console.log(`${check ? 'Checked' : 'Wrote'} manifest: ${paths.length} assets, ${total} bytes. Network object preserved unchanged.`);
