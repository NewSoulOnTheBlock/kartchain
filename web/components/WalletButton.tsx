"use client";

import dynamic from "next/dynamic";

/**
 * WalletMultiButton's rendered HTML depends on browser-only wallet
 * detection, which differs between SSR (no Phantom) and the client
 * (Phantom installed) — causing a React hydration mismatch.
 *
 * Loading it via next/dynamic with ssr:false renders nothing on the
 * server and mounts the real button only on the client.
 */
const WalletMultiButton = dynamic(
  async () => (await import("@solana/wallet-adapter-react-ui")).WalletMultiButton,
  { ssr: false }
);

export function WalletButton() {
  return <WalletMultiButton />;
}
