// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {EpochController} from "../src/core/EpochController.sol";

/// @notice Sets the ReactVM ID after Reactive creates it. This action is intentionally one-time.
contract ConfigureRvmScript is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        EpochController controller = EpochController(vm.envAddress("EPOCH_CONTROLLER"));
        address rvmId = vm.envAddress("REACTIVE_RVM_ID");

        vm.startBroadcast(deployerKey);
        controller.setExpectedRvmId(rvmId);
        vm.stopBroadcast();
    }
}
