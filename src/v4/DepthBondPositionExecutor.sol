// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {DepthBondVault} from "../core/DepthBondVault.sol";
import {SafeCallback} from "@uniswap/v4-periphery/src/base/SafeCallback.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

interface IERC20Minimal {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @notice Executes one managed v4 position for each DepthBond commitment.
/// @dev ERC-20-only demo executor. Native-currency pools require explicit wrapped-native settlement support.
contract DepthBondPositionExecutor is SafeCallback {
    using BalanceDeltaLibrary for BalanceDelta;

    uint8 internal constant RANGE_COUNT = 3;

    enum Action {
        Add,
        Remove
    }

    struct Operation {
        Action action;
        uint256 commitmentId;
        address owner;
        uint128 amount0Bound;
        uint128 amount1Bound;
    }

    error Unauthorized();
    error InvalidRange();
    error InvalidPool();
    error PositionAlreadyActive();
    error PositionNotActive();
    error ReentrantCall();
    error NativeCurrencyUnsupported();
    error SlippageExceeded();
    error UnexpectedDebtOnRemoval();
    error TokenTransferFailed();

    DepthBondVault public immutable vault;
    IHooks public immutable hook;
    PoolKey public poolKey;
    int24[3] public tickLower;
    int24[3] public tickUpper;
    bool private executing;

    event PositionAdded(
        uint256 indexed commitmentId, address indexed owner, uint128 liquidity, uint256 amount0, uint256 amount1
    );
    event PositionRemoved(
        uint256 indexed commitmentId, address indexed owner, uint128 liquidity, uint256 amount0, uint256 amount1
    );

    constructor(
        IPoolManager poolManager_,
        DepthBondVault vault_,
        PoolKey memory poolKey_,
        IHooks hook_,
        int24[3] memory tickLower_,
        int24[3] memory tickUpper_
    ) SafeCallback(poolManager_) {
        if (address(vault_) == address(0) || address(hook_) == address(0) || address(poolKey_.hooks) != address(hook_))
        {
            revert InvalidPool();
        }
        if (Currency.unwrap(poolKey_.currency0) == address(0) || Currency.unwrap(poolKey_.currency1) == address(0)) {
            revert NativeCurrencyUnsupported();
        }

        vault = vault_;
        hook = hook_;
        poolKey = poolKey_;
        for (uint8 rangeId; rangeId < RANGE_COUNT; ++rangeId) {
            if (tickLower_[rangeId] >= tickUpper_[rangeId]) revert InvalidRange();
            tickLower[rangeId] = tickLower_[rangeId];
            tickUpper[rangeId] = tickUpper_[rangeId];
        }
    }

    function addLiquidity(uint256 commitmentId, uint128 amount0Max, uint128 amount1Max) external {
        (address commitmentOwner,, uint8 rangeId, bool exited, bool active) = vault.positionCommitment(commitmentId);
        if (commitmentOwner != msg.sender || exited) revert Unauthorized();
        if (rangeId >= RANGE_COUNT) revert InvalidRange();
        if (active) revert PositionAlreadyActive();

        _unlock(Operation(Action.Add, commitmentId, msg.sender, amount0Max, amount1Max));
    }

    function removeLiquidity(uint256 commitmentId, uint128 amount0Min, uint128 amount1Min) external {
        (address commitmentOwner,, uint8 rangeId, bool exited, bool active) = vault.positionCommitment(commitmentId);
        if (commitmentOwner != msg.sender || exited) revert Unauthorized();
        if (rangeId >= RANGE_COUNT) revert InvalidRange();
        if (!active) revert PositionNotActive();

        _unlock(Operation(Action.Remove, commitmentId, msg.sender, amount0Min, amount1Min));
    }

    function _unlock(Operation memory operation) private {
        if (executing) revert ReentrantCall();
        executing = true;
        poolManager.unlock(abi.encode(operation));
        executing = false;
    }

    function _unlockCallback(bytes calldata data) internal override returns (bytes memory) {
        if (!executing) revert Unauthorized();
        Operation memory operation = abi.decode(data, (Operation));
        (address commitmentOwner, uint128 liquidity, uint8 rangeId, bool exited, bool active) =
            vault.positionCommitment(operation.commitmentId);
        if (commitmentOwner != operation.owner || exited || rangeId >= RANGE_COUNT) revert Unauthorized();

        int256 liquidityDelta =
            operation.action == Action.Add ? int256(uint256(liquidity)) : -int256(uint256(liquidity));
        if ((operation.action == Action.Add && active) || (operation.action == Action.Remove && !active)) {
            revert PositionNotActive();
        }

        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: tickLower[rangeId],
                tickUpper: tickUpper[rangeId],
                liquidityDelta: liquidityDelta,
                salt: bytes32(operation.commitmentId)
            }),
            abi.encode(operation.commitmentId)
        );

        if (operation.action == Action.Add) {
            (uint256 amount0, uint256 amount1) =
                _settleAdd(delta, operation.owner, operation.amount0Bound, operation.amount1Bound);
            vault.activatePosition(operation.commitmentId);
            emit PositionAdded(operation.commitmentId, operation.owner, liquidity, amount0, amount1);
        } else {
            (uint256 amount0, uint256 amount1) =
                _takeRemoval(delta, operation.owner, operation.amount0Bound, operation.amount1Bound);
            // This state transition and the pool removal are one transaction; either both persist or both revert.
            vault.preparePositionExit(operation.commitmentId, operation.owner);
            emit PositionRemoved(operation.commitmentId, operation.owner, liquidity, amount0, amount1);
        }

        return bytes("");
    }

    function _settleAdd(BalanceDelta delta, address owner, uint128 amount0Max, uint128 amount1Max)
        private
        returns (uint256 amount0, uint256 amount1)
    {
        amount0 = _settleOrTake(poolKey.currency0, delta.amount0(), owner, amount0Max);
        amount1 = _settleOrTake(poolKey.currency1, delta.amount1(), owner, amount1Max);
    }

    function _settleOrTake(Currency currency, int128 delta, address owner, uint128 maximum)
        private
        returns (uint256 amount)
    {
        if (delta < 0) {
            amount = uint256(-int256(delta));
            if (amount > maximum) revert SlippageExceeded();
            poolManager.sync(currency);
            if (!IERC20Minimal(Currency.unwrap(currency)).transferFrom(owner, address(poolManager), amount)) {
                revert TokenTransferFailed();
            }
            poolManager.settle();
        } else if (delta > 0) {
            amount = uint256(uint128(delta));
            poolManager.take(currency, owner, amount);
        }
    }

    function _takeRemoval(BalanceDelta delta, address owner, uint128 amount0Min, uint128 amount1Min)
        private
        returns (uint256 amount0, uint256 amount1)
    {
        amount0 = _take(poolKey.currency0, delta.amount0(), owner, amount0Min);
        amount1 = _take(poolKey.currency1, delta.amount1(), owner, amount1Min);
    }

    function _take(Currency currency, int128 delta, address owner, uint128 minimum) private returns (uint256 amount) {
        if (delta < 0) revert UnexpectedDebtOnRemoval();
        amount = uint256(uint128(delta));
        if (amount < minimum) revert SlippageExceeded();
        if (amount != 0) poolManager.take(currency, owner, amount);
    }
}
