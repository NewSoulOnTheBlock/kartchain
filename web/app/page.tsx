import Link from "next/link";
import { WalletButton } from "@/components/WalletButton";

export default function HomePage() {
  return (
    <div>
      <nav className="nav">
        <div className="brand">TRENCHKART</div>
        <div className="nav-links">
          <Link href="/race">Race</Link>
          <Link href="/garage">Garage</Link>
          <WalletButton />
        </div>
      </nav>

      <section className="hero">
        <h1>RACE. EARN. OWN.</h1>
        <p>
          A web-native 3D kart racer powered by Solana. Connect your wallet,
          pick a kart, and join an 8-player race in your browser. Win SOL
          prizes from the entry-fee pool and earn P2E tokens just by finishing.
        </p>
        <div style={{ display: "flex", gap: 12, justifyContent: "center" }}>
          <Link href="/race"><button className="button">Find a Race</button></Link>
          <Link href="/garage"><button className="button ghost">Browse Karts</button></Link>
        </div>
      </section>

      <div className="container">
        <div className="card">
          <h3 style={{ marginTop: 0 }}>How it works</h3>
          <ol style={{ lineHeight: 1.7 }}>
            <li><strong>Connect a wallet</strong> (Phantom or Solflare on Devnet for now).</li>
            <li><strong>Pick a lobby.</strong> Free practice or paid wagers (0.01 – 0.1 SOL).</li>
            <li><strong>Race.</strong> 8 karts, 3 laps. Server-authoritative — no cheaters.</li>
            <li><strong>Get paid.</strong> Prize pool splits 70 / 20 / 5 to top three. P2E tokens minted to every finisher.</li>
          </ol>
        </div>
      </div>
    </div>
  );
}
