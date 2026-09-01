// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {DepthBondVault} from "../src/core/DepthBondVault.sol";
import {EpochController, IDepthBondVault} from "../src/core/EpochController.sol";
import {DepthBondHook, IEpochObserver} from "../src/hook/DepthBondHook.sol";
import {DepthBondHookFactory} from "../src/deploy/DepthBondHookFactory.sol";
import {DepthBondPositionExecutor} from "../src/v4/DepthBondPositionExecutor.sol";
import {DepthBondSwapRouter} from "../src/v4/DepthBondSwapRouter.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @notice Deploys and wires the Unichain side. Run ConfigureRvmScript after the Reactive RSC exists.
contract DeployUnichainScript is Script {
    uint160 internal constant SQRT_PRICE_1_1 = 79_228_162_514_264_337_593_543_950_336;

    struct Deployment {
        address vault;
        address controller;
        address hookFactory;
        address hook;
        address executor;
        address swapRouter;
        address token0;
        address token1;
    }

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        IPoolManager poolManager = IPoolManager(vm.envAddress("POOL_MANAGER"));
        address callbackProxy = vm.envAddress("CALLBACK_PROXY");
        address token0 = vm.envOr("TOKEN0", address(0));
        address token1 = vm.envOr("TOKEN1", address(0));
        uint256 initialRewards = vm.envOr("INITIAL_REWARD_BUDGET", uint256(5 ether));

        vm.startBroadcast(deployerKey);
        if (token0 == address(0) && token1 == address(0)) {
            MockERC20 first = new MockERC20("DepthBond Token A", "DBA");
            MockERC20 second = new MockERC20("DepthBond Token B", "DBB");
            (token0, token1) = address(first) < address(second)
                ? (address(first), address(second))
                : (address(second), address(first));
        } else {
            require(token0 != address(0) && token1 != address(0), "provide both tokens");
        }
        require(token0 < token1, "tokens not sorted");

        DepthBondVault vault = new DepthBondVault(vm.envOr("MINIMUM_BOND", uint256(0.1 ether)));
        EpochController controller = new EpochController(
            IDepthBondVault(address(vault)),
            callbackProxy,
            address(0),
            uint64(vm.envOr("EPOCH_LENGTH_BLOCKS", uint256(20))),
            vm.envOr("REWARD_BUDGET_PER_EPOCH", uint256(5 ether))
        );
        vault.setController(address(controller));
        vault.fundRewards{value: initialRewards}();

        DepthBondHook.Range[3] memory ranges = _ranges();
        DepthBondHookFactory factory = new DepthBondHookFactory();
        (, bytes32 salt) = factory.findSalt(poolManager, IEpochObserver(address(controller)), ranges, deployer);
        DepthBondHook hook = factory.deployHook(salt, poolManager, IEpochObserver(address(controller)), ranges);

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: uint24(vm.envOr("POOL_FEE", uint256(3_000))),
            tickSpacing: int24(int256(vm.envOr("TICK_SPACING", uint256(60)))),
            hooks: IHooks(address(hook))
        });
        poolManager.initialize(key, uint160(vm.envOr("INITIAL_SQRT_PRICE_X96", uint256(SQRT_PRICE_1_1))));

        (int24[3] memory lower, int24[3] memory upper) = _ticks(ranges);
        DepthBondPositionExecutor executor = new DepthBondPositionExecutor(poolManager, vault, key, hook, lower, upper);
        DepthBondSwapRouter swapRouter = new DepthBondSwapRouter(poolManager);
        vault.setPositionExecutor(address(executor));
        hook.setManagedVault(address(executor));
        controller.setObserver(address(hook));
        vm.stopBroadcast();

        _writeDeployment(
            Deployment({
                vault: address(vault),
                controller: address(controller),
                hookFactory: address(factory),
                hook: address(hook),
                executor: address(executor),
                swapRouter: address(swapRouter),
                token0: token0,
                token1: token1
            })
        );
    }

    function _writeDeployment(Deployment memory deployment) private {
        string memory json = vm.serializeAddress("deployment", "vault", deployment.vault);
        json = vm.serializeAddress("deployment", "controller", deployment.controller);
        json = vm.serializeAddress("deployment", "hookFactory", deployment.hookFactory);
        json = vm.serializeAddress("deployment", "hook", deployment.hook);
        json = vm.serializeAddress("deployment", "executor", deployment.executor);
        json = vm.serializeAddress("deployment", "swapRouter", deployment.swapRouter);
        json = vm.serializeAddress("deployment", "token0", deployment.token0);
        json = vm.serializeAddress("deployment", "token1", deployment.token1);
        vm.writeJson(json, "deployments/unichain-sepolia.json");
        vm.writeJson(json, "frontend/public/deployments/unichain-sepolia.json");
    }

    function _ranges() private pure returns (DepthBondHook.Range[3] memory ranges) {
        ranges[0] = DepthBondHook.Range({lower: -600, upper: 600});
        ranges[1] = DepthBondHook.Range({lower: -1_800, upper: 1_800});
        ranges[2] = DepthBondHook.Range({lower: -6_000, upper: 6_000});
    }

    function _ticks(DepthBondHook.Range[3] memory ranges)
        private
        pure
        returns (int24[3] memory lower, int24[3] memory upper)
    {
        for (uint8 rangeId; rangeId < 3; ++rangeId) {
            lower[rangeId] = ranges[rangeId].lower;
            upper[rangeId] = ranges[rangeId].upper;
        }
    }
}
