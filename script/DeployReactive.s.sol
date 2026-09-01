// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {DepthBondRSC} from "../src/reactive/DepthBondRSC.sol";

/// @notice Deploy on Reactive Lasna after the Unichain controller address is known.
contract DeployReactiveScript is Script {
    function run() external returns (DepthBondRSC rsc) {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        uint256 originChainId = vm.envOr("ORIGIN_CHAIN_ID", uint256(1_301));
        uint256 destinationChainId = vm.envOr("DESTINATION_CHAIN_ID", uint256(1_301));
        address controller = vm.envAddress("EPOCH_CONTROLLER");
        uint64 callbackGasLimit = uint64(vm.envOr("CALLBACK_GAS_LIMIT", uint256(500_000)));
        uint256 reactiveFunding = vm.envOr("REACTIVE_FUNDING", uint256(0.01 ether));

        vm.startBroadcast(deployerKey);
        rsc = new DepthBondRSC{value: reactiveFunding}(
            originChainId, destinationChainId, controller, controller, callbackGasLimit
        );
        vm.stopBroadcast();

        string memory json = vm.serializeAddress("deployment", "rsc", address(rsc));
        vm.writeJson(json, "deployments/reactive-lasna.json");
        vm.writeJson(json, "frontend/public/deployments/reactive-lasna.json");
    }
}
