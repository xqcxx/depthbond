import { NextResponse } from "next/server";
import { db } from "@/lib/mongodb";
import { verifyTransaction } from "@/lib/server";
import type { Address, Roles } from "@/lib/types";

export const runtime = "nodejs";

type StepBody = {
  stepId: string;
  actor: keyof Roles;
  transactionHash: Address;
  eventSummary: string;
  metadata?: Record<string, string>;
};

export async function POST(request: Request, { params }: { params: Promise<{ runId: string }> }) {
  try {
    const { runId } = await params;
    const body = (await request.json()) as StepBody;
    if (!body.stepId || !body.actor || !body.transactionHash || !body.eventSummary) throw new Error("Incomplete step evidence.");

    const database = await db();
    const run = await database.collection("demoRuns").findOne({ id: runId });
    if (!run) throw new Error("Demo run not found.");

    const { receipt, transaction } = await verifyTransaction(body.transactionHash);
    const expectedActor = (run.roles as Roles)[body.actor];
    if (!expectedActor || transaction.from.toLowerCase() !== expectedActor.toLowerCase()) {
      throw new Error("Transaction sender does not match this step's assigned demo role.");
    }
    const existing = await database.collection("demoSteps").findOne({ runId, stepId: body.stepId });
    if (existing) return NextResponse.json(existing, { status: 200 });

    const step = {
      runId,
      stepId: body.stepId,
      actor: body.actor,
      transactionHash: body.transactionHash,
      blockNumber: receipt.blockNumber.toString(),
      eventSummary: body.eventSummary,
      metadata: body.metadata ?? {},
      createdAt: new Date().toISOString(),
    };
    await database.collection("demoSteps").insertOne(step);
    return NextResponse.json(step, { status: 201 });
  } catch (error) {
    return NextResponse.json({ error: error instanceof Error ? error.message : "Could not save step evidence." }, { status: 400 });
  }
}
