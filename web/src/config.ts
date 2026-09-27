import { createPublicClient, defineChain, fallback, http, isAddress, keccak256, toHex, type Abi, type Address } from 'viem';

export type Contract = { name: string; address: Address; abiHash: string; abiPath: string; abi: Abi };
export type Deployment = {
  version: number; launchId: string; chainId: number; sourceCommit: string; attestationHash: string;
  contracts: Contract[]; assets: { path: string; sha256: string }[];
  network: { chainId: number; name: string; testnet: boolean; rpcUrls: string[]; explorer: string;
    nativeCurrency: { name: string; symbol: string; decimals: number }; faucets: string[];
    uniswapV4: Record<string, Address> };
  walletAddChain: { chainId: string; chainName: string; rpcUrls: string[];
    nativeCurrency: { name: string; symbol: string; decimals: number }; blockExplorerUrls: string[] };
};
export function canonical(value: unknown): string {
  function sorted(v: unknown): unknown {
    if (Array.isArray(v)) return v.map(sorted);
    if (v && typeof v === 'object') return Object.fromEntries(Object.entries(v).sort(([a], [b]) => a < b ? -1 : a > b ? 1 : 0).map(([k, v]) => [k, sorted(v)]));
    return v;
  }
  return JSON.stringify(sorted(value));
}
const safePath = (path: string) => /^[a-zA-Z0-9_./-]+$/.test(path) && !path.startsWith('/') && !path.split('/').includes('..');
async function json(path: string) {
  const response = await fetch(new URL(path, new URL('./', window.location.href)), { cache: 'no-cache' });
  if (!response.ok) throw new Error(`Unable to load ${path}. Reload the page to retry.`);
  return response.json();
}
export async function loadConfig() {
  const deployment = await json('imd-deployment.json') as Deployment;
  if (deployment.version !== 1 || deployment.chainId !== deployment.network?.chainId ||
      Number(BigInt(deployment.walletAddChain.chainId)) !== deployment.chainId ||
      !/^[0-9a-f]{64}$/.test(deployment.attestationHash) || !deployment.network.rpcUrls.length)
    throw new Error('Deployment configuration is inconsistent. Transactions are disabled.');
  for (const contract of deployment.contracts) {
    if (!isAddress(contract.address) || !safePath(contract.abiPath)) throw new Error('Invalid deployment contract.');
    contract.abi = await json(contract.abiPath) as Abi;
    if (!Array.isArray(contract.abi) || keccak256(toHex(canonical(contract.abi))).slice(2) !== contract.abiHash)
      throw new Error(`ABI verification failed for ${contract.name}. Transactions are disabled.`);
  }
  const game = deployment.contracts.find(c => c.name === 'CommitRevealCoinFlip');
  const token = deployment.contracts.find(c => c.name === 'LaunchToken');
  if (!game || !token || deployment.contracts.length !== 2) throw new Error('Expected deployment contracts are missing.');
  const chain = defineChain({ id: deployment.chainId, name: deployment.network.name,
    nativeCurrency: deployment.network.nativeCurrency, testnet: deployment.network.testnet,
    rpcUrls: { default: { http: deployment.network.rpcUrls } } });
  const client = createPublicClient({ chain, transport: fallback(deployment.network.rpcUrls.map(url => http(url, { timeout: 8_000, retryCount: 0 })), { retryCount: 0 }) });
  return { deployment, game, token, chain, client };
}
export type Config = Awaited<ReturnType<typeof loadConfig>>;
export async function verifyChain(config: Config) {
  const { client, deployment, game, token } = config;
  const [chainId, gameCode, tokenCode, tokenAddress] = await Promise.all([
    client.getChainId(), client.getCode({ address: game.address }), client.getCode({ address: token.address }),
    client.readContract({ address: game.address, abi: game.abi, functionName: 'token' }),
  ]);
  if (chainId !== deployment.chainId || !gameCode || gameCode === '0x' || !tokenCode || tokenCode === '0x')
    throw new Error('The RPC chain or deployed code could not be verified. Retry live reads.');
  if (String(tokenAddress).toLowerCase() !== token.address.toLowerCase())
    throw new Error('The game’s HEDS address differs from the deployment. Transactions are disabled.');
  return tokenAddress as Address;
}
