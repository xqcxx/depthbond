import { NextResponse } from "next/server";
import { db } from "@/lib/mongodb";

export const runtime = "nodejs";

export async function GET(_: Request, { params }: { params: Promise<{ runId: string }> }) {
  const { runId } = await params;
  const database = await db();
  const run = await database.collection("demoRuns").findOne({ id: runId }, { projection: { _id: 0 } });
  if (!run) return NextResponse.json({ error: "Demo run not found." }, { status: 404 });
  const steps = await database.collection("demoSteps").find({ runId }, { projection: { _id: 0, runId: 0 } }).sort({ createdAt: 1 }).toArray();
  return NextResponse.json({ ...run, steps });
}
