# Frontend worker validation

## Scope and decisions

Implemented one Vite/React/TypeScript page and repository-root static export against deployed source commit `8887feb3c66e4e049889eac3b06d6c7b3fe7ee00`. The complete handoff is retained under `web/deployment/`. No contract, root build file, workflow, library or deployment was changed. Protected Solidity tests were read as definition inputs; Solidity was not rebuilt or redeployed for this frontend task.

The approved workflow explicitly requires **no in-page swap**. The delivered page provides an external Uniswap link, game approval, create/join/reveal/reclaim/settle/withdraw controls, live balances, paged contract-view round discovery and secret backup/recovery. `network` is copied unchanged, including all vetted Uniswap addresses; the app itself makes no swap, quote or liquidity call.

The higher-priority path budget excludes root `DESIGN.md`. Its complete implemented-design content is delivered at `docs/DESIGN.md`. The only modified ignore file is the explicitly allowed `web/.gitignore` (one-file budget). Dependency/cache directories are excluded at every level within `web/`.

## Commands and results

Run from the repository root on 2026-09-27 with Node 22.22.2 and npm 10.9.7:

| Check | Result |
| --- | --- |
| `npm --prefix web ci` | Locked dependencies installed; source/package lock remain under `web/` |
| `npm --prefix web run typecheck` | Passed; strict TypeScript, no emit |
| `npm --prefix web run build` | Passed; relative-base static export, pinned ABIs and final manifest generated |
| `npm --prefix web run check:export` | Passed; every final file rehashed, complete contract set and network compared |
| `npm --prefix web test` | Passed; production files served at `/preview/`, Chromium 154.0.8037.0; 24 recorded checks |
| `npm --prefix web run check:live` | Passed; all three configured public RPCs returned Sepolia, code and matching token binding |
| `node web/scripts/audit.mjs` | Passed; allowed paths, excluded dependency/cache trees, no submodules, no new symlinks, hashes and conservative size budget |
| `git add web dist docs` | Blocked: `.git/index.lock` cannot be created on the read-only `.git` filesystem. No local commit was made. |

Machine-readable evidence is in [browser-results.json](evidence/browser-results.json) and [live-rpc.json](evidence/live-rpc.json). Build and inventory output are saved alongside them. Vite reports one advisory for a minified JS chunk over 500 kB. The whole export remains far below the delivery/HTTP budgets; there is no code-splitting requirement for this single page.

The final export has **7 inventoried assets, 600,587 bytes excluding the manifest**. Source, evidence, export and the preexisting tracked repository together total approximately **4.46 MB uncompressed**, leaving ample room below the 8 MiB bundle budget. [Submission audit](evidence/submission-audit.json) records exact working-tree counts. Because `.git` is read-only, an actual commit/bundle could not be produced or measured on this worker; the raw file budget is the conservative proxy. Generated dependencies are ignored and are not part of that count.

Both canonical ABI Keccak hashes matched the handoff:

- LaunchToken: `38880b8e56d42ce900f744a7908c7139632a49f1c3f33385c64ceaed29d37bee`
- CommitRevealCoinFlip: `f45607189e6576c8a8406f6a7011a03faea1eb6d58908cbf0bc183d077082d23`

`dist/imd-deployment.json` is the runtime configuration and inventories every other export, including license text and both raw ABI arrays, with lowercase SHA-256. The emitter runs after Vite and copies ABIs from the pinned git source. It rejects ABI mismatch, missing entrypoint, unsafe contract names, symlinks, excessive count or oversized exports. Runtime ABI tampering was also tested to block the application.

## Browser and interaction coverage

The supplied MCP browser connector failed to initialize with `EROFS` while creating its cache under `/home/imd/.cache/ms-playwright/`. The fallback was the installed Chromium controlled by local Playwright, using a temporary server inside a bounded foreground script. Both server and browser close at the end. This is actual rendered browser evidence, not source-only validation.

The browser uses the production HTML/JS/CSS/manifest/ABIs. A mock injected EIP-1193 provider and encoded JSON-RPC responses exercise transactions without real funds or signatures. The suite checks:

- Disconnected, missing-wallet, rejected-connection and wrong-chain states; exact add-chain payload after 4902 and a second switch.
- Invalid stake validation and accessible field error. Exact one-stake approval precedes joining; insufficient allowance disables join.
- Random salt generation, storage/backup acknowledgment, original secret reuse after rejection, reload persistence, wrong-wallet backup rejection and onchain commitment mismatch rejection.
- Simulation failure shown before signing; join, reveal within its window, early settlement gating, settlement results, credited balances and withdrawal.
- Creation without entry/payment; lone-player reclaim and refund-specific result text; direct round lookup.
- Account/chain change invalidation, empty-code and token-binding failures, RPC outage/recovery, ABI tamper rejection.
- Native Enter activation on transaction buttons, focus on the skip link, responsive overflow checks and an automated axe WCAG A/AA scan of the connected join state (zero violations).
- Reduced-motion removes transitions; 200% root text enlargement reflows. No console errors or failed resources during mocked interactions.

Separately, an **unmocked browser** read of the actual production page successfully showed the live deployment with no rounds. Read-only Node RPC probes verified chain ID 11155111, token runtime length 1,722 bytes, game runtime length 5,458 bytes, matching `token()`, and round count zero at blocks 11,791,620–11,791,621. No transaction was broadcast.

## Better Interface review

All six pinned core domains and the document method were read and applied during construction. Scope is the single page, English, light theme. Checked widths are 320, 390, 744, 1024 and 1440 CSS pixels; root text enlargement was tested at 744px.

| Domain | Coverage and evidence | Limits |
| --- | --- | --- |
| Accessibility — Checked | Semantic landmarks/headings, native forms/radios/disclosures, bound labels, alerts/status, native disabled states, 44px buttons, skip/focus screenshot, keyboard transaction activation, axe scan | No screen-reader session, physical touch device or complete sequential keyboard journey through every disclosure |
| Layout — Checked | Desktop/mobile screenshots, shared gutters, stacking grids, all stated width overflow assertions, 200% text enlargement | Native browser zoom and RTL/pseudo-localization untested; only English is implemented |
| Writing — Checked | Contract-derived action labels; gas-only creation vs stake-taking join; exact allowance; window/forfeiture/backup instructions; refund and no-winner result branches reviewed | External swap interface wording/support is outside this site |
| Typography — Checked | System-font stacks, hierarchy, unitless line heights, tabular values, wrapping addresses, selectable backup; desktop and mobile rendered review | System font files vary by OS; cross-browser shaping untested |
| Colors — Checked | Semantic roles; axe; measured rendered body/page 12.68:1, secondary/page 5.54:1, primary button 10.03:1, selected phase 4.96:1 | Sampled opaque pairs, not every dynamic combination; no dark theme requested |
| UI — Checked | Empty, unavailable, loading, rejection, wrong-chain, approved/join, settled and credited states; disclosure controls; reduced motion; static coin artwork | Full slow-motion/forced-colors review not performed; no overlays or animated outcomes exist |

### Findings, fixes and rechecks

| Severity/domain | Source | Reproduction / impact | Fix and evidence |
| --- | --- | --- | --- |
| Medium — Writing/UI | `web/src/useGame.ts:55`, `web/src/game.ts:52` | Periodic successful reads cleared a signing error; using only the top-level viem summary hid a simulation reason. This made retry/recovery ambiguous. | Separated read errors from action errors and surfaced decoded/deep RPC reasons. Rejection and simulation-failure browser cases pass; source confirms action errors survive read refreshes. |
| Medium — Layout | `web/src/styles.css:199` | At 744px, the rotated decorative orbit extended to x=749.12 and created horizontal scrolling. | Remove this optional decoration at the compact breakpoint. Rechecked 320/390/744/1024/1440 and enlarged text with no page overflow. |
| Medium — UI/observability | `web/src/useGame.ts:61` | Source review found fixed-interval polling could overlap a slow three-RPC fallback; a failed post-receipt read could still be described as refreshed. | Poll after each completed read; return refresh success and use accurate receipt/status wording. Final interaction suite, outage/recovery and reconnect paths pass. A sustained 24-second fallback was not separately timed. |
| Low — Writing/accessibility | `web/src/App.tsx:65` | An invalid stake message remained after editing the input. | Clear the field-specific message on edit; invalid stake handling rechecked before the full game flow. |

### Rendered evidence inspected

- [Desktop, disconnected](evidence/desktop-disconnected.png), [desktop, connected](evidence/desktop-connected.png), [keyboard focus](evidence/keyboard-focus.png)
- [Mobile, connected](evidence/mobile-connected.png), [mobile backup detail](evidence/mobile-backup.png), [200% text enlargement](evidence/text-enlargement.png)
- [Wrong network](evidence/wrong-network.png), [settled result](evidence/settled.png), [RPC error](evidence/rpc-error.png)
- [Live unmocked deployment](evidence/live-desktop.png)

Screenshots contain mock wallet addresses and mock reveal secrets, not credentials for funded wallets. Passing a mocked interaction is not proof of live contract execution or wallet-extension behavior.

## Remaining limitations and completion

Live funded transactions, real wallet prompts, nonce races, wallet cancellation/repricing UI, reorgs, physical mobile devices, Safari/Firefox, native 200% zoom and screen readers were not tested. Receipt replacement/cancellation handling and account checks are implemented but those chain-level race paths are not independently proven here. The test model is a frontend fixture; it does not replace the existing Solidity adversarial/accounting tests. Publication URLs, CIDs, IPFS pinning, naming, immutable asset HTTP checks and control-plane RPC verification remain subsequent publisher responsibilities.

**Implementation and validation are complete; Git recording is blocked by the worker's read-only `.git` mount.** Source, lockfile, final export and evidence are present in permitted working-tree paths for publisher collection. The requested local commit remains unperformed. Root-design-file content is delivered under the overriding allowed documentation path. This is worker evidence only and carries no independent certification authority.
