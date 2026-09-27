import { useEffect, useState, type FormEvent } from 'react';
import type { Config } from './config';
import { useGame, type Game } from './useGame';
import { commitment, errorMessage, newSecret, phases, readSecret, resultText, stakeAmount, storeSecret, units, validateSecret, type Secret } from './game';

const short = (value: string) => `${value.slice(0, 6)}…${value.slice(-4)}`;
const date = (seconds: bigint) => new Date(Number(seconds) * 1000).toLocaleString(undefined, { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit', timeZoneName: 'short' });
function External({ href, children }: { href: string; children: React.ReactNode }) {
  return <a href={href} target="_blank" rel="noreferrer">{children} <span aria-hidden="true">↗</span></a>;
}

export default function App({ config }: { config: Config }) {
  const game = useGame(config);
  const { account, snapshot: snap, ready, busy } = game;
  const [stake, setStake] = useState('10');
  const [stakeError, setStakeError] = useState('');
  const [findId, setFindId] = useState('');
  const [findError, setFindError] = useState('');
  const explorer = config.deployment.network.explorer;
  async function create(e: FormEvent) {
    e.preventDefault(); setStakeError('');
    try { const value = stakeAmount(stake, snap?.decimals ?? 18); await game.transact('Create round', config.game, 'createRound', [value]); }
    catch (e) { setStakeError(errorMessage(e)); document.getElementById('stake')?.focus(); }
  }
  function find(e: FormEvent) {
    e.preventDefault(); setFindError('');
    if (!/^\d+$/.test(findId) || BigInt(findId) < 1n || !snap || BigInt(findId) > snap.count) {
      setFindError('Enter an existing round number.'); document.getElementById('round-id')?.focus(); return;
    }
    game.select(BigInt(findId));
  }
  return <>
    <a className="skip" href="#play">Skip to game</a>
    <header className="header wrap">
      <a className="brand" href="./" aria-label="Heads home"><span className="brand-mark" aria-hidden="true">h.</span> heads<span className="brand-caption">a small experiment in trust</span></a>
      <div className="wallet-controls"><span className="network-tag">{config.deployment.network.name} testnet</span>
        <button className={account ? '' : 'primary'} disabled={busy} onClick={() => void game.connect()}>{account ? `Wallet ${short(account)}` : 'Connect wallet'} <span aria-hidden="true">↗</span></button></div>
    </header>
    <main className="wrap" id="play">
      <section className="hero" aria-labelledby="hero-title">
        <div><p className="eyebrow">The commit–reveal coin flip</p><h1 id="hero-title">Call it.<br/><em>Then prove it.</em></h1>
          <p className="intro">Pick a side. Keep it secret. Reveal together.<br/>A shared pot, settled onchain in HEDS.</p></div>
        <div className="coin-scene" aria-hidden="true"><span className="orbit"></span><div className="coin tails">T<span>TAILS</span></div><div className="coin heads">H<span>HEADS</span></div><span className="coin-caption">Two sides. One shared outcome.</span></div>
      </section>
      <ol className="steps"><li><span>01</span><div><strong>Commit your pick</strong><p>Equal stakes. Up to 16 players.</p></div></li><li><span>02</span><div><strong>Come back to reveal</strong><p>1 hour to join, then 1 hour to reveal.</p></div></li><li><span>03</span><div><strong>Collect your HEDS</strong><p>Settle the round, then withdraw.</p></div></li></ol>
      <div className="test-note"><strong>Test game. No real value.</strong> The last revealer can bias the result by withholding. <a href="#rules">Read the rules ↓</a></div>

      <section className="wallet-bar" aria-label="Wallet balances">
        <div><span className="eyebrow">HEDS balance</span><strong data-testid="balance">{snap?.balance !== undefined ? units(snap.balance, snap.decimals) : '—'} <small>HEDS</small></strong></div>
        <div><span className="eyebrow">Game allowance</span><strong data-testid="allowance">{snap?.allowance !== undefined ? units(snap.allowance, snap.decimals) : '—'} <small>HEDS</small></strong></div>
        <div><span className="eyebrow">Ready to withdraw</span><strong data-testid="withdrawable">{snap?.withdrawable !== undefined ? units(snap.withdrawable, snap.decimals) : '—'} <small>HEDS</small></strong></div>
        <div><button disabled={!ready || !snap?.withdrawable} onClick={() => void game.transact('Withdraw HEDS', config.game, 'withdraw')}>Withdraw HEDS <span aria-hidden="true">↗</span></button><small>Collect all credited HEDS.</small></div>
      </section>
      <div className="connection-note">{account ? <span>Connected: <External href={`${explorer}/address/${account}`}><span className="address">{account}</span></External></span> : <span>Connect a browser wallet to see your balances and play.</span>}</div>
      {account && game.chainId !== config.deployment.chainId && <div className="warning"><span>Your wallet is on a different network. Actions require {config.deployment.network.name}.</span><button disabled={busy} onClick={() => void game.switchNetwork()}>Switch to {config.deployment.network.name}</button></div>}
      <div className="read-status"><span role="status">{game.status}</span><button className="text-button" disabled={game.loading || busy} onClick={() => void game.refresh()}>{game.loading ? 'Refreshing…' : 'Refresh'}</button></div>
      {game.error && <p role="alert" className="error">{game.error}</p>}
      {game.txHash && <p className="transaction"><External href={`${explorer}/tx/${game.txHash}`}>View transaction {short(game.txHash)}</External></p>}

      <div className="game-grid">
        <section className="lobby" aria-labelledby="rounds-title">
          <div className="section-heading"><h2 id="rounds-title">The rounds</h2><span className="count">{snap ? `${snap.count} created` : 'Reading chain…'}</span></div>
          <form onSubmit={create} className="create-form"><label htmlFor="stake">Stake per player</label><div className="input-row"><div className="amount-field"><input id="stake" name="stake" inputMode="decimal" autoComplete="off" value={stake} onChange={e => { setStake(e.target.value); setStakeError(''); }} aria-invalid={!!stakeError} aria-describedby="stake-help stake-error"/><span>HEDS</span></div><button disabled={!ready}>Create round <span aria-hidden="true">+</span></button></div>
            <p className="muted small" id="stake-help">Minimum 1 HEDS. Creates an empty round; join separately. Only gas is charged.</p><p id="stake-error" className="field-error" role={stakeError ? 'alert' : undefined}>{stakeError}</p></form>
          <div className="round-list" aria-label="Recent rounds">
            {!snap ? <div className="empty"><span className="empty-symbol" aria-hidden="true">◎</span><h3>{game.loading ? 'Reading the rounds…' : 'Rounds are unavailable'}</h3><p>{game.loading ? 'Checking the contracts on Sepolia.' : 'Use Refresh above to retry the live connection.'}</p></div> : snap.rounds.length === 0 ? <div className="empty"><span className="empty-symbol" aria-hidden="true">◎</span><h3>No rounds yet</h3><p>Create the first round and invite another player.</p></div> : snap.rounds.map(r => <button key={String(r.id)} className={`round-row ${snap.selected?.id === r.id ? 'selected' : ''}`} aria-pressed={snap.selected?.id === r.id} onClick={() => game.select(r.id)} disabled={busy}>
              <span><strong>Round #{String(r.id)}</strong><small>{String(r.playerCount)}/16 players · {units(r.stake, snap.decimals)} HEDS</small></span><span className="phase">{phases[r.phase]} <span aria-hidden="true">↗</span></span></button>)}
          </div>
          <div className="pagination"><button disabled={game.page === 0 || busy || game.loading} onClick={() => game.setPage(p => p - 1)}>← Newer</button><span>Page {game.page + 1}</span><button disabled={!snap || BigInt((game.page + 1) * 6) >= snap.count || busy || game.loading} onClick={() => game.setPage(p => p + 1)}>Older →</button></div>
          <form className="find-form" onSubmit={find}><label htmlFor="round-id">Find a round</label><div className="input-row"><input id="round-id" name="round-id" inputMode="numeric" placeholder="Round number" value={findId} onChange={e => setFindId(e.target.value)} aria-invalid={!!findError} aria-describedby="find-error"/><button disabled={!snap || busy}>Open</button></div><p id="find-error" className="field-error" role={findError ? 'alert' : undefined}>{findError}</p></form>
        </section>
        <section className="play-panel" aria-label="Selected round">
          {snap?.selected ? <RoundPanel key={`${account}:${snap.selected.id}`} config={config} game={game}/> : <div className="waiting-panel"><span className="eyebrow">Your next flip</span><h2>A little mystery.<br/>A shared reveal.</h2><p>Select a round to see its stake, deadlines and your next step.</p><div className="mini-coins" aria-hidden="true"><span>H</span><span>T</span></div><p className="small">Your pick stays private until you reveal it.<br/>Keep your salt backup safe.</p></div>}
        </section>
      </div>
      <section className="rules" id="rules" aria-labelledby="rules-title"><div><p className="eyebrow">Before you play</p><h2 id="rules-title">Know the flip.</h2><p>HEDS comes from swapping Sepolia ETH in the launch pool. There is no in-page swap.</p><External href={`https://app.uniswap.org/swap?chain=sepolia&inputCurrency=ETH&outputCurrency=${config.token.address}`}>Get HEDS on Uniswap</External><p className="small muted">External app; pool support and liquidity may vary. Use Sepolia test ETH only.</p></div>
        <div className="rule-details"><details open><summary>How the pot is shared</summary><p>Revealed salts are XORed together; an odd result means heads. Correct picks split the whole pot, including forfeited stakes. If no pick matches, all revealers split it. Rounding dust is burned.</p></details><details><summary>Missed a reveal or need a refund?</summary><p>One player can reclaim after joining closes. If nobody reveals, everyone gets their stake credited after settlement. Otherwise a missing reveal forfeits that player’s stake. Reclaim and settle create credits; Withdraw HEDS collects them.</p></details><details><summary>This is an experiment, not fair randomness</summary><p>The last revealer can see the outcome and change it by withholding, at the cost of their stake. With 2 players, withholding against a revealer always loses. There is no VRF, oracle, owner or admin. Do not use this test game for anything of value.</p></details><details><summary>Keep your reveal backup</summary><p>Your side and a random salt are stored only in this browser. Save the backup JSON before joining; clearing site data or moving to another gateway loses local access. Restore the backup using the same wallet and round. Keep it private until you reveal.</p></details></div>
      </section>
    </main>
    <footer className="wrap"><div><strong>heads.</strong><span>lab-coin-flip-commit · {config.deployment.network.name}</span></div><div className="contract-links">{config.deployment.contracts.map(c => <External key={c.name} href={`${explorer}/address/${c.address}`}>{c.name === 'LaunchToken' ? 'HEDS token' : 'Game contract'} <span className="address">{short(c.address)}</span></External>)}<a href="./imd-deployment.json">Deployment manifest ↗</a></div></footer>
  </>;
}

function RoundPanel({ config, game }: { config: Config; game: Game }) {
  const snap = game.snapshot!;
  const round = snap.selected!;
  const player = snap.player;
  const [heads, setHeads] = useState(true);
  const [secret, setSecret] = useState<Secret | null>(null);
  const [backup, setBackup] = useState('');
  const [saved, setSaved] = useState(false);
  const [error, setError] = useState('');
  const [message, setMessage] = useState('');
  useEffect(() => {
    if (!game.account) return;
    try { const stored = readSecret(config, game.account, round.id); setSecret(stored); if (stored) setHeads(stored.heads); }
    catch { setError('Local backup could not be read. Restore your saved backup before joining or revealing.'); }
  }, [config, game.account, round.id]);
  function prepare() {
    if (!game.account) return;
    try {
      // Reuse a secret created in another tab, or a prior rejected/pending attempt.
      const s = readSecret(config, game.account, round.id) ?? newSecret(config, game.account, round.id, heads);
      storeSecret(config, game.account, round.id, s); setSecret(s); setHeads(s.heads); setError('');
    } catch (e) { setError(`Cannot save your secret. ${errorMessage(e)}`); }
  }
  function restore(e: FormEvent) {
    e.preventDefault(); setError('');
    if (!game.account) return;
    try {
      const s = validateSecret(JSON.parse(backup), config, game.account, round.id);
      if (player?.joined && commitment(s).toLowerCase() !== player.commitment.toLowerCase()) throw new Error('Backup does not match your onchain commitment. Use the original side and salt.');
      storeSecret(config, game.account, round.id, s); setSecret(s); setHeads(s.heads); setSaved(true); setMessage('Backup restored for this wallet and round.');
    } catch (e) { setError(errorMessage(e)); }
  }
  async function join() {
    if (!secret || !game.account) return;
    try {
      const stored = readSecret(config, game.account, round.id);
      if (!stored || commitment(stored) !== commitment(secret)) throw new Error('Saved secret changed in another tab. Reload and back up the current secret before joining.');
      await game.transact('Join round', config.game, 'join', [round.id, commitment(secret)]);
    } catch (e) { setError(errorMessage(e)); }
  }
  const open = round.phase === 0 && !player?.joined && round.playerCount < 16n;
  const funded = (snap.balance ?? 0n) >= round.stake;
  const approved = (snap.allowance ?? 0n) >= round.stake;
  const match = !!secret && !!player?.joined && commitment(secret).toLowerCase() === player.commitment.toLowerCase();
  const canReveal = round.phase === 1 && !!player?.joined && !player.revealed && match;
  const canReclaim = round.phase === 2 && !!player?.joined && !player.reclaimed;
  const canSettle = !round.settled && snap.timestamp >= round.revealDeadline;
  return <>
    <div className="section-heading"><span className="eyebrow">At the table</span><span className="phase">{phases[round.phase]}</span></div>
    <h2 className="round-title">Round #{String(round.id)}</h2>
    <dl className="round-stats"><div><dt>Stake</dt><dd>{units(round.stake, snap.decimals)} <small>HEDS</small></dd></div><div><dt>Pot</dt><dd>{units(round.stake * round.playerCount, snap.decimals)} <small>HEDS</small></dd></div><div><dt>Players</dt><dd>{String(round.playerCount)}<small>/16</small></dd></div></dl>
    <div className="deadlines"><p><span>Joining closes</span><time dateTime={new Date(Number(round.joinDeadline) * 1000).toISOString()}>{date(round.joinDeadline)}</time></p><p><span>Reveal by</span><time dateTime={new Date(Number(round.revealDeadline) * 1000).toISOString()}>{date(round.revealDeadline)}</time></p></div>
    {round.settled ? <div className="outcome"><span className="eyebrow">Final result</span><h3>{resultText(round, snap.decimals)}</h3><p>Use your withdrawable balance above to collect any credit.</p></div> : <>
      <fieldset disabled={!game.ready || !open || !!secret}><legend>Choose your side</legend><div className="side-picker"><label className={heads ? 'picked' : ''}><input type="radio" name="side" value="heads" checked={heads} onChange={() => setHeads(true)}/><span>H</span> Heads</label><label className={!heads ? 'picked' : ''}><input type="radio" name="side" value="tails" checked={!heads} onChange={() => setHeads(false)}/><span>T</span> Tails</label></div></fieldset>
      {player?.joined ? <p className="entry-note">{player.revealed ? `You revealed ${player.heads ? 'heads' : 'tails'}. ${round.revealCount}/${round.playerCount} players revealed.` : 'You joined this round. Reveal your saved pick during the reveal window.'}</p> : <p className="small muted">Joining transfers exactly {units(round.stake, snap.decimals)} HEDS to the pot. Missing your reveal can forfeit it.</p>}
      {open && !secret && <button className="full" disabled={!game.ready} onClick={prepare}>Generate & save secret</button>}
    </>}
    {secret && <details className="backup" open={!player?.joined}><summary>Reveal backup · {secret.heads ? 'heads' : 'tails'}</summary><p className="small">Saved in this browser. Save this JSON elsewhere before joining. Keep it private until reveal.</p><label htmlFor="secret-backup">Backup JSON (includes your salt)</label><textarea id="secret-backup" readOnly value={JSON.stringify(secret)} rows={5} spellCheck={false}/><button onClick={() => { const blob = new Blob([JSON.stringify(secret, null, 2)], { type: 'application/json' }); const url = URL.createObjectURL(blob); const a = document.createElement('a'); a.href = url; a.download = `heads-round-${round.id}-backup.json`; a.click(); setTimeout(() => URL.revokeObjectURL(url), 1000); setMessage('Backup downloaded. Keep it somewhere safe.'); }}>Download backup</button>
      {!player?.joined && <label className="checkbox"><input type="checkbox" checked={saved} onChange={e => setSaved(e.target.checked)}/> I saved my side and salt outside this browser.</label>}</details>}
    {game.account && !round.settled && <details className="restore"><summary>Restore a saved backup</summary><form onSubmit={restore}><label htmlFor="restore-backup">Backup JSON</label><textarea id="restore-backup" value={backup} onChange={e => setBackup(e.target.value)} rows={3} spellCheck={false} placeholder='{"version":1,…}'/><button disabled={game.busy}>Restore backup</button></form></details>}
    {error && <p className="error" role="alert">{error}</p>}<p className="small" role="status">{message}</p>
    {!round.settled && <div className="round-actions">
      {open && <><div className="action-step"><span>1</span><div><button disabled={!game.ready || !funded || approved} onClick={() => void game.transact('Approve HEDS', config.token, 'approve', [config.game.address, round.stake])}>{approved ? 'HEDS approved' : `Approve ${units(round.stake, snap.decimals)} HEDS`}</button><small>Allows this game to spend one stake.</small></div></div><div className="action-step"><span>2</span><div><button className="primary" disabled={!game.ready || !funded || !approved || !secret || !saved} onClick={() => void join()}>Join round · {units(round.stake, snap.decimals)} HEDS</button><small>{!game.account ? 'Connect your wallet to join.' : !funded ? 'You need more HEDS to cover this stake.' : !approved ? 'Approve HEDS first, then join.' : !secret || !saved ? 'Save your secret and confirm the backup first.' : 'Your side and salt stay private until reveal.'}</small></div></div></>}
      {!open && !player?.joined && <p className="small">{round.playerCount === 16n && round.phase === 0 ? 'This round is full.' : 'Joining has closed for this round.'}</p>}
      <div className="later-actions"><button className={canReveal ? 'primary' : ''} disabled={!game.ready || !canReveal} onClick={() => secret && void game.transact('Reveal pick', config.game, 'reveal', [round.id, secret.heads, secret.salt])}>Reveal pick</button><button disabled={!game.ready || !canReclaim} onClick={() => void game.transact('Reclaim stake', config.game, 'reclaim', [round.id])}>Reclaim stake</button><button disabled={!game.ready || !canSettle} onClick={() => void game.transact('Settle round', config.game, 'settle', [round.id])}>Settle round</button></div>
      <p className="small muted">{round.phase === 1 && player?.joined && !player.revealed && !match ? 'Restore a matching backup to reveal. A different salt or side cannot be used.' : round.phase === 2 ? 'Fewer than two players joined. The sole player can reclaim; anyone can settle after the reveal deadline.' : 'Reveal during its window. Settle after the reveal deadline. A lone player can reclaim after joining closes.'}</p>
    </div>}
  </>;
}
