import "dotenv/config";
import { Server } from "@colyseus/core";
import { WebSocketTransport } from "@colyseus/ws-transport";
import { monitor } from "@colyseus/monitor";
import { playground } from "@colyseus/playground";
import express from "express";
import { createServer } from "node:http";

import { LobbyRoom } from "./rooms/LobbyRoom.js";
import { RaceRoom } from "./rooms/RaceRoom.js";
import { loadWallets, escrowPubkey } from "./solana/wallets.js";
import { mintKartNft } from "./solana/kartNft.js";
import { loadKartCatalog, loadTrackCatalog } from "./content/catalog.js";

const PORT = Number(process.env.PORT ?? 2567);

async function main() {
  const app = express();
  app.use(express.json());

  // CORS — the web app runs on a different origin (Vercel) than the server
  // (Render). Allow the production origin from env, plus localhost in dev.
  const allowedOrigins = (process.env.ALLOWED_ORIGINS ?? "http://localhost:3000")
    .split(",")
    .map((s) => s.trim());
  app.use((req, res, next) => {
    const origin = req.header("origin") ?? "";
    if (allowedOrigins.includes(origin) || allowedOrigins.includes("*")) {
      res.setHeader("Access-Control-Allow-Origin", origin || "*");
      res.setHeader("Vary", "Origin");
    }
    res.setHeader("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
    res.setHeader("Access-Control-Allow-Headers", "Content-Type, x-admin-token");
    if (req.method === "OPTIONS") { res.sendStatus(204); return; }
    next();
  });

  app.get("/health", (_req, res) => {
    res.json({ ok: true, ts: Date.now() });
  });

  // Public: where to send entry-fee transfers. The web host queries this
  // and builds a SystemProgram.transfer + memo for the player to sign.
  app.get("/api/escrow-address", (_req, res) => {
    res.json({ escrow: escrowPubkey() });
  });

  // Public: the imported STK kart + track catalog so the web/Godot client
  // can render names, icons, and screenshots.
  app.get("/api/catalog", (_req, res) => {
    res.json({
      karts: loadKartCatalog(),
      tracks: loadTrackCatalog(),
    });
  });

  // Admin: mint a kart NFT to a recipient. Lock down in production with
  // an auth header or move behind a separate admin service.
  app.post("/api/admin/mint-kart", async (req, res) => {
    const adminToken = req.header("x-admin-token");
    if (adminToken !== (process.env.ADMIN_TOKEN ?? "")) {
      res.status(401).json({ error: "unauthorized" });
      return;
    }
    try {
      const result = await mintKartNft(req.body);
      res.json(result);
    } catch (err) {
      res.status(500).json({ error: String(err) });
    }
  });

  // Dev tools — disable in prod
  if (process.env.NODE_ENV !== "production") {
    app.use("/colyseus", monitor());
    app.use("/playground", playground());
  }

  const httpServer = createServer(app);
  const gameServer = new Server({
    transport: new WebSocketTransport({ server: httpServer }),
  });

  gameServer.define("lobby", LobbyRoom);
  // RaceRoom is created on demand by LobbyRoom via `matchMaker.createRoom`.
  gameServer.define("race", RaceRoom);

  // Eagerly load all custodial keypairs so we fail fast on misconfig.
  loadWallets();

  // Eagerly load the imported STK catalogs (warns if missing).
  loadKartCatalog();
  loadTrackCatalog();

  await gameServer.listen(PORT);
  console.log(`[kartchain-server] listening on http://localhost:${PORT}`);
  console.log(`[kartchain-server] WS lobby: ws://localhost:${PORT}`);
  console.log(`[kartchain-server] monitor:  http://localhost:${PORT}/colyseus`);
}

main().catch((err) => {
  console.error("[kartchain-server] fatal:", err);
  process.exit(1);
});
