# DepthBond Core Architecture

This implementation connects the deterministic accounting layer to a v4 event hook and a Reactive Network coordinator. The managed position executor is the remaining v4 component.

```text
LP -> DepthBondVault.depositAndCommit() -> commitment + bond
LP -> DepthBondPositionExecutor.addLiquidity() -> v4 position salted by commitment ID
v4 DepthBondHook.afterSwap() -> post-swap tick -> EpochController.recordQualifyingSwap() -> range volume
Anyone -> EpochController.requestEpochClose() -> CloseRequested
Reactive RSC -> Callback Proxy -> EpochController.settleEpoch(rvmId, epochId, nonce)
                                      -> DepthBondVault settles reward indices
LP -> DepthBondVault.claim()
```

`DepthBondVault` snapshots total active liquidity in each of three standard ranges when an epoch begins. Settlement only distributes the fixed reward budget to ranges that both had a snapshot and observed qualifying volume. Each LP claims against the resulting per-epoch index, avoiding settlement-time iteration over LP addresses.

`DepthBondHook` uses the upstream v4 `BaseHook`. It registers `afterAddLiquidity`, `beforeRemoveLiquidity`, `afterRemoveLiquidity`, and `afterSwap`; therefore it must be CREATE2-mined for those permission bits. After each swap, it reads the pool's actual post-swap tick through v4 `StateLibrary` and records the amount against every standard range containing that tick. The hook only accepts managed-vault liquidity removals.

`DepthBondPositionExecutor` is the managed-vault boundary for real v4 liquidity. It is the only configured vault executor, opens the PoolManager with `unlock`, and adds/removes exactly the committed liquidity under `bytes32(commitmentId)` as the position salt. During adds it validates actual negative deltas against LP-provided maxima and transfers ERC-20 funds directly to the PoolManager. During removes it validates minimum output, takes credits to the LP, then atomically marks the commitment exited in `DepthBondVault`; direct vault exits are rejected while the position remains active.

`DepthBondHookFactory` solves the hook/executor deployment cycle. It mines the hook's CREATE2 salt with its permissions and constructor bytes, deploys an initially unbound hook, and assigns its immutable configuration authority to the caller. The caller deploys the executor with that hook address and performs the hook's one-time executor binding. This is safer than accepting an arbitrary post-deployment hook address or weakening the hook's `beforeRemoveLiquidity` authorization.

`DepthBondRSC` uses `reactive-lib` to subscribe to the controller's `EpochCloseRequested(uint64)` event. On its ReactVM instance, it deduplicates the source log and emits a callback targeting `settleEpoch(address,uint64,uint64)`. The destination controller remains the final authorization boundary: it requires the configured Callback Proxy, the RVM address injected as the first argument, and an unused callback nonce.

The local `DepthBondRealV4Lifecycle` test runs this architecture against the upstream v4 `PoolManager`, not a PoolManager mock. It initializes the hook-bound pool, adds ERC-20 liquidity through the executor, performs an unlocked swap through a settlement router, asserts that `afterSwap` credited qualifying volume, then sends the RSC's callback identity through the callback-proxy boundary to settle and claim the epoch reward.
