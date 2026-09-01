// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IEpochController {
    function entryEpoch() external view returns (uint64);
    function canExitWithoutPenalty(uint64 commitmentEndEpoch) external view returns (bool);
}

/// @notice Holds LP commitments, bonds, and epoch-indexed native-token rewards.
/// @dev The configured position executor is the sole path for an active commitment to leave v4 liquidity.
contract DepthBondVault {
    uint8 public constant RANGE_COUNT = 3;
    uint16 public constant EARLY_EXIT_PENALTY_BPS = 2_500;
    uint256 internal constant INDEX_SCALE = 1e18;

    error Unauthorized();
    error InvalidRange();
    error InvalidLiquidity();
    error InsufficientBond();
    error CommitmentTooShort();
    error AlreadyExited();
    error NoRefund();
    error EpochAlreadySnapshotted();
    error EpochNotSettled();
    error NotEligible();
    error AlreadyClaimed();
    error InsufficientRewardReserve();
    error TransferFailed();
    error PositionExecutorAlreadySet();
    error PositionIsActive();
    error PositionNotActive();

    struct Commitment {
        address owner;
        uint128 liquidity;
        uint64 enteredEpoch;
        uint64 commitmentEndEpoch;
        uint128 bondedAmount;
        uint64 exitedEpoch;
        uint8 rangeId;
        bool exited;
    }

    address public immutable owner;
    address public controller;
    address public positionExecutor;
    uint256 public immutable minimumBond;
    uint256 public nextCommitmentId;
    uint256 public rewardReserve;

    mapping(uint256 commitmentId => Commitment) public commitments;
    mapping(uint256 commitmentId => bool) public positionActive;
    mapping(uint8 rangeId => uint128) public activeLiquidity;
    mapping(address account => uint256 amount) public refundableBonds;
    mapping(uint64 epochId => mapping(uint8 rangeId => uint128 liquidity)) public epochLiquidity;
    mapping(uint64 epochId => mapping(uint8 rangeId => uint256 index)) public rewardIndex;
    mapping(uint64 epochId => bool) public epochSettled;
    mapping(uint256 commitmentId => mapping(uint64 epochId => bool)) public claimed;

    event ControllerSet(address indexed controller);
    event PositionExecutorSet(address indexed executor);
    event PositionActivated(uint256 indexed commitmentId);
    event CommitmentCreated(
        uint256 indexed commitmentId,
        address indexed owner,
        uint8 indexed rangeId,
        uint128 liquidity,
        uint64 enteredEpoch,
        uint64 commitmentEndEpoch,
        uint128 bondedAmount
    );
    event CommitmentExited(uint256 indexed commitmentId, uint256 refund, uint256 penalty);
    event EpochSnapshotted(uint64 indexed epochId, uint128[3] liquidity);
    event EpochSettled(uint64 indexed epochId, uint256[3] rewardByRange);
    event RewardClaimed(uint256 indexed commitmentId, uint64 indexed epochId, address indexed owner, uint256 amount);
    event RewardFunded(address indexed funder, uint256 amount);

    modifier onlyController() {
        if (msg.sender != controller) revert Unauthorized();
        _;
    }

    constructor(uint256 minimumBond_) {
        owner = msg.sender;
        minimumBond = minimumBond_;
    }

    function setController(address controller_) external {
        if (msg.sender != owner || controller != address(0) || controller_ == address(0)) revert Unauthorized();
        controller = controller_;
        emit ControllerSet(controller_);
    }

    function setPositionExecutor(address executor_) external {
        if (msg.sender != owner || positionExecutor != address(0) || executor_ == address(0)) {
            revert PositionExecutorAlreadySet();
        }
        positionExecutor = executor_;
        emit PositionExecutorSet(executor_);
    }

    function fundRewards() external payable {
        rewardReserve += msg.value;
        emit RewardFunded(msg.sender, msg.value);
    }

    function depositAndCommit(uint8 rangeId, uint128 liquidity, uint64 commitmentEndEpoch)
        external
        payable
        returns (uint256 commitmentId)
    {
        if (rangeId >= RANGE_COUNT) revert InvalidRange();
        if (liquidity == 0) revert InvalidLiquidity();
        if (msg.value < minimumBond) revert InsufficientBond();

        uint64 enteredEpoch = IEpochController(controller).entryEpoch();
        // End epoch is inclusive, so this commits the LP for at least two epochs.
        if (commitmentEndEpoch < enteredEpoch + 1) revert CommitmentTooShort();

        commitmentId = ++nextCommitmentId;
        commitments[commitmentId] = Commitment({
            owner: msg.sender,
            liquidity: liquidity,
            enteredEpoch: enteredEpoch,
            commitmentEndEpoch: commitmentEndEpoch,
            bondedAmount: uint128(msg.value),
            exitedEpoch: 0,
            rangeId: rangeId,
            exited: false
        });
        activeLiquidity[rangeId] += liquidity;

        emit CommitmentCreated(
            commitmentId, msg.sender, rangeId, liquidity, enteredEpoch, commitmentEndEpoch, uint128(msg.value)
        );
    }

    function exit(uint256 commitmentId) external {
        Commitment storage commitment = commitments[commitmentId];
        if (commitment.owner != msg.sender) revert Unauthorized();
        if (positionActive[commitmentId]) revert PositionIsActive();
        _exit(commitmentId, commitment);
    }

    function activatePosition(uint256 commitmentId) external {
        if (msg.sender != positionExecutor) revert Unauthorized();
        Commitment storage commitment = commitments[commitmentId];
        if (commitment.owner == address(0) || commitment.exited || positionActive[commitmentId]) {
            revert PositionIsActive();
        }
        positionActive[commitmentId] = true;
        emit PositionActivated(commitmentId);
    }

    function preparePositionExit(uint256 commitmentId, address commitmentOwner) external {
        if (msg.sender != positionExecutor) revert Unauthorized();
        Commitment storage commitment = commitments[commitmentId];
        if (commitment.owner != commitmentOwner) revert Unauthorized();
        if (!positionActive[commitmentId]) revert PositionNotActive();
        positionActive[commitmentId] = false;
        _exit(commitmentId, commitment);
    }

    function positionCommitment(uint256 commitmentId)
        external
        view
        returns (address commitmentOwner, uint128 liquidity, uint8 rangeId, bool exited, bool active)
    {
        Commitment storage commitment = commitments[commitmentId];
        return
            (
                commitment.owner,
                commitment.liquidity,
                commitment.rangeId,
                commitment.exited,
                positionActive[commitmentId]
            );
    }

    function withdrawBond() external {
        uint256 amount = refundableBonds[msg.sender];
        if (amount == 0) revert NoRefund();
        refundableBonds[msg.sender] = 0;
        _sendValue(msg.sender, amount);
    }

    function snapshotEpoch(uint64 epochId) external onlyController {
        if (epochLiquidity[epochId][0] != 0 || epochLiquidity[epochId][1] != 0 || epochLiquidity[epochId][2] != 0) {
            revert EpochAlreadySnapshotted();
        }

        uint128[3] memory liquidity;
        for (uint8 rangeId; rangeId < RANGE_COUNT; ++rangeId) {
            liquidity[rangeId] = activeLiquidity[rangeId];
            epochLiquidity[epochId][rangeId] = liquidity[rangeId];
        }
        emit EpochSnapshotted(epochId, liquidity);
    }

    function settleEpoch(uint64 epochId, uint256[3] calldata rewardByRange) external onlyController {
        if (epochSettled[epochId]) revert EpochNotSettled();

        uint256 distributed;
        for (uint8 rangeId; rangeId < RANGE_COUNT; ++rangeId) {
            uint256 reward = rewardByRange[rangeId];
            distributed += reward;
            uint128 liquidity = epochLiquidity[epochId][rangeId];
            if (reward != 0 && liquidity == 0) revert NotEligible();
            if (liquidity != 0) rewardIndex[epochId][rangeId] = reward * INDEX_SCALE / liquidity;
        }
        if (distributed > rewardReserve) revert InsufficientRewardReserve();

        rewardReserve -= distributed;
        epochSettled[epochId] = true;
        emit EpochSettled(epochId, rewardByRange);
    }

    function claim(uint256 commitmentId, uint64 epochId) external returns (uint256 amount) {
        Commitment memory commitment = commitments[commitmentId];
        if (commitment.owner != msg.sender) revert Unauthorized();
        if (!epochSettled[epochId]) revert EpochNotSettled();
        if (claimed[commitmentId][epochId]) revert AlreadyClaimed();
        if (commitment.enteredEpoch >= epochId || (commitment.exitedEpoch != 0 && commitment.exitedEpoch <= epochId)) {
            revert NotEligible();
        }

        claimed[commitmentId][epochId] = true;
        amount = uint256(commitment.liquidity) * rewardIndex[epochId][commitment.rangeId] / INDEX_SCALE;
        if (amount != 0) _sendValue(msg.sender, amount);
        emit RewardClaimed(commitmentId, epochId, msg.sender, amount);
    }

    function _sendValue(address recipient, uint256 amount) private {
        (bool success,) = recipient.call{value: amount}("");
        if (!success) revert TransferFailed();
    }

    function _exit(uint256 commitmentId, Commitment storage commitment) private {
        if (commitment.exited) revert AlreadyExited();

        commitment.exited = true;
        activeLiquidity[commitment.rangeId] -= commitment.liquidity;

        uint256 penalty;
        if (!IEpochController(controller).canExitWithoutPenalty(commitment.commitmentEndEpoch)) {
            penalty = uint256(commitment.bondedAmount) * EARLY_EXIT_PENALTY_BPS / 10_000;
            rewardReserve += penalty;
        }
        uint256 refund = uint256(commitment.bondedAmount) - penalty;
        refundableBonds[commitment.owner] += refund;

        uint64 currentEpoch = IEpochController(controller).entryEpoch();
        commitment.exitedEpoch = currentEpoch;
        emit CommitmentExited(commitmentId, refund, penalty);
    }
}
