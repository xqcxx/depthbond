# DepthBond

DepthBond is an epoch-based managed-liquidity prototype. LPs commit liquidity and a separate native-token bond; only liquidity present before an epoch opens can earn that epoch's reward. An early exit forfeits 25% of its bond to the reward reserve, while an out-of-range LP is simply unpaid rather than slashed.

## Implemented Partner Integrations

### Unichain

DepthBond is deployed against Unichain Sepolia's Uniswap v4 `PoolManager` (`chain ID 1301`). The integration is implemented in:

- `src/hook/DepthBondHook.sol`: Uniswap v4 `BaseHook` callbacks for post-swap observation and managed liquidity authorization.
- `src/v4/DepthBondPositionExecutor.sol`: v4 unlock-callback position management and ERC-20 settlement.
- `src/v4/DepthBondSwapRouter.sol`: v4 swap settlement callback.
- `src/deploy/DepthBondHookFactory.sol`: CREATE2 hook deployment with v4 permission bits.
- `script/DeployUnichain.s.sol`: Unichain deployment, pool initialization, and contract wiring.
- `test/DepthBondRealV4Lifecycle.t.sol`: local lifecycle test against the upstream v4 `PoolManager`.

### Reactive Network

DepthBond uses Reactive Lasna (`chain ID 5318007`) for epoch-close automation. The integration is implemented in:

- `src/reactive/DepthBondRSC.sol`: subscribes to `EpochCloseRequested` and emits the authenticated settlement callback.
- `src/core/EpochController.sol`: validates the Callback Proxy, expected RVM ID, and single-use callback nonce.
- `script/DeployReactive.s.sol`: Reactive deployment configuration for the RSC.
- `script/ConfigureRvm.s.sol`: one-time binding of the RVM ID on Unichain.
- `test/DepthBondIntegration.t.sol`: RSC event deduplication and callback authorization tests.

## Current Implementation

The initial Foundry core implements:

- Three standard liquidity ranges with snapshot-based, per-range reward indices.
- Commitment records and bonded exits with a 25% deterministic early-exit penalty.
- Permissionless epoch close requests after an explicit block deadline.
- Reactive-style settlement authentication: callback proxy, RVM identity, and single-use callback nonce checks.
- A lifecycle test covering durable, late, inactive, and early-exit LP outcomes.
- A v4 `BaseHook` implementation that observes post-swap ticks, records qualifying volume for every active standard range, and restricts liquidity removal to the managed vault.
- A Reactive RSC that subscribes to `EpochCloseRequested` and emits a single authenticated `settleEpoch` callback per source log.
- A v4 unlock-callback executor that creates one commitment-bound position, settles its ERC-20 token deltas, and cannot remove it until the vault applies the commitment exit rule.
- A complete local lifecycle test using upstream `PoolManager`: pool initialization, managed liquidity, an actual swap observed by the mined hook, Reactive callback identity, settlement, and LP reward claim.

The core records liquidity amounts at commitment time; `DepthBondPositionExecutor` uses that amount as the actual v4 position liquidity and binds the pool position salt to the commitment ID. ERC-20 principal is transferred directly from the LP to the PoolManager during the v4 unlock callback. Native-currency pools and pooled/multi-LP position aggregation are not implemented.

## Local Test

```bash
forge test
```

The project uses Solidity `0.8.26`, matching the pinned upstream v4 core release.

## Testnet Deployment

Deploy the Unichain contracts with the canonical Unichain Sepolia PoolManager and Callback Proxy. Omit `TOKEN0` and `TOKEN1` to deploy two demo tokens. The deployed Unichain contract addresses are recorded in [`deployments/unichain-sepolia.json`](deployments/unichain-sepolia.json).

```bash
POOL_MANAGER=<unichain-pool-manager> CALLBACK_PROXY=<unichain-callback-proxy> \
  forge script script/DeployUnichain.s.sol:DeployUnichainScript --rpc-url "$UNICHAIN_RPC_URL" --broadcast
```

The Reactive RSC deployment is:

- RSC: `0x478e2d976758a261252C262eb68E84273188E6ED`
- RVM ID: `0x599282387bcec523e9d10711ee8b396d7644ce13`

Deploy the RSC on Reactive Lasna after setting `EPOCH_CONTROLLER` to the Unichain controller. Use `forge create` because Reactive subscription registration does not simulate normally through a Foundry script.

```bash
forge create src/reactive/DepthBondRSC.sol:DepthBondRSC \
  --rpc-url "$REACTIVE_RPC_URL" --private-key "$PRIVATE_KEY" \
  --value 0.01ether --broadcast --verify --verifier sourcify \
  --constructor-args 1301 1301 "$EPOCH_CONTROLLER" "$EPOCH_CONTROLLER" 500000
```

Bind the deployed RVM ID from the original Unichain deployer:

```bash
EPOCH_CONTROLLER=<unichain-controller> REACTIVE_RVM_ID=0x599282387bcec523e9d10711ee8b396d7644ce13 \
  forge script script/ConfigureRvm.s.sol:ConfigureRvmScript --rpc-url "$UNICHAIN_RPC_URL" --broadcast
```

## Demo Scenario

For mock tokens, fund and approve the four demo wallets first. This writes wallet addresses to `deployments/demo-accounts.json`.

```bash
TOKEN0=<token0> TOKEN1=<token1> EXECUTOR=<executor> SWAP_ROUTER=<swap-router> \
  forge script script/SeedDemo.s.sol:SeedDemoScript --rpc-url "$UNICHAIN_RPC_URL" --broadcast
```

`RunScenarioScript` adds Ada and Bao before epoch one, adds then removes JIT liquidity after the epoch opens, and submits an on-chain swap. It writes commitment IDs and the epoch close block to `deployments/scenario.json`.

```bash
VAULT=<vault> EPOCH_CONTROLLER=<controller> EXECUTOR=<executor> SWAP_ROUTER=<swap-router> \
TOKEN0=<token0> TOKEN1=<token1> HOOK=<hook> \
  forge script script/RunScenario.s.sol:RunScenarioScript --rpc-url "$UNICHAIN_RPC_URL" --broadcast
```

After the recorded close block, call `requestEpochClose(1)`, wait for the Reactive callback, then claim using the LP wallets. These steps are separate because testnet block production and callback delivery cannot be safely simulated as immediate script calls.

## Demo Frontend

`demo-frontend/` is a Next.js and viem scenario console. It verifies the supplied deployment data, polls the vault/controller, indexes recent hook and settlement events, and submits only real close/claim wallet transactions.

```bash
cd demo-frontend
npm install
NEXT_PUBLIC_UNICHAIN_RPC_URL="$UNICHAIN_RPC_URL" npm run dev
```

Use `docs/demo-runbook.md` for the complete deployment, scenario, close, callback, claim, and recording sequence.

Live demo run: https://demo-frontend-khaki-nu.vercel.app/demo/ec063867-641b-4eac-8dac-df2386f0b04a

## Local Dependencies

The v4 and Reactive sources are checked into `lib/` at these revisions:

- `v4-core`: `46c6834698c48bc4a463a86d8420f4eb1d7f3b75`
- `v4-periphery`: `07336f2144f522874e2c3c85e04d1d3f8d5fa471`
- `v4-hooks-public`: `f2aa843e266f8f9b34fdaf94ffb72eda5d9204f9`
- `reactive-lib`: `f6990ce3526928d039fec78855b2004ff8d65c9f`
- `forge-std`: `467ffd422ca01fed5797a4c766a1e4e3a5327902`

## Demo Parameters

The test uses a 10-block epoch, a 5 ETH reward budget, 50 units of Ada liquidity in an active medium range, and 50 units of Bao liquidity in an inactive tight range. A late JIT LP posts a 4 ETH bond, exits early, and contributes a 1 ETH penalty to the reserve. Ada claims 5 ETH; Bao claims zero; the JIT LP is ineligible for epoch 1.
