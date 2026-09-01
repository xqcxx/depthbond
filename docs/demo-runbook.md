# DepthBond Demo Runbook

## Prerequisites

- Fund the deployment wallet and the Ada, Bao, JIT, and trader wallets on Unichain Sepolia.
- Set `PRIVATE_KEY`, `ADA_PRIVATE_KEY`, `BAO_PRIVATE_KEY`, `JIT_PRIVATE_KEY`, and `TRADER_PRIVATE_KEY` in the shell environment.
- Set the canonical Unichain Sepolia `POOL_MANAGER`, the Reactive Callback Proxy as `CALLBACK_PROXY`, and RPC URLs as `UNICHAIN_RPC_URL` and `REACTIVE_RPC_URL`.

## Deploy

1. Deploy the Unichain contracts:

```bash
POOL_MANAGER=<pool-manager> CALLBACK_PROXY=<callback-proxy> \
  forge script script/DeployUnichain.s.sol:DeployUnichainScript --rpc-url "$UNICHAIN_RPC_URL" --broadcast
```

2. Read `deployments/unichain-sepolia.json` and provide its controller address to the Reactive deployment. Use `forge create` because Reactive's subscription service does not behave normally during Foundry script simulation:

```bash
export EPOCH_CONTROLLER=<controller>
forge create src/reactive/DepthBondRSC.sol:DepthBondRSC \
  --rpc-url "$REACTIVE_RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --value 0.01ether \
  --broadcast \
  --verify \
  --verifier sourcify \
  --constructor-args \
    1301 \
    1301 \
    "$EPOCH_CONTROLLER" \
    "$EPOCH_CONTROLLER" \
    500000
```

3. After Reactive reports the ReactVM ID, set it on Unichain:

```bash
EPOCH_CONTROLLER=<controller> REACTIVE_RVM_ID=<reactvm-id> \
  forge script script/ConfigureRvm.s.sol:ConfigureRvmScript --rpc-url "$UNICHAIN_RPC_URL" --broadcast
```

## Seed And Run

1. Seed the four demo wallets. This is valid only for the `MockERC20` tokens deployed by the Unichain script:

```bash
TOKEN0=<token0> TOKEN1=<token1> EXECUTOR=<executor> SWAP_ROUTER=<swap-router> \
  forge script script/SeedDemo.s.sol:SeedDemoScript --rpc-url "$UNICHAIN_RPC_URL" --broadcast
```

2. Run the scenario. It creates Ada and Bao commitments before epoch one, adds and immediately removes JIT liquidity after the epoch starts, then executes an actual v4 swap:

```bash
VAULT=<vault> EPOCH_CONTROLLER=<controller> EXECUTOR=<executor> SWAP_ROUTER=<swap-router> \
TOKEN0=<token0> TOKEN1=<token1> HOOK=<hook> \
  forge script script/RunScenario.s.sol:RunScenarioScript --rpc-url "$UNICHAIN_RPC_URL" --broadcast
```

3. Inspect `deployments/scenario.json`; wait until its `epochEndBlock` has passed. Check readiness at any point:

```bash
VAULT=<vault> EPOCH_CONTROLLER=<controller> forge script script/ScenarioStatus.s.sol:ScenarioStatusScript --rpc-url "$UNICHAIN_RPC_URL"
```

4. Request close after the deadline:

```bash
REQUEST_CLOSE=true CLOSER_PRIVATE_KEY=<private-key> VAULT=<vault> EPOCH_CONTROLLER=<controller> \
  forge script script/CloseAndClaim.s.sol:CloseAndClaimScript --rpc-url "$UNICHAIN_RPC_URL" --broadcast
```

5. Wait for the Reactive callback. `ScenarioStatusScript` reports `phase = 3` and `settled = true` after settlement. Claim with each LP wallet:

```bash
CLAIM_ADA=true ADA_PRIVATE_KEY=<private-key> ADA_COMMITMENT=<id> VAULT=<vault> EPOCH_CONTROLLER=<controller> \
  forge script script/CloseAndClaim.s.sol:CloseAndClaimScript --rpc-url "$UNICHAIN_RPC_URL" --broadcast
```

## Frontend

The deployment and scenario scripts copy JSON records into `frontend/public/deployments/`. Start the console after a deployment:

```bash
cd frontend
NEXT_PUBLIC_UNICHAIN_RPC_URL="$UNICHAIN_RPC_URL" npm run dev
```

The console only submits `requestEpochClose` and `claim` through the connected wallet. It never simulates protocol state locally. All other scenario actions use Foundry scripts so private keys stay outside the browser.

## Evidence Checklist

- Capture the source `EpochCloseRequested` transaction.
- Capture the Reactive callback and destination `EpochSettled` transaction.
- Capture `SwapObserved`, JIT `CommitmentExited`, and Ada/Bao `RewardClaimed` events.
- Show the failed direct active-position exit from the local test or a controlled testnet attempt.
