import type { Metadata } from "next";
import { Providers } from "./providers";
import "./globals.css";

export const metadata: Metadata = {
  title: "DepthBond | CleanFlow Bonds for Reliable Liquidity",
  description: "An epoch-based liquidity commitment protocol for Unichain, with Reactive settlement automation.",
};

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return <html lang="en"><body><Providers>{children}</Providers></body></html>;
}
