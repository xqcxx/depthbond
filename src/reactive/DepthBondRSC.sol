// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IReactive} from "reactive-lib/interfaces/IReactive.sol";
import {AbstractReactive} from "reactive-lib/abstract-base/AbstractReactive.sol";

/// @notice Reactive Network coordinator for authenticated DepthBond epoch settlements.
/// @dev The destination controller verifies both the callback proxy and this RVM identity.
contract DepthBondRSC is AbstractReactive {
    bytes32 public constant EPOCH_CLOSE_REQUESTED = keccak256("EpochCloseRequested(uint64)");

    uint256 public immutable originChainId;
    uint256 public immutable destinationChainId;
    address public immutable originController;
    address public immutable destinationController;
    uint64 public immutable callbackGasLimit;
    uint64 public nextCallbackNonce;

    mapping(bytes32 eventId => bool) public processedLog;

    event SettlementCallbackRequested(uint64 indexed epochId, uint64 indexed callbackNonce, bytes32 indexed eventId);

    constructor(
        uint256 originChainId_,
        uint256 destinationChainId_,
        address originController_,
        address destinationController_,
        uint64 callbackGasLimit_
    ) payable {
        require(originController_ != address(0) && destinationController_ != address(0), "invalid controller");
        originChainId = originChainId_;
        destinationChainId = destinationChainId_;
        originController = originController_;
        destinationController = destinationController_;
        callbackGasLimit = callbackGasLimit_;

        // Top-level Reactive deployment registers the subscription; RVM copies only execute `react`.
        if (!vm) {
            service.subscribe(
                originChainId_,
                originController_,
                uint256(EPOCH_CLOSE_REQUESTED),
                REACTIVE_IGNORE,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            );
        }
    }

    function react(IReactive.LogRecord calldata log) external override vmOnly {
        if (
            log.chain_id != originChainId || log._contract != originController
                || log.topic_0 != uint256(EPOCH_CLOSE_REQUESTED)
        ) {
            return;
        }

        bytes32 eventId = keccak256(abi.encode(log.chain_id, log.tx_hash, log.log_index));
        if (processedLog[eventId]) return;
        processedLog[eventId] = true;

        uint64 epochId = uint64(log.topic_1);
        uint64 callbackNonce = ++nextCallbackNonce;
        bytes memory payload =
            abi.encodeWithSignature("settleEpoch(address,uint64,uint64)", address(this), epochId, callbackNonce);

        emit Callback(destinationChainId, destinationController, callbackGasLimit, payload);
        emit SettlementCallbackRequested(epochId, callbackNonce, eventId);
    }
}
