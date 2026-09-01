// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {DepthBondVault} from "../src/core/DepthBondVault.sol";
import {EpochController, IDepthBondVault} from "../src/core/EpochController.sol";
import {DepthBondHook, IEpochObserver} from "../src/hook/DepthBondHook.sol";
import {DepthBondRSC} from "../src/reactive/DepthBondRSC.sol";
import {IReactive} from "reactive-lib/interfaces/IReactive.sol";
import {BaseHook} from "v4-hooks-public/base/BaseHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

interface Vm {
    function deal(address account, uint256 newBalance) external;
    function prank(address caller) external;
}

/// @dev Skips address-bit validation only in this unit-test harness. Production uses DepthBondHook directly with CREATE2 mining.
contract TestDepthBondHook is DepthBondHook {
    constructor(IPoolManager poolManager_, IEpochObserver controller_, address managedVault_, Range[3] memory ranges_)
        DepthBondHook(poolManager_, controller_, managedVault_, ranges_, msg.sender)
    {}

    function validateHookAddress(BaseHook) internal pure override {}
}

contract DepthBondIntegrationTest {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    address private constant ADA = address(0xA11CE);
    address private constant MANAGED_VAULT = address(0xB0D);
    address private constant CALLBACK_PROXY = address(0xCA11BAC);
    address private constant RVM_ID = address(0xA11CE123);

    DepthBondVault private vault;
    EpochController private controller;
    TestDepthBondHook private hook;

    receive() external payable {}

    /// @dev StateLibrary reads slot0 through this exact IPoolManager ABI method.
    function extsload(bytes32) external pure returns (bytes32) {
        return bytes32(0);
    }

    function setUp() public {
        vault = new DepthBondVault(1 ether);
        controller = new EpochController(IDepthBondVault(address(vault)), CALLBACK_PROXY, RVM_ID, 10, 5 ether);
        vault.setController(address(controller));

        DepthBondHook.Range[3] memory ranges;
        ranges[0] = DepthBondHook.Range({lower: -10, upper: 10});
        ranges[1] = DepthBondHook.Range({lower: -100, upper: 100});
        ranges[2] = DepthBondHook.Range({lower: -1_000, upper: 1_000});
        hook = new TestDepthBondHook(
            IPoolManager(address(this)), IEpochObserver(address(controller)), MANAGED_VAULT, ranges
        );
        controller.setObserver(address(hook));

        vm.deal(ADA, 10 ether);
    }

    function test_HookRecordsOneSwapAcrossAllActiveRanges() public {
        vm.prank(ADA);
        vault.depositAndCommit{value: 1 ether}(0, 10, 2);
        vm.prank(ADA);
        vault.depositAndCommit{value: 1 ether}(1, 10, 2);
        vm.prank(ADA);
        vault.depositAndCommit{value: 1 ether}(2, 10, 2);
        controller.beginEpoch();

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(1)),
            currency1: Currency.wrap(address(2)),
            fee: 3_000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: -100, sqrtPriceLimitX96: 0});
        hook.afterSwap(address(0x1234), key, params, BalanceDelta.wrap(0), "");

        (,, uint256[3] memory volume) = controller.getEpoch(1);
        _assertEq(volume[0], 100, "tight range did not receive volume");
        _assertEq(volume[1], 100, "medium range did not receive volume");
        _assertEq(volume[2], 100, "wide range did not receive volume");
    }

    function test_HookRejectsLiquidityRemovalOutsideManagedVault() public {
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(1)),
            currency1: Currency.wrap(address(2)),
            fee: 3_000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        ModifyLiquidityParams memory params =
            ModifyLiquidityParams({tickLower: -10, tickUpper: 10, liquidityDelta: -1, salt: bytes32(0)});

        (bool success,) =
            address(hook).call(abi.encodeCall(hook.beforeRemoveLiquidity, (address(0xBAD), key, params, bytes(""))));
        _assertFalse(success, "unmanaged liquidity removal was allowed");
    }

    function test_RscDeduplicatesCloseEvents() public {
        DepthBondRSC rsc = new DepthBondRSC(1_301, 1_301, address(controller), address(controller), 500_000);
        IReactive.LogRecord memory closeLog = IReactive.LogRecord({
            chain_id: 1_301,
            _contract: address(controller),
            topic_0: uint256(keccak256("EpochCloseRequested(uint64)")),
            topic_1: 1,
            topic_2: 0,
            topic_3: 0,
            data: "",
            block_number: 100,
            op_code: 0,
            block_hash: 0,
            tx_hash: 123,
            log_index: 4
        });

        rsc.react(closeLog);
        rsc.react(closeLog);

        bytes32 eventId = keccak256(abi.encode(uint256(1_301), uint256(123), uint256(4)));
        _assertTrue(rsc.processedLog(eventId), "source event was not recorded");
        _assertEq(rsc.nextCallbackNonce(), 1, "duplicate source event emitted a second callback");
    }

    function _assertEq(uint256 actual, uint256 expected, string memory reason) private pure {
        require(actual == expected, reason);
    }

    function _assertFalse(bool value, string memory reason) private pure {
        require(!value, reason);
    }

    function _assertTrue(bool value, string memory reason) private pure {
        require(value, reason);
    }
}
