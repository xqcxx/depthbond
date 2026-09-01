// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {DepthBondHook, IEpochObserver} from "../hook/DepthBondHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "v4-hooks-public/utils/HookMiner.sol";

/// @notice CREATE2 deployer for a DepthBond hook at the address required by v4 hook permissions.
contract DepthBondHookFactory {
    uint160 public constant REQUIRED_FLAGS = Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
        | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_SWAP_FLAG;

    error InvalidHookAddress();

    event HookDeployed(address indexed hook, address indexed owner, bytes32 indexed salt);

    function findSalt(
        IPoolManager poolManager,
        IEpochObserver controller,
        DepthBondHook.Range[3] memory ranges,
        address owner
    ) external view returns (address predictedHook, bytes32 salt) {
        return HookMiner.find(
            address(this),
            REQUIRED_FLAGS,
            type(DepthBondHook).creationCode,
            _constructorArgs(poolManager, controller, ranges, owner)
        );
    }

    function deployHook(
        bytes32 salt,
        IPoolManager poolManager,
        IEpochObserver controller,
        DepthBondHook.Range[3] memory ranges
    ) external returns (DepthBondHook hook) {
        hook = new DepthBondHook{salt: salt}(poolManager, controller, address(0), ranges, msg.sender);
        if ((uint160(address(hook)) & Hooks.ALL_HOOK_MASK) != REQUIRED_FLAGS) revert InvalidHookAddress();
        emit HookDeployed(address(hook), msg.sender, salt);
    }

    function _constructorArgs(
        IPoolManager poolManager,
        IEpochObserver controller,
        DepthBondHook.Range[3] memory ranges,
        address owner
    ) private pure returns (bytes memory) {
        return abi.encode(poolManager, controller, address(0), ranges, owner);
    }
}
