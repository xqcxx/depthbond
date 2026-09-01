// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {DepthBondVault} from "../src/core/DepthBondVault.sol";
import {EpochController, IDepthBondVault} from "../src/core/EpochController.sol";

interface Vm {
    function deal(address account, uint256 newBalance) external;
    function prank(address caller) external;
    function roll(uint256 newHeight) external;
}

contract DepthBondLifecycleTest {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    address private constant ADA = address(0xA11CE);
    address private constant BAO = address(0xBA0);
    address private constant JIT = address(0xB07);
    address private constant CALLBACK_PROXY = address(0xCA11BAC);
    address private constant RVM_ID = address(0xA11CE123);

    DepthBondVault private vault;
    EpochController private controller;

    receive() external payable {}

    function setUp() public {
        vault = new DepthBondVault(1 ether);
        controller = new EpochController(IDepthBondVault(address(vault)), CALLBACK_PROXY, RVM_ID, 10, 5 ether);
        vault.setController(address(controller));
        vault.fundRewards{value: 5 ether}();
        vm.deal(ADA, 10 ether);
        vm.deal(BAO, 10 ether);
        vm.deal(JIT, 10 ether);
    }

    function test_DurableLiquidityEarnsWhileLateAndInactiveLiquidityDoNot() public {
        vm.prank(ADA);
        uint256 adaCommitment = vault.depositAndCommit{value: 4 ether}(1, 50, 2);
        vm.prank(BAO);
        uint256 baoCommitment = vault.depositAndCommit{value: 4 ether}(0, 50, 2);

        controller.beginEpoch();

        vm.prank(JIT);
        uint256 jitCommitment = vault.depositAndCommit{value: 4 ether}(1, 20, 2);
        vm.prank(JIT);
        vault.exit(jitCommitment);
        _assertEq(vault.rewardReserve(), 6 ether, "early-exit penalty was not reserved");

        controller.recordQualifyingSwap(1, 1, 1_000);
        (uint64 endBlock,,) = controller.getEpoch(1);
        vm.roll(uint256(endBlock) + 1);
        controller.requestEpochClose(1);
        vm.prank(CALLBACK_PROXY);
        controller.settleEpoch(RVM_ID, 1, 42);

        vm.prank(ADA);
        _assertEq(vault.claim(adaCommitment, 1), 5 ether, "durable LP reward is wrong");
        vm.prank(BAO);
        _assertEq(vault.claim(baoCommitment, 1), 0, "inactive range should receive no reward");

        vm.prank(JIT);
        (bool success,) = address(vault).call(abi.encodeCall(vault.claim, (jitCommitment, 1)));
        _assertFalse(success, "late LP claimed an epoch reward");
    }

    function test_RevertsUnauthorizedOrReplayedSettlementCallbacks() public {
        vm.prank(ADA);
        vault.depositAndCommit{value: 2 ether}(1, 60, 2);
        controller.beginEpoch();
        controller.recordQualifyingSwap(1, 1, 100);
        (uint64 endBlock,,) = controller.getEpoch(1);
        vm.roll(uint256(endBlock) + 1);
        controller.requestEpochClose(1);

        (bool directSuccess,) = address(controller).call(abi.encodeCall(controller.settleEpoch, (RVM_ID, 1, 7)));
        _assertFalse(directSuccess, "direct callback settlement succeeded");

        vm.prank(CALLBACK_PROXY);
        controller.settleEpoch(RVM_ID, 1, 7);

        vm.prank(CALLBACK_PROXY);
        (bool replaySuccess,) = address(controller).call(abi.encodeCall(controller.settleEpoch, (RVM_ID, 1, 7)));
        _assertFalse(replaySuccess, "callback nonce replay succeeded");
    }

    function _assertEq(uint256 actual, uint256 expected, string memory reason) private pure {
        require(actual == expected, reason);
    }

    function _assertFalse(bool value, string memory reason) private pure {
        require(!value, reason);
    }
}
