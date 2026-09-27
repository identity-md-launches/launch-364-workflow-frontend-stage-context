// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {CommitRevealCoinFlip as Game} from "../src/CommitRevealCoinFlip.sol";

interface ITokenCallback {
    function onTokenTransfer() external;
}

/// @dev Adversarial test asset only. Production must use LaunchToken.
contract AdversarialToken is ERC20 {
    bool public failPull;
    bool public shortPull;
    bool public noReturn;
    address public blockedRecipient;
    address public callbackRecipient;

    constructor() ERC20("Test", "TEST") {
        _mint(msg.sender, 1_000_000 ether);
    }

    function configurePull(bool fail, bool short, bool emptyReturn) external {
        failPull = fail;
        shortPull = short;
        noReturn = emptyReturn;
    }

    function setBlockedRecipient(address recipient) external {
        blockedRecipient = recipient;
    }

    function setCallbackRecipient(address recipient) external {
        callbackRecipient = recipient;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        // Deliberately mutate before returning false: SafeERC20 must roll it all back.
        super.transferFrom(from, to, shortPull ? amount - 1 : amount);
        if (failPull) return false;
        if (noReturn) {
            assembly ("memory-safe") {
                return(0, 0)
            }
        }
        return true;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (to == blockedRecipient) return false;
        super.transfer(to, amount);
        if (to == callbackRecipient) ITokenCallback(to).onTokenTransfer();
        if (noReturn) {
            assembly ("memory-safe") {
                return(0, 0)
            }
        }
        return true;
    }
}

contract ReenteringPlayer is ITokenCallback {
    Game public immutable game;
    AdversarialToken public immutable token;
    bool public nestedSucceeded;
    bytes public nestedError;
    uint256 public creditDuringCallback;

    constructor(Game game_, AdversarialToken token_) {
        game = game_;
        token = token_;
    }

    function enter(uint256 id) external {
        token.approve(address(game), game.round(id).stake);
        game.join(id, bytes32(0));
    }

    function collect() external {
        game.withdraw();
    }

    function onTokenTransfer() external {
        require(msg.sender == address(token));
        creditDuringCallback = game.withdrawable(address(this));
        (nestedSucceeded, nestedError) = address(game).call(abi.encodeCall(game.withdraw, ()));
    }
}

contract TokenFailuresTest is Test {
    AdversarialToken private token;
    Game private game;
    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);
    address private constant CAROL = address(0xCA401);

    function setUp() public {
        token = new AdversarialToken();
        game = new Game(address(token));
    }

    function _join(uint256 id, address account, bool heads, uint256 salt) private {
        uint256 stake = game.round(id).stake;
        token.transfer(account, stake);
        vm.startPrank(account);
        token.approve(address(game), stake);
        game.join(id, keccak256(abi.encode(heads, bytes32(salt), account, id)));
        vm.stopPrank();
    }

    function _preparePull() private returns (uint256 id) {
        id = game.createRound(1 ether);
        token.transfer(ALICE, 1 ether);
        vm.prank(ALICE);
        token.approve(address(game), 1 ether);
    }

    function _assertPullRollback(uint256 id) private view {
        assertEq(token.balanceOf(ALICE), 1 ether);
        assertEq(token.allowance(ALICE, address(game)), 1 ether);
        assertEq(token.balanceOf(address(game)), 0);
        assertFalse(game.player(id, ALICE).joined);
        assertEq(game.round(id).playerCount, 0);
        assertEq(game.totalStaked(), 0);
    }

    function test_falseTransferFromRollsBackAllEffects() public {
        uint256 id = _preparePull();
        token.configurePull(true, false, false);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token)));
        vm.prank(ALICE);
        game.join(id, bytes32(0));
        _assertPullRollback(id);
    }

    function test_shortTransferFromRejectedWithoutLiabilities() public {
        uint256 id = _preparePull();
        token.configurePull(false, true, false);
        vm.expectRevert(Game.UnexpectedTransferAmount.selector);
        vm.prank(ALICE);
        game.join(id, bytes32(0));
        _assertPullRollback(id);
    }

    function test_noReturnTokenSupportedBySafeERC20() public {
        uint256 id = _preparePull();
        token.configurePull(false, false, true);
        vm.prank(ALICE);
        game.join(id, bytes32(0));
        vm.warp(game.round(id).joinDeadline);
        vm.startPrank(ALICE);
        game.reclaim(id);
        game.withdraw();
        vm.stopPrank();
        assertEq(token.balanceOf(ALICE), 1 ether);
        assertEq(game.totalStaked(), 0);
        assertEq(game.totalWithdrawable(), 0);
    }

    function test_failedWithdrawalPreservesCreditAndDoesNotBlockOthers() public {
        uint256 id = game.createRound(1 ether);
        _join(id, ALICE, true, 1);
        _join(id, BOB, false, 2);
        vm.warp(game.round(id).revealDeadline);
        game.settle(id);
        token.setBlockedRecipient(ALICE);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token)));
        vm.prank(ALICE);
        game.withdraw();
        assertEq(game.withdrawable(ALICE), 1 ether);
        assertEq(game.totalWithdrawable(), 2 ether);
        vm.prank(BOB);
        game.withdraw();
        assertEq(token.balanceOf(BOB), 1 ether);
        token.setBlockedRecipient(address(0));
        vm.prank(ALICE);
        game.withdraw();
        assertEq(token.balanceOf(ALICE), 1 ether);
        assertEq(game.totalWithdrawable(), 0);
    }

    function test_failedRemainderBurnRollsBackSettlementAndCanRetry() public {
        uint256 stake = 1 ether + 1;
        uint256 id = game.createRound(stake);
        _join(id, ALICE, false, 2);
        _join(id, BOB, false, 4);
        _join(id, CAROL, true, 1);
        vm.warp(game.round(id).joinDeadline);
        vm.prank(ALICE);
        game.reveal(id, false, bytes32(uint256(2)));
        vm.prank(BOB);
        game.reveal(id, false, bytes32(uint256(4)));
        vm.warp(game.round(id).revealDeadline);
        token.setBlockedRecipient(game.BURN_ADDRESS());
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token)));
        game.settle(id);
        assertFalse(game.round(id).settled);
        assertEq(game.withdrawable(ALICE), 0);
        assertEq(game.withdrawable(BOB), 0);
        assertEq(game.totalWithdrawable(), 0);
        assertEq(game.totalStaked(), 3 * stake);
        assertEq(token.balanceOf(address(game)), 3 * stake);
        token.setBlockedRecipient(address(0));
        game.settle(id);
        assertTrue(game.round(id).settled);
        assertEq(token.balanceOf(game.BURN_ADDRESS()), 1);
        assertEq(game.totalStaked(), 0);
        assertEq(token.balanceOf(address(game)), game.totalWithdrawable());
    }

    function test_reentrantWithdrawalCannotCollectTwiceAndSeesZeroCredit() public {
        ReenteringPlayer attacker = new ReenteringPlayer(game, token);
        uint256 id = game.createRound(1 ether);
        token.transfer(address(attacker), 1 ether);
        attacker.enter(id);
        _join(id, ALICE, false, 0);
        vm.warp(game.round(id).revealDeadline);
        game.settle(id);
        token.setCallbackRecipient(address(attacker));
        attacker.collect();
        assertFalse(attacker.nestedSucceeded());
        assertEq(attacker.nestedError(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
        assertEq(attacker.creditDuringCallback(), 0);
        assertEq(game.withdrawable(address(attacker)), 0);
        assertEq(token.balanceOf(address(attacker)), 1 ether);
        assertEq(game.withdrawable(ALICE), 1 ether);
        assertEq(token.balanceOf(address(game)), 1 ether);
        vm.prank(ALICE);
        game.withdraw();
        assertEq(token.balanceOf(address(game)), 0);
    }
}
