import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { createPublicClient, http } from 'viem';

const manifest = JSON.parse(await readFile(new URL('../../dist/imd-deployment.json', import.meta.url)));
const records = [];
for (const url of manifest.network.rpcUrls) {
  const client = createPublicClient({ transport: http(url, { timeout: 10_000, retryCount: 0 }) });
  const record = { rpc: url };
  try {
    record.chainId = await client.getChainId();
    if (record.chainId !== manifest.chainId) throw Error('Wrong RPC chain');
    record.contracts = [];
    for (const c of manifest.contracts) {
      const code = await client.getCode({ address: c.address });
      if (!code || code === '0x') throw Error(`No code: ${c.name}`);
      record.contracts.push({ name: c.name, address: c.address, runtimeBytes: (code.length - 2) / 2 });
    }
    const game = manifest.contracts.find(c => c.name === 'CommitRevealCoinFlip');
    const token = manifest.contracts.find(c => c.name === 'LaunchToken');
    const abi = JSON.parse(await readFile(new URL(`../../dist/${game.abiPath}`, import.meta.url)));
    record.token = await client.readContract({ address: game.address, abi, functionName: 'token' });
    if (record.token.toLowerCase() !== token.address.toLowerCase()) throw Error('Token address mismatch');
    record.roundCount = String(await client.readContract({ address: game.address, abi, functionName: 'roundCount' }));
    record.blockNumber = String(await client.getBlockNumber());
    record.verified = true;
  } catch (e) { record.verified = false; record.error = e.shortMessage ?? e.message; }
  records.push(record);
}
const evidence = { checkedAt: new Date().toISOString(), readOnly: true, noTransactions: true, records };
await mkdir(new URL('../../docs/evidence/', import.meta.url), { recursive: true });
await writeFile(new URL('../../docs/evidence/live-rpc.json', import.meta.url), JSON.stringify(evidence, null, 2) + '\n');
console.log(JSON.stringify(evidence, null, 2));
if (!records.some(r => r.verified)) process.exitCode = 1;
