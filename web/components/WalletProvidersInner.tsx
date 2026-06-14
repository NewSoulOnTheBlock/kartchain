"use client";

import { useMemo } from "react";
import { ConnectionProvider, WalletProvider } from "@solana/wallet-adapter-react";
import { WalletModalProvider } from "@solana/wallet-adapter-react-ui";
import { PhantomWalletAdapter } from "@solana/wallet-adapter-phantom";
import { SolflareWalletAdapter } from "@solana/wallet-adapter-solflare";
import { clusterApiUrl, type Cluster } from "@solana/web3.js";
import { KartchainBridge } from "@/components/KartchainBridge";

/**
 * The actual Solana wallet provider tree. This file MUST only be imported
 * via `dynamic({ ssr: false })` — see app/providers.tsx — because the
 * @solana/wallet-adapter-* packages have module-load-time side effects that
 * crash Next.js prerender when env vars aren't set.
 */
export default function WalletProvidersInner({ children }: { children: React.ReactNode }) {
  const network = (process.env.NEXT_PUBLIC_SOLANA_CLUSTER as Cluster) ?? "devnet";
  const endpoint = useMemo(() => {
    const fromEnv = process.env.NEXT_PUBLIC_SOLANA_RPC_URL;
    if (fromEnv && /^https?:\/\//.test(fromEnv)) return fromEnv;
    return clusterApiUrl(network);
  }, [network]);
  const wallets = useMemo(
    () => [new PhantomWalletAdapter(), new SolflareWalletAdapter()],
    []
  );
  return (
    <ConnectionProvider endpoint={endpoint}>
      <WalletProvider wallets={wallets} autoConnect>
        <WalletModalProvider>
          <KartchainBridge />
          {children}
        </WalletModalProvider>
      </WalletProvider>
    </ConnectionProvider>
  );
}
