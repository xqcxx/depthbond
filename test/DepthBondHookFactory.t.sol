// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {DepthBondHook, IEpochObserver} from "../src/hook/DepthBondHook.sol";
import {DepthBondHookFactory} from "../src/deploy/DepthBondHookFactory.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

contract MockEpochObserver is IEpochObserver {
    function activeEpoch() external pure returns (uint64) {
        return 0;
    }

    function isEpochOpen() external pure returns (bool) {
        return false;
    }

    function recordQualifyingSwap(uint64, uint8, uint256) external {}
}

contract DepthBondHookFactoryTest {
    function test_DeploysHookAtPermissionValidAddressAndBindsExecutorOnce() public {
        DepthBondHookFactory factory = new DepthBondHookFactory();
        MockEpochObserver controller = new MockEpochObserver();
        DepthBondHook.Range[3] memory ranges;
        ranges[0] = DepthBondHook.Range({lower: -10, upper: 10});
        ranges[1] = DepthBondHook.Range({lower: -100, upper: 100});
        ranges[2] = DepthBondHook.Range({lower: -1_000, upper: 1_000});

        IPoolManager poolManager = IPoolManager(address(0xF00));
        (address predicted, bytes32 salt) = factory.findSalt(poolManager, controller, ranges, address(this));
        DepthBondHook hook = factory.deployHook(salt, poolManager, controller, ranges);

        _assertEq(address(hook), predicted, "CREATE2 address did not match prediction");
        _assertEq(
            uint160(address(hook)) & Hooks.ALL_HOOK_MASK,
            factory.REQUIRED_FLAGS(),
            "hook address does not encode declared permissions"
        );

        hook.setManagedVault(address(0xB0D));
        _assertEq(hook.managedVault(), address(0xB0D), "executor binding failed");
        (bool secondBindingSuccess,) = address(hook).call(abi.encodeCall(hook.setManagedVault, (address(0xBEEF))));
        _assertFalse(secondBindingSuccess, "executor was rebound");
    }

    function _assertEq(address actual, address expected, string memory reason) private pure {
        require(actual == expected, reason);
    }

    function _assertEq(uint160 actual, uint160 expected, string memory reason) private pure {
        require(actual == expected, reason);
    }

    function _assertFalse(bool value, string memory reason) private pure {
        require(!value, reason);
    }
}
