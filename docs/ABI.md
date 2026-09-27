# Contract ABI guide

The JSON files in `docs/abi/` are raw compiler ABI arrays, including custom errors,
events, constructor declarations, and tuple component names. Regenerate them from
Solidity 0.8.26 artifacts using `python3 tools/export_abi.py` after `forge build`.
`--check` verifies that delivered exports match the current build artifacts.

## LaunchToken

`constructor()` is nonpayable and mints `10^27` units to `msg.sender`.
Standard ERC-20 calls are `name()`, `symbol()`, `decimals()`, `totalSupply()`,
`balanceOf(address)`, `allowance(address,address)`, `approve(address,uint256)`,
`transfer(address,uint256)`, and `transferFrom(address,address,uint256)`.
Amounts use 18 decimals. Standard `Transfer` and `Approval` events apply.
There are no mint, burn, ownership, pause, or upgrade entry points.

## CommitRevealCoinFlip

`constructor(address token_)` is nonpayable. The manifest uses `["$token"]`.
All calls are nonpayable, and every round-specific call reverts `InvalidRound()`
for zero or an uncreated ID. `roundCount()` is the highest created ID.

| Call | Result / behavior |
| --- | --- |
| `token()` | Immutable HEDS address; obtain ERC-20 metadata, balances and approvals here |
| `createRound(uint256 stake)` | Returns new `uint256 roundId`; no automatic entry or payment |
| `join(uint256 roundId, bytes32 commitment)` | Pulls one stake from caller after approval |
| `reveal(uint256 roundId, bool heads, bytes32 salt)` | Validates caller's commitment and contributes salt |
| `reclaim(uint256 roundId)` | Finalizes a lone-player round and credits caller after join close |
| `settle(uint256 roundId)` | Finalizes after reveal close, credits recipients and burns dust |
| `withdraw()` | Collects all caller credits to caller, reverts if zero |
| `round(uint256 id)` | Returns the `Round` tuple described below |
| `player(uint256 id, address account)` | Returns the `Player` tuple described below |
| `phase(uint256 id)` | Returns `uint8` enum value in the table below |
| `withdrawable(address account)` | Caller's available credit in token minor units |
| `totalStaked()` / `totalWithdrawable()` | Aggregate liabilities, useful for accounting |
| `MIN_STAKE()` / `MAX_PLAYERS()` | `10^18` / `16` |
| `JOIN_WINDOW()` / `REVEAL_WINDOW()` | `3600` / `3600` seconds |
| `BURN_ADDRESS()` | `0x000000000000000000000000000000000000dEaD` |

Round tuple, in order:

| Field | Type | Meaning |
| --- | --- | --- |
| `stake` | uint256 | Equal HEDS entry amount |
| `joinDeadline` | uint256 | Unix seconds; joining excludes this instant |
| `revealDeadline` | uint256 | Unix seconds; revealing excludes, settlement includes this instant |
| `playerCount` | uint256 | Total joined, retained after settlement/reclaim |
| `revealCount` | uint256 | Valid revealed entries |
| `saltXor` | bytes32 | XOR of revealed salts; final outcome is its low bit |
| `settled` | bool | Closed by settlement or reclaim |
| `heads` | bool | Final coin; meaningful only after settlement with revealers |
| `winners` | uint256 | Correct-side revealer count, zero for fallback/refund/reclaim |
| `share` | uint256 | Credited amount per eligible recipient; zero for empty settlement |

Before settlement, `heads`, `winners` and `share` are placeholders. An all-withhold
refund has `heads=false`, `winners=0`, `share=stake`; this is a refund, not a tails
win. A no-winner split has `winners=0`, `revealCount>0`, and `share` applies to all
revealers. A reclaim sets `settled=true`, `share=stake` and leaves the coin fields
at their defaults. Do not label these cases solely from `heads` or `winners`.

Player tuple, in order: `commitment (bytes32)`, `joined (bool)`, `revealed (bool)`,
`heads (bool)`, `reclaimed (bool)`. An absent player returns zero/default fields.
`joined` distinguishes absence from an intentionally zero commitment. `heads` is
meaningful only when revealed. `reclaimed` means the account used `reclaim` rather
than being refunded by `settle`; it is not a withdrawal flag. Check `withdrawable`
for outstanding credits.

| Phase | Value | Available actions |
| --- | --- | --- |
| Join | 0 | Join until deadline, subject to cap and duplicate rules |
| Reveal | 1 | Reveal for rounds with at least two players |
| Reclaimable | 2 | Lone player can reclaim; after revealDeadline anyone can settle, including an empty round |
| AwaitingSettlement | 3 | Anyone can settle a round with at least two players |
| Settled | 4 | Round is closed; credit holders can withdraw |

`withdraw()` can also be called while other rounds are active. There is no
withdrawal expiry or need to specify a round.

## Events

| Signature | Indexed fields | Notes |
| --- | --- | --- |
| `RoundCreated(uint256 roundId,uint256 stake,uint256 joinDeadline,uint256 revealDeadline)` | roundId | Enumerate rounds, or read IDs 1 through roundCount |
| `Joined(uint256 roundId,address account,bytes32 commitment)` | roundId, account | Enumerate participants; at most 16 per round |
| `Revealed(uint256 roundId,address account,bool heads,bytes32 salt)` | roundId, account | Accepted preimage |
| `Settled(uint256 roundId,bool heads,uint256 winners,uint256 share)` | roundId | Winners counts correct-side revealers, not fallback recipients |
| `Reclaimed(uint256 roundId,address account,uint256 amount)` | roundId, account | Credit issued and round closed; does not also emit Settled |
| `Withdrawn(address account,uint256 amount)` | account | Successful transfer of all account credits |

Rounding burns emit the token's standard `Transfer(game, BURN_ADDRESS, remainder)`.
Round closure events create credits, not immediate payments. Confirm transaction
receipts and refresh views to handle reorgs, concurrent actions and stale UI state.

## Common errors

App-defined errors are `InvalidToken`, `InvalidStake`, `InvalidRound`, `JoinClosed`,
`AlreadyJoined`, `RoundFull`, `RevealClosed`, `NotJoined`, `AlreadyRevealed`,
`InvalidReveal`, `TooFewPlayers`, `NotReclaimable`, `SettlementTooEarly`,
`AlreadySettled`, `NothingToWithdraw`, and `UnexpectedTransferAmount` (all have no
arguments). SafeERC20 and ReentrancyGuard errors are included in the ABI as well.
Underlying token custom errors, such as insufficient balance/allowance, can bubble
through the app; decode those using the LaunchToken ABI. Failed transactions make
no partial entry, credit, burn or withdrawal changes.
