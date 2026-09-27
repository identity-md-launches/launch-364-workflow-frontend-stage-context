// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {CommitRevealCoinFlip as Game} from "../src/CommitRevealCoinFlip.sol";

contract AccountingHandler is Test {
    LaunchToken public immutable token;
    Game public immutable game;
    uint256 public paidIn;
    uint256 public paidOut;
    uint256 public constant ACTORS = 12;

    constructor(LaunchToken token_, Game game_) {
        token = token_;
        game = game_;
    }

    function actor(uint256 index) public pure returns (address) {
        return address(uint160(100 + index));
    }

    function _salt(uint256 id, address account) private pure returns (bytes32) {
        return keccak256(abi.encode(id, account));
    }

    function create(uint96 stakeSeed) external {
        if (game.roundCount() >= 8) return;
        game.createRound(bound(stakeSeed, 1 ether, 100 ether));
    }

    function join(uint256 roundSeed, uint256 actorSeed) external {
        uint256 count = game.roundCount();
        if (count == 0) return;
        uint256 id = bound(roundSeed, 1, count);
        uint256 index = actorSeed % ACTORS;
        address account = actor(index);
        Game.Round memory r = game.round(id);
        if (r.settled || block.timestamp >= r.joinDeadline || game.player(id, account).joined) return;
        if (token.balanceOf(account) < r.stake) return;
        vm.prank(account);
        game.join(id, keccak256(abi.encode(index % 2 == 0, _salt(id, account), account, id)));
        paidIn += r.stake;
    }

    function advance(uint16 secondsSeed) external {
        vm.warp(block.timestamp + bound(secondsSeed, 1, 30 minutes));
    }

    function reveal(uint256 roundSeed, uint256 actorSeed) external {
        uint256 count = game.roundCount();
        if (count == 0) return;
        uint256 id = bound(roundSeed, 1, count);
        uint256 index = actorSeed % ACTORS;
        address account = actor(index);
        if (game.phase(id) != Game.Phase.Reveal) return;
        Game.Player memory p = game.player(id, account);
        if (!p.joined || p.revealed) return;
        vm.prank(account);
        game.reveal(id, index % 2 == 0, _salt(id, account));
    }

    function reclaim(uint256 roundSeed, uint256 actorSeed) external {
        uint256 count = game.roundCount();
        if (count == 0) return;
        uint256 id = bound(roundSeed, 1, count);
        address account = actor(actorSeed % ACTORS);
        if (game.phase(id) != Game.Phase.Reclaimable || !game.player(id, account).joined) return;
        vm.prank(account);
        game.reclaim(id);
    }

    function settle(uint256 roundSeed) external {
        uint256 count = game.roundCount();
        if (count == 0) return;
        uint256 id = bound(roundSeed, 1, count);
        Game.Round memory r = game.round(id);
        if (r.settled || block.timestamp < r.revealDeadline) return;
        game.settle(id);
    }

    function withdraw(uint256 actorSeed) external {
        address account = actor(actorSeed % ACTORS);
        uint256 credit = game.withdrawable(account);
        if (credit == 0) return;
        vm.prank(account);
        game.withdraw();
        paidOut += credit;
    }
}

contract AccountingInvariantTest is Test {
    LaunchToken private token;
    Game private game;
    AccountingHandler private handler;

    function setUp() public {
        token = new LaunchToken();
        game = new Game(address(token));
        handler = new AccountingHandler(token, game);
        for (uint256 i; i < handler.ACTORS(); ++i) {
            address account = handler.actor(i);
            token.transfer(account, 10_000 ether);
            vm.prank(account);
            token.approve(address(game), type(uint256).max);
        }
        handler.create(1 ether);
        handler.create(2 ether + 1);
        // Start with multiple active rounds so even short sequences exercise custody.
        handler.join(1, 0);
        handler.join(1, 1);
        handler.join(2, 2);

        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = handler.create.selector;
        selectors[1] = handler.join.selector;
        selectors[2] = handler.advance.selector;
        selectors[3] = handler.reveal.selector;
        selectors[4] = handler.reclaim.selector;
        selectors[5] = handler.settle.selector;
        selectors[6] = handler.withdraw.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_heldTokensEqualUnsettledStakesPlusCredits() public view {
        uint256 stakes;
        for (uint256 id = 1; id <= game.roundCount(); ++id) {
            Game.Round memory r = game.round(id);
            if (!r.settled) stakes += r.playerCount * r.stake;
        }
        uint256 credits;
        for (uint256 i; i < handler.ACTORS(); ++i) {
            credits += game.withdrawable(handler.actor(i));
        }
        assertEq(game.totalStaked(), stakes);
        assertEq(game.totalWithdrawable(), credits);
        assertEq(token.balanceOf(address(game)), stakes + credits);
        assertEq(
            token.balanceOf(address(game)) + handler.paidOut() + token.balanceOf(game.BURN_ADDRESS()), handler.paidIn()
        );
        assertEq(token.totalSupply(), 1_000_000_000 ether);
    }

    function afterInvariant() public {
        // Every generated history must have a permissionless path to empty custody.
        vm.warp(block.timestamp + 2 hours);
        for (uint256 id = 1; id <= game.roundCount(); ++id) {
            handler.settle(id);
        }
        for (uint256 i; i < handler.ACTORS(); ++i) {
            handler.withdraw(i);
        }
        assertEq(game.totalStaked(), 0);
        assertEq(game.totalWithdrawable(), 0);
        assertEq(token.balanceOf(address(game)), 0);
        assertEq(handler.paidOut() + token.balanceOf(game.BURN_ADDRESS()), handler.paidIn());
    }
}
