import { defineChain, http } from "viem";
import { createConfig } from "wagmi";
import { injected } from "wagmi/connectors";

export const unichainRpcUrl = process.env.NEXT_PUBLIC_UNICHAIN_RPC_URL ?? "https://sepolia.unichain.org";
export const uniscanUrl = "https://sepolia.uniscan.xyz";

export const unichainSepolia = defineChain({
  id: 1301,
  name: "Unichain Sepolia",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: [unichainRpcUrl] } },
  blockExplorers: { default: { name: "Uniscan", url: uniscanUrl } },
  testnet: true,
});

export const wagmiConfig = createConfig({
  chains: [unichainSepolia],
  // EIP-6963 keeps MetaMask and Rabby distinct instead of whichever extension overwrote window.ethereum last.
  connectors: [injected()],
  multiInjectedProviderDiscovery: true,
  transports: { [unichainSepolia.id]: http(unichainRpcUrl) },
  ssr: true,
});

export const transactionUrl = (hash: string) => `${uniscanUrl}/tx/${hash}`;
export const addressUrl = (address: string) => `${uniscanUrl}/address/${address}`;
