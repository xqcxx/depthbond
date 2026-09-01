// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {DepthBondHook, IEpochObserver} from "../src/hook/DepthBondHook.sol";
import {DepthBondHookFactory} from "../src/deploy/DepthBondHookFactory.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

/// @notice Deploys a permission-valid hook. Configure its executor afterwards, once the pool key is known.
contract DeployHookScript is Script {
    function run() external returns (DepthBondHook hook) {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address controller = vm.envAddress("EPOCH_CONTROLLER");
        address poolManager = vm.envAddress("POOL_MANAGER");

        DepthBondHook.Range[3] memory ranges;
        ranges[0] = DepthBondHook.Range({lower: -600, upper: 600});
        ranges[1] = DepthBondHook.Range({lower: -1_800, upper: 1_800});
        ranges[2] = DepthBondHook.Range({lower: -6_000, upper: 6_000});

        vm.startBroadcast(deployerKey);
        DepthBondHookFactory factory = new DepthBondHookFactory();
        (, bytes32 salt) =
            factory.findSalt(IPoolManager(poolManager), IEpochObserver(controller), ranges, vm.addr(deployerKey));
        hook = factory.deployHook(salt, IPoolManager(poolManager), IEpochObserver(controller), ranges);
        vm.stopBroadcast();
    }
}
