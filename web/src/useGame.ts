import { useCallback, useEffect, useRef, useState } from 'react';
import { createWalletClient, custom, type Address, type Hex } from 'viem';
import { verifyChain, type Config, type Contract } from './config';
import { errorMessage, type Player, type Round } from './game';
import { switchChain, walletState } from './wallet';

export type Snapshot = { rounds: Round[]; selected?: Round; player?: Player; count: bigint; decimals: number;
  balance?: bigint; allowance?: bigint; withdrawable?: bigint; timestamp: bigint; block: bigint; account?: Address };
export function useGame(config: Config) {
  const [account, setAccount] = useState<Address>();
  const [chainId, setChainId] = useState<number>();
  const [walletRevision, setWalletRevision] = useState(0);
  const [selectedId, setSelectedId] = useState<bigint>();
  const [page, setPage] = useState(0);
  const [snapshot, setSnapshot] = useState<Snapshot>();
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');
  const [readError, setReadError] = useState('');
  const [status, setStatus] = useState('Reading the deployment…');
  const [busy, setBusy] = useState(false);
  const [txHash, setTxHash] = useState<Hex>();
  const generation = useRef(0);
  const actionLock = useRef(false);
  const readSerial = useRef(0);
  const refresh = useCallback(async () => {
    const serial = ++readSerial.current;
    const session = generation.current;
    setLoading(true);
    try {
      const { client, game, token } = config;
      const tokenAddress = await verifyChain(config);
      const block = await client.getBlock();
      const read = (contract: Contract, functionName: string, args: readonly unknown[] = []) =>
        client.readContract({ address: contract.address, abi: contract.abi, functionName, args, blockNumber: block.number });
      const count = await read(game, 'roundCount') as bigint;
      const decimals = Number(await read({ ...token, address: tokenAddress }, 'decimals'));
      if (decimals !== 18) throw new Error('Unexpected HEDS decimals. Transactions are disabled.');
      const top = count - BigInt(page * 6);
      const ids = Array.from({ length: Number(top > 6n ? 6n : top > 0n ? top : 0n) }, (_, i) => top - BigInt(i));
      const chosen = selectedId ?? ids[0];
      if (chosen && (chosen < 1n || chosen > count)) throw new Error('Round not found. Select an existing round.');
      const allIds = [...new Set([...ids, ...(chosen ? [chosen] : [])])];
      const rounds = await Promise.all(allIds.map(async id => ({ ...await read(game, 'round', [id]) as Omit<Round, 'id' | 'phase'>,
        id, phase: Number(await read(game, 'phase', [id])) })));
      const [balance, allowance, withdrawable, player] = account ? await Promise.all([
        read({ ...token, address: tokenAddress }, 'balanceOf', [account]),
        read({ ...token, address: tokenAddress }, 'allowance', [account, game.address]),
        read(game, 'withdrawable', [account]), chosen ? read(game, 'player', [chosen, account]) : Promise.resolve(undefined),
      ]) : [];
      if (serial !== readSerial.current || session !== generation.current) return false;
      setSnapshot({ rounds: rounds.filter(r => ids.includes(r.id)), selected: rounds.find(r => r.id === chosen),
        player: player as Player | undefined, count, decimals, balance: balance as bigint | undefined,
        allowance: allowance as bigint | undefined, withdrawable: withdrawable as bigint | undefined,
        timestamp: block.timestamp, block: block.number, account });
      setReadError('');
      if (!actionLock.current) setStatus(`Live reads verified · block ${block.number.toLocaleString()}`);
      return true;
    } catch (e) {
      if (serial === readSerial.current && session === generation.current) { setSnapshot(undefined); setReadError(errorMessage(e)); setStatus('Live reads unavailable. Use Refresh to retry.'); }
      return false;
    } finally { if (serial === readSerial.current && session === generation.current) setLoading(false); }
  }, [config, account, chainId, walletRevision, selectedId, page]);

  useEffect(() => {
    let stopped = false;
    let timer: ReturnType<typeof setTimeout>;
    const poll = async () => { await refresh(); if (!stopped) timer = setTimeout(() => void poll(), 15_000); };
    void poll();
    return () => { stopped = true; clearTimeout(timer); readSerial.current++; };
  }, [refresh]);
  const syncWallet = useCallback(async (connect = false) => {
    if (!window.ethereum) { setError('No browser wallet detected. Install a compatible Ethereum wallet, then reload this page.'); return; }
    const session = ++generation.current;
    setSnapshot(undefined);
    try {
      const state = await walletState(window.ethereum, connect);
      if (session !== generation.current) return;
      setAccount(state.account); setChainId(state.chainId); setWalletRevision(v => v + 1); setError('');
    } catch (e) { if (session === generation.current) { setAccount(undefined); setChainId(undefined); setError(errorMessage(e)); } }
  }, []);
  useEffect(() => {
    const provider = window.ethereum;
    if (!provider) return;
    const changed = () => { void syncWallet(); };
    const disconnected = () => { generation.current++; setAccount(undefined); setChainId(undefined); setSnapshot(undefined); };
    provider.on?.('accountsChanged', changed); provider.on?.('chainChanged', changed); provider.on?.('disconnect', disconnected);
    void syncWallet();
    return () => { generation.current++; provider.removeListener?.('accountsChanged', changed); provider.removeListener?.('chainChanged', changed); provider.removeListener?.('disconnect', disconnected); };
  }, [syncWallet]);
  const ready = !!account && chainId === config.deployment.chainId && !!snapshot && snapshot.account === account && !loading && !busy;

  async function transact(label: string, contract: Contract, functionName: string, args: readonly unknown[] = []) {
    if (!ready || !account || !window.ethereum || actionLock.current) { setError('Connect on the correct network and wait for verified live reads.'); return false; }
    actionLock.current = true; setBusy(true); setError(''); setTxHash(undefined);
    const session = generation.current;
    try {
      setStatus(`Checking ${label.toLowerCase()}…`);
      await verifyChain(config);
      const { request } = await config.client.simulateContract({ address: contract.address, abi: contract.abi,
        functionName, args, account });
      const state = await walletState(window.ethereum);
      if (session !== generation.current || state.account?.toLowerCase() !== account.toLowerCase() || state.chainId !== config.deployment.chainId)
        throw new Error('Wallet or network changed. Refresh and try again.');
      const wallet = createWalletClient({ chain: config.chain, transport: custom(window.ethereum), account });
      setStatus(`${label}: confirm in your wallet.`);
      const hash = await wallet.writeContract({ ...request, account, chain: config.chain });
      setTxHash(hash); setStatus(`${label}: submitted. Waiting for confirmation…`);
      let cancelled = false;
      const receipt = await config.client.waitForTransactionReceipt({ hash, timeout: 120_000,
        onReplaced: replacement => { setTxHash(replacement.transaction.hash); cancelled = replacement.reason !== 'repriced'; } });
      if (cancelled) throw new Error(`${label} was replaced or cancelled. Check the transaction link and refresh.`);
      if (receipt.status !== 'success') throw new Error(`${label} reverted. Refresh the state before trying again.`);
      if (session === generation.current) {
        const updated = await refresh();
        setStatus(`${label} confirmed. ${updated ? 'Live balances refreshed.' : 'Use Refresh to reload balances.'}`);
      }
      else setStatus(`${label} confirmed for the previous wallet. Refresh this wallet’s state.`);
      return true;
    } catch (e) { setError(errorMessage(e)); setStatus(`${label} did not complete here. If submitted, check the transaction link before retrying.`); return false; }
    finally { setBusy(false); actionLock.current = false; }
  }
  async function switchNetwork() {
    if (!window.ethereum || actionLock.current) return;
    actionLock.current = true; setBusy(true); setError('');
    try { await switchChain(window.ethereum, config); await syncWallet(); }
    catch (e) { setError(errorMessage(e)); }
    finally { setBusy(false); actionLock.current = false; }
  }
  return { account, chainId, snapshot, ready, busy, loading, error: error || readError, status, txHash, page, setPage,
    selectedId, select: (id: bigint) => { setSnapshot(undefined); setSelectedId(id); },
    connect: () => syncWallet(true), switchNetwork, refresh, transact };
}
export type Game = ReturnType<typeof useGame>;
