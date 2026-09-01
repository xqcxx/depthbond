# DepthBond Demo Visualizer

A shared, transaction-backed walkthrough for a single fresh DepthBond testnet deployment. It performs every post-deployment action through RainbowKit wallets and stores public evidence in MongoDB.

## Security

Do not put private keys in this app. Wallets sign each transaction through RainbowKit.

Create `demo-frontend/.env.local` from `.env.example` and set a rotated MongoDB credential:

```bash
MONGODB_URI=<rotated-atlas-connection-string>
MONGODB_DB=depthbond_demo
NEXT_PUBLIC_UNICHAIN_RPC_URL=https://sepolia.unichain.org
REACTIVE_RPC_URL=https://lasna-rpc.rnk.dev/
```

`MONGODB_URI` is server-only. `.env.local` is ignored by git.

## Run Locally

```bash
npm run dev
```

Open `http://localhost:3000` and create a walkthrough by pasting the fresh `deployments/unichain-sepolia.json`, the deployed Reactive RSC address, and the five role addresses.

The app verifies Unichain bytecode and queries Reactive for the RVM ID before it creates the public run URL.

## Fresh Deployments

Use a fresh contract deployment for each public walkthrough. The vault intentionally keeps durable positions committed for multiple epochs, so reusing an old vault would mix previous liquidity and rewards with a new demo.

For a human-paced walkthrough, deploy with longer epochs and small testnet amounts:

```bash
export EPOCH_LENGTH_BLOCKS=300
export MINIMUM_BOND=1000000000000000
export INITIAL_REWARD_BUDGET=1000000000000000
export REWARD_BUDGET_PER_EPOCH=1000000000000000
```

## Walkthrough Actions

1. Verify deployed contracts and the Reactive RSC.
2. Bind the RVM ID from the frontend as the deployer.
3. Fund participant gas, mint mock tokens, and submit approvals.
4. Have Ada and Bao create commitment-backed liquidity positions.
5. Start the epoch from the deployer wallet.
6. Have JIT enter late and exit early.
7. Have the trader perform the real v4 swap.
8. Close the epoch after its deadline and observe Reactive settlement.
9. Have Ada and Bao claim their rewards.

Every confirmed transaction is persisted with its assigned wallet role, receipt block, explanation, and Uniscan link. Interrupted steps resume without submitting a duplicate known action.
