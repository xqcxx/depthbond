// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SafeCallback} from "@uniswap/v4-periphery/src/base/SafeCallback.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

interface IERC20SwapToken {
    function transferFrom(address owner, address recipient, uint256 amount) external returns (bool);
}

/// @notice Minimal ERC-20 v4 swap route used by the DepthBond demo and local lifecycle test.
contract DepthBondSwapRouter is SafeCallback {
    using BalanceDeltaLibrary for BalanceDelta;

    struct SwapOperation {
        PoolKey key;
        SwapParams params;
        address payer;
    }

    error ReentrantCall();
    error NotExecuting();
    error NativeCurrencyUnsupported();
    error TokenTransferFailed();

    bool private executing;

    constructor(IPoolManager poolManager_) SafeCallback(poolManager_) {}

    function swap(PoolKey memory key, SwapParams memory params) external {
        if (executing) revert ReentrantCall();
        if (Currency.unwrap(key.currency0) == address(0) || Currency.unwrap(key.currency1) == address(0)) {
            revert NativeCurrencyUnsupported();
        }

        executing = true;
        poolManager.unlock(abi.encode(SwapOperation({key: key, params: params, payer: msg.sender})));
        executing = false;
    }

    function _unlockCallback(bytes calldata data) internal override returns (bytes memory) {
        if (!executing) revert NotExecuting();
        SwapOperation memory operation = abi.decode(data, (SwapOperation));
        BalanceDelta delta = poolManager.swap(operation.key, operation.params, "");
        _settleOrTake(operation.key.currency0, delta.amount0(), operation.payer);
        _settleOrTake(operation.key.currency1, delta.amount1(), operation.payer);
        return bytes("");
    }

    function _settleOrTake(Currency currency, int128 delta, address payer) private {
        if (delta < 0) {
            uint256 amount = uint256(-int256(delta));
            poolManager.sync(currency);
            if (!IERC20SwapToken(Currency.unwrap(currency)).transferFrom(payer, address(poolManager), amount)) {
                revert TokenTransferFailed();
            }
            poolManager.settle();
        } else if (delta > 0) {
            poolManager.take(currency, payer, uint256(uint128(delta)));
        }
    }
}
