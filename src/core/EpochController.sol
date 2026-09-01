// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IDepthBondVault {
    function snapshotEpoch(uint64 epochId) external;
    function epochLiquidity(uint64 epochId, uint8 rangeId) external view returns (uint128);
    function rewardReserve() external view returns (uint256);
    function settleEpoch(uint64 epochId, uint256[3] calldata rewardByRange) external;
}

/// @notice Owns epoch boundaries and accepts authenticated Reactive settlement callbacks.
contract EpochController {
    uint8 internal constant RANGE_COUNT = 3;

    enum Phase {
        None,
        Open,
        CloseRequested,
        Settled
    }

    error Unauthorized();
    error InvalidEpoch();
    error EpochStillOpen();
    error EpochNotOpen();
    error CallbackAlreadyUsed();
    error RvmIdAlreadySet();

    struct Epoch {
        uint64 endBlock;
        Phase phase;
        uint256[3] qualifyingVolume;
    }

    address public immutable owner;
    address public immutable callbackProxy;
    address public expectedRvmId;
    IDepthBondVault public immutable vault;
    uint64 public immutable epochLength;
    uint256 public immutable rewardBudgetPerEpoch;
    uint64 public activeEpoch;
    address public observer;

    mapping(uint64 epochId => Epoch) internal epochs;
    mapping(uint64 callbackNonce => bool) public callbackNonceUsed;

    event ObserverSet(address indexed observer);
    event ExpectedRvmIdSet(address indexed rvmId);
    event EpochStarted(uint64 indexed epochId, uint64 endBlock);
    event QualifyingSwapRecorded(uint64 indexed epochId, uint8 indexed rangeId, uint256 volume);
    event EpochCloseRequested(uint64 indexed epochId);
    event EpochSettled(uint64 indexed epochId, uint64 indexed callbackNonce, uint256 allocatedRewards);

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    modifier onlyObserver() {
        if (msg.sender != observer) revert Unauthorized();
        _;
    }

    constructor(
        IDepthBondVault vault_,
        address callbackProxy_,
        address expectedRvmId_,
        uint64 epochLength_,
        uint256 rewardBudgetPerEpoch_
    ) {
        if (address(vault_) == address(0) || callbackProxy_ == address(0) || epochLength_ == 0) {
            revert Unauthorized();
        }
        owner = msg.sender;
        observer = msg.sender;
        vault = vault_;
        callbackProxy = callbackProxy_;
        expectedRvmId = expectedRvmId_;
        epochLength = epochLength_;
        rewardBudgetPerEpoch = rewardBudgetPerEpoch_;
    }

    function setObserver(address observer_) external onlyOwner {
        if (observer_ == address(0)) revert Unauthorized();
        observer = observer_;
        emit ObserverSet(observer_);
    }

    function setExpectedRvmId(address rvmId_) external onlyOwner {
        if (expectedRvmId != address(0) || rvmId_ == address(0)) revert RvmIdAlreadySet();
        expectedRvmId = rvmId_;
        emit ExpectedRvmIdSet(rvmId_);
    }

    function beginEpoch() external onlyOwner returns (uint64 epochId) {
        if (activeEpoch != 0 && epochs[activeEpoch].phase != Phase.Settled) revert EpochNotOpen();

        epochId = ++activeEpoch;
        Epoch storage epochData = epochs[epochId];
        epochData.endBlock = uint64(block.number) + epochLength;
        epochData.phase = Phase.Open;
        vault.snapshotEpoch(epochId);
        emit EpochStarted(epochId, epochData.endBlock);
    }

    /// @notice Temporary hook adapter. The v4 hook will become this contract's configured observer.
    function recordQualifyingSwap(uint64 epochId, uint8 rangeId, uint256 volume) external onlyObserver {
        if (rangeId >= RANGE_COUNT || epochs[epochId].phase != Phase.Open) revert EpochNotOpen();
        epochs[epochId].qualifyingVolume[rangeId] += volume;
        emit QualifyingSwapRecorded(epochId, rangeId, volume);
    }

    function requestEpochClose(uint64 epochId) external {
        Epoch storage epochData = epochs[epochId];
        if (epochData.phase != Phase.Open) revert EpochNotOpen();
        if (block.number <= epochData.endBlock) revert EpochStillOpen();
        epochData.phase = Phase.CloseRequested;
        emit EpochCloseRequested(epochId);
    }

    /// @dev The first argument is injected by Reactive and identifies the RSC.
    function settleEpoch(address rvmId, uint64 epochId, uint64 callbackNonce) external {
        if (msg.sender != callbackProxy || rvmId != expectedRvmId || rvmId == address(0)) revert Unauthorized();
        if (callbackNonceUsed[callbackNonce]) revert CallbackAlreadyUsed();

        Epoch storage epochData = epochs[epochId];
        if (epochData.phase != Phase.CloseRequested) revert EpochNotOpen();
        callbackNonceUsed[callbackNonce] = true;

        uint256 totalVolume;
        for (uint8 rangeId; rangeId < RANGE_COUNT; ++rangeId) {
            if (vault.epochLiquidity(epochId, rangeId) != 0) totalVolume += epochData.qualifyingVolume[rangeId];
        }

        uint256[3] memory rewards;
        uint256 budget = rewardBudgetPerEpoch;
        uint256 reserve = vault.rewardReserve();
        if (budget > reserve) budget = reserve;
        if (totalVolume != 0) {
            for (uint8 rangeId; rangeId < RANGE_COUNT; ++rangeId) {
                if (vault.epochLiquidity(epochId, rangeId) != 0) {
                    rewards[rangeId] = budget * epochData.qualifyingVolume[rangeId] / totalVolume;
                }
            }
        }

        epochData.phase = Phase.Settled;
        vault.settleEpoch(epochId, rewards);
        emit EpochSettled(epochId, callbackNonce, budget);
    }

    function entryEpoch() external view returns (uint64) {
        if (activeEpoch == 0) return 0;
        if (epochs[activeEpoch].phase == Phase.Open && block.number <= epochs[activeEpoch].endBlock) {
            return activeEpoch;
        }
        return activeEpoch + 1;
    }

    function isEpochOpen() external view returns (bool) {
        return
            activeEpoch != 0 && epochs[activeEpoch].phase == Phase.Open && block.number <= epochs[activeEpoch].endBlock;
    }

    function canExitWithoutPenalty(uint64 commitmentEndEpoch) external view returns (bool) {
        if (activeEpoch == 0) return true;
        return activeEpoch > commitmentEndEpoch
            || (activeEpoch == commitmentEndEpoch && epochs[activeEpoch].phase != Phase.Open);
    }

    function getEpoch(uint64 epochId)
        external
        view
        returns (uint64 endBlock, Phase phase, uint256[3] memory qualifyingVolume)
    {
        Epoch storage stored = epochs[epochId];
        return (stored.endBlock, stored.phase, stored.qualifyingVolume);
    }
}
