"use client";

import Link from "next/link";
import { useEffect, useRef, useState } from "react";
import { demoDeployment, demoRoles, demoRsc } from "@/lib/demo-config";

export default function DemoLauncher() {
  const started = useRef(false);
  const [notice, setNotice] = useState("Loading the preconfigured DepthBond demo...");

  useEffect(() => {
    if (started.current) return;
    started.current = true;
    void fetch("/api/runs", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ title: "DepthBond reliability walkthrough", deployment: demoDeployment, rsc: demoRsc, roles: demoRoles }),
    })
      .then(async (response) => {
        const result = (await response.json()) as { id?: string; error?: string };
        if (!response.ok || !result.id) throw new Error(result.error ?? "Could not load the demo.");
        window.location.replace(`/demo/${result.id}`);
      })
      .catch((error) => setNotice(error instanceof Error ? error.message : "Could not load the demo."));
  }, []);

  return <main className="demo-launcher"><div className="demo-launcher-mark"><span>DB</span><i /></div><p className="eyebrow">DepthBond / Unichain Sepolia</p><h1>{notice}</h1><p>Preparing the live contracts, demo wallets, and Reactive settlement identity.</p><div className="loader-line"><span /></div><Link href="/demo/setup">Use a custom deployment instead →</Link></main>;
}
