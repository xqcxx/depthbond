import { NextResponse } from "next/server";
import { createPublicClient, http, parseAbiItem } from "viem";
import { unichainRpcUrl } from "@/lib/chain";
import { db } from "@/lib/mongodb";
import type { Address } from "@/lib/types";

export const runtime = "nodejs";

type ReactiveTransaction = { hash: string; number: string; refTx: string; status: number };
const epochSettledEvent = parseAbiItem("event EpochSettled(uint64 indexed epochId, uint64 indexed callbackNonce, uint256 allocatedRewards)");

export async function GET(_: Request, { params }: { params: Promise<{ runId: string }> }) {
  const { runId } = await params;
  const database = await db();
  const run = await database.collection("demoRuns").findOne({ id: runId });
  const close = await database.collection("demoSteps").findOne({ runId, stepId: "request-close" });
  if (!run || !close) return NextResponse.json({ settlement: null });

  const client = createPublicClient({ transport: http(unichainRpcUrl) });
  const fromBlock = BigInt(close.blockNumber);
  const latestBlock = await client.getBlockNumber();
  // Reactive callbacks arrive immediately after the close request. This bounded window also respects public RPC limits.
  const logs = await client.getLogs({
    address: run.deployment.controller as Address,
    event: epochSettledEvent,
    fromBlock,
    toBlock: fromBlock + 9_999n > latestBlock ? latestBlock : fromBlock + 9_999n,
  });
  const settled = logs[0];

  const reactiveResponse = await fetch(process.env.REACTIVE_RPC_URL ?? "https://lasna-rpc.rnk.dev/", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "rnk_getTransactions", params: [run.rvmId, "0x0", "0x100"] }),
  });
  const reactiveBody = (await reactiveResponse.json()) as { result?: ReactiveTransaction[] };
  const reactive = reactiveBody.result?.find((transaction) => transaction.refTx.toLowerCase() === close.transactionHash.toLowerCase() && transaction.status === 1);

  return NextResponse.json({
    settlement: settled && reactive ? {
      closeTransaction: close.transactionHash,
      unichainCallbackTransaction: settled.transactionHash,
      reactiveExecutionHash: reactive.hash,
      reactiveExecutionNumber: Number.parseInt(reactive.number, 16),
      rvmId: run.rvmId,
      rsc: run.rsc,
    } : null,
  });
}
