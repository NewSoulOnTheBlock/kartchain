import { GodotGame } from "@/components/GodotGame";
import Link from "next/link";
import { WalletButton } from "@/components/WalletButton";

export default function RacePage() {
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
      <div className="game-shell">
        <GodotGame />
      </div>
    </div>
  );
}
