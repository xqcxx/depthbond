// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {DepthBondVault} from "../src/core/DepthBondVault.sol";
import {EpochController, IDepthBondVault} from "../src/core/EpochController.sol";
import {DepthBondPositionExecutor} from "../src/v4/DepthBondPositionExecutor.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

interface Vm {
    function deal(address account, uint256 newBalance) external;
    function prank(address caller) external;
}

contract MockERC20 {
    mapping(address account => uint256) public balanceOf;
    mapping(address owner => mapping(address spender => uint256)) public allowance;

    function mint(address account, uint256 amount) external {
        balanceOf[account] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(allowance[from][msg.sender] >= amount, "allowance");
        require(balanceOf[from] >= amount, "balance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev Implements only the PoolManager selectors used by the executor's unlock callback.
contract MockPoolManager {
    uint256 public syncCount;
    uint256 public settleCount;
    uint256 public takeCount;
    int256 public lastLiquidityDelta;
    bytes32 public lastSalt;
    address public lastTakeRecipient;
    uint256 public lastTakeAmount;

    function unlock(bytes calldata data) external returns (bytes memory) {
        return IUnlockCallback(msg.sender).unlockCallback(data);
    }

    function modifyLiquidity(PoolKey calldata, ModifyLiquidityParams calldata params, bytes calldata)
        external
        returns (BalanceDelta, BalanceDelta)
    {
        lastLiquidityDelta = params.liquidityDelta;
        lastSalt = params.salt;
        if (params.liquidityDelta > 0) return (toBalanceDelta(-100, -200), BalanceDelta.wrap(0));
        return (toBalanceDelta(100, 200), BalanceDelta.wrap(0));
    }

    function sync(Currency) external {
        ++syncCount;
    }

    function settle() external payable returns (uint256) {
        ++settleCount;
        return 0;
    }

    function take(Currency, address recipient, uint256 amount) external {
        ++takeCount;
        lastTakeRecipient = recipient;
        lastTakeAmount = amount;
    }
}

contract DepthBondPositionExecutorTest {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    address private constant ADA = address(0xA11CE);
    address private constant HOOK = address(0xB00B);
    address private constant CALLBACK_PROXY = address(0xCA11BAC);
    address private constant RVM_ID = address(0xA11CE123);

    DepthBondVault private vault;
    EpochController private controller;
    MockPoolManager private poolManager;
    MockERC20 private token0;
    MockERC20 private token1;
    DepthBondPositionExecutor private executor;

    receive() external payable {}

    function setUp() public {
        vault = new DepthBondVault(1 ether);
        controller = new EpochController(IDepthBondVault(address(vault)), CALLBACK_PROXY, RVM_ID, 10, 5 ether);
        vault.setController(address(controller));

        poolManager = new MockPoolManager();
        token0 = new MockERC20();
        token1 = new MockERC20();
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 3_000,
            tickSpacing: 60,
            hooks: IHooks(HOOK)
        });
        int24[3] memory lower;
        int24[3] memory upper;
        lower[0] = -10;
        lower[1] = -100;
        lower[2] = -1_000;
        upper[0] = 10;
        upper[1] = 100;
        upper[2] = 1_000;
        executor =
            new DepthBondPositionExecutor(IPoolManager(address(poolManager)), vault, key, IHooks(HOOK), lower, upper);
        vault.setPositionExecutor(address(executor));

        vm.deal(ADA, 10 ether);
        token0.mint(ADA, 100);
        token1.mint(ADA, 200);
        vm.prank(ADA);
        token0.approve(address(executor), 100);
        vm.prank(ADA);
        token1.approve(address(executor), 200);
    }

    function test_ExecutorOwnsPositionLifecycleAndVaultBlocksBypass() public {
        vm.prank(ADA);
        uint256 commitmentId = vault.depositAndCommit{value: 4 ether}(1, 50, 2);

        vm.prank(ADA);
        executor.addLiquidity(commitmentId, 100, 200);

        _assertTrue(vault.positionActive(commitmentId), "position was not activated");
        _assertEq(uint256(poolManager.lastLiquidityDelta()), 50, "wrong liquidity added");
        _assertEq(token0.balanceOf(address(poolManager)), 100, "token0 was not settled");
        _assertEq(token1.balanceOf(address(poolManager)), 200, "token1 was not settled");

        vm.prank(ADA);
        (bool bypassSuccess,) = address(vault).call(abi.encodeCall(vault.exit, (commitmentId)));
        _assertFalse(bypassSuccess, "active v4 position bypassed executor");

        controller.beginEpoch();
        vm.prank(ADA);
        executor.removeLiquidity(commitmentId, 100, 200);

        _assertFalse(vault.positionActive(commitmentId), "position was not removed");
        _assertEq(vault.refundableBonds(ADA), 3 ether, "early-exit bond penalty was not applied");
        _assertEq(poolManager.takeCount(), 2, "removal credits were not taken");
        _assertEq(poolManager.lastTakeAmount(), 200, "wrong removal credit");
        _assertEq(poolManager.lastSalt(), bytes32(commitmentId), "position was not commitment-bound");
    }

    function _assertEq(uint256 actual, uint256 expected, string memory reason) private pure {
        require(actual == expected, reason);
    }

    function _assertEq(bytes32 actual, bytes32 expected, string memory reason) private pure {
        require(actual == expected, reason);
    }

    function _assertFalse(bool value, string memory reason) private pure {
        require(!value, reason);
    }

    function _assertTrue(bool value, string memory reason) private pure {
        require(value, reason);
    }
}
