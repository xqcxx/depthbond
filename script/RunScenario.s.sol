// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {DepthBondVault} from "../src/core/DepthBondVault.sol";
import {EpochController} from "../src/core/EpochController.sol";
import {DepthBondPositionExecutor} from "../src/v4/DepthBondPositionExecutor.sol";
import {DepthBondSwapRouter} from "../src/v4/DepthBondSwapRouter.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// @notice Runs the pre-settlement demo: durable LPs enter, a JIT LP exits, and a real swap supplies evidence.
/// @dev Close the epoch after its block deadline, wait for Reactive, then claim with the appropriate LP wallet.
contract RunScenarioScript is Script {
    uint160 internal constant MIN_SQRT_PRICE_PLUS_ONE = 4_295_128_740;

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        uint256 adaKey = vm.envUint("ADA_PRIVATE_KEY");
        uint256 baoKey = vm.envUint("BAO_PRIVATE_KEY");
        uint256 jitKey = vm.envUint("JIT_PRIVATE_KEY");
        uint256 traderKey = vm.envUint("TRADER_PRIVATE_KEY");
        DepthBondVault vault = DepthBondVault(vm.envAddress("VAULT"));
        EpochController controller = EpochController(vm.envAddress("EPOCH_CONTROLLER"));
        DepthBondPositionExecutor executor = DepthBondPositionExecutor(vm.envAddress("EXECUTOR"));
        DepthBondSwapRouter swapRouter = DepthBondSwapRouter(vm.envAddress("SWAP_ROUTER"));

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(vm.envAddress("TOKEN0")),
            currency1: Currency.wrap(vm.envAddress("TOKEN1")),
            fee: uint24(vm.envOr("POOL_FEE", uint256(3_000))),
            tickSpacing: int24(int256(vm.envOr("TICK_SPACING", uint256(60)))),
            hooks: IHooks(vm.envAddress("HOOK"))
        });

        uint256 adaCommitment = _addLp(adaKey, vault, executor, 1, uint128(vm.envOr("ADA_LIQUIDITY", uint256(1e18))));
        uint256 baoCommitment = _addLp(baoKey, vault, executor, 0, uint128(vm.envOr("BAO_LIQUIDITY", uint256(5e17))));

        vm.startBroadcast(deployerKey);
        controller.beginEpoch();
        vm.stopBroadcast();

        uint256 jitCommitment = _addLp(jitKey, vault, executor, 1, uint128(vm.envOr("JIT_LIQUIDITY", uint256(1e17))));
        vm.startBroadcast(jitKey);
        executor.removeLiquidity(jitCommitment, 0, 0);
        vm.stopBroadcast();

        vm.startBroadcast(traderKey);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(vm.envOr("SWAP_AMOUNT_IN", uint256(1e15))),
                sqrtPriceLimitX96: MIN_SQRT_PRICE_PLUS_ONE
            })
        );
        vm.stopBroadcast();

        (uint64 endBlock,,) = controller.getEpoch(1);
        string memory json = vm.serializeUint("scenario", "adaCommitment", adaCommitment);
        json = vm.serializeUint("scenario", "baoCommitment", baoCommitment);
        json = vm.serializeUint("scenario", "jitCommitment", jitCommitment);
        json = vm.serializeUint("scenario", "epochEndBlock", endBlock);
        vm.writeJson(json, "deployments/scenario.json");
        vm.writeJson(json, "frontend/public/deployments/scenario.json");
    }

    function _addLp(
        uint256 accountKey,
        DepthBondVault vault,
        DepthBondPositionExecutor executor,
        uint8 rangeId,
        uint128 liquidity
    ) private returns (uint256 commitmentId) {
        vm.startBroadcast(accountKey);
        commitmentId = vault.depositAndCommit{value: vm.envOr("LP_BOND", uint256(1 ether))}(rangeId, liquidity, 2);
        executor.addLiquidity(commitmentId, type(uint128).max, type(uint128).max);
        vm.stopBroadcast();
    }
}
