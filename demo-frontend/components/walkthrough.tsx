"use client";

import { ConnectButton } from "@rainbow-me/rainbowkit";
import { useEffect, useState } from "react";
import { createPublicClient, http, maxUint128, maxUint256, parseEventLogs } from "viem";
import { useAccount, useSendTransaction, useSwitchChain, useWriteContract } from "wagmi";
import { controllerAbi, executorAbi, routerAbi, tokenAbi, vaultAbi } from "@/lib/abi";
import { transactionUrl, unichainRpcUrl, unichainSepolia } from "@/lib/chain";
import type { DemoRun, Roles, StepRecord } from "@/lib/types";

const publicClient = createPublicClient({ chain: unichainSepolia, transport: http(unichainRpcUrl) });
const mintAmount = 10n ** 30n;
const tradeAmount = 10n ** 15n;
const priceLimit = 4_295_128_740n;

type ChainState = { block: bigint; epoch: bigint; phase: number; endBlock: bigint; reserve: bigint; minimumBond: bigint; settled: boolean; expectedRvmId: string };
type SettlementEvidence = { closeTransaction: string; unichainCallbackTransaction: string; reactiveExecutionHash: string; reactiveExecutionNumber: number; rvmId: string; rsc: string };

const roleLabel: Record<keyof Roles, string> = { deployer: "Deployer", ada: "Ada", bao: "Bao", jit: "JIT LP", trader: "Trader" };
const phaseLabel = ["No epoch", "Open", "Close requested", "Settled"];

export function Walkthrough({ runId }: { runId: string }) {
  const [run, setRun] = useState<DemoRun | null>(null);
  const [state, setState] = useState<ChainState | null>(null);
  const [settlement, setSettlement] = useState<SettlementEvidence | null>(null);
  const [notice, setNotice] = useState("Loading shared walkthrough...");
  const { address, chainId, isConnected } = useAccount();
  const { switchChainAsync } = useSwitchChain();
  const { writeContractAsync } = useWriteContract();
  const { sendTransactionAsync } = useSendTransaction();

  const reload = async () => {
    const response = await fetch(`/api/runs/${runId}`, { cache: "no-store" });
    const result = (await response.json()) as DemoRun & { error?: string };
    if (!response.ok) throw new Error(result.error ?? "Could not load this demo run.");
    setRun(result);
    const settlementResponse = await fetch(`/api/runs/${runId}/settlement`, { cache: "no-store" });
    if (settlementResponse.ok) {
      const settlementResult = (await settlementResponse.json()) as { settlement: SettlementEvidence | null };
      setSettlement(settlementResult.settlement);
    }
    const [block, epoch, reserve, minimumBond, expectedRvmId] = await Promise.all([
      publicClient.getBlockNumber(),
      publicClient.readContract({ address: result.deployment.controller, abi: controllerAbi, functionName: "activeEpoch" }),
      publicClient.readContract({ address: result.deployment.vault, abi: vaultAbi, functionName: "rewardReserve" }),
      publicClient.readContract({ address: result.deployment.vault, abi: vaultAbi, functionName: "minimumBond" }),
      publicClient.readContract({ address: result.deployment.controller, abi: controllerAbi, functionName: "expectedRvmId" }),
    ]);
    const epochData = epoch === 0n
      ? [0n, 0, [0n, 0n, 0n]] as const
      : await publicClient.readContract({ address: result.deployment.controller, abi: controllerAbi, functionName: "getEpoch", args: [epoch] });
    const settled = epoch !== 0n && await publicClient.readContract({ address: result.deployment.vault, abi: vaultAbi, functionName: "epochSettled", args: [epoch] });
    setState({ block, epoch, endBlock: epochData[0], phase: epochData[1], reserve, minimumBond, settled, expectedRvmId });
  };

  useEffect(() => {
    void reload().then(() => setNotice("Live Unichain state loaded.")).catch((error) => setNotice(error.message));
    const timer = window.setInterval(() => void reload().catch(() => undefined), 12_000);
    return () => window.clearInterval(timer);
  }, [runId]);

  const completed = (stepId: string) => Boolean(run?.steps.some((step) => step.stepId === stepId));
  const step = (stepId: string) => run?.steps.find((entry) => entry.stepId === stepId);
  const commitmentId = (role: "ada" | "bao" | "jit") => step(`commit-${role}`)?.metadata?.commitmentId;

  async function requireRole(role: keyof Roles) {
    if (!run || !isConnected || !address) throw new Error(`Connect the ${roleLabel[role]} wallet first.`);
    if (chainId !== unichainSepolia.id) await switchChainAsync({ chainId: unichainSepolia.id });
    if (address.toLowerCase() !== run.roles[role].toLowerCase()) throw new Error(`Switch RainbowKit to the ${roleLabel[role]} wallet.`);
  }

  async function record(stepId: string, actor: keyof Roles, hash: `0x${string}`, eventSummary: string, metadata?: Record<string, string>) {
    const receipt = await publicClient.waitForTransactionReceipt({ hash });
    if (receipt.status !== "success") throw new Error("Transaction reverted.");
    const response = await fetch(`/api/runs/${runId}/steps`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ stepId, actor, transactionHash: hash, eventSummary, metadata }),
    });
    const result = (await response.json()) as { error?: string };
    if (!response.ok) throw new Error(result.error ?? "Transaction succeeded but evidence could not be saved.");
    await reload();
    return receipt;
  }

  async function execute(stepId: string, actor: keyof Roles, config: unknown, summary: string, metadata?: Record<string, string>) {
    try {
      await requireRole(actor);
      setNotice(`Confirm ${summary.toLowerCase()} in your wallet...`);
      const hash = await writeContractAsync(config as never);
      setNotice("Transaction submitted. Waiting for Unichain confirmation...");
      await record(stepId, actor, hash, summary, metadata);
      setNotice(`${summary} confirmed and added to the public evidence trail.`);
      return hash;
    } catch (error) {
      setNotice(error instanceof Error ? error.message : "Transaction failed.");
      return undefined;
    }
  }

  async function mint(role: Exclude<keyof Roles, "deployer">) {
    if (!run) return;
    if (!completed(`mint-${role}-token0`)) {
      const first = await execute(`mint-${role}-token0`, "deployer", { address: run.deployment.token0, abi: tokenAbi, functionName: "mint", args: [run.roles[role], mintAmount] }, `Mint Token A for ${roleLabel[role]}`);
      if (!first) return;
    }
    if (!completed(`mint-${role}-token1`)) await execute(`mint-${role}-token1`, "deployer", { address: run.deployment.token1, abi: tokenAbi, functionName: "mint", args: [run.roles[role], mintAmount] }, `Mint Token B for ${roleLabel[role]}`);
  }

  async function fundGas(role: Exclude<keyof Roles, "deployer">) {
    if (!run) return;
    try {
      await requireRole("deployer");
      const hash = await sendTransactionAsync({ to: run.roles[role], value: 2n * 10n ** 15n });
      await record(`fund-gas-${role}`, "deployer", hash, `Fund ${roleLabel[role]} with Unichain Sepolia gas`);
      setNotice(`${roleLabel[role]} has a small native-token gas grant.`);
    } catch (error) {
      setNotice(error instanceof Error ? error.message : "Gas funding failed.");
    }
  }

  async function approve(role: Exclude<keyof Roles, "deployer">) {
    if (!run) return;
    const calls = role === "trader"
      ? [["token0-router", run.deployment.token0, run.deployment.swapRouter]] as const
      : [
          ["token0-executor", run.deployment.token0, run.deployment.executor],
          ["token1-executor", run.deployment.token1, run.deployment.executor],
        ] as const;
    for (const [id, token, spender] of calls) {
      if (completed(`approve-${role}-${id}`)) continue;
      if (!await execute(`approve-${role}-${id}`, role, { address: token, abi: tokenAbi, functionName: "approve", args: [spender, maxUint256] }, `${roleLabel[role]} approves ${id}`)) break;
    }
  }

  async function commit(role: "ada" | "bao", rangeId: number, liquidity: bigint) {
    if (!run || !state) return;
    try {
      await requireRole(role);
      let id = commitmentId(role);
      if (!id) {
        const hash = await writeContractAsync({ address: run.deployment.vault, abi: vaultAbi, functionName: "depositAndCommit", args: [rangeId, liquidity, 2n], value: state.minimumBond });
        const receipt = await publicClient.waitForTransactionReceipt({ hash });
        const events = parseEventLogs({ abi: vaultAbi, logs: receipt.logs, strict: false });
        const created = events.find((event) => event.eventName === "CommitmentCreated");
        if (created?.args.commitmentId === undefined) throw new Error("CommitmentCreated event was not found in the receipt.");
        id = created.args.commitmentId.toString();
        await record(`commit-${role}`, role, hash, `${roleLabel[role]} posts a bond and commits liquidity`, { commitmentId: id });
      }
      if (!completed(`add-${role}`)) await execute(`add-${role}`, role, { address: run.deployment.executor, abi: executorAbi, functionName: "addLiquidity", args: [BigInt(id), maxUint128, maxUint128] }, `${roleLabel[role]} adds managed v4 liquidity`, { commitmentId: id });
      setNotice(`${roleLabel[role]} is now committed before the epoch snapshot.`);
    } catch (error) {
      setNotice(error instanceof Error ? error.message : "Commitment failed.");
    }
  }

  async function jitCommit() {
    if (!run || !state) return;
    try {
      await requireRole("jit");
      let id = commitmentId("jit");
      if (!id) {
        const endEpoch = state.epoch + 1n;
        const hash = await writeContractAsync({ address: run.deployment.vault, abi: vaultAbi, functionName: "depositAndCommit", args: [1, 10n ** 17n, endEpoch], value: state.minimumBond });
        const receipt = await publicClient.waitForTransactionReceipt({ hash });
        const events = parseEventLogs({ abi: vaultAbi, logs: receipt.logs, strict: false });
        const created = events.find((event) => event.eventName === "CommitmentCreated");
        if (created?.args.commitmentId === undefined) throw new Error("CommitmentCreated event was not found in the receipt.");
        id = created.args.commitmentId.toString();
        await record("commit-jit", "jit", hash, "JIT LP enters after the epoch snapshot", { commitmentId: id });
      }
      if (!completed("add-jit")) await execute("add-jit", "jit", { address: run.deployment.executor, abi: executorAbi, functionName: "addLiquidity", args: [BigInt(id), maxUint128, maxUint128] }, "JIT LP adds liquidity", { commitmentId: id });
    } catch (error) {
      setNotice(error instanceof Error ? error.message : "JIT entry failed.");
    }
  }

  if (!run || !state) return <main className="loading"><p>{notice}</p></main>;
  const canClose = state.phase === 1 && state.block > state.endBlock;
  const remaining = state.endBlock > state.block ? state.endBlock - state.block : 0n;
  const approvalsComplete = (role: "ada" | "bao" | "jit" | "trader") => role === "trader"
    ? completed("approve-trader-token0-router")
    : completed(`approve-${role}-token1-executor`);
  const actionsReady = (["ada", "bao", "jit", "trader"] as const).every(approvalsComplete);
  const rvmConfigured = state.expectedRvmId.toLowerCase() === run.rvmId.toLowerCase();

  return (
    <main className="walkthrough">
      <header className="topbar"><a href="/">Depth<span>Bond</span></a><div><small>Shared run</small><b>{run.title}</b></div><ConnectButton showBalance={false} /></header>
      <section className="hero"><div><p className="eyebrow">Transaction-backed testnet walkthrough</p><h1>Depth earns<br />when it <em>stays.</em></h1><p>Every card below maps a real action to its testnet transaction, contract event, and economic meaning.</p></div><div className="epoch"><p>Epoch pulse</p><strong>#{state.epoch || 1n}</strong><b>{phaseLabel[state.phase]}</b><span>{state.phase === 1 ? `${remaining} blocks remaining` : state.settled ? "Reactive settlement confirmed" : "Awaiting epoch start"}</span></div></section>
      <section className="live-strip"><span>Reserve <b>{state.reserve.toString()} wei</b></span><span>Minimum bond <b>{state.minimumBond.toString()} wei</b></span><span>Expected RVM <b>{short(state.expectedRvmId)}</b></span><span className="notice">{notice}</span></section>

      <section className="steps">
        <Step index="01" title="Prove the environment" detail="These are fresh contracts for this run. The walkthrough never reuses a prior vault, pool, or reward reserve." done>
          <Evidence label="Vault" value={short(run.deployment.vault)} href={transactionUrl(run.deployment.vault).replace("/tx/", "/address/")} />
          <Evidence label="Controller" value={short(run.deployment.controller)} href={transactionUrl(run.deployment.controller).replace("/tx/", "/address/")} />
          <Evidence label="Reactive RSC" value={short(run.rsc)} href={`https://lasna.reactscan.net/address/${run.rsc}`} />
        </Step>

        <Step index="02" title="Bind the Reactive identity" detail="The controller accepts settlement only from the RVM created for this Reactive RSC. Binding it once prevents an arbitrary automation contract from settling the epoch.">
          <button disabled={rvmConfigured} onClick={() => void execute("configure-rvm", "deployer", { address: run.deployment.controller, abi: controllerAbi, functionName: "setExpectedRvmId", args: [run.rvmId] }, "Bind the expected Reactive RVM")}>{rvmConfigured ? "Reactive RVM bound" : "Configure Reactive RVM"}</button>
        </Step>

        <Step index="03" title="Fund the actors" detail="The deployer grants gas and mints disposable mock tokens. LPs approve two tokens for the executor; the Trader approves only Token A for the fixed zero-for-one swap route.">
          {(["ada", "bao", "jit", "trader"] as const).map((role) => <div className="actor-row" key={role}><b>{roleLabel[role]}</b><span>{short(run.roles[role])}</span><button disabled={!rvmConfigured || completed(`fund-gas-${role}`)} onClick={() => void fundGas(role)}>{completed(`fund-gas-${role}`) ? "Gas funded" : "Fund gas"}</button><button disabled={!completed(`fund-gas-${role}`) || completed(`mint-${role}-token1`)} onClick={() => void mint(role)}>{completed(`mint-${role}-token1`) ? "Tokens minted" : "Mint tokens"}</button><button disabled={!completed(`mint-${role}-token1`) || approvalsComplete(role)} onClick={() => void approve(role)}>{approvalsComplete(role) ? "Approved" : role === "trader" ? "Approve Token A" : "Approve 2 tokens"}</button></div>)}
        </Step>

        <Step index="04" title="Put reliable liquidity on the line" detail="Ada and Bao bond their positions before the epoch begins. This makes them part of the opening liquidity snapshot.">
          <button disabled={!actionsReady || completed("add-ada")} onClick={() => void commit("ada", 1, 10n ** 18n)}>{completed("add-ada") ? "Ada liquidity active" : "Ada: commit medium-range liquidity"}</button>
          <button disabled={!completed("add-ada") || completed("add-bao")} onClick={() => void commit("bao", 0, 5n * 10n ** 17n)}>{completed("add-bao") ? "Bao liquidity active" : "Bao: commit tight-range liquidity"}</button>
        </Step>

        <Step index="05" title="Freeze the reliability baseline" detail="Starting the epoch snapshots eligible liquidity. A position added afterwards can help trading, but it cannot earn this epoch's reliability reward.">
          <button disabled={!completed("add-bao") || state.epoch !== 0n} onClick={() => void execute("begin-epoch", "deployer", { address: run.deployment.controller, abi: controllerAbi, functionName: "beginEpoch" }, "Start epoch and snapshot liquidity")}>{state.epoch > 0n ? `Epoch ${state.epoch} is open` : "Begin epoch"}</button>
        </Step>

        <Step index="06" title="Test short-term liquidity" detail="JIT enters after the snapshot, then exits early. The exit adds a 25% bond penalty to the reward reserve and leaves JIT ineligible for this epoch.">
          <button disabled={state.phase !== 1 || completed("add-jit")} onClick={() => void jitCommit()}>{completed("add-jit") ? "JIT liquidity active" : "JIT: enter after snapshot"}</button>
          <button disabled={!completed("add-jit") || completed("remove-jit")} onClick={() => { const id = commitmentId("jit"); if (id) void execute("remove-jit", "jit", { address: run.deployment.executor, abi: executorAbi, functionName: "removeLiquidity", args: [BigInt(id), 0n, 0n] }, "JIT LP exits early", { commitmentId: id }); }}>{completed("remove-jit") ? "Early exit recorded" : "JIT: exit early"}</button>
        </Step>

        <Step index="07" title="Create real demand" detail="The trader performs a real Uniswap v4 swap. The hook observes it and records qualifying volume for the active ranges.">
          <button disabled={!completed("remove-jit") || completed("trade")} onClick={() => void execute("trade", "trader", { address: run.deployment.swapRouter, abi: routerAbi, functionName: "swap", args: [{ currency0: run.deployment.token0, currency1: run.deployment.token1, fee: 3000, tickSpacing: 60, hooks: run.deployment.hook }, { zeroForOne: true, amountSpecified: -tradeAmount, sqrtPriceLimitX96: priceLimit }] }, "Trader executes a v4 swap")}>{completed("trade") ? "Swap observed by hook" : "Execute test swap"}</button>
        </Step>

        <Step index="08" title="Close and let Reactive settle" detail="After the epoch deadline, the close request emits an event. Reactive observes it and sends one authenticated settlement callback to the controller.">
          <button disabled={!completed("trade") || !canClose || completed("request-close")} onClick={() => void execute("request-close", "deployer", { address: run.deployment.controller, abi: controllerAbi, functionName: "requestEpochClose", args: [state.epoch] }, "Request epoch close")}>{completed("request-close") ? "Close requested" : canClose ? "Request epoch close" : `Wait ${remaining} blocks`}</button>
          <span className={state.settled ? "settled" : "waiting"}>{state.settled ? "Reactive callback settled the epoch." : "Waiting for Reactive settlement callback..."}</span>
          {settlement && <div className="cross-chain-proof"><b>Cross-chain settlement proof</b><a href={transactionUrl(settlement.closeTransaction)} target="_blank" rel="noreferrer">1. Unichain close request</a><a href={`https://lasna.reactscan.net/address/${settlement.rvmId}/${settlement.reactiveExecutionNumber}`} target="_blank" rel="noreferrer">2. Reactive RVM execution #{settlement.reactiveExecutionNumber}</a><a href={transactionUrl(settlement.unichainCallbackTransaction)} target="_blank" rel="noreferrer">3. Unichain callback settlement</a></div>}
        </Step>

        <Step index="09" title="Reward reliability" detail="Only the owners of eligible commitments can claim. The result links economic behavior to a public on-chain outcome.">
          <button disabled={!state.settled || completed("claim-ada")} onClick={() => { const id = commitmentId("ada"); if (id) void execute("claim-ada", "ada", { address: run.deployment.vault, abi: vaultAbi, functionName: "claim", args: [BigInt(id), state.epoch] }, "Ada claims settled reward", { commitmentId: id }); }}>{completed("claim-ada") ? "Ada reward claimed" : "Ada: claim reward"}</button>
          <button disabled={!state.settled || completed("claim-bao")} onClick={() => { const id = commitmentId("bao"); if (id) void execute("claim-bao", "bao", { address: run.deployment.vault, abi: vaultAbi, functionName: "claim", args: [BigInt(id), state.epoch] }, "Bao claims settled reward", { commitmentId: id }); }}>{completed("claim-bao") ? "Bao reward claimed" : "Bao: claim reward"}</button>
        </Step>
      </section>

      <section className="evidence"><p className="eyebrow">Public evidence ledger</p><h2>Every completed action has a receipt.</h2>{run.steps.length === 0 ? <p>No actions have been recorded for this run yet.</p> : run.steps.map((entry) => <Ledger key={entry.stepId} entry={entry} />)}</section>
    </main>
  );
}

function Step({ index, title, detail, done, children }: { index: string; title: string; detail: string; done?: boolean; children: React.ReactNode }) {
  return <article className={`step ${done ? "complete" : ""}`}><div className="step-number">{index}</div><div className="step-content"><p className="eyebrow">{done ? "Verified deployment" : "Guided action"}</p><h2>{title}</h2><p>{detail}</p><div className="step-actions">{children}</div></div></article>;
}

function Evidence({ label, value, href }: { label: string; value: string; href: string }) {
  return <a className="evidence-link" href={href} target="_blank" rel="noreferrer"><span>{label}</span><b>{value}</b></a>;
}

function Ledger({ entry }: { entry: StepRecord }) {
  return <a className="ledger-row" href={transactionUrl(entry.transactionHash)} target="_blank" rel="noreferrer"><span>{entry.stepId.replaceAll("-", " ")}</span><b>{entry.eventSummary}</b><small>Block {entry.blockNumber} / {short(entry.transactionHash)}</small></a>;
}

function short(value: string) {
  return `${value.slice(0, 6)}...${value.slice(-4)}`;
}
