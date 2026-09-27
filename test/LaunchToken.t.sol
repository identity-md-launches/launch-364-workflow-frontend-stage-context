// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract LaunchTokenTest is Test {
    LaunchToken private token;
    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);
    uint256 private constant SUPPLY = 1_000_000_000 ether;

    function setUp() public {
        token = new LaunchToken();
    }

    function test_metadataAndFixedSupply() public view {
        assertEq(token.name(), "Heads");
        assertEq(token.symbol(), "HEDS");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    function testFuzz_transferConservesSupply(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        assertTrue(token.transfer(ALICE, amount));
        assertEq(token.balanceOf(ALICE), amount);
        assertEq(token.balanceOf(address(this)), SUPPLY - amount);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_approvalAndTransferFrom() public {
        token.transfer(ALICE, 10 ether);
        vm.prank(ALICE);
        token.approve(BOB, 7 ether);
        vm.prank(BOB);
        assertTrue(token.transferFrom(ALICE, BOB, 6 ether));
        assertEq(token.allowance(ALICE, BOB), 1 ether);
        assertEq(token.balanceOf(ALICE), 4 ether);
        assertEq(token.balanceOf(BOB), 6 ether);
    }

    function test_infiniteApprovalIsNotConsumed() public {
        token.approve(BOB, type(uint256).max);
        vm.prank(BOB);
        token.transferFrom(address(this), ALICE, 1 ether);
        assertEq(token.allowance(address(this), BOB), type(uint256).max);
    }

    function test_insufficientApprovalFails() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, BOB, 0, 1));
        vm.prank(BOB);
        token.transferFrom(address(this), BOB, 1);
    }

    function test_insufficientBalanceFails() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 0, 1));
        vm.prank(ALICE);
        token.transfer(BOB, 1);
    }

    function test_zeroRecipientFails() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
    }

    function test_noMintAdminOrUpgradeSelectors() public {
        string[11] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "pause()",
            "unpause()",
            "setMinter(address)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            bytes memory data = abi.encodeWithSignature(signatures[i], ALICE, uint256(1));
            (bool deployerOk,) = address(token).call(data);
            assertFalse(deployerOk);
            vm.prank(ALICE);
            (bool attackerOk,) = address(token).call(data);
            assertFalse(attackerOk);
        }
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(ALICE), 0);
    }
}
