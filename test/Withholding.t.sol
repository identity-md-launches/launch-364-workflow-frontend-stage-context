// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {CommitRevealCoinFlip as Game} from "../src/CommitRevealCoinFlip.sol";

/// @dev Executable risk examples, not an independent security review or fairness claim.
contract WithholdingTest is Test {
    LaunchToken private token;
    Game private game;
    uint256 private constant STAKE = 1 ether;

    function setUp() public {
        token = new LaunchToken();
        game = new Game(address(token));
    }

    function _scenario(uint256 count, bool withhold) private returns (uint256 allyPayout, uint256 lastPayout) {
        uint256 id = game.createRound(STAKE);
        for (uint256 i; i < count; ++i) {
            address account = address(uint160(100 + i));
            bool side = count == 2 ? i == 1 : (i != 0 && i != count - 1);
            bytes32 salt = bytes32(i == count - 1 ? uint256(1) : 0);
            token.transfer(account, STAKE);
            vm.startPrank(account);
            token.approve(address(game), STAKE);
            game.join(id, keccak256(abi.encode(side, salt, account, id)));
            vm.stopPrank();
        }
        vm.warp(game.round(id).joinDeadline);
        for (uint256 i; i < count; ++i) {
            if (withhold && i == count - 1) continue;
            bool side = count == 2 ? i == 1 : (i != 0 && i != count - 1);
            vm.prank(address(uint160(100 + i)));
            game.reveal(id, side, bytes32(i == count - 1 ? uint256(1) : 0));
        }
        uint256 beforeAlly = game.withdrawable(address(100));
        uint256 beforeLast = game.withdrawable(address(uint160(100 + count - 1)));
        vm.warp(game.round(id).revealDeadline);
        game.settle(id);
        allyPayout = game.withdrawable(address(100)) - beforeAlly;
        lastPayout = game.withdrawable(address(uint160(100 + count - 1))) - beforeLast;
    }

    function test_twoPlayersWithholderLosesEntireStakeAndPotentialWin() public {
        (uint256 revealOther, uint256 revealLast) = _scenario(2, false);
        (uint256 withholdOther, uint256 withholdLast) = _scenario(2, true);
        assertEq(revealOther, 0);
        assertEq(revealLast, 2 * STAKE);
        assertEq(withholdOther, 2 * STAKE);
        assertEq(withholdLast, 0);
    }

    function test_threePlayersTwoWalletCoalitionCanGainFullPotByWithholding() public {
        _coalitionExample(3);
    }

    function test_sixteenPlayersTwoWalletCoalitionCanGainFullPotByWithholding() public {
        _coalitionExample(16);
    }

    function _coalitionExample(uint256 count) private {
        (uint256 revealAlly, uint256 revealLast) = _scenario(count, false);
        (uint256 withholdAlly, uint256 withholdLast) = _scenario(count, true);
        assertEq(revealAlly + revealLast, 0);
        assertEq(withholdLast, 0);
        assertEq(withholdAlly, count * STAKE);
        // Coalition net profit after both of its stakes: 1 HEDS for 3, 14 HEDS for 16.
        assertEq(withholdAlly - 2 * STAKE, (count - 2) * STAKE);
    }
}
