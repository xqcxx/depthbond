import { NextResponse } from "next/server";
import { randomUUID } from "node:crypto";
import { db } from "@/lib/mongodb";
import { rvmIdFor, verifyDeployment } from "@/lib/server";
import type { Address, Deployment, Roles } from "@/lib/types";

export const runtime = "nodejs";

type CreateRunBody = { title: string; deployment: Deployment; rsc: Address; roles: Roles };

const deploymentFields: (keyof Deployment)[] = ["vault", "controller", "hook", "hookFactory", "executor", "swapRouter", "token0", "token1"];
const roleFields: (keyof Roles)[] = ["deployer", "ada", "bao", "jit", "trader"];

function isAddress(value: unknown): value is Address {
  return typeof value === "string" && /^0x[\da-fA-F]{40}$/.test(value);
}

function validate(body: CreateRunBody) {
  if (!body.title?.trim()) throw new Error("A run title is required.");
  const invalid = [
    !isAddress(body.rsc) && "Reactive RSC address",
    ...deploymentFields.filter((field) => !isAddress(body.deployment?.[field])).map((field) => `deployment.${field}`),
    ...roleFields.filter((field) => !isAddress(body.roles?.[field])).map((field) => `role.${field}`),
  ].filter(Boolean);
  if (invalid.length) throw new Error(`Invalid address: ${invalid.join(", ")}.`);
}

export async function POST(request: Request) {
  try {
    const body = (await request.json()) as CreateRunBody;
    validate(body);
    await verifyDeployment(body.deployment);
    const rvmId = await rvmIdFor(body.rsc);
    const run = {
      id: randomUUID(),
      title: body.title.trim(),
      deployment: body.deployment,
      rsc: body.rsc,
      rvmId,
      roles: body.roles,
      createdAt: new Date().toISOString(),
    };
    await (await db()).collection("demoRuns").insertOne(run);
    return NextResponse.json(run, { status: 201 });
  } catch (error) {
    return NextResponse.json({ error: error instanceof Error ? error.message : "Could not create demo run." }, { status: 400 });
  }
}
