import { encodeAbiParameters, keccak256, parseUnits, formatUnits, type Address, type Hex } from 'viem';
import type { Config } from './config';

export type Round = { id: bigint; stake: bigint; joinDeadline: bigint; revealDeadline: bigint;
  playerCount: bigint; revealCount: bigint; saltXor: Hex; settled: boolean; heads: boolean; winners: bigint; share: bigint; phase: number };
export type Player = { commitment: Hex; joined: boolean; revealed: boolean; heads: boolean; reclaimed: boolean };
export type Secret = { version: 1; chainId: number; game: Address; account: Address; roundId: string; heads: boolean; salt: Hex };
export const phases = ['Joining', 'Reveal now', 'Reclaimable', 'Ready to settle', 'Settled'];
export const units = (v: bigint, decimals: number) => formatUnits(v, decimals);
export function stakeAmount(input: string, decimals: number) {
  if (!new RegExp(`^\\d+(?:\\.\\d{1,${decimals}})?$`).test(input)) throw new Error(`Enter a HEDS amount with up to ${decimals} decimal places.`);
  const value = parseUnits(input, decimals);
  if (value < 10n ** BigInt(decimals) || value > ((1n << 256n) - 1n) / 16n) throw new Error('Enter at least 1 HEDS, within the contract’s stake limit.');
  return value;
}
export function commitment(secret: Secret): Hex {
  return keccak256(encodeAbiParameters([{ type: 'bool' }, { type: 'bytes32' }, { type: 'address' }, { type: 'uint256' }],
    [secret.heads, secret.salt, secret.account, BigInt(secret.roundId)]));
}
export function secretKey(config: Config, account: Address, id: bigint) {
  return `heads:v1:${config.deployment.chainId}:${config.game.address.toLowerCase()}:${account.toLowerCase()}:${id}`;
}
export function validateSecret(value: unknown, config: Config, account: Address, id: bigint): Secret {
  const s = value as Secret;
  if (!s || s.version !== 1 || s.chainId !== config.deployment.chainId || s.game?.toLowerCase() !== config.game.address.toLowerCase() ||
    s.account?.toLowerCase() !== account.toLowerCase() || s.roundId !== String(id) || typeof s.heads !== 'boolean' || !/^0x[0-9a-fA-F]{64}$/.test(s.salt))
    throw new Error('Backup must match this wallet, round, chain and game. Paste the original backup JSON.');
  return s;
}
export function readSecret(config: Config, account: Address, id: bigint): Secret | null {
  const stored = localStorage.getItem(secretKey(config, account, id));
  return stored ? validateSecret(JSON.parse(stored), config, account, id) : null;
}
export function storeSecret(config: Config, account: Address, id: bigint, secret: Secret) {
  const key = secretKey(config, account, id);
  localStorage.setItem(key, JSON.stringify(secret));
  if (localStorage.getItem(key) !== JSON.stringify(secret)) throw new Error('Secret could not be saved. Enable local storage before joining.');
}
export function newSecret(config: Config, account: Address, id: bigint, heads: boolean): Secret {
  const bytes = crypto.getRandomValues(new Uint8Array(32));
  return { version: 1, chainId: config.deployment.chainId, game: config.game.address, account, roundId: String(id), heads,
    salt: `0x${Array.from(bytes, b => b.toString(16).padStart(2, '0')).join('')}` };
}
export function resultText(round: Round, decimals: number) {
  if (!round.settled) return 'Outcome is recorded after settlement.';
  if (round.playerCount === 0n) return 'Empty round · no payout';
  if (round.revealCount === 0n) return `Stake refund · ${units(round.share, decimals)} HEDS per player`;
  const coin = round.heads ? 'Heads' : 'Tails';
  if (round.winners === 0n) return `${coin} · no matching picks. Each revealer receives ${units(round.share, decimals)} HEDS.`;
  return `${coin} · ${round.winners} winning ${round.winners === 1n ? 'pick' : 'picks'}. ${units(round.share, decimals)} HEDS per winner.`;
}
export function errorMessage(e: unknown) {
  type Cause = { code?: number; shortMessage?: string; message?: string; details?: string; reason?: string; data?: { errorName?: string }; cause?: Cause };
  const error = e as Cause;
  let current = error;
  let detail = '';
  for (let i = 0; current && i < 10; i++, current = current.cause!) {
    if (current.code === 4001 || /user rejected|user denied/i.test(current.shortMessage ?? current.message ?? ''))
      return 'Wallet request rejected. Your saved secret is safe; try again when ready.';
    if (current.data?.errorName || current.reason) return `Contract rejected the action: ${current.data?.errorName || current.reason}. Refresh and check the round’s requirements.`;
    if (current.details) detail = current.details;
  }
  return detail || error?.shortMessage || error?.message || 'Request failed. Check your connection and retry.';
}
