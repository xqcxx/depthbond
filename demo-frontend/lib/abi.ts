export const controllerAbi = [
  { type: "function", name: "activeEpoch", stateMutability: "view", inputs: [], outputs: [{ type: "uint64" }] },
  { type: "function", name: "expectedRvmId", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
  { type: "function", name: "beginEpoch", stateMutability: "nonpayable", inputs: [], outputs: [{ type: "uint64" }] },
  { type: "function", name: "setExpectedRvmId", stateMutability: "nonpayable", inputs: [{ type: "address", name: "rvmId" }], outputs: [] },
  { type: "function", name: "requestEpochClose", stateMutability: "nonpayable", inputs: [{ type: "uint64", name: "epochId" }], outputs: [] },
  { type: "function", name: "getEpoch", stateMutability: "view", inputs: [{ type: "uint64", name: "epochId" }], outputs: [{ type: "uint64", name: "endBlock" }, { type: "uint8", name: "phase" }, { type: "uint256[3]", name: "qualifyingVolume" }] },
  { type: "event", name: "EpochStarted", inputs: [{ indexed: true, type: "uint64", name: "epochId" }, { indexed: false, type: "uint64", name: "endBlock" }], anonymous: false },
  { type: "event", name: "EpochCloseRequested", inputs: [{ indexed: true, type: "uint64", name: "epochId" }], anonymous: false },
  { type: "event", name: "EpochSettled", inputs: [{ indexed: true, type: "uint64", name: "epochId" }, { indexed: true, type: "uint64", name: "callbackNonce" }, { indexed: false, type: "uint256", name: "allocatedRewards" }], anonymous: false },
] as const;

export const vaultAbi = [
  { type: "function", name: "minimumBond", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", name: "rewardReserve", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", name: "epochSettled", stateMutability: "view", inputs: [{ type: "uint64", name: "epochId" }], outputs: [{ type: "bool" }] },
  { type: "function", name: "activeLiquidity", stateMutability: "view", inputs: [{ type: "uint8", name: "rangeId" }], outputs: [{ type: "uint128" }] },
  { type: "function", name: "depositAndCommit", stateMutability: "payable", inputs: [{ type: "uint8", name: "rangeId" }, { type: "uint128", name: "liquidity" }, { type: "uint64", name: "commitmentEndEpoch" }], outputs: [{ type: "uint256", name: "commitmentId" }] },
  { type: "function", name: "claim", stateMutability: "nonpayable", inputs: [{ type: "uint256", name: "commitmentId" }, { type: "uint64", name: "epochId" }], outputs: [{ type: "uint256" }] },
  { type: "function", name: "withdrawBond", stateMutability: "nonpayable", inputs: [], outputs: [] },
  { type: "event", name: "CommitmentCreated", inputs: [{ indexed: true, type: "uint256", name: "commitmentId" }, { indexed: true, type: "address", name: "owner" }, { indexed: true, type: "uint8", name: "rangeId" }, { indexed: false, type: "uint128", name: "liquidity" }, { indexed: false, type: "uint64", name: "enteredEpoch" }, { indexed: false, type: "uint64", name: "commitmentEndEpoch" }, { indexed: false, type: "uint128", name: "bondedAmount" }], anonymous: false },
  { type: "event", name: "CommitmentExited", inputs: [{ indexed: true, type: "uint256", name: "commitmentId" }, { indexed: false, type: "uint256", name: "refund" }, { indexed: false, type: "uint256", name: "penalty" }], anonymous: false },
  { type: "event", name: "RewardClaimed", inputs: [{ indexed: true, type: "uint256", name: "commitmentId" }, { indexed: true, type: "uint64", name: "epochId" }, { indexed: true, type: "address", name: "owner" }, { indexed: false, type: "uint256", name: "amount" }], anonymous: false },
] as const;

export const executorAbi = [
  { type: "function", name: "addLiquidity", stateMutability: "nonpayable", inputs: [{ type: "uint256", name: "commitmentId" }, { type: "uint128", name: "amount0Max" }, { type: "uint128", name: "amount1Max" }], outputs: [] },
  { type: "function", name: "removeLiquidity", stateMutability: "nonpayable", inputs: [{ type: "uint256", name: "commitmentId" }, { type: "uint128", name: "amount0Min" }, { type: "uint128", name: "amount1Min" }], outputs: [] },
  { type: "event", name: "PositionAdded", inputs: [{ indexed: true, type: "uint256", name: "commitmentId" }, { indexed: true, type: "address", name: "owner" }, { indexed: false, type: "uint128", name: "liquidity" }, { indexed: false, type: "uint256", name: "amount0" }, { indexed: false, type: "uint256", name: "amount1" }], anonymous: false },
  { type: "event", name: "PositionRemoved", inputs: [{ indexed: true, type: "uint256", name: "commitmentId" }, { indexed: true, type: "address", name: "owner" }, { indexed: false, type: "uint128", name: "liquidity" }, { indexed: false, type: "uint256", name: "amount0" }, { indexed: false, type: "uint256", name: "amount1" }], anonymous: false },
] as const;

export const tokenAbi = [
  { type: "function", name: "mint", stateMutability: "nonpayable", inputs: [{ type: "address", name: "to" }, { type: "uint256", name: "amount" }], outputs: [] },
  { type: "function", name: "approve", stateMutability: "nonpayable", inputs: [{ type: "address", name: "spender" }, { type: "uint256", name: "amount" }], outputs: [{ type: "bool" }] },
  { type: "function", name: "balanceOf", stateMutability: "view", inputs: [{ type: "address", name: "owner" }], outputs: [{ type: "uint256" }] },
  { type: "function", name: "allowance", stateMutability: "view", inputs: [{ type: "address", name: "owner" }, { type: "address", name: "spender" }], outputs: [{ type: "uint256" }] },
] as const;

export const routerAbi = [
  { type: "function", name: "swap", stateMutability: "nonpayable", inputs: [{ type: "tuple", name: "key", components: [{ type: "address", name: "currency0" }, { type: "address", name: "currency1" }, { type: "uint24", name: "fee" }, { type: "int24", name: "tickSpacing" }, { type: "address", name: "hooks" }] }, { type: "tuple", name: "params", components: [{ type: "bool", name: "zeroForOne" }, { type: "int256", name: "amountSpecified" }, { type: "uint160", name: "sqrtPriceLimitX96" }] }], outputs: [] },
] as const;
