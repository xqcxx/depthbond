// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {DepthBondVault} from "../src/core/DepthBondVault.sol";
import {EpochController} from "../src/core/EpochController.sol";

/// @notice Requests close and claims completed rewards. Reactive settlement must occur between those actions.
contract CloseAndClaimScript is Script {
    function run() external {
        uint64 epochId = uint64(vm.envOr("EPOCH_ID", uint256(1)));
        EpochController controller = EpochController(vm.envAddress("EPOCH_CONTROLLER"));
        DepthBondVault vault = DepthBondVault(vm.envAddress("VAULT"));

        if (vm.envOr("REQUEST_CLOSE", false)) {
            vm.startBroadcast(vm.envUint("CLOSER_PRIVATE_KEY"));
            controller.requestEpochClose(epochId);
            vm.stopBroadcast();
        }
        if (vm.envOr("CLAIM_ADA", false)) {
            _claim(vm.envUint("ADA_PRIVATE_KEY"), vault, vm.envUint("ADA_COMMITMENT"), epochId);
        }
        if (vm.envOr("CLAIM_BAO", false)) {
            _claim(vm.envUint("BAO_PRIVATE_KEY"), vault, vm.envUint("BAO_COMMITMENT"), epochId);
        }
    }

    function _claim(uint256 accountKey, DepthBondVault vault, uint256 commitmentId, uint64 epochId) private {
        vm.startBroadcast(accountKey);
        vault.claim(commitmentId, epochId);
        vm.stopBroadcast();
    }
}
