// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {DepthBondVault} from "../src/core/DepthBondVault.sol";
import {EpochController, IDepthBondVault} from "../src/core/EpochController.sol";
import {DepthBondHook, IEpochObserver} from "../src/hook/DepthBondHook.sol";
import {DepthBondHookFactory} from "../src/deploy/DepthBondHookFactory.sol";
import {DepthBondPositionExecutor} from "../src/v4/DepthBondPositionExecutor.sol";
import {DepthBondSwapRouter} from "../src/v4/DepthBondSwapRouter.sol";
import {DepthBondRSC} from "../src/reactive/DepthBondRSC.sol";
import {IReactive} from "reactive-lib/interfaces/IReactive.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

interface Vm {
    function deal(address account, uint256 newBalance) external;
    function prank(address caller) external;
    function roll(uint256 newHeight) external;
}

contract LifecycleToken {
    mapping(address account => uint256) public balanceOf;
    mapping(address owner => mapping(address spender => uint256)) public allowance;

    function mint(address account, uint256 amount) external {
        balanceOf[account] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address recipient, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[recipient] += amount;
        return true;
    }

    function transferFrom(address owner, address recipient, uint256 amount) external returns (bool) {
        require(allowance[owner][msg.sender] >= amount, "allowance");
        require(balanceOf[owner] >= amount, "balance");
        allowance[owner][msg.sender] -= amount;
        balanceOf[owner] -= amount;
        balanceOf[recipient] += amount;
        return true;
    }
}

contract DepthBondRealV4LifecycleTest {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    address private constant ADA = address(0xA11CE);
    address private constant TRADER = address(0x7A0E);
    address private constant CALLBACK_PROXY = address(0xCA11BAC);
    uint256 private constant CHAIN_ID = 31_337;
    uint160 private constant SQRT_PRICE_1_1 = 79_228_162_514_264_337_593_543_950_336;

    DepthBondVault private vault;
    EpochController private controller;
    PoolManager private manager;
    LifecycleToken private token0;
    LifecycleToken private token1;
    PoolKey private key;
    DepthBondPositionExecutor private executor;
    DepthBondRSC private rsc;

    receive() external payable {}

    function setUp() public {
        vm.deal(address(this), 10 ether);
        vm.deal(ADA, 10 ether);

        vault = new DepthBondVault(1 ether);
        controller = new EpochController(IDepthBondVault(address(vault)), CALLBACK_PROXY, address(0), 10, 5 ether);
        vault.setController(address(controller));
        vault.fundRewards{value: 5 ether}();

        manager = new PoolManager(address(this));
        (token0, token1) = _deploySortedTokens();

        DepthBondHook.Range[3] memory ranges = _ranges();
        DepthBondHookFactory factory = new DepthBondHookFactory();
        (, bytes32 salt) = factory.findSalt(manager, IEpochObserver(address(controller)), ranges, address(this));
        DepthBondHook hook = factory.deployHook(salt, manager, IEpochObserver(address(controller)), ranges);

        key = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 3_000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        manager.initialize(key, SQRT_PRICE_1_1);

        int24[3] memory lower;
        int24[3] memory upper;
        for (uint8 rangeId; rangeId < 3; ++rangeId) {
            lower[rangeId] = ranges[rangeId].lower;
            upper[rangeId] = ranges[rangeId].upper;
        }
        executor = new DepthBondPositionExecutor(manager, vault, key, hook, lower, upper);
        vault.setPositionExecutor(address(executor));
        hook.setManagedVault(address(executor));
        controller.setObserver(address(hook));

        rsc = new DepthBondRSC(CHAIN_ID, CHAIN_ID, address(controller), address(controller), 500_000);
        controller.setExpectedRvmId(address(rsc));

        token0.mint(ADA, 1e30);
        token1.mint(ADA, 1e30);
        token0.mint(TRADER, 1e30);
        vm.prank(ADA);
        token0.approve(address(executor), type(uint256).max);
        vm.prank(ADA);
        token1.approve(address(executor), type(uint256).max);
    }

    function test_RealPoolLifecycleFromLiquidityToReactiveSettlement() public {
        vm.prank(ADA);
        uint256 commitmentId = vault.depositAndCommit{value: 4 ether}(1, 1e18, 2);
        vm.prank(ADA);
        executor.addLiquidity(commitmentId, type(uint128).max, type(uint128).max);
        _assertTrue(vault.positionActive(commitmentId), "real pool position was not added");

        controller.beginEpoch();
        DepthBondSwapRouter router = new DepthBondSwapRouter(manager);
        vm.prank(TRADER);
        token0.approve(address(router), type(uint256).max);
        vm.prank(TRADER);
        router.swap(key, SwapParams({zeroForOne: true, amountSpecified: -1e15, sqrtPriceLimitX96: 4_295_128_740}));

        (uint64 endBlock,, uint256[3] memory volume) = controller.getEpoch(1);
        _assertTrue(volume[1] != 0, "real swap did not reach the hook observer");
        vm.roll(uint256(endBlock) + 1);
        controller.requestEpochClose(1);

        rsc.react(_closeLog());
        vm.prank(CALLBACK_PROXY);
        controller.settleEpoch(address(rsc), 1, 1);

        vm.prank(ADA);
        _assertEq(vault.claim(commitmentId, 1), 5 ether, "LP did not receive settled epoch reward");
    }

    function _closeLog() private view returns (IReactive.LogRecord memory) {
        return IReactive.LogRecord({
            chain_id: CHAIN_ID,
            _contract: address(controller),
            topic_0: uint256(keccak256("EpochCloseRequested(uint64)")),
            topic_1: 1,
            topic_2: 0,
            topic_3: 0,
            data: "",
            block_number: block.number,
            op_code: 0,
            block_hash: 0,
            tx_hash: 1,
            log_index: 0
        });
    }

    function _deploySortedTokens() private returns (LifecycleToken first, LifecycleToken second) {
        LifecycleToken a = new LifecycleToken();
        LifecycleToken b = new LifecycleToken();
        return address(a) < address(b) ? (a, b) : (b, a);
    }

    function _ranges() private pure returns (DepthBondHook.Range[3] memory ranges) {
        ranges[0] = DepthBondHook.Range({lower: -600, upper: 600});
        ranges[1] = DepthBondHook.Range({lower: -1_800, upper: 1_800});
        ranges[2] = DepthBondHook.Range({lower: -6_000, upper: 6_000});
    }

    function _assertEq(uint256 actual, uint256 expected, string memory reason) private pure {
        require(actual == expected, reason);
    }

    function _assertTrue(bool value, string memory reason) private pure {
        require(value, reason);
    }
}
