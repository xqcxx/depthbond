"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { FormEvent, useState } from "react";
import type { Deployment, Roles } from "@/lib/types";

const fieldNames = ["deployer", "ada", "bao", "jit", "trader"] as const;

export default function ManualDemoSetupPage() {
  const router = useRouter();
  const [title, setTitle] = useState("DepthBond reliability walkthrough");
  const [deploymentJson, setDeploymentJson] = useState("");
  const [rsc, setRsc] = useState("");
  const [roles, setRoles] = useState<Record<(typeof fieldNames)[number], string>>({ deployer: "", ada: "", bao: "", jit: "", trader: "" });
  const [notice, setNotice] = useState("");

  async function createRun(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    try {
      setNotice("Verifying Unichain deployment and Reactive RSC...");
      const deployment = JSON.parse(deploymentJson) as Deployment;
      const response = await fetch("/api/runs", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ title, deployment, rsc, roles: roles as Roles }) });
      const result = (await response.json()) as { id?: string; error?: string };
      if (!response.ok || !result.id) throw new Error(result.error ?? "Could not create the walkthrough.");
      router.push(`/demo/${result.id}`);
    } catch (error) { setNotice(error instanceof Error ? error.message : "Could not create the walkthrough."); }
  }

  return <main className="landing"><section className="landing-copy"><Link className="back-link" href="/">← Back to DepthBond</Link><p className="eyebrow">Manual configuration</p><h1>Bring your own<br /><em>deployment.</em></h1><p>Use this setup when you want to run the walkthrough against a different Unichain deployment or wallet set.</p></section><form className="import-card" onSubmit={createRun}><div><p className="eyebrow">Manual / Register deployment</p><h2>Start a custom walkthrough</h2></div><label>Walkthrough title<input value={title} onChange={(event) => setTitle(event.target.value)} required /></label><label>Unichain deployment JSON<textarea value={deploymentJson} onChange={(event) => setDeploymentJson(event.target.value)} placeholder="Paste deployments/unichain-sepolia.json" required /></label><label>Reactive RSC address<input value={rsc} onChange={(event) => setRsc(event.target.value)} placeholder="0x..." required /></label><div className="role-grid">{fieldNames.map((role) => <label key={role}>{role}<input value={roles[role]} onChange={(event) => setRoles({ ...roles, [role]: event.target.value })} placeholder="0x..." required /></label>)}</div><button type="submit">Verify deployment and create run</button>{notice && <p className="notice">{notice}</p>}</form></main>;
}
