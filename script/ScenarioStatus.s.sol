// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {DepthBondVault} from "../src/core/DepthBondVault.sol";
import {EpochController} from "../src/core/EpochController.sol";

/// @notice Reads the current epoch and reward state without submitting transactions.
contract ScenarioStatusScript is Script {
    function run() external view {
        uint64 epochId = uint64(vm.envOr("EPOCH_ID", uint256(1)));
        EpochController controller = EpochController(vm.envAddress("EPOCH_CONTROLLER"));
        DepthBondVault vault = DepthBondVault(vm.envAddress("VAULT"));
        (uint64 endBlock, EpochController.Phase phase, uint256[3] memory volume) = controller.getEpoch(epochId);

        console2.log("epoch", epochId);
        console2.log("end block", endBlock);
        console2.log("phase", uint256(phase));
        console2.log("range 0 volume", volume[0]);
        console2.log("range 1 volume", volume[1]);
        console2.log("range 2 volume", volume[2]);
        console2.log("settled", vault.epochSettled(epochId));
        console2.log("reward reserve", vault.rewardReserve());
        console2.log("expected RVM", controller.expectedRvmId());
    }
}
