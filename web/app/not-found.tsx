// Minimal not-found page that doesn't depend on the wallet providers.
// Without this, Next.js uses a default _not-found that's prerendered
// inside the root layout — which pulls in the Solana wallet stack and
// crashes on environments where NEXT_PUBLIC_SOLANA_RPC_URL is unset.
//
// Force-dynamic ensures Next never tries to statically pre-render it.
export const dynamic = "force-dynamic";

export default function NotFound() {
  return (
    <div style={{
      minHeight: "100vh",
      display: "flex",
      alignItems: "center",
      justifyContent: "center",
      background: "#0b1020",
      color: "#e6edf7",
      fontFamily: "system-ui, sans-serif",
    }}>
      <div style={{ textAlign: "center" }}>
        <h1 style={{ fontSize: 64, margin: 0, color: "#5be1ff" }}>404</h1>
        <p style={{ marginTop: 8 }}>That page doesn&apos;t exist.</p>
        <a href="/" style={{ color: "#5be1ff", marginTop: 16, display: "inline-block" }}>
          ← Back to Kartchain
        </a>
      </div>
    </div>
  );
}
