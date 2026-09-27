# Heads frontend

One static React/TypeScript page for the deployed CommitRevealCoinFlip on Sepolia. HEDS is the staking and payout currency. This is a **test game with no real value**. Contracts and root build configuration are unchanged.

## Install, build, preview

Use Node 22.12+ and npm. From the repository root:

```sh
npm --prefix web ci
npm --prefix web run typecheck
npm --prefix web run build
npm --prefix web run check:export
npm --prefix web run preview
```

Open the local address printed by Vite. The committed `dist/` is the deployable output; the publisher does not need to rebuild. Vite uses `base: './'`; HTML, JS, CSS, configuration and ABIs work below a gateway path without rewrites. Serve over HTTPS (or localhost during development) for wallet access and secure random generation. No remote fonts, images, backend, indexer, service worker or vendored registry are required.

`npm run dev` is a source-only Vite development server; use build + preview to exercise the complete deployment configuration. The manifest is deliberately emitted after the production build, not from an independent development address map.

## Configuration and provenance

`deployment/handoff.json` and `deployment/network.json` preserve the supplied public handoffs. They are **build inputs only**, not imported by the app. The build reads `docs/abi/<Contract>.json` with `git show` at the handoff's `sourceCommit`, verifies canonical Keccak-256 hashes, and exports the exact original ABI bytes. Keep that commit reachable in the checkout; no Solidity rebuild or contract modification is needed. Canonicalization recursively sorts object keys, preserves array order, and uses compact JSON with UTF-8 encoding.

`scripts/export.mjs` writes `dist/imd-deployment.json` last. It preserves launch ID, deployed source commit, attestation hash, chain, exact contract set, names, addresses and ABI hashes. It copies the complete `network` object unchanged and adds the exact `walletAddChain` object and handoff pool description. The inventory includes **every other exported file**, including licenses, HTML and both ABIs, with lowercase SHA-256; the manifest excludes itself. `check:export` independently re-enumerates final bytes and compares the manifest with its source handoffs. Paths are relative to `dist/`.

At runtime `src/config.ts` loads this same manifest and its referenced ABIs. There is no second address, chain or RPC map. ABI hashes are checked again. Before exposing usable transaction controls, the page verifies the RPC chain ID, nonempty deployed code, `game.token()` matching the attested token, and 18-decimal metadata. This is a deployment binding check, not a signature verifier or bytecode audit. The publisher independently checks attestation and immutable asset integrity.

Public RPCs use ordered fallback. Wallets are injected EIP-1193 browser wallets; signing never uses the public RPC. There are no private credentials or WalletConnect project IDs. WalletConnect and a multi-wallet chooser are not configured. Wrong-chain wallets can switch; unknown-chain code 4902 (including nested errors) triggers the supplied `wallet_addEthereumChain` parameters, followed by another switch. Failed RPC verification disables actions. A disconnected visitor can still read rounds through public RPCs.

## Playing

- **Create round:** choose a stake of at least 1 HEDS. Creation transfers no HEDS and does not enroll the creator. Joining is separate.
- **Join:** pick heads or tails, generate a secret, download/copy the backup JSON and acknowledge saving it. If allowance is insufficient, approve exactly one stake to the game, wait for confirmation, then join. Balance and game allowance remain visible.
- **Reveal:** return during the hour following the one-hour join window. The page uses the saved side and salt; a restored backup must match the onchain commitment before revealing.
- **Reclaim:** a sole participant can reclaim after joining closes. After the reveal deadline, anyone can settle, including empty rounds.
- **Settle and withdraw:** finalization credits balances; Withdraw HEDS collects all available credits. Outcome labels distinguish winning-side payouts, no-winner splits, no-reveal refunds and empty rounds.

Rounds come from `roundCount`, `round`, `phase` and `player`, paged six at a time with direct round lookup. Account balances and round views are read at one block. Polling runs 15 seconds after each completed refresh, avoiding overlapping slow fallback requests. A wallet change immediately invalidates eligibility. Every write is simulated before signing, then checked for matching wallet/chain, tracked through its receipt, and followed by a balance refresh. A transaction link remains available if confirmation times out. Read errors, rejections and decoded revert details are shown without silently discarding saved secrets.

The approved workflow explicitly says **no in-page swap**. The page links to Uniswap using the runtime token address and explains that HEDS comes from the Sepolia ETH launch pool. External interface support/liquidity is not certified here. The manifest retains the full vetted Uniswap v4 address block unchanged; this app performs no router calls, quotes, Permit2 approvals or liquidity operations. Its only token approval is to the game for a stake.

## Secrets and game assumptions

`crypto.getRandomValues` generates a 32-byte salt. The commitment is `keccak256(abi.encode(bool heads, bytes32 salt, address account, uint256 roundId))`. Local storage keys include chain, game, account and round. An existing secret is reused after rejection or pending attempts; it is never automatically replaced. Joining requires successful storage and a backup acknowledgment. Backup restoration validates its context and, once joined, its onchain commitment. Local storage is unencrypted and specific to the browser/origin: clearing site data, changing gateway origins, device loss or malicious same-origin scripts can expose/lose secrets. Save the downloadable JSON privately before joining. No secret is sent to an application server.

The last revealer can see the outcome and change it by withholding, at the cost of their stake; with two players, withholding against a revealer always loses. This is not unbiased randomness. Correct revealers split the pot; if no side matches, all revealers split it; rounding dust is burned. If nobody reveals, all participants are credited their original stakes. The game has no owner, pause, upgrade or VRF. HEDS remains in contract custody until eligible credits are withdrawn. The frontend does not alter those economics or guarantee a reveal/settlement will be included before its deadline.

## Validation

```sh
npm --prefix web test
npm --prefix web run check:live
```

The browser script starts a temporary foreground HTTP server under `/preview/`, launches Chromium, and closes both on completion. It uses the worker's installed Chromium when present; otherwise run `npx --prefix web playwright install chromium` with a writable browser cache, or set `CHROMIUM_PATH` to an installed Chromium binary. Wallet and RPC interaction tests are mocks; no transactions are broadcast. An additional unmocked browser read and `check:live` exercise public RPC access without signing.

See [validation and limitations](../docs/VALIDATION.md), [design system](../docs/DESIGN.md), and [machine-readable evidence](../docs/evidence/browser-results.json). The provided browser connector could not initialize its read-only cache, so browser evidence uses local Playwright/Chromium. Live funded transactions, wallet-extension UI, physical devices and screen readers are untested. The three configured RPCs were independently checked for chain ID, code and token binding. These are worker observations, not independent network certification or publication checks.

## Delivery scope

Source, lockfile and frontend configuration are under `web/`; static export is under `dist/`; docs/evidence are under `docs/`. The explicit ignore-file budget is **one file: `web/.gitignore`**. Its patterns exclude dependency/cache directories at every depth below `web/`. No submodule, registry archive, package cache or `node_modules` is delivered. Root `DESIGN.md` would violate the higher-priority allowed paths, so its required content is delivered as `docs/DESIGN.md`. Publication, IPFS pinning, names and contract redeployment are outside this worker assignment.

Implementation references: [Vite relative base](https://vite.dev/config/shared-options.html#base), [viem simulation](https://viem.sh/docs/contract/simulateContract). Runtime license notices are included in the static export.
