import type { Metadata } from "next";
import { WalletProviders } from "./providers";
import "./globals.css";
import "@solana/wallet-adapter-react-ui/styles.css";

export const metadata: Metadata = {
  title: "Kartchain",
  description: "Web3 SuperTuxKart-inspired browser kart racer on Solana",
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body>
        <WalletProviders>
          {children}
        </WalletProviders>
      </body>
    </html>
  );
}
