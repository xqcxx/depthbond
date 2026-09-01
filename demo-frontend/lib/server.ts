import { createPublicClient, http } from "viem";
import { unichainRpcUrl } from "./chain";
import type { Address, Deployment } from "./types";

const client = createPublicClient({ transport: http(unichainRpcUrl) });

export async function verifyDeployment(deployment: Deployment) {
  const addresses = Object.values(deployment) as Address[];
  const code = await Promise.all(addresses.map((address) => client.getCode({ address })));
  if (code.some((value) => !value || value === "0x")) {
    throw new Error("One or more supplied deployment addresses have no Unichain Sepolia bytecode.");
  }
}

export async function verifyTransaction(hash: Address) {
  const [receipt, transaction] = await Promise.all([client.getTransactionReceipt({ hash }), client.getTransaction({ hash })]);
  if (receipt.status !== "success") throw new Error("The submitted transaction reverted.");
  return { receipt, transaction };
}

export async function rvmIdFor(rsc: Address): Promise<Address> {
  const response = await fetch(process.env.REACTIVE_RPC_URL ?? "https://lasna-rpc.rnk.dev/", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "rnk_getRnkAddressMapping", params: [rsc] }),
  });
  const body = (await response.json()) as { result?: { rvmId?: Address }; error?: { message: string } };
  if (!body.result?.rvmId) throw new Error(body.error?.message ?? "Reactive did not return an RVM ID for this RSC.");
  return body.result.rvmId;
}
