// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {DepthBondVault} from "../src/core/DepthBondVault.sol";
import {EpochController, IDepthBondVault} from "../src/core/EpochController.sol";

interface Vm {
    function deal(address account, uint256 newBalance) external;
    function prank(address caller) external;
}

contract DepthBondFuzzTest {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    address private constant LP = address(0x1A);

    function testFuzz_EarlyExitConservesBond(uint96 rawBond, uint96 rawLiquidity) public {
        uint256 bond = uint256(rawBond) % 100 ether + 1 ether;
        uint128 liquidity = uint128(uint256(rawLiquidity) % type(uint64).max + 1);
        vm.deal(LP, bond);

        DepthBondVault vault = new DepthBondVault(1 ether);
        EpochController controller =
            new EpochController(IDepthBondVault(address(vault)), address(0xCA11BAC), address(0xA11CE), 10, 0);
        vault.setController(address(controller));

        vm.prank(LP);
        uint256 commitmentId = vault.depositAndCommit{value: bond}(1, liquidity, 2);
        controller.beginEpoch();
        vm.prank(LP);
        vault.exit(commitmentId);

        uint256 penalty = bond * vault.EARLY_EXIT_PENALTY_BPS() / 10_000;
        require(vault.rewardReserve() == penalty, "penalty reserve mismatch");
        require(vault.refundableBonds(LP) + vault.rewardReserve() == bond, "bond conservation failed");
    }
}
