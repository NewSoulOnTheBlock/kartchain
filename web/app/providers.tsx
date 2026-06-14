"use client";

import dynamic from "next/dynamic";

// Thin wrapper — has NO @solana/* imports at the top level so the SSR/
// prerender bundle never pulls them in. The real providers live in
// components/WalletProvidersInner.tsx and are loaded client-side only.
const WalletProvidersInner = dynamic(
  () => import("@/components/WalletProvidersInner"),
  { ssr: false }
);

export function WalletProviders({ children }: { children: React.ReactNode }) {
  return <WalletProvidersInner>{children}</WalletProvidersInner>;
}
