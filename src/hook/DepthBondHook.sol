// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "v4-hooks-public/base/BaseHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

interface IEpochObserver {
    function activeEpoch() external view returns (uint64);
    function isEpochOpen() external view returns (bool);
    function recordQualifyingSwap(uint64 epochId, uint8 rangeId, uint256 volume) external;
}

/// @notice v4 hook that records managed-liquidity and in-range swap evidence for DepthBond epochs.
/// @dev Deploy with CREATE2 at an address whose low 14 bits match `getHookPermissions`.
contract DepthBondHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint8 internal constant RANGE_COUNT = 3;

    error NotManagedVault();
    error InvalidRange();
    error Unauthorized();

    struct Range {
        int24 lower;
        int24 upper;
    }

    IEpochObserver public immutable controller;
    address public immutable owner;
    address public managedVault;
    Range[3] public ranges;

    event SwapObserved(bytes32 indexed poolId, uint64 indexed epochId, int24 tick, uint256 volume, bool zeroForOne);
    event PoolLiquidityObserved(bytes32 indexed poolId, uint64 indexed epochId, bool added, uint128 liquidity);

    constructor(
        IPoolManager poolManager_,
        IEpochObserver controller_,
        address managedVault_,
        Range[3] memory ranges_,
        address owner_
    ) BaseHook(poolManager_) {
        if (address(controller_) == address(0) || owner_ == address(0)) revert Unauthorized();
        controller = controller_;
        owner = owner_;
        managedVault = managedVault_;

        for (uint8 rangeId; rangeId < RANGE_COUNT; ++rangeId) {
            if (ranges_[rangeId].lower >= ranges_[rangeId].upper) revert InvalidRange();
            ranges[rangeId] = ranges_[rangeId];
        }
    }

    function setManagedVault(address managedVault_) external {
        if (msg.sender != owner) revert Unauthorized();
        if (managedVault != address(0) || managedVault_ == address(0)) revert NotManagedVault();
        managedVault = managedVault_;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory permissions) {
        permissions.afterAddLiquidity = true;
        permissions.beforeRemoveLiquidity = true;
        permissions.afterRemoveLiquidity = true;
        permissions.afterSwap = true;
    }

    function _afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, BalanceDelta) {
        _requireManagedVault(sender);
        emit PoolLiquidityObserved(
            PoolId.unwrap(key.toId()), controller.activeEpoch(), true, uint128(uint256(params.liquidityDelta))
        );
        return (this.afterAddLiquidity.selector, BalanceDelta.wrap(0));
    }

    function _beforeRemoveLiquidity(address sender, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        view
        override
        returns (bytes4)
    {
        _requireManagedVault(sender);
        return this.beforeRemoveLiquidity.selector;
    }

    function _afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, BalanceDelta) {
        _requireManagedVault(sender);
        emit PoolLiquidityObserved(
            PoolId.unwrap(key.toId()), controller.activeEpoch(), false, uint128(uint256(-params.liquidityDelta))
        );
        return (this.afterRemoveLiquidity.selector, BalanceDelta.wrap(0));
    }

    function _afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        if (!controller.isEpochOpen()) return (this.afterSwap.selector, 0);

        PoolId poolId = key.toId();
        (, int24 tick,,) = poolManager.getSlot0(poolId);
        uint256 volume = _absolute(params.amountSpecified);
        uint64 epochId = controller.activeEpoch();

        for (uint8 rangeId; rangeId < RANGE_COUNT; ++rangeId) {
            Range memory range = ranges[rangeId];
            if (tick >= range.lower && tick < range.upper) {
                controller.recordQualifyingSwap(epochId, rangeId, volume);
            }
        }

        emit SwapObserved(PoolId.unwrap(poolId), epochId, tick, volume, params.zeroForOne);
        return (this.afterSwap.selector, 0);
    }

    function _requireManagedVault(address sender) private view {
        if (sender != managedVault) revert NotManagedVault();
    }

    function _absolute(int256 value) private pure returns (uint256) {
        return value < 0 ? uint256(-(value + 1)) + 1 : uint256(value);
    }
}
