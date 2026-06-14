"use client";
import Link from "next/link";
import { useWallet } from "@solana/wallet-adapter-react";
import { WalletButton } from "@/components/WalletButton";
import { useOwnedKarts } from "@/lib/karts";

export default function GaragePage() {
  const { publicKey } = useWallet();
  const { karts, loading } = useOwnedKarts(publicKey?.toBase58());

  return (
    <div>
      <nav className="nav">
        <div className="brand"><Link href="/" style={{ color: "inherit" }}>TRENCHKART</Link></div>
        <div className="nav-links">
          <Link href="/race">Race</Link>
          <Link href="/garage">Garage</Link>
          <WalletButton />
        </div>
      </nav>

      <div className="container">
        <h1>Garage</h1>
        {!publicKey && <p>Connect a wallet to see your karts.</p>}
        {publicKey && loading && <p>Loading karts...</p>}
        {publicKey && !loading && karts.length === 0 && (
          <div className="card">
            <h3 style={{ marginTop: 0 }}>No karts yet</h3>
            <p>You're racing with the starter kart. Win a race or mint an
              NFT kart to upgrade your stats.</p>
          </div>
        )}
        <div className="lobby-list">
          {karts.map((k) => (
            <div key={k.mint} className="card lobby">
              <h3>{k.name}</h3>
              <div className="meta">Type #{k.kartType}</div>
              <div className="meta">Top: {k.topSpeed}  •  Acc: {k.accel}  •  Hdl: {k.handling}</div>
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}
