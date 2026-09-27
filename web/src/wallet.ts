import type { Address } from 'viem';
import type { Config } from './config';
export type Provider = {
  request: (args: { method: string; params?: unknown[] }) => Promise<unknown>;
  on?: (event: string, listener: (...args: unknown[]) => void) => void;
  removeListener?: (event: string, listener: (...args: unknown[]) => void) => void;
};
declare global { interface Window { ethereum?: Provider } }
export async function switchChain(provider: Provider, config: Config) {
  const chainId = config.deployment.walletAddChain.chainId;
  try { await provider.request({ method: 'wallet_switchEthereumChain', params: [{ chainId }] }); }
  catch (e) {
    const err = e as { code?: number; message?: string; data?: { originalError?: { code?: number } } };
    if (err.code !== 4902 && err.data?.originalError?.code !== 4902 && !/unknown chain|unrecognized chain|not added/i.test(err.message ?? '')) throw e;
    await provider.request({ method: 'wallet_addEthereumChain', params: [config.deployment.walletAddChain] });
    await provider.request({ method: 'wallet_switchEthereumChain', params: [{ chainId }] });
  }
}
export async function walletState(provider: Provider, connect = false) {
  const accounts = await provider.request({ method: connect ? 'eth_requestAccounts' : 'eth_accounts' }) as Address[];
  const chainId = Number(BigInt(await provider.request({ method: 'eth_chainId' }) as string));
  return { account: accounts[0], chainId };
}
