import { chromium } from 'playwright';
import { expect } from 'playwright/test';
import AxeBuilder from '@axe-core/playwright';
import { createServer } from 'node:http';
import { readFile, writeFile, mkdir, access } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import assert from 'node:assert/strict';
import { decodeFunctionData, encodeFunctionResult, encodeAbiParameters, keccak256, parseEther, toHex } from 'viem';

const root = fileURLToPath(new URL('../../', import.meta.url));
const manifest = JSON.parse(await readFile(`${root}dist/imd-deployment.json`));
const contracts = await Promise.all(manifest.contracts.map(async c => ({ ...c, abi: JSON.parse(await readFile(`${root}dist/${c.abiPath}`)) })));
const game = contracts.find(c => c.name === 'CommitRevealCoinFlip');
const token = contracts.find(c => c.name === 'LaunchToken');
const alice = '0x1111111111111111111111111111111111111111';
const bob = '0x2222222222222222222222222222222222222222';
const zeroHash = `0x${'0'.repeat(64)}`;
const wei = parseEther;
const tests = [];
const record = (name, details = {}) => { tests.push({ name, passed: true, ...details }); console.log(`PASS ${name}`); };
let timestamp = BigInt(Math.floor(Date.now() / 1000));
let rounds, balances, allowance, credits, players, sent, simulated, receipts, failRPC, rejectTx, failSimulation, badToken, badCode;
function initialRound() { return { stake: wei('10'), joinDeadline: timestamp + 3600n, revealDeadline: timestamp + 7200n, playerCount: 1n, revealCount: 0n, saltXor: zeroHash, settled: false, heads: false, winners: 0n, share: 0n }; }
function reset() {
  timestamp = BigInt(Math.floor(Date.now() / 1000)); rounds = [initialRound()]; balances = wei('100'); allowance = 0n; credits = 0n; players = new Map(); sent = []; simulated = []; receipts = new Map(); failRPC = rejectTx = failSimulation = badToken = badCode = false;
}
reset();
const emptyPlayer = () => ({ commitment: zeroHash, joined: false, revealed: false, heads: false, reclaimed: false });
const playerKey = (id, account = alice) => `${id}:${account.toLowerCase()}`;
const player = (id, account) => players.get(playerKey(id, account)) ?? emptyPlayer();
function phase(r) { return r.settled ? 4 : timestamp < r.joinDeadline ? 0 : r.playerCount < 2n ? 2 : timestamp < r.revealDeadline ? 1 : 3; }
function call(tx, mutate = false) {
  const c = contracts.find(c => c.address.toLowerCase() === tx.to.toLowerCase());
  if (!c) throw Error('Unexpected contract address');
  const { functionName: name, args = [] } = decodeFunctionData({ abi: c.abi, data: tx.data });
  const writes = ['approve', 'createRound', 'join', 'reveal', 'reclaim', 'settle', 'withdraw'];
  if (writes.includes(name)) {
    if (!mutate) simulated.push(name);
    if (failSimulation && !mutate) throw Error('Simulation rejected: JoinClosed');
  }
  const [id, arg1, arg2] = args;
  const r = rounds[Number(id) - 1];
  const p = player(id, tx.from ?? alice);
  let value;
  switch (name) {
    case 'token': value = badToken ? bob : token.address; break;
    case 'decimals': value = 18; break;
    case 'roundCount': value = BigInt(rounds.length); break;
    case 'round': if (!r) throw Error('InvalidRound'); value = r; break;
    case 'phase': value = phase(r); break;
    case 'player': value = player(id, arg1); break;
    case 'balanceOf': value = tx.from?.toLowerCase() === bob ? 0n : balances; break;
    case 'allowance': value = allowance; break;
    case 'withdrawable': value = credits; break;
    case 'approve':
      assert.equal(id.toLowerCase(), game.address.toLowerCase(), 'Approval spender is runtime game address');
      if (mutate) allowance = arg1;
      value = true; break;
    case 'createRound':
      if (mutate) rounds.push({ ...initialRound(), stake: id, playerCount: 0n });
      value = BigInt(rounds.length + (mutate ? 0 : 1)); break;
    case 'join':
      if (!r || phase(r) !== 0 || p.joined || r.playerCount >= 16n || allowance < r.stake || balances < r.stake) throw Error('JoinClosed or insufficient allowance');
      if (mutate) { r.playerCount++; balances -= r.stake; allowance -= r.stake; players.set(playerKey(id, tx.from), { ...emptyPlayer(), joined: true, commitment: arg1 }); }
      break;
    case 'reveal':
      if (phase(r) !== 1 || !p.joined || p.revealed) throw Error('RevealClosed');
      assert.equal(keccak256(encodeAbiParameters([{ type: 'bool' }, { type: 'bytes32' }, { type: 'address' }, { type: 'uint256' }], [arg1, arg2, tx.from, id])), p.commitment);
      if (mutate) { p.revealed = true; p.heads = arg1; r.revealCount++; r.saltXor = arg2; }
      break;
    case 'reclaim':
      if (phase(r) !== 2 || !p.joined) throw Error('NotReclaimable');
      if (mutate) { r.settled = true; p.reclaimed = true; r.share = r.stake; credits += r.stake; } break;
    case 'settle':
      if (timestamp < r.revealDeadline || r.settled) throw Error('SettlementTooEarly');
      if (mutate) { r.settled = true; r.heads = (BigInt(r.saltXor) & 1n) === 1n; r.winners = r.revealCount > 0n && p.heads === r.heads ? 1n : 0n; r.share = r.revealCount > 0n ? r.stake * r.playerCount : r.stake; credits += r.share; } break;
    case 'withdraw': if (!credits) throw Error('NothingToWithdraw'); if (mutate) { balances += credits; credits = 0n; } break;
    default: throw Error(`Unexpected function ${name}`);
  }
  return { name, result: encodeFunctionResult({ abi: c.abi, functionName: name, result: value }) };
}
const block = () => ({ number: '0x100', hash: '0x' + 'ab'.repeat(32), parentHash: zeroHash, timestamp: toHex(timestamp), nonce: '0x0000000000000000', sha3Uncles: zeroHash, logsBloom: '0x' + '00'.repeat(256), transactionsRoot: zeroHash, stateRoot: zeroHash, receiptsRoot: zeroHash, miner: alice, difficulty: '0x0', totalDifficulty: '0x0', extraData: '0x', size: '0x1', gasLimit: '0x1c9c380', gasUsed: '0x0', baseFeePerGas: '0x1', transactions: [], uncles: [] });
function rpc(method, params = []) {
  if (failRPC) throw Error('Mock RPC unavailable');
  if (method === 'eth_chainId') return toHex(manifest.chainId);
  if (method === 'eth_getCode') return badCode ? '0x' : '0x6001600055';
  if (method === 'eth_getBlockByNumber') return block();
  if (method === 'eth_blockNumber') return '0x100';
  if (method === 'eth_call') return call(params[0]).result;
  if (method === 'eth_getTransactionReceipt') return receipts.get(params[0]) ?? null;
  if (method === 'eth_getTransactionByHash') return receipts.has(params[0]) ? { ...receipts.get(params[0]), hash: params[0], value: '0x0', input: '0x', nonce: '0x0', gas: '0x10000', gasPrice: '0x1', v: '0x1', r: zeroHash, s: zeroHash } : null;
  throw Error(`Unexpected RPC ${method}`);
}
const server = createServer(async (req, res) => {
  try {
    const path = decodeURIComponent(new URL(req.url, 'http://localhost').pathname);
    if (!path.startsWith('/preview/') || path.includes('..')) { res.writeHead(404).end(); return; }
    const file = path === '/preview/' ? 'index.html' : path.slice('/preview/'.length);
    const data = await readFile(`${root}dist/${file}`);
    const mime = file.endsWith('.js') ? 'text/javascript' : file.endsWith('.css') ? 'text/css' : file.endsWith('.json') ? 'application/json' : 'text/html';
    res.writeHead(200, { 'Content-Type': mime }); res.end(data);
  } catch { res.writeHead(404).end(); }
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
const url = `http://127.0.0.1:${server.address().port}/preview/`;
await mkdir(`${root}docs/evidence`, { recursive: true });
let executablePath = process.env.CHROMIUM_PATH;
if (!executablePath) {
  const installed = '/opt/imd-tools/ms-playwright/chromium-1246/chrome-linux64/chrome';
  try { await access(installed); executablePath = installed; } catch { /* use Playwright's normal installed binary */ }
}
const browser = await chromium.launch({ executablePath, headless: true, args: ['--no-sandbox'] });
const context = await browser.newContext({ viewport: { width: 1440, height: 1080 } });
const page = await context.newPage();
const errors = [], failedResources = [];
page.on('pageerror', e => errors.push(e.message));
page.on('console', e => { if (e.type() === 'error') errors.push(e.text()); });
page.on('requestfailed', r => failedResources.push(r.url()));
await page.route('https://**/*', async route => {
  if (!manifest.network.rpcUrls.some(r => route.request().url().startsWith(r))) { await route.abort(); return; }
  const body = route.request().postDataJSON();
  const response = (request) => { try { return { jsonrpc: '2.0', id: request.id, result: rpc(request.method, request.params) }; } catch (e) { return { jsonrpc: '2.0', id: request.id, error: { code: -32000, message: e.message } }; } };
  await route.fulfill({ json: Array.isArray(body) ? body.map(response) : response(body) });
});
await page.route('**/test-wallet', async route => {
  const tx = route.request().postDataJSON();
  try {
    if (rejectTx) { await route.fulfill({ json: { error: 'User rejected request', code: 4001 } }); return; }
    const { name } = call(tx, true); sent.push(name);
    const hash = '0x' + sent.length.toString(16).padStart(64, '0');
    receipts.set(hash, { transactionHash: hash, transactionIndex: '0x0', blockHash: block().hash, blockNumber: '0x100', from: alice, to: tx.to, cumulativeGasUsed: '0x5208', gasUsed: '0x5208', contractAddress: null, logs: [], logsBloom: '0x' + '00'.repeat(256), status: '0x1', effectiveGasPrice: '0x1', type: '0x2' });
    await route.fulfill({ json: { result: hash } });
  } catch (e) { await route.fulfill({ json: { error: e.message, code: -32000 } }); }
});
await context.addInitScript(({ alice, chainId }) => {
  const listeners = {};
  const state = { accounts: [], chain: '0x1', missing: true, requests: [], rejectConnect: false };
  window.testWallet = state;
  window.ethereum = {
    on: (e, fn) => { (listeners[e] ??= []).push(fn); },
    removeListener: (e, fn) => { listeners[e] = (listeners[e] ?? []).filter(f => f !== fn); },
    request: async ({ method, params }) => {
      state.requests.push({ method, params });
      if (method === 'eth_accounts') return state.accounts;
      if (method === 'eth_requestAccounts') { if (state.rejectConnect) throw { code: 4001, message: 'User rejected request' }; state.accounts = [alice]; return state.accounts; }
      if (method === 'eth_chainId') return state.chain;
      if (method === 'wallet_switchEthereumChain') {
        if (state.missing) throw { code: 4902, message: 'Unknown chain' };
        state.chain = params[0].chainId; (listeners.chainChanged ?? []).forEach(fn => fn(state.chain)); return null;
      }
      if (method === 'wallet_addEthereumChain') { state.missing = false; return null; }
      if (method === 'eth_sendTransaction') { const r = await fetch('/test-wallet', { method: 'POST', body: JSON.stringify(params[0]) }).then(r => r.json()); if (r.error) throw { code: r.code, message: r.error }; return r.result; }
      throw Error(`Unexpected wallet request ${method}`);
    },
  };
  state.changeAccount = account => { state.accounts = account ? [account] : []; (listeners.accountsChanged ?? []).forEach(fn => fn(state.accounts)); };
  state.changeChain = chain => { state.chain = chain; (listeners.chainChanged ?? []).forEach(fn => fn(chain)); };
}, { alice, chainId: manifest.chainId });
const button = (name) => page.getByRole('button', { name, exact: true });
async function refresh() { await button('Refresh').waitFor(); await button('Refresh').click(); await page.waitForFunction(() => document.querySelector('[role=status]')?.textContent?.includes('Live reads verified')); }
async function enabled(name) { await expect(button(name)).toBeEnabled({ timeout: 15_000 }); }
async function clickTx(name, expected) { await enabled(name); await button(name).focus(); await page.keyboard.press('Enter'); await page.waitForFunction(expected => document.querySelector('[role=status]')?.textContent?.includes(expected), expected); }
async function screenshot(name) { await page.screenshot({ path: `${root}docs/evidence/${name}.png`, fullPage: true }); }
async function reflow(width) {
  await page.setViewportSize({ width, height: 1000 });
  const fits = await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth);
  if (!fits) console.log('OVERFLOW', await page.evaluate(() => [...document.querySelectorAll('body *')].filter(el => el.getBoundingClientRect().right > innerWidth).map(el => ({ tag: el.tagName, class: el.className, right: el.getBoundingClientRect().right }))));
  assert(fits, `No overflow at ${width}px`);
}
try {
  await page.goto(url); await page.getByRole('heading', { name: 'Round #1', exact: true }).waitFor();
  assert(await button('Create round').isDisabled()); assert(await button('Withdraw HEDS').isDisabled());
  await screenshot('desktop-disconnected'); record('Subpath export loads and disconnected actions are disabled');
  await page.keyboard.press('Tab'); assert.equal(await page.locator(':focus').textContent(), 'Skip to game');
  await screenshot('keyboard-focus'); record('Keyboard skip link receives visible focus');
  await page.evaluate(() => { window.testWallet.rejectConnect = true; });
  await button('Connect wallet').click(); await page.getByRole('alert').filter({ hasText: 'Wallet request rejected' }).waitFor();
  await page.evaluate(() => { window.testWallet.rejectConnect = false; });
  record('Wallet connection rejection has a recoverable error');
  await button('Connect wallet').click(); await button('Switch to Sepolia').waitFor(); assert(await button('Create round').isDisabled());
  await screenshot('wrong-network');
  await button('Switch to Sepolia').click(); await enabled('Create round');
  const add = await page.evaluate(() => window.testWallet.requests.find(r => r.method === 'wallet_addEthereumChain'));
  assert.deepEqual(add.params[0], manifest.walletAddChain);
  record('Wrong network gates writes; unknown chain adds exact handoff parameters and switches again');
  assert.match(await page.getByTestId('balance').textContent(), /100 HEDS/);
  await page.getByLabel('Stake per player').fill('0.1'); await button('Create round').click();
  assert(await page.getByLabel('Stake per player').getAttribute('aria-invalid') === 'true');
  assert.equal(sent.length, 0); await page.getByLabel('Stake per player').fill('10'); record('Invalid stake is blocked before wallet request');
  await button('Generate & save secret').click();
  const original = await page.getByLabel('Backup JSON (includes your salt)').inputValue();
  const secret = JSON.parse(original);
  assert.match(secret.salt, /^0x[0-9a-f]{64}$/); assert.equal(secret.account, alice);
  assert(await button('Join round · 10 HEDS').isDisabled());
  await page.getByLabel('I saved my side and salt outside this browser.').check();
  rejectTx = true; await button('Approve 10 HEDS').click(); await page.getByRole('alert').filter({ hasText: 'Wallet request rejected' }).waitFor();
  rejectTx = false; assert.equal(sent.length, 0); record('Approval rejection keeps the secret and allows retry');
  failSimulation = true; await button('Approve 10 HEDS').click(); await page.getByRole('alert').filter({ hasText: 'JoinClosed' }).waitFor();
  failSimulation = false; assert.equal(sent.length, 0); record('Simulation revert is shown before signing');
  await clickTx('Approve 10 HEDS', 'Approve HEDS confirmed');
  assert.equal(allowance, wei('10')); await enabled('Join round · 10 HEDS');
  const axe = await new AxeBuilder({ page }).withTags(['wcag2a', 'wcag2aa', 'wcag21aa']).analyze();
  assert.deepEqual(axe.violations.map(v => ({ id: v.id, impact: v.impact })), []);
  await screenshot('desktop-connected');
  await page.emulateMedia({ reducedMotion: 'reduce' });
  assert.equal(await button('Join round · 10 HEDS').evaluate(el => getComputedStyle(el).transitionDuration), '0s');
  await page.emulateMedia({ reducedMotion: 'no-preference' });
  record('Reduced-motion preference removes button transitions');
  for (const width of [320, 390, 744, 1024, 1440]) { await reflow(width); if (width === 390) { await screenshot('mobile-connected'); await page.locator('.backup').screenshot({ path: `${root}docs/evidence/mobile-backup.png` }); } }
  record('Approval-first joining; saved secret; axe scan and reflow at 320/390/744/1024/1440px', { axeViolations: axe.violations.length });
  const contrast = await page.evaluate(() => {
    const values = [document.body, document.querySelector('.intro'), document.querySelector('.primary:not(:disabled)'), document.querySelector('.test-note'), document.querySelector('.phase')].filter(Boolean).map(el => {
      const s = getComputedStyle(el); let parent = el; let bg = s.backgroundColor;
      while (bg === 'rgba(0, 0, 0, 0)' && parent.parentElement) { parent = parent.parentElement; bg = getComputedStyle(parent).backgroundColor; }
      return { selector: el.className || el.tagName, color: s.color, background: bg };
    }); return values;
  });
  const luminance = rgb => { const c = rgb.match(/[\d.]+/g).slice(0, 3).map(Number).map(v => { v /= 255; return v <= .04045 ? v / 12.92 : ((v + .055) / 1.055) ** 2.4; }); return .2126 * c[0] + .7152 * c[1] + .0722 * c[2]; };
  for (const pair of contrast) { const a = luminance(pair.color), b = luminance(pair.background); pair.ratio = +((Math.max(a, b) + .05) / (Math.min(a, b) + .05)).toFixed(2); assert(pair.ratio >= 4.5); }
  record('Computed rendered text/background contrast meets 4.5:1 on sampled opaque pairs', { contrast });
  await page.evaluate(() => document.documentElement.style.fontSize = '200%'); await reflow(744); await screenshot('text-enlargement');
  await page.evaluate(() => document.documentElement.style.fontSize = ''); await reflow(1440); record('200% text enlargement reflows without page overflow (not native browser zoom)');
  await clickTx('Join round · 10 HEDS', 'Join round confirmed');
  assert.deepEqual(sent, ['approve', 'join']); assert.equal(balances, wei('90')); assert.equal(allowance, 0n);
  assert(simulated.includes('join')); record('Join transfers one stake after exact approval and simulation');
  await page.reload(); await button('Connect wallet').click(); await button('Switch to Sepolia').click(); await enabled('Create round');
  await page.getByText('Reveal backup · heads', { exact: true }).click();
  assert.equal(await page.getByLabel('Backup JSON (includes your salt)').inputValue(), original); record('Salt persists across reload and reconnect');
  timestamp = rounds[0].joinDeadline; await refresh(); await enabled('Reveal pick');
  await page.getByText('Restore a saved backup', { exact: true }).click();
  await page.getByLabel('Backup JSON', { exact: true }).fill(JSON.stringify({ ...secret, account: bob })); await button('Restore backup').click();
  await page.getByRole('alert').filter({ hasText: 'Backup must match' }).waitFor();
  await page.getByLabel('Backup JSON', { exact: true }).fill(JSON.stringify({ ...secret, salt: zeroHash })); await button('Restore backup').click();
  await page.getByRole('alert').filter({ hasText: 'does not match your onchain commitment' }).waitFor();
  await page.getByLabel('Backup JSON', { exact: true }).fill(original); await button('Restore backup').click();
  await clickTx('Reveal pick', 'Reveal pick confirmed'); assert(players.get(playerKey(1n)).revealed); assert(await button('Settle round').isDisabled());
  record('Reveal validates account, round and commitment; correct saved salt reveals at the window; early settlement disabled');
  timestamp = rounds[0].revealDeadline; await refresh(); await clickTx('Settle round', 'Settle round confirmed');
  await page.getByText('Final result', { exact: true }).waitFor(); assert(credits > 0n);
  await screenshot('settled'); await clickTx('Withdraw HEDS', 'Withdraw HEDS confirmed'); assert.equal(credits, 0n);
  record('Settle displays result and credited balance; Withdraw collects all credits');
  await clickTx('Create round', 'Create round confirmed'); assert.equal(rounds.length, 2);
  await page.getByRole('heading', { name: 'Round #2', exact: true }).waitFor();
  await button('Generate & save secret').click(); await page.getByLabel('I saved my side and salt outside this browser.').check();
  await clickTx('Approve 10 HEDS', 'Approve HEDS confirmed'); await clickTx('Join round · 10 HEDS', 'Join round confirmed');
  timestamp = rounds[1].joinDeadline; await refresh(); await clickTx('Reclaim stake', 'Reclaim stake confirmed');
  await page.getByText('Stake refund · 10 HEDS per player', { exact: true }).waitFor(); assert.equal(credits, wei('10'));
  record('Create is separate from entry; lone player reclaim credits a refund without labeling tails as a win');
  await page.getByLabel('Find a round').fill('1'); await button('Open').click(); await page.getByRole('heading', { name: 'Round #1', exact: true }).waitFor();
  record('Round lookup reads an existing round by ID');
  await page.evaluate(bob => window.testWallet.changeAccount(bob), bob); await enabled('Create round'); assert.equal(await page.locator('#secret-backup').count(), 0);
  await page.evaluate(() => window.testWallet.changeChain('0x1')); await button('Switch to Sepolia').waitFor(); assert(await button('Create round').isDisabled());
  record('Wallet account and chain changes invalidate eligibility and isolate secrets');
  await page.evaluate(() => window.testWallet.changeChain('0xaa36a7')); await enabled('Create round');
  badToken = true; await button('Refresh').click(); await page.getByRole('alert').filter({ hasText: 'HEDS address differs' }).waitFor(); assert(await button('Create round').isDisabled()); badToken = false;
  await refresh(); badCode = true; await button('Refresh').click(); await page.getByRole('alert').filter({ hasText: 'could not be verified' }).waitFor(); assert(await button('Create round').isDisabled()); badCode = false; await refresh();
  record('Token mismatch and empty deployed code fail closed');
  failRPC = true; await button('Refresh').click(); await page.getByRole('alert').waitFor(); assert(await button('Create round').isDisabled()); await screenshot('rpc-error'); failRPC = false; await refresh();
  record('RPC outage clears stale balances and disables signing; refresh recovers');
  assert.deepEqual(errors, []); assert.deepEqual(failedResources, []);
  record('No console errors or failed resources in mocked production interactions');
  const noWallet = await browser.newContext(); const missing = await noWallet.newPage();
  await missing.goto(url); await missing.getByRole('button', { name: 'Connect wallet', exact: true }).waitFor(); await missing.getByRole('button', { name: 'Connect wallet', exact: true }).click();
  await missing.getByRole('alert').filter({ hasText: 'No browser wallet detected' }).waitFor(); record('Missing browser wallet has a specific recovery message');
  try {
    await missing.waitForFunction(() => document.querySelector('[role=status]')?.textContent?.includes('Live reads verified'), { timeout: 30_000 });
    await missing.screenshot({ path: `${root}docs/evidence/live-desktop.png`, fullPage: true });
    record('Unmocked browser RPC reads succeed from production export', { content: await missing.locator('.round-list').innerText() });
  } catch { tests.push({ name: 'Unmocked browser RPC reads', passed: false, limitation: await missing.locator('.read-status').innerText() }); }
  await noWallet.close();
  const tampered = await context.newPage(); await tampered.route('**/abi/LaunchToken.json', route => route.fulfill({ json: [] })); await tampered.goto(url);
  await tampered.getByRole('alert').filter({ hasText: 'ABI verification failed' }).waitFor(); await tampered.close(); record('Tampered runtime ABI blocks the app');
  await writeFile(`${root}docs/evidence/browser-results.json`, JSON.stringify({ checkedAt: new Date().toISOString(), browser: await browser.version(), servedUnder: '/preview/', mode: 'Production bundle with mocked EIP-1193 wallet and RPC. No broadcasts.', tests, errors, failedResources, simulated, signed: sent }, null, 2) + '\n');
} catch (e) { console.error('PAGE:', await page.locator('body').innerText()); throw e; } finally { await browser.close(); await new Promise(resolve => server.close(resolve)); }
