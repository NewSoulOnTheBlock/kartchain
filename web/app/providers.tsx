"use client";

import { useMemo } from "react";
import dynamic from "next/dynamic";
import { ConnectionProvider, WalletProvider } from "@solana/wallet-adapter-react";
import { WalletModalProvider } from "@solana/wallet-adapter-react-ui";
import { PhantomWalletAdapter } from "@solana/wallet-adapter-phantom";
import { SolflareWalletAdapter } from "@solana/wallet-adapter-solflare";
import { clusterApiUrl, type Cluster } from "@solana/web3.js";

// KartchainBridge installs window.kartchain — must not run during SSR
// because it touches `window` and pulls in the Solana Connection constructor
// (which crashes prerender if NEXT_PUBLIC_SOLANA_RPC_URL is unset).
const KartchainBridge = dynamic(
  () => import("@/components/KartchainBridge").then((m) => m.KartchainBridge),
  { ssr: false }
);

function ProvidersInner({ children }: { children: React.ReactNode }) {
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

// The entire wallet tree is client-only — prevents Solana adapters from
// being included in any SSR/prerender bundle.
export const WalletProviders = dynamic(() => Promise.resolve(ProvidersInner), {
  ssr: false,
});
