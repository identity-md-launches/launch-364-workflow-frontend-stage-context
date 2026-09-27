# Heads — implemented design

## Overview

Heads is a one-page Sepolia commit–reveal test game. A warm paper background, dark green actions, restrained borders and a serif headline keep the page approachable while putting stake, deadline and backup information next to the relevant controls. The desktop page has a two-column round browser and selected-round panel; mobile follows the same DOM reading order in one column. The illustrative coins are CSS shapes, not external image assets.

This document describes `web/src/App.tsx` and `web/src/styles.css`. It lives in `docs/` because the assignment forbids creating root files. Its design choices were inferred from the product brief, not supplied as a preexisting brand system.

## Colors

Canonical values are hex primitives at the start of `styles.css`, mapped to semantic roles. Only a light theme is implemented.

| Role | Token | Value | Use |
| --- | --- | --- | --- |
| Page | `--bg` | `#f5f4ed` | Main paper background |
| Surface | `--surface` | `#fffef9` | Forms, buttons, round panel |
| Subtle fill | `--subtle` | `#eae9df` | Balance strip, disabled controls |
| Structure | `--line` | `#c9cbbd` | Dividers and surface borders |
| Primary text | `--text` | `#262e27` | Body, headings, values |
| Secondary text | `--muted` | `#5d645b` | Help, metadata and labels |
| Action/focus | `--accent`, `--focus` | `#1e493c` | Primary buttons, links, focus |
| Action hover | `--accent-hover` | `#153a2f` | Hovered primary action |
| Selection | `--selected` | `#e3eadb` | Chosen side and selected round |
| On accent | `--on-accent` | `#fffef9` | Primary action text |
| Warning | `--warning-bg`, `--warning-text` | `#f4ebd4`, `#684817` | Wrong-network message |
| Error | `--error-bg`, `--error-text` | `#fae8e3`, `#882d24` | Persistent failure feedback |

Rendered opaque pairs measured in Chromium: body/page **12.68:1**, secondary/page **5.54:1**, primary button **10.03:1**, round-list phase/selection **4.96:1**. These are sampled WCAG contrast ratios, not a certification of every possible state. Focus is a 3px outline with 4px offset; forced-colors mode uses `Highlight`.

## Typography

The UI requests `'Helvetica Neue', Helvetica, Arial, sans-serif`; display italics and coin letters use `Georgia, 'Times New Roman', serif`. There are no downloaded font files. Installed system fonts determine the exact rendered face; font-file identity is not certified.

- Body: 16px root, weight 400, unitless 1.55 line height. Common controls use 14px/600 and labels/help 12–13px. Compact metadata uses 10–11px in some places; it is selectable and responds to text enlargement.
- Hero: `clamp(3.3rem, 6.8vw, 5.7rem)`, 400, line height .98, letter spacing −.065em. Its italic line uses Georgia. Smaller breakpoints use 3.5rem, then `clamp(3rem, 12vw, 4rem)`.
- Section headings: 1.5rem/500, line height 1.15. Selected round: 2rem. The decorative empty-panel heading is 2.375rem Georgia; ordinary result headings are 1.125rem.
- Inputs are 16px. The read-only backup is 12px monospace on desktop and 16px at the narrow breakpoint, with scrolling and resizing available.
- Headings use balanced wrapping; descriptions use pretty wrapping. Changing quantities use tabular digits. Addresses and monetary values wrap anywhere rather than escape their containers. Meaningful values remain accessible in full, or through the linked explorer.

## Layout

`.wrap` sets a 1160px maximum outer width, centered, with 40px inline padding. Layout uses repeated 8/12/16/24/32/48px spacing; `--space-1` through `--space-6` document that scale. Components group label/control/help tightly and separate sections more widely. CSS uses logical margins/padding for text layout.

The hero is a 1.25fr/1fr grid. The round browser and rules use a 1fr/1.15fr grid with a 40px gutter. Wallet balances use three flexible columns and an action column. The selected panel stays in normal document flow, with no sticky overlay hiding controls.

| Breakpoint | Implemented change |
| --- | --- |
| ≤62rem | 28px page padding; 24px game gutter; hide brand tagline; compact balance type and wrap stake controls |
| ≤47rem | 20px page padding; game/rules stack; balances become two columns; coin art shrinks and decorative orbit is removed |
| ≤34rem | Hide hero coin art and header network tag; stack the three explanatory steps; withdraw spans the balance strip; create/action controls stack |

No page overflow was observed at 320, 390, 744, 1024 and 1440px, or at 744px with 200% root text enlargement. This is not browser-native zoom or physical-device verification. The final design intentionally has a longer mobile page rather than concealing contract actions behind tabs.

## Elevation & depth

The interface is mostly flat: surface tones and 1px structural borders separate the round panel, inputs and lists. Only decorative coins have offset solid shadows. There are no modals, tooltips, floating drawers or background scrims. The keyboard skip link uses a temporary high stacking order when focused.

## Shapes

Buttons and inputs use 6px radii; major panels/balance strip use 8px; phase tags use 4px. Coins, step indices and the small brand mark are circles. The decorative orbit is dashed and never carries information. Selection combines a tinted surface and a strong border; statuses always include text.

## Components

| Pattern/source | Purpose and states |
| --- | --- |
| `App`, `External` in `web/src/App.tsx` | One main landmark, header, balances, round browser, rules and footer. Explorer links open a new tab with `noreferrer`; external indicator is decorative. |
| `RoundPanel` in `web/src/App.tsx` | Stake, pot, deadlines, side choice, backup and actions for one account/round. Identity changes remount it; an existing secret is recovered from scoped storage. |
| Native `button`, `.primary`, `.text-button` | Neutral secondary actions, green next action, underlined refresh. Hover, focus and disabled styles; ≥44px minimum button height. Disabled action reasons are in adjacent text. |
| `.round-row`, `.selected`, `.phase` | Entire row is a native button. `aria-pressed` identifies selection; phase is text as well as a surface treatment. Six entries per page. |
| `.amount-field`, `.input-row` | Persistent labels, token suffix, input help and field error. Invalid stake submissions announce an error and focus the input. |
| `.side-picker` | Native radio group in a fieldset. Arrow keys and normal browser focus behavior apply; an existing saved side cannot be silently replaced. |
| `.backup`, `.restore`, `.rule-details` | Native disclosures; backup download, selectable read-only JSON, acknowledgment checkbox and context-validated restoration. |
| `.read-status`, `.error`, `.warning` | Stable polite status region, alert failures and visible network-switch recovery. Polling no longer clears transaction errors. |
| `.empty`, `.waiting-panel`, `.outcome` | Explicit empty/unavailable states, round selection prompt, and settlement/refund-specific result copy. No fabricated balances. |

Interactive color transitions last 120ms with `ease-out`, only under `prefers-reduced-motion: no-preference`. No entrance, coin-flip or payout animation is used. Reduced motion removes those transitions. Native keyboard activation of primary transaction controls was exercised in the browser; a screen-reader session was not performed.

## Do’s and don’ts

- Reuse `.wrap`, semantic palette roles, native controls and existing spacing before adding a new layout primitive.
- Reserve a filled primary action for the currently available next step. Keep other operations neutral and state why an action is unavailable.
- Put amounts in HEDS, preserve exact decimals for transactions, and keep deadlines near actions. Do not label refunds as coin wins.
- Keep errors actionable and persistent. Keep backup content selectable and downloadable. Do not replace a previously generated secret automatically.
- Any added page should inherit the root tokens, heading hierarchy and normal reading order. The current deployment intentionally has one entrypoint; additional routes would require explicit static exports or hash routing.

Guidance attribution: Jakub Krehel’s Better Interface, MIT, pinned commit `267330e1adfc66a718fb65fa6918c1f06d0a689e`; documentation method adapted from Paul Bakaus’s Impeccable, Apache-2.0, pinned commit `9d715cc4f5564a990ca8345abfdd5df6dc9b41c8`. See [attribution](ATTRIBUTION.md) and [validation](VALIDATION.md).
