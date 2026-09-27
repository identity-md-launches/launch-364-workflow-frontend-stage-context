// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {CommitRevealCoinFlip as Game} from "../src/CommitRevealCoinFlip.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract CommitRevealCoinFlipTest is Test {
    LaunchToken internal token;
    Game internal game;
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant CAROL = address(0xCA401);
    uint256 internal constant STAKE = 1 ether;

    event RoundCreated(uint256 indexed roundId, uint256 stake, uint256 joinDeadline, uint256 revealDeadline);
    event Joined(uint256 indexed roundId, address indexed account, bytes32 commitment);
    event Revealed(uint256 indexed roundId, address indexed account, bool heads, bytes32 salt);
    event Settled(uint256 indexed roundId, bool heads, uint256 winners, uint256 share);
    event Reclaimed(uint256 indexed roundId, address indexed account, uint256 amount);
    event Withdrawn(address indexed account, uint256 amount);

    function setUp() public virtual {
        token = new LaunchToken();
        game = new Game(address(token));
    }

    function _commit(uint256 id, address account, bool heads, uint256 salt) internal pure returns (bytes32) {
        return keccak256(abi.encode(heads, bytes32(salt), account, id));
    }

    function _fundApprove(address account, uint256 amount) internal {
        token.transfer(account, amount);
        vm.prank(account);
        token.approve(address(game), amount);
    }

    function _join(uint256 id, address account, bool heads, uint256 salt) internal {
        _fundApprove(account, game.round(id).stake);
        vm.prank(account);
        game.join(id, _commit(id, account, heads, salt));
    }

    function _reveal(uint256 id, address account, bool heads, uint256 salt) internal {
        vm.prank(account);
        game.reveal(id, heads, bytes32(salt));
    }

    function _twoPlayers() internal returns (uint256 id) {
        id = game.createRound(STAKE);
        _join(id, ALICE, true, 1);
        _join(id, BOB, false, 2);
    }

    function _assertAccounting() internal view {
        assertEq(token.balanceOf(address(game)), game.totalStaked() + game.totalWithdrawable());
    }

    function test_constructorStartsEmptyAndBindsToken() public view {
        assertEq(address(game.token()), address(token));
        assertEq(game.roundCount(), 0);
        assertEq(token.balanceOf(address(game)), 0);
        assertEq(token.balanceOf(address(this)), 1_000_000_000 ether);
    }

    function test_constructorRejectsZeroAndNonContractToken() public {
        vm.expectRevert(Game.InvalidToken.selector);
        new Game(address(0));
        vm.expectRevert(Game.InvalidToken.selector);
        new Game(ALICE);
    }

    function test_createRoundAndViews() public {
        vm.expectEmit(true, false, false, true, address(game));
        emit RoundCreated(1, STAKE, block.timestamp + 1 hours, block.timestamp + 2 hours);
        uint256 id = game.createRound(STAKE);
        Game.Round memory r = game.round(id);
        assertEq(id, 1);
        assertEq(game.roundCount(), 1);
        assertEq(r.stake, STAKE);
        assertEq(r.joinDeadline, block.timestamp + 1 hours);
        assertEq(r.revealDeadline, block.timestamp + 2 hours);
        assertEq(r.playerCount, 0);
        assertFalse(r.settled);
        assertEq(uint256(game.phase(id)), uint256(Game.Phase.Join));
        assertFalse(game.player(id, ALICE).joined);
    }

    function test_invalidStakeAndRound() public {
        vm.expectRevert(Game.InvalidStake.selector);
        game.createRound(STAKE - 1);
        vm.expectRevert(Game.InvalidStake.selector);
        game.createRound(type(uint256).max);
        vm.expectRevert(Game.InvalidRound.selector);
        game.round(0);
        vm.expectRevert(Game.InvalidRound.selector);
        game.phase(1);
        vm.expectRevert(Game.InvalidRound.selector);
        game.player(1, ALICE);
        vm.expectRevert(Game.InvalidRound.selector);
        game.join(1, bytes32(0));
        vm.expectRevert(Game.InvalidRound.selector);
        game.reveal(1, true, bytes32(0));
        vm.expectRevert(Game.InvalidRound.selector);
        game.reclaim(1);
        vm.expectRevert(Game.InvalidRound.selector);
        game.settle(1);
    }

    function test_joinPullsExactStakeAndEmits() public {
        uint256 id = game.createRound(STAKE);
        bytes32 commitment = _commit(id, ALICE, true, 7);
        _fundApprove(ALICE, STAKE);
        vm.expectEmit(true, true, false, true, address(game));
        emit Joined(id, ALICE, commitment);
        vm.prank(ALICE);
        game.join(id, commitment);
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.allowance(ALICE, address(game)), 0);
        assertEq(game.round(id).playerCount, 1);
        assertEq(game.player(id, ALICE).commitment, commitment);
        assertTrue(game.player(id, ALICE).joined);
        _assertAccounting();
    }

    function test_joinWithoutApprovalOrBalanceRollsBack() public {
        uint256 id = game.createRound(STAKE);
        token.transfer(ALICE, STAKE);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(game), 0, STAKE)
        );
        vm.prank(ALICE);
        game.join(id, bytes32(0));
        vm.prank(BOB);
        token.approve(address(game), STAKE);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, BOB, 0, STAKE));
        vm.prank(BOB);
        game.join(id, bytes32(0));
        assertEq(game.round(id).playerCount, 0);
        assertFalse(game.player(id, ALICE).joined);
        assertFalse(game.player(id, BOB).joined);
        _assertAccounting();
    }

    function test_duplicateJoinFails() public {
        uint256 id = _twoPlayers();
        vm.expectRevert(Game.AlreadyJoined.selector);
        vm.prank(ALICE);
        game.join(id, bytes32(0));
        assertEq(game.round(id).playerCount, 2);
        _assertAccounting();
    }

    function test_sixteenPlayerCap() public {
        uint256 id = game.createRound(STAKE);
        for (uint256 i; i < 16; ++i) {
            _join(id, address(uint160(100 + i)), true, i);
        }
        _fundApprove(CAROL, STAKE);
        vm.expectRevert(Game.RoundFull.selector);
        vm.prank(CAROL);
        game.join(id, bytes32(0));
        assertEq(game.round(id).playerCount, 16);
        assertEq(token.balanceOf(CAROL), STAKE);
        _assertAccounting();
    }

    function test_wrongSaltSideAndSenderCannotReveal() public {
        uint256 id = _twoPlayers();
        vm.warp(game.round(id).joinDeadline);
        vm.expectRevert(Game.InvalidReveal.selector);
        _reveal(id, ALICE, true, 3);
        vm.expectRevert(Game.InvalidReveal.selector);
        _reveal(id, ALICE, false, 1);
        vm.expectRevert(Game.InvalidReveal.selector);
        _reveal(id, BOB, true, 1);
        vm.expectRevert(Game.NotJoined.selector);
        _reveal(id, CAROL, true, 1);
        assertEq(game.round(id).revealCount, 0);
    }

    function test_copiedCommitmentCannotRevealFromAnotherAddress() public {
        uint256 id = game.createRound(STAKE);
        _join(id, ALICE, true, 7);
        _fundApprove(BOB, STAKE);
        vm.prank(BOB);
        game.join(id, _commit(id, ALICE, true, 7));
        vm.warp(game.round(id).joinDeadline);
        vm.expectRevert(Game.InvalidReveal.selector);
        _reveal(id, BOB, true, 7);
        _reveal(id, ALICE, true, 7);
    }

    function test_commitmentCannotReplayAcrossRounds() public {
        uint256 first = game.createRound(STAKE);
        uint256 second = game.createRound(STAKE);
        _join(first, ALICE, true, 7);
        _fundApprove(ALICE, STAKE);
        vm.prank(ALICE);
        game.join(second, _commit(first, ALICE, true, 7));
        _join(second, BOB, false, 0);
        vm.warp(game.round(second).joinDeadline);
        vm.expectRevert(Game.InvalidReveal.selector);
        _reveal(second, ALICE, true, 7);
    }

    function test_exactWindowBoundariesAndPhases() public {
        uint256 id = _twoPlayers();
        Game.Round memory r = game.round(id);
        vm.warp(r.joinDeadline - 1);
        vm.expectRevert(Game.RevealClosed.selector);
        _reveal(id, ALICE, true, 1);
        vm.warp(r.joinDeadline);
        assertEq(uint256(game.phase(id)), uint256(Game.Phase.Reveal));
        vm.expectRevert(Game.JoinClosed.selector);
        vm.prank(CAROL);
        game.join(id, bytes32(0));
        vm.expectEmit(true, true, false, true, address(game));
        emit Revealed(id, ALICE, true, bytes32(uint256(1)));
        _reveal(id, ALICE, true, 1);
        vm.warp(r.revealDeadline - 1);
        _reveal(id, BOB, false, 2);
        vm.expectRevert(Game.SettlementTooEarly.selector);
        game.settle(id);
        vm.warp(r.revealDeadline);
        vm.expectRevert(Game.RevealClosed.selector);
        _reveal(id, ALICE, true, 1);
        assertEq(uint256(game.phase(id)), uint256(Game.Phase.AwaitingSettlement));
        game.settle(id);
        assertEq(uint256(game.phase(id)), uint256(Game.Phase.Settled));
        vm.expectRevert(Game.JoinClosed.selector);
        game.join(id, bytes32(0));
    }

    function test_joinImmediatelyBeforeDeadline() public {
        uint256 id = game.createRound(STAKE);
        vm.warp(game.round(id).joinDeadline - 1);
        _join(id, ALICE, true, 1);
        assertEq(game.round(id).playerCount, 1);
    }

    function test_duplicateRevealFailsWithoutChangingXor() public {
        uint256 id = _twoPlayers();
        vm.warp(game.round(id).joinDeadline);
        _reveal(id, ALICE, true, 1);
        vm.expectRevert(Game.AlreadyRevealed.selector);
        _reveal(id, ALICE, true, 1);
        assertEq(game.round(id).saltXor, bytes32(uint256(1)));
        assertEq(game.round(id).revealCount, 1);
    }

    function test_singlePlayerReclaimsToCreditAtJoinDeadline() public {
        uint256 id = game.createRound(STAKE);
        _join(id, ALICE, true, 1);
        vm.expectRevert(Game.NotReclaimable.selector);
        vm.prank(ALICE);
        game.reclaim(id);
        vm.warp(game.round(id).joinDeadline);
        assertEq(uint256(game.phase(id)), uint256(Game.Phase.Reclaimable));
        vm.expectRevert(Game.TooFewPlayers.selector);
        _reveal(id, ALICE, true, 1);
        vm.expectRevert(Game.NotJoined.selector);
        vm.prank(BOB);
        game.reclaim(id);
        vm.expectEmit(true, true, false, true, address(game));
        emit Reclaimed(id, ALICE, STAKE);
        vm.prank(ALICE);
        game.reclaim(id);
        assertTrue(game.player(id, ALICE).reclaimed);
        assertTrue(game.round(id).settled);
        assertEq(game.withdrawable(ALICE), STAKE);
        assertEq(token.balanceOf(ALICE), 0);
        _assertAccounting();
        vm.expectRevert(Game.AlreadySettled.selector);
        vm.prank(ALICE);
        game.reclaim(id);
        vm.warp(game.round(id).revealDeadline);
        vm.expectRevert(Game.AlreadySettled.selector);
        game.settle(id);
        vm.prank(ALICE);
        game.withdraw();
        assertEq(token.balanceOf(ALICE), STAKE);
        _assertAccounting();
    }

    function test_singlePlayerCanInsteadBeRefundedBySettlement() public {
        uint256 id = game.createRound(STAKE);
        _join(id, ALICE, true, 1);
        vm.warp(game.round(id).revealDeadline);
        game.settle(id);
        assertEq(game.withdrawable(ALICE), STAKE);
        vm.expectRevert(Game.AlreadySettled.selector);
        vm.prank(ALICE);
        game.reclaim(id);
        _assertAccounting();
    }

    function test_cannotReclaimCompetitiveRound() public {
        uint256 id = _twoPlayers();
        vm.warp(game.round(id).joinDeadline);
        vm.expectRevert(Game.NotReclaimable.selector);
        vm.prank(ALICE);
        game.reclaim(id);
    }

    function test_emptyRoundSettlesWithoutDivisionByZero() public {
        uint256 id = game.createRound(STAKE);
        vm.warp(game.round(id).revealDeadline);
        game.settle(id);
        assertTrue(game.round(id).settled);
        assertEq(game.round(id).share, 0);
        _assertAccounting();
    }

    function test_allWithholdRefundsAndDoubleSettleFails() public {
        uint256 id = _twoPlayers();
        vm.warp(game.round(id).revealDeadline);
        vm.expectEmit(true, false, false, true, address(game));
        emit Settled(id, false, 0, STAKE);
        game.settle(id);
        assertEq(game.withdrawable(ALICE), STAKE);
        assertEq(game.withdrawable(BOB), STAKE);
        vm.expectRevert(Game.AlreadySettled.selector);
        game.settle(id);
        _assertAccounting();
    }

    function test_winnerReceivesFullPotThroughWithdrawOnly() public {
        uint256 id = _twoPlayers();
        vm.warp(game.round(id).joinDeadline);
        _reveal(id, ALICE, true, 1);
        _reveal(id, BOB, false, 2);
        vm.warp(game.round(id).revealDeadline);
        vm.expectEmit(true, false, false, true, address(game));
        emit Settled(id, true, 1, 2 * STAKE);
        vm.prank(CAROL);
        game.settle(id);
        assertEq(game.withdrawable(ALICE), 2 * STAKE);
        assertEq(game.withdrawable(BOB), 0);
        assertEq(token.balanceOf(ALICE), 0);
        _assertAccounting();
        vm.expectEmit(true, false, false, true, address(game));
        emit Withdrawn(ALICE, 2 * STAKE);
        vm.prank(ALICE);
        game.withdraw();
        assertEq(token.balanceOf(ALICE), 2 * STAKE);
        assertEq(game.withdrawable(ALICE), 0);
        vm.expectRevert(Game.NothingToWithdraw.selector);
        vm.prank(ALICE);
        game.withdraw();
        vm.expectRevert(Game.NothingToWithdraw.selector);
        vm.prank(BOB);
        game.withdraw();
        _assertAccounting();
    }

    function test_noWinnerSplitsAmongRevealersAndForfeitsNonrevealer() public {
        uint256 id = game.createRound(STAKE);
        _join(id, ALICE, true, 2);
        _join(id, BOB, true, 4);
        _join(id, CAROL, false, 1);
        vm.warp(game.round(id).joinDeadline);
        _reveal(id, ALICE, true, 2);
        _reveal(id, BOB, true, 4);
        vm.warp(game.round(id).revealDeadline);
        game.settle(id);
        assertFalse(game.round(id).heads);
        assertEq(game.round(id).winners, 0);
        assertEq(game.withdrawable(ALICE), 3 * STAKE / 2);
        assertEq(game.withdrawable(BOB), 3 * STAKE / 2);
        assertEq(game.withdrawable(CAROL), 0);
        _assertAccounting();
    }

    function test_winnerRemainderIsTransferredToDeadAddress() public {
        _checkRemainder(false);
    }

    function test_fallbackSplitRemainderIsTransferredToDeadAddress() public {
        _checkRemainder(true);
    }

    function _checkRemainder(bool fallbackSplit) internal {
        uint256 id = game.createRound(STAKE + 1);
        _join(id, ALICE, fallbackSplit, 2);
        _join(id, BOB, fallbackSplit, 4);
        _join(id, CAROL, true, 1);
        vm.warp(game.round(id).joinDeadline);
        _reveal(id, ALICE, fallbackSplit, 2);
        _reveal(id, BOB, fallbackSplit, 4);
        vm.warp(game.round(id).revealDeadline);
        game.settle(id);
        uint256 share = 3 * (STAKE + 1) / 2;
        assertEq(game.withdrawable(ALICE), share);
        assertEq(game.withdrawable(BOB), share);
        assertEq(game.withdrawable(CAROL), 0);
        assertEq(game.round(id).winners, fallbackSplit ? 0 : 2);
        assertEq(token.balanceOf(game.BURN_ADDRESS()), 1);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        _assertAccounting();
    }

    function test_creditsAccumulateAcrossIndependentRounds() public {
        uint256 first = _twoPlayers();
        uint256 second = _twoPlayers();
        vm.warp(game.round(first).joinDeadline);
        _reveal(first, ALICE, true, 1);
        vm.warp(game.round(first).revealDeadline);
        game.settle(first);
        assertEq(game.totalStaked(), 2 * STAKE);
        _assertAccounting();
        game.settle(second);
        assertEq(game.withdrawable(ALICE), 3 * STAKE);
        assertEq(game.withdrawable(BOB), STAKE);
        vm.prank(ALICE);
        game.withdraw();
        assertEq(token.balanceOf(ALICE), 3 * STAKE);
        assertEq(game.totalWithdrawable(), STAKE);
        _assertAccounting();
    }

    function test_ethAndUnknownCallsRejected() public {
        vm.deal(address(this), 1 ether);
        (bool sent,) = address(game).call{value: 1}("");
        assertFalse(sent);
        (bool paidCall,) = address(game).call{value: 1}(abi.encodeCall(game.createRound, (STAKE)));
        assertFalse(paidCall);
        (bool unknown,) = address(game).call(hex"deadbeef");
        assertFalse(unknown);
        assertEq(address(game).balance, 0);
    }

    function test_directDonationStaysSurplusAndDoesNotChangePot() public {
        uint256 id = _twoPlayers();
        token.transfer(address(game), 7 ether);
        vm.warp(game.round(id).revealDeadline);
        game.settle(id);
        assertEq(game.totalWithdrawable(), 2 * STAKE);
        assertEq(token.balanceOf(address(game)), game.totalWithdrawable() + 7 ether);
    }

    function testFuzz_settlementMatchesIndependentModel(
        uint8 countSeed,
        uint16 revealMask,
        uint16 sideMask,
        uint256 saltSeed,
        uint96 stakeSeed
    ) public {
        uint256 count = bound(countSeed, 2, 16);
        uint256 stake = bound(stakeSeed, STAKE, 1_000 ether);
        uint256 id = game.createRound(stake);
        uint256[16] memory salts;
        bool coin;
        uint256 revealed;
        for (uint256 i; i < count; ++i) {
            salts[i] = uint256(keccak256(abi.encode(saltSeed, i)));
            _join(id, address(uint160(100 + i)), (sideMask & (1 << i)) != 0, salts[i]);
            if ((revealMask & (1 << i)) != 0) {
                ++revealed;
                if (salts[i] % 2 == 1) coin = !coin;
            }
        }
        vm.warp(game.round(id).joinDeadline);
        uint256 winners;
        for (uint256 i; i < count; ++i) {
            if ((revealMask & (1 << i)) != 0) {
                bool side = (sideMask & (1 << i)) != 0;
                _reveal(id, address(uint160(100 + i)), side, salts[i]);
                if (side == coin) ++winners;
            }
        }
        vm.warp(game.round(id).revealDeadline);
        game.settle(id);
        uint256 recipients = revealed == 0 ? count : (winners == 0 ? revealed : winners);
        uint256 share = count * stake / recipients;
        for (uint256 i; i < count; ++i) {
            bool eligible = revealed == 0
                || ((revealMask & (1 << i)) != 0 && (winners == 0 || ((sideMask & (1 << i)) != 0) == coin));
            address account = address(uint160(100 + i));
            assertEq(game.withdrawable(account), eligible ? share : 0);
            if (eligible) {
                vm.prank(account);
                game.withdraw();
                assertEq(token.balanceOf(account), share);
            }
            _assertAccounting();
        }
        assertEq(game.round(id).heads, coin);
        assertEq(game.round(id).winners, winners);
        assertEq(token.balanceOf(game.BURN_ADDRESS()), count * stake - recipients * share);
        assertEq(token.balanceOf(address(game)), 0);
    }
}
