// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";

/// @notice Funds deterministic demo accounts and grants the executor/router token allowances.
/// @dev Only use with the mock tokens deployed by DeployUnichainScript.
contract SeedDemoScript is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        uint256 adaKey = vm.envUint("ADA_PRIVATE_KEY");
        uint256 baoKey = vm.envUint("BAO_PRIVATE_KEY");
        uint256 jitKey = vm.envUint("JIT_PRIVATE_KEY");
        uint256 traderKey = vm.envUint("TRADER_PRIVATE_KEY");
        MockERC20 token0 = MockERC20(vm.envAddress("TOKEN0"));
        MockERC20 token1 = MockERC20(vm.envAddress("TOKEN1"));
        address executor = vm.envAddress("EXECUTOR");
        address swapRouter = vm.envAddress("SWAP_ROUTER");
        uint256 allocation = vm.envOr("DEMO_TOKEN_ALLOCATION", uint256(1e30));

        address[4] memory accounts = [vm.addr(adaKey), vm.addr(baoKey), vm.addr(jitKey), vm.addr(traderKey)];
        vm.startBroadcast(deployerKey);
        for (uint8 index; index < accounts.length; ++index) {
            token0.mint(accounts[index], allocation);
            token1.mint(accounts[index], allocation);
        }
        vm.stopBroadcast();

        _approve(adaKey, token0, token1, executor, swapRouter);
        _approve(baoKey, token0, token1, executor, swapRouter);
        _approve(jitKey, token0, token1, executor, swapRouter);
        _approve(traderKey, token0, token1, executor, swapRouter);

        string memory json = vm.serializeAddress("accounts", "ada", accounts[0]);
        json = vm.serializeAddress("accounts", "bao", accounts[1]);
        json = vm.serializeAddress("accounts", "jit", accounts[2]);
        json = vm.serializeAddress("accounts", "trader", accounts[3]);
        vm.writeJson(json, "deployments/demo-accounts.json");
        vm.writeJson(json, "frontend/public/deployments/demo-accounts.json");
    }

    function _approve(uint256 accountKey, MockERC20 token0, MockERC20 token1, address executor, address swapRouter)
        private
    {
        vm.startBroadcast(accountKey);
        token0.approve(executor, type(uint256).max);
        token1.approve(executor, type(uint256).max);
        token0.approve(swapRouter, type(uint256).max);
        token1.approve(swapRouter, type(uint256).max);
        vm.stopBroadcast();
    }
}
