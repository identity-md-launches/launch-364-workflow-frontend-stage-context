// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {CommitRevealCoinFlip as Game} from "../src/CommitRevealCoinFlip.sol";

/// @dev Local deployment probe, not the protocol's production factory.
contract FactoryProbe {
    function deploy() external returns (LaunchToken token, Game game) {
        token = new LaunchToken{salt: bytes32(uint256(1))}();
        game = new Game{salt: bytes32(uint256(2))}(address(token));
    }
}

contract FactoryCompatibilityTest is Test {
    function test_factoryDeploymentPreservesSupplyAndRuntimeConstraints() public {
        FactoryProbe factory = new FactoryProbe();
        (LaunchToken token, Game game) = factory.deploy();
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(token.balanceOf(address(factory)), token.totalSupply());
        assertEq(address(game.token()), address(token));
        assertEq(token.balanceOf(address(game)), 0);
        _checkRuntime(address(token).code);
        _checkRuntime(address(game).code);
        // No initialization transaction or factory privilege is needed to start a round.
        vm.prank(address(0xBEEF));
        assertEq(game.createRound(1 ether), 1);
    }

    function _checkRuntime(bytes memory runtime) private pure {
        assertGt(runtime.length, 0);
        assertLe(runtime.length, 24_576);
        for (uint256 i; i < runtime.length; ++i) {
            uint8 opcode = uint8(runtime[i]);
            if (opcode >= 0x60 && opcode <= 0x7f) {
                i += opcode - 0x5f;
                continue;
            }
            assertTrue(opcode != 0xf4 && opcode != 0xf2 && opcode != 0xff);
        }
    }
}
