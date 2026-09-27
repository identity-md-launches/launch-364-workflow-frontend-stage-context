# Heads (HEDS)

Heads is a **Sepolia test game with no real value**. Players commit to heads or
tails, reveal during a later window, and share a HEDS pot. This commit-reveal
mechanism is manipulable by withholding, especially across coordinated wallets.
It is unsuitable for fair wagering with valuable assets.

This contribution supplies the two contracts, Foundry tests, and ABI exports.
The separate manifest contributor and independent reviewer consume these files.
Services subsequently publish source, attest, admit, deploy through ProjectFactory,
and start the frontend stage. No deployment, independent approval, or live site is
claimed here.

## Build and test

Requires Foundry with Solidity **0.8.26** installed. The verifier supplies that
compiler. All Solidity dependencies are ordinary vendored source files, so builds
need no package downloads. No FFI, filesystem cheatcode permissions, wallet keys,
RPC configuration, or environment variables are needed by the tests.

```sh
forge build
forge test
forge fmt --check
python3 tools/export_abi.py --check
```

Regenerate the ABI arrays after a source change with `forge build` followed by
`python3 tools/export_abi.py`. They are at
[`docs/abi/LaunchToken.json`](docs/abi/LaunchToken.json) and
[`docs/abi/CommitRevealCoinFlip.json`](docs/abi/CommitRevealCoinFlip.json).
The [ABI guide](docs/ABI.md) describes calls, structures, events and integration.
Dependencies and licenses are listed in [DEPENDENCIES.md](DEPENDENCIES.md).

## Token and deployment parameters

| Parameter | Value |
| --- | --- |
| Network | Sepolia, chain ID `11155111` only |
| Project kind / site label | `evm_project` / `lab-coin-flip-commit` |
| Launch token | `src/LaunchToken.sol:LaunchToken` |
| Name / symbol / decimals | Heads / HEDS / 18 |
| Supply | 1,000,000,000 HEDS = `1000000000000000000000000000` minor units |
| Token constructor | No arguments, nonpayable |
| Application | `src/CommitRevealCoinFlip.sol:CommitRevealCoinFlip` |
| Application constructor | One nonpayable `address token_`, manifest argument `["$token"]` |
| Compiler | Solidity 0.8.26, Cancun, optimizer enabled with 200 runs |
| Metadata | `bytecode_hash = "none"` |

Deploy LaunchToken first, then CommitRevealCoinFlip using the resulting token
address. LaunchToken mints its entire supply once to its deployer (the factory).
The app constructor checks that the supplied token has code, stores it immutably,
and makes no transfers or initialization calls. It begins with zero HEDS. Neither
contract has an owner, mint extension, fee, pause, upgrade, rescue, or privileged
beneficiary. The factory need not exercise any application authority.

The manifest assignment writes `launch.json`, naming LaunchToken as the launch
token and CommitRevealCoinFlip as the single application, with `["$token"]`.
Both identifiers fit the 32-character limit. Manifest policy and signed artifact
linkage belong to services; the independent reviewer must still inspect actual
source/constructor/authorization consistency. No `$owner` argument is needed.

The service selects the pinned Sepolia policy, LP/reward distribution and effective
opening price. Canonical pool guidance is native ETH (zero address), fee 3000,
tick spacing 60, no hook, legacy `initialPrice` of
`79228162514264337593543950336`; a pinned policy's `initialMarketCapWei` overrides
that legacy price. The factory seeds liquidity with launch tokens only. This
source does not encode policy economics or assume an initial application balance.

Deployment services must verify chain ID, correct `$token` resolution, runtime
constraints, and the independent review before release. The contracts themselves
do not prohibit deployment on other chains; Sepolia-only operation is a service
and frontend responsibility. Actual addresses and the applicable policy/artifact
identifiers are outputs of those later stages, not missing constructor settings.

## Round rules

1. Anyone calls `createRound(stake)` to create an **empty** round. No HEDS is paid
   and the creator is not automatically a player. IDs start at 1. Stake is at
   least `10^18` minor units, with a defensive upper bound of `uint256.max / 16`.
2. Joining is allowed from creation until strictly before `joinDeadline`
   (creation plus 1 hour). Each address can enter once, with at most 16 entries.
   Approve the app on HEDS, then call `join(id, commitment)`; it pulls exactly the
   stake using SafeERC20. There is no permit dependency.
3. The commitment is exactly
   `keccak256(abi.encode(heads, salt, playerAddress, roundId))`, with types
   `(bool, bytes32, address, uint256)`. Use ABI encoding, **not packed encoding**.
   The side and salt cannot be changed after entry.
4. With at least two players, reveal during
   `[joinDeadline, revealDeadline)`, where revealDeadline is creation plus
   2 hours. Call `reveal(id, heads, salt)` from the joining address. Every valid
   salt, including zero, contributes to the XOR. A zero commitment can be entered
   but still requires a matching preimage to reveal.
5. With fewer than two players, the sole player can call `reclaim(id)` at or after
   joinDeadline. This closes the round and credits the stake; `withdraw()` collects
   it. Reveal is unavailable in such a round. Alternatively, anyone can settle it
   after revealDeadline, producing the same refund. An empty round can also be
   settled after revealDeadline.
6. Anyone calls `settle(id)` at or after revealDeadline, once. Even when all players
   reveal early, settlement waits for the deadline. There is no later expiry:
   settlement, reclaim and withdrawal remain available indefinitely.
7. The coin is heads if the XOR of revealed salts is odd; otherwise tails. The pot
   includes **all** stakes, including nonrevealers' forfeited stakes. Correct-side
   revealers receive `floor(pot / winners)` each. If there are no correct-side
   revealers, all revealers receive `floor(pot / revealers)` each. Nonrevealers
   receive nothing in either case. If nobody revealed, every player is refunded.
8. Division remainder is transferred to
   `0x000000000000000000000000000000000000dEaD`. This removes it from use without
   reducing ERC-20 `totalSupply()`. No other fee is taken.
9. Settlement and reclaim create credits. `withdraw()` transfers all the caller's
   credits to that same caller. Credits from multiple rounds accumulate. No third
   party can choose the recipient or withdraw someone else's balance.

All mutations use ReentrancyGuard. Withdrawals zero the credit before SafeERC20
transfers. Failed token calls roll back their entire transaction, preserving
credits or unsettled stakes for retry. Settlement transfers only rounding dust;
player recipients cannot block it by refusing a payout. No keeper is required,
but somebody must submit settlement transactions and pay Sepolia gas.

## Custody and accounting assumptions

Only this exact, fixed-supply, non-rebasing LaunchToken is supported for production.
The constructor cannot establish a token's honesty merely from its address.
Inbound balance checks reject short transfers; they do not make malicious,
rebasing, or fee-charging assets supported. Test mocks demonstrate defensive
failure behavior, not alternative authorized deployment tokens.

For game operations, the maintained invariant is:

```text
HEDS held = sum(playerCount * stake for every unsettled round)
          + sum(withdrawable balances)
          = totalStaked + totalWithdrawable
```

The stateful suite recomputes both sides from individual rounds/accounts and
also checks `deposits = held + withdrawn + burned`. Every generated history is
finally settled and withdrawn to establish a path to zero custody.

ERC-20 transfers can send unsolicited HEDS to any address. Such a donation makes
`held > totalStaked + totalWithdrawable`; it never changes a pot or credit and is
permanently stranded. There is intentionally no sweep authority. Exact equality
cannot be guaranteed against arbitrary external token transfers.

All public functions and constructors are nonpayable, with no receive or fallback.
Ordinary ETH transfers revert. Forced ETH (an EVM balance credit bypassing a
recipient call) is outside this guarantee and would likewise be stranded. ETH is
never a game currency or an accounting input.

## Randomness and review handoff

The last revealer can see the outcome and change it by withholding, at the cost
of their stake. With two players, withholding always loses that player's stake
**when the other player has revealed**. If both withhold, the explicit all-withhold
rule refunds both. With any number of players, a sole withholding address receives
zero if anyone else revealed; however, coalitions, bribes, and outside positions
can make steering the outcome worthwhile.

The executable examples in `test/Withholding.t.sol` quantify this using stake `s`:

| Players | Reveal all: attacker receipts | Withhold last: attacker receipts | Net under withholding |
| --- | --- | --- | --- |
| 2, attacker owns the last address | `2s` | `0` | `-s` |
| 3, coalition owns two addresses | `0` | `3s` at its other address | `+s` after its two stakes |
| 16, coalition owns two addresses | `0` | `16s` at its other address | `+14s` after its two stakes |

For the coalition examples, its two addresses choose tails; the last one has an
odd salt. Outsiders choose heads and every other salt is even. Revealing that last
salt makes heads win; withholding it lets the coalition's other address take the
entire pot. These are possible outcomes, not expected returns: other participants'
hidden commitments prevent assuming these conditions in advance. One-entry rules
limit addresses, not people. There is no VRF, oracle, trusted randomness server,
or valuable randomness derived from block values.

Commitments bind the round and address. They intentionally follow the approved
formula without a chain or contract domain; clients should never reuse secrets
across deployments. Validators can affect inclusion/timing near a deadline. Users
must allow time for inclusion and retain their salt; lost secrets cannot be reset.

This author's tests are **not an independent adversarial review**. The assigned
independent reviewer still needs to inspect accepted source and the final manifest,
including withholding at 2/3/16 players, commitment replay, premature settlement,
rounding, withdrawal reentrancy, and the factory constructor relationship. Tests
cover those concrete attacks, transfer failures, capacity, window boundaries,
refunds, accounting, and runtime restrictions; they do not prove cryptographic
fairness or real-network liveness.

## Frontend handoff

The later frontend is one static page, exported to `dist/index.html`, labelled
`lab-coin-flip-commit`, restricted to Sepolia and prominently marked “Sepolia test
game with no real value.” It reads HEDS from `game.token()` and displays the
connected wallet's balance, allowance, and withdrawable balance.

The page must expose Create, Join with heads/tails, Reveal, Settle, and outcome
views, plus Reclaim for a lone player and Withdraw for accumulated credits. Show
an Approve step before Join, the only paying game action. Users obtain HEDS by
swapping Sepolia ETH in the launch pool; the page has no swap integration.

Generate a fresh 32-byte salt with `crypto.getRandomValues`, persist the salt,
side, round, account and deployment context in localStorage **before joining**,
and show a backup to the player. A localStorage key should include chain ID,
application address, account and round ID. Never regenerate the secret between
joining and revealing. Use events and views for lists, with paginated RPC log
queries if needed; there is no backend or indexer. See the ABI guide for phase
values and zero-winner outcome handling. GitHub/IPFS publication and live address
configuration are service/frontend work after contract admission.
