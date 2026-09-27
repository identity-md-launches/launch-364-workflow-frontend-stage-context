// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {CommitRevealCoinFlip as Game} from "../src/CommitRevealCoinFlip.sol";

/// @dev Randomised conservation checks over 2-16 players with random sides, salts and reveal
/// subsets. Every expected quantity is recomputed here from first principles (per-round stakes,
/// per-account credits, token balances) rather than read back from the contract's own counters,
/// so a counter that drifted from custody would fail these tests.
contract PayoutConservationFuzzTest is Test {
    LaunchToken private token;
    Game private game;
    address private burn;

    uint256 private constant MAX = 16;
    uint256 private constant MIN_STAKE = 1 ether;
    uint256 private constant MAX_FUZZ_STAKE = 1_000_000 ether;
    uint256 private constant FUNDING = 10_000_000 ether;

    struct Plan {
        uint256 id;
        uint256 count;
        uint256 stake;
        uint16 sideMask;
        uint16 revealMask;
        bytes32[16] salts;
    }

    function setUp() public {
        token = new LaunchToken();
        game = new Game(address(token));
        burn = game.BURN_ADDRESS();
        for (uint256 i; i < MAX; ++i) {
            address account = _player(i);
            token.transfer(account, FUNDING);
            vm.prank(account);
            token.approve(address(game), type(uint256).max);
        }
    }

    // ---------------------------------------------------------------- helpers

    function _player(uint256 i) private pure returns (address) {
        return address(uint160(0x1000 + i));
    }

    function _side(uint16 mask, uint256 i) private pure returns (bool) {
        return (mask & (1 << i)) != 0;
    }

    function _reveals(uint16 mask, uint256 i) private pure returns (bool) {
        return (mask & (1 << i)) != 0;
    }

    function _commit(uint256 id, address account, bool heads, bytes32 salt) private pure returns (bytes32) {
        return keccak256(abi.encode(heads, salt, account, id));
    }

    function _salt(uint256 seed, uint256 i) private pure returns (bytes32) {
        // A random 256-bit salt, with an exact zero salt forced in about one run in eight so the
        // "zero still XORs and still needs its preimage" edge is exercised.
        if (seed % 8 == 0 && i == 0) return bytes32(0);
        return keccak256(abi.encode(seed, i));
    }

    /// @dev Creates a round and joins `count` players with the planned sides and salts.
    function _fill(Plan memory p, uint256 saltSeed) private {
        p.id = game.createRound(p.stake);
        for (uint256 i; i < p.count; ++i) {
            p.salts[i] = _salt(saltSeed, i);
            vm.prank(_player(i));
            game.join(p.id, _commit(p.id, _player(i), _side(p.sideMask, i), p.salts[i]));
        }
    }

    /// @dev Reveals the planned subset and returns the independently computed outcome.
    function _revealSubset(Plan memory p) private returns (uint256 revealed, bool coin) {
        bytes32 acc;
        for (uint256 i; i < p.count; ++i) {
            if (!_reveals(p.revealMask, i)) continue;
            vm.prank(_player(i));
            game.reveal(p.id, _side(p.sideMask, i), p.salts[i]);
            ++revealed;
            acc ^= p.salts[i];
        }
        coin = (uint256(acc) & 1) == 1;
    }

    function _unsettledStakes() private view returns (uint256 stakes) {
        for (uint256 id = 1; id <= game.roundCount(); ++id) {
            Game.Round memory r = game.round(id);
            if (!r.settled) stakes += r.playerCount * r.stake;
        }
    }

    function _sumWithdrawable() private view returns (uint256 credits) {
        for (uint256 i; i < MAX; ++i) {
            credits += game.withdrawable(_player(i));
        }
    }

    function _snapshotCredits() private view returns (uint256[16] memory credits) {
        for (uint256 i; i < MAX; ++i) {
            credits[i] = game.withdrawable(_player(i));
        }
    }

    /// @dev HEDS held == unsettled stakes + sum(withdrawable), with both sides recomputed here.
    function _assertCustody() private view {
        uint256 stakes = _unsettledStakes();
        uint256 credits = _sumWithdrawable();
        assertEq(token.balanceOf(address(game)), stakes + credits, "held != unsettled stakes + credits");
        assertEq(game.totalStaked(), stakes, "totalStaked drifted from per-round recomputation");
        assertEq(game.totalWithdrawable(), credits, "totalWithdrawable drifted from per-account recomputation");
    }

    function _plan(uint8 countSeed, uint96 stakeSeed, uint16 sideMask, uint16 revealMask)
        private
        pure
        returns (Plan memory p)
    {
        p.count = bound(countSeed, 2, MAX);
        p.stake = bound(stakeSeed, MIN_STAKE, MAX_FUZZ_STAKE);
        p.sideMask = sideMask;
        p.revealMask = uint16(revealMask & ((1 << p.count) - 1));
    }

    // ------------------------------------------------------------------ tests

    /// @notice payouts + burn == pot exactly, for any player count, side mix, salt mix and reveal subset.
    function testFuzz_payoutsPlusBurnEqualPotExactly(
        uint8 countSeed,
        uint96 stakeSeed,
        uint16 sideMask,
        uint16 revealMask,
        uint256 saltSeed
    ) public {
        Plan memory p = _plan(countSeed, stakeSeed, sideMask, revealMask);
        _fill(p, saltSeed);
        uint256 pot = p.count * p.stake;
        assertEq(token.balanceOf(address(game)), pot, "pot must be fully custodied after joins");
        _assertCustody();

        vm.warp(game.round(p.id).joinDeadline);
        (uint256 revealed, bool coin) = _revealSubset(p);
        _assertCustody();

        uint256 burnBefore = token.balanceOf(burn);
        vm.warp(game.round(p.id).revealDeadline);
        game.settle(p.id);
        _assertCustody();

        uint256 burned = token.balanceOf(burn) - burnBefore;
        uint256 paid;
        for (uint256 i; i < p.count; ++i) {
            paid += game.withdrawable(_player(i));
        }
        assertEq(paid + burned, pot, "payouts + burn != pot");
        assertLt(burned, MAX, "burn is more than rounding dust");
        assertEq(game.totalStaked(), 0, "settled pot still counted as staked");

        Game.Round memory r = game.round(p.id);
        assertTrue(r.settled);
        assertEq(r.heads, coin, "coin disagrees with XOR-parity recomputation");
        if (revealed == 0) {
            assertEq(burned, 0, "an all-withhold refund must not burn anything");
            assertEq(r.winners, 0);
            assertEq(r.share, p.stake);
        } else {
            uint256 recipients = r.winners == 0 ? revealed : r.winners;
            assertEq(r.share, pot / recipients, "share is not floor(pot / recipients)");
            assertEq(burned, pot % recipients, "burn is not the division remainder");
        }

        // Every credited player can actually collect exactly what the view promised; the contract
        // ends empty, and paid-out tokens plus dust equal the pot down to the wei.
        uint256 collected;
        for (uint256 i; i < p.count; ++i) {
            address account = _player(i);
            uint256 credit = game.withdrawable(account);
            if (credit == 0) continue;
            uint256 before = token.balanceOf(account);
            vm.prank(account);
            game.withdraw();
            assertEq(token.balanceOf(account) - before, credit, "withdraw paid a different amount than credited");
            collected += credit;
            _assertCustody();
        }
        assertEq(collected + burned, pot);
        assertEq(token.balanceOf(address(game)), 0, "custody not empty after every credit was collected");
        assertEq(token.totalSupply(), 1_000_000_000 ether, "burning to dEaD must not change supply");
    }

    /// @notice When at least one player reveals, a player who did not reveal is paid nothing and cannot withdraw.
    function testFuzz_nonRevealerIsNeverPaidWhenAnyoneRevealed(
        uint8 countSeed,
        uint96 stakeSeed,
        uint16 sideMask,
        uint16 revealMask,
        uint256 saltSeed
    ) public {
        Plan memory p = _plan(countSeed, stakeSeed, sideMask, revealMask);
        // Guarantee at least one revealer and at least one withholder, at fuzzed positions.
        uint256 revealer = uint256(saltSeed) % p.count;
        uint256 withholder = (revealer + 1 + (uint256(sideMask) % (p.count - 1))) % p.count;
        p.revealMask |= uint16(1 << revealer);
        p.revealMask &= ~uint16(1 << withholder);
        _fill(p, saltSeed);
        uint256 pot = p.count * p.stake;

        vm.warp(game.round(p.id).joinDeadline);
        (uint256 revealed, bool coin) = _revealSubset(p);
        assertGe(revealed, 1);
        assertLe(revealed, p.count - 1);

        uint256 burnBefore = token.balanceOf(burn);
        vm.warp(game.round(p.id).revealDeadline);
        game.settle(p.id);
        _assertCustody();

        uint256 winners;
        uint256 toRevealers;
        for (uint256 i; i < p.count; ++i) {
            address account = _player(i);
            if (!_reveals(p.revealMask, i)) {
                assertEq(game.withdrawable(account), 0, "a withholder was paid although someone revealed");
                assertFalse(game.player(p.id, account).revealed);
                vm.prank(account);
                vm.expectRevert(Game.NothingToWithdraw.selector);
                game.withdraw();
            } else {
                if (_side(p.sideMask, i) == coin) ++winners;
                toRevealers += game.withdrawable(account);
            }
        }
        assertEq(game.round(p.id).winners, winners);
        // The forfeited stakes are in the pot that revealers and the burn address split exactly.
        assertEq(toRevealers + (token.balanceOf(burn) - burnBefore), pot, "forfeited stakes leaked");
        assertGt(toRevealers, (p.count - revealed) * p.stake / 2, "forfeits were not redistributed");

        uint256 recipients = winners == 0 ? revealed : winners;
        for (uint256 i; i < p.count; ++i) {
            if (!_reveals(p.revealMask, i)) continue;
            bool paid = winners == 0 || _side(p.sideMask, i) == coin;
            assertEq(game.withdrawable(_player(i)), paid ? pot / recipients : 0, "revealer credit mismatch");
        }
    }

    /// @notice A unanimous side mix pays every revealer the same whether they all won or all lost.
    function testFuzz_unanimousSidesPayEveryRevealerEqually(
        uint8 countSeed,
        uint96 stakeSeed,
        bool heads,
        uint16 revealMask,
        uint256 saltSeed
    ) public {
        Plan memory p = _plan(countSeed, stakeSeed, heads ? type(uint16).max : 0, revealMask);
        p.revealMask |= uint16(1 << (saltSeed % p.count));
        _fill(p, saltSeed);
        uint256 pot = p.count * p.stake;

        vm.warp(game.round(p.id).joinDeadline);
        (uint256 revealed, bool coin) = _revealSubset(p);
        uint256 burnBefore = token.balanceOf(burn);
        vm.warp(game.round(p.id).revealDeadline);
        game.settle(p.id);

        Game.Round memory r = game.round(p.id);
        assertEq(r.winners, coin == heads ? revealed : 0);
        assertEq(r.share, pot / revealed);
        for (uint256 i; i < p.count; ++i) {
            assertEq(game.withdrawable(_player(i)), _reveals(p.revealMask, i) ? pot / revealed : 0);
        }
        assertEq(token.balanceOf(burn) - burnBefore, pot % revealed);
        _assertCustody();
    }

    /// @notice Custody holds across three overlapping rounds with shared players, partial settlement
    /// and partial withdrawal, with unsettled stakes and credits recomputed independently.
    function testFuzz_custodyHoldsAcrossOverlappingRoundsAndPartialWithdrawals(
        uint8[3] memory countSeeds,
        uint96[3] memory stakeSeeds,
        uint16[3] memory sideMasks,
        uint16[3] memory revealMasks,
        uint256 saltSeed,
        uint8 settleMask,
        uint16 withdrawMask
    ) public {
        Plan[3] memory plans;
        uint256 start = block.timestamp;
        uint256 paidIn;
        for (uint256 k; k < 3; ++k) {
            // Staggered creation: while round k is joinable, earlier rounds are already revealing.
            vm.warp(start + k * 25 minutes);
            plans[k] = _plan(countSeeds[k], stakeSeeds[k], sideMasks[k], revealMasks[k]);
            _fill(plans[k], uint256(keccak256(abi.encode(saltSeed, k))));
            paidIn += plans[k].count * plans[k].stake;
            _assertCustody();
        }
        assertEq(token.balanceOf(address(game)), paidIn);

        for (uint256 k; k < 3; ++k) {
            vm.warp(game.round(plans[k].id).joinDeadline);
            _revealSubset(plans[k]);
            _assertCustody();
        }

        // All three reveal windows are closed once the last one is.
        vm.warp(game.round(plans[2].id).revealDeadline);
        uint256 settledRounds;
        for (uint256 k; k < 3; ++k) {
            if ((settleMask & (1 << k)) == 0) continue;
            game.settle(plans[k].id);
            ++settledRounds;
            _assertCustody();
        }
        uint256 stillStaked;
        for (uint256 k; k < 3; ++k) {
            if ((settleMask & (1 << k)) == 0) stillStaked += plans[k].count * plans[k].stake;
        }
        assertEq(_unsettledStakes(), stillStaked, "unsettled stakes must be exactly the unsettled rounds' pots");

        uint256 paidOut;
        for (uint256 i; i < MAX; ++i) {
            if ((withdrawMask & (1 << i)) == 0) continue;
            address account = _player(i);
            uint256 credit = game.withdrawable(account);
            vm.prank(account);
            if (credit == 0) {
                vm.expectRevert(Game.NothingToWithdraw.selector);
                game.withdraw();
                continue;
            }
            game.withdraw();
            paidOut += credit;
            assertEq(game.withdrawable(account), 0);
            _assertCustody();
        }
        assertEq(
            token.balanceOf(address(game)) + paidOut + token.balanceOf(burn),
            paidIn,
            "deposits != held + withdrawn + burned"
        );

        // Finish every history: settle the rest, collect the rest, custody returns to zero.
        for (uint256 k; k < 3; ++k) {
            if ((settleMask & (1 << k)) != 0) {
                vm.expectRevert(Game.AlreadySettled.selector);
            }
            game.settle(plans[k].id);
            _assertCustody();
        }
        for (uint256 i; i < MAX; ++i) {
            address account = _player(i);
            uint256 credit = game.withdrawable(account);
            if (credit == 0) continue;
            vm.prank(account);
            game.withdraw();
            paidOut += credit;
        }
        assertEq(token.balanceOf(address(game)), 0);
        assertEq(game.totalStaked(), 0);
        assertEq(game.totalWithdrawable(), 0);
        assertEq(paidOut + token.balanceOf(burn), paidIn);
        assertLt(token.balanceOf(burn), 3 * MAX, "more than rounding dust burned across three rounds");
    }

    /// @notice Every rejected action around a fuzzed round leaves custody untouched.
    function testFuzz_rejectedActionsDoNotMoveCustody(
        uint8 countSeed,
        uint96 stakeSeed,
        uint16 sideMask,
        uint16 revealMask,
        uint256 saltSeed
    ) public {
        Plan memory p = _plan(countSeed, stakeSeed, sideMask, revealMask);
        _fill(p, saltSeed);
        uint256 pot = p.count * p.stake;
        Game.Round memory r = game.round(p.id);
        address outsider = address(0xDEAD1);
        token.transfer(outsider, p.stake);
        vm.prank(outsider);
        token.approve(address(game), type(uint256).max);

        // Cap: a 17th entry never gets in, at any stake.
        if (p.count == MAX) {
            vm.prank(outsider);
            vm.expectRevert(Game.RoundFull.selector);
            game.join(p.id, _commit(p.id, outsider, true, bytes32(0)));
        }

        // Reveal in the join window is refused, even with a correct preimage.
        vm.warp(r.joinDeadline - 1);
        vm.prank(_player(0));
        vm.expectRevert(Game.RevealClosed.selector);
        game.reveal(p.id, _side(p.sideMask, 0), p.salts[0]);

        // Join exactly at the deadline is refused; the stake stays with the outsider.
        vm.warp(r.joinDeadline);
        vm.prank(outsider);
        vm.expectRevert(Game.JoinClosed.selector);
        game.join(p.id, _commit(p.id, outsider, true, bytes32(0)));
        assertEq(token.balanceOf(outsider), p.stake);

        // Wrong salt, wrong side, wrong sender: none of them reveal, and none change the XOR.
        bytes32 xorBefore = game.round(p.id).saltXor;
        vm.prank(_player(0));
        vm.expectRevert(Game.InvalidReveal.selector);
        game.reveal(p.id, _side(p.sideMask, 0), p.salts[0] ^ bytes32(uint256(1)));
        vm.prank(_player(0));
        vm.expectRevert(Game.InvalidReveal.selector);
        game.reveal(p.id, !_side(p.sideMask, 0), p.salts[0]);
        vm.prank(_player(1));
        vm.expectRevert(Game.InvalidReveal.selector);
        game.reveal(p.id, _side(p.sideMask, 0), p.salts[0]);
        vm.prank(outsider);
        vm.expectRevert(Game.NotJoined.selector);
        game.reveal(p.id, _side(p.sideMask, 0), p.salts[0]);
        assertEq(game.round(p.id).saltXor, xorBefore);
        assertEq(game.round(p.id).revealCount, 0);

        // A competitive round can never be reclaimed.
        vm.prank(_player(0));
        vm.expectRevert(Game.NotReclaimable.selector);
        game.reclaim(p.id);

        (uint256 revealed,) = _revealSubset(p);
        for (uint256 i; i < p.count; ++i) {
            if (!_reveals(p.revealMask, i)) continue;
            vm.prank(_player(i));
            vm.expectRevert(Game.AlreadyRevealed.selector);
            game.reveal(p.id, _side(p.sideMask, i), p.salts[i]);
        }
        assertEq(game.round(p.id).revealCount, revealed);

        // One second early is too early; the pot is still fully staked.
        vm.warp(r.revealDeadline - 1);
        vm.expectRevert(Game.SettlementTooEarly.selector);
        game.settle(p.id);
        assertEq(game.totalStaked(), pot);
        assertEq(token.balanceOf(address(game)), pot);
        _assertCustody();

        // At the deadline reveals are over, settlement happens once, and everything after is refused.
        vm.warp(r.revealDeadline);
        for (uint256 i; i < p.count; ++i) {
            if (_reveals(p.revealMask, i)) continue;
            vm.prank(_player(i));
            vm.expectRevert(Game.RevealClosed.selector);
            game.reveal(p.id, _side(p.sideMask, i), p.salts[i]);
        }
        game.settle(p.id);
        _assertCustody();
        vm.expectRevert(Game.AlreadySettled.selector);
        game.settle(p.id);
        vm.prank(_player(0));
        vm.expectRevert(Game.AlreadySettled.selector);
        game.reclaim(p.id);
        vm.prank(outsider);
        vm.expectRevert(Game.JoinClosed.selector);
        game.join(p.id, _commit(p.id, outsider, true, bytes32(0)));
        for (uint256 i; i < p.count; ++i) {
            if (_reveals(p.revealMask, i)) continue;
            vm.prank(_player(i));
            vm.expectRevert(Game.RevealClosed.selector);
            game.reveal(p.id, _side(p.sideMask, i), p.salts[i]);
        }

        // A second withdrawal by anyone who was paid gets nothing.
        for (uint256 i; i < p.count; ++i) {
            address account = _player(i);
            if (game.withdrawable(account) == 0) continue;
            vm.prank(account);
            game.withdraw();
            vm.prank(account);
            vm.expectRevert(Game.NothingToWithdraw.selector);
            game.withdraw();
        }
        assertEq(token.balanceOf(address(game)), 0);
        _assertCustody();
    }

    /// @notice A lone player (count 1) and an empty round (count 0) refund exactly and burn nothing.
    function testFuzz_fewerThanTwoPlayersRefundExactly(uint96 stakeSeed, bool lone, bool viaReclaim) public {
        uint256 stake = bound(stakeSeed, MIN_STAKE, MAX_FUZZ_STAKE);
        uint256 id = game.createRound(stake);
        address solo = _player(0);
        if (lone) {
            vm.prank(solo);
            game.join(id, _commit(id, solo, true, bytes32(uint256(7))));
        }
        _assertCustody();
        uint256 burnBefore = token.balanceOf(burn);

        vm.warp(game.round(id).joinDeadline);
        // Reveal is unavailable below two players even with a correct preimage.
        vm.prank(solo);
        vm.expectRevert(Game.TooFewPlayers.selector);
        game.reveal(id, true, bytes32(uint256(7)));

        if (lone && viaReclaim) {
            vm.prank(solo);
            game.reclaim(id);
            vm.prank(solo);
            vm.expectRevert(Game.AlreadySettled.selector);
            game.reclaim(id);
            vm.expectRevert(Game.AlreadySettled.selector);
            game.settle(id);
        } else {
            if (!lone) {
                vm.prank(solo);
                vm.expectRevert(Game.NotJoined.selector);
                game.reclaim(id);
            }
            vm.warp(game.round(id).revealDeadline);
            game.settle(id);
            if (lone) {
                vm.prank(solo);
                vm.expectRevert(Game.AlreadySettled.selector);
                game.reclaim(id);
            }
        }
        _assertCustody();
        assertEq(game.withdrawable(solo), lone ? stake : 0);
        assertEq(token.balanceOf(burn), burnBefore, "refund path must not burn");
        assertEq(game.round(id).winners, 0);
        if (lone) {
            vm.prank(solo);
            game.withdraw();
            assertEq(token.balanceOf(solo), FUNDING);
        }
        assertEq(token.balanceOf(address(game)), 0);
    }

    /// @notice createRound accepts exactly [1 HEDS, uint256.max / 16] so that a 16-player pot cannot overflow.
    function testFuzz_stakeBounds(uint256 stake) public {
        uint256 cap = type(uint256).max / MAX;
        if (stake < MIN_STAKE || stake > cap) {
            vm.expectRevert(Game.InvalidStake.selector);
            game.createRound(stake);
            assertEq(game.roundCount(), 0);
        } else {
            uint256 id = game.createRound(stake);
            assertEq(game.round(id).stake, stake);
            unchecked {
                assertGe(MAX * stake, stake, "16 * stake must not wrap");
            }
        }
        vm.expectRevert(Game.InvalidStake.selector);
        game.createRound(cap + 1);
        vm.expectRevert(Game.InvalidStake.selector);
        game.createRound(MIN_STAKE - 1);
        assertEq(game.round(game.createRound(cap)).stake, cap);
        _assertCustody();
    }
}
