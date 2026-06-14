"use client";

/**
 * KartchainBridge
 *
 * Installs `window.kartchain` — the JS API the Godot game calls via
 * JavaScriptBridge. Lives in the root provider so it's available everywhere
 * including on the /race page where the Godot iframe expects it.
 *
 * Surface:
 *   window.kartchain = {
 *     getWallet,
 *     connectWallet,
 *     signAndSendEnterRace,
 *     signAndSendClaimP2E,   // no-op in custodial flow; reserved for future
 *     getOwnedKarts,
 *     subscribe,
 *     net: { joinLobby, joinRace, leaveRoom, sendInput, sendReady, useItem, subscribe }
 *   }
 */

import { useEffect, useRef } from "react";
import { useConnection, useWallet } from "@solana/wallet-adapter-react";
import { useWalletModal } from "@solana/wallet-adapter-react-ui";
import { Client, Room } from "colyseus.js";
import {
  Connection, PublicKey, SystemProgram, Transaction, TransactionInstruction,
} from "@solana/web3.js";
import { fetchOwnedKarts } from "@/lib/karts-fetch";

declare global {
  interface Window {
    kartchain: KartchainApi;
  }
}

type WalletEvent =
  | { type: "wallet:changed"; pubkey: string }
  | { type: "wallet:error";   message: string }
  /**
   * Owned NFT karts, pushed asynchronously after a `refreshOwnedKarts()`
   * call or whenever the connected wallet changes. The Godot SolanaBridge
   * listens for this event because it can't `await` a JS Promise from
   * GDScript.
   */
  | { type: "wallet:karts";   karts: any[] };

type NetEvent =
  | { type: "lobby:state";    lobbies: any[] }
  | { type: "race:self";      sessionId: string }
  | { type: "race:state";     state: any }
  | { type: "race:countdown"; seconds: number }
  | { type: "race:lap";       playerId: string; lapNumber: number; lapTime: number }
  | { type: "race:finish";    playerId: string; totalTime: number; position: number }
  | { type: "race:settled";   txSignature: string }
  | { type: "error";          code: string; message: string };

type KartchainApi = {
  getWallet: () => { pubkey: string } | null;
  /** JSON-string variant for the Godot/JS bridge — see emitNet rationale. */
  getWalletJson: () => string;
  connectWallet: () => Promise<{ pubkey: string }>;
  signAndSendEnterRace: (args: { raceId: string; entryFeeLamports: number; kartType?: number }) => Promise<{ tx: string }>;
  signAndSendClaimP2E: (args: { raceId: string; amount: number; attestation: string }) => Promise<{ tx: string }>;
  getOwnedKarts: () => Promise<any[]>;
  /** JSON-string variant for the Godot/JS bridge. */
  getOwnedKartsJson: () => Promise<string>;
  /**
   * Async-friendly variant for Godot's JavaScriptBridge: kicks off the
   * fetch and pushes a `wallet:karts` WalletEvent when results arrive.
   * GDScript can't `await` a JS Promise, so we deliver via the existing
   * subscribe channel that SolanaBridge.gd already listens to.
   */
  refreshOwnedKarts: () => void;
  /** Subscribers receive a JSON-stringified WalletEvent. */
  subscribe: (cb: (json: string) => void) => void;
  net: {
    joinLobby: () => Promise<void>;
    joinRace: (raceId: string, opts?: { entryTxSignature?: string; kartType?: number; trackId?: string; maxPlayers?: number }) => Promise<void>;
    /** Variant called by Godot — kartType is a plain int arg to avoid
     *  GDScript→JS dict conversion issues. maxPlayers is also a plain int
     *  (0 = use server default). */
    joinRaceWithKart: (raceId: string, kartType: number, maxPlayers?: number) => Promise<void>;
    leaveRoom: () => Promise<void>;
    sendInput: (i: { seq: number; throttle: number; brake: number; steer: number; items: number }) => void;
    sendReady: () => void;
    useItem: (slot: number) => void;
    setSpawn: (x: number, y: number, z: number) => void;
    /** Subscribers receive a JSON-stringified NetEvent. */
    subscribe: (cb: (json: string) => void) => void;
  };
};

const COLYSEUS_URL = process.env.NEXT_PUBLIC_COLYSEUS_URL ?? "ws://localhost:2567";
const SERVER_URL   = process.env.NEXT_PUBLIC_SERVER_URL   ?? "http://localhost:2567";
const MEMO_PROGRAM_ID = new PublicKey("MemoSq4gqABAXKb96qnH8TysNcWxMyWCqXgDLGmfcHr");

export function KartchainBridge() {
  const { connection } = useConnection();
  const wallet = useWallet();
  const { setVisible: setWalletModalVisible } = useWalletModal();

  // Subscribers receive JSON strings (see emitNet / emitWallet rationale).
  const walletSubs = useRef<Array<(json: string) => void>>([]);
  const netSubs    = useRef<Array<(json: string) => void>>([]);

  // Colyseus state
  const clientRef = useRef<Client | null>(null);
  const lobbyRef  = useRef<Room | null>(null);
  const raceRef   = useRef<Room | null>(null);

  // Stable refs to React-managed dependencies. These are mutated on every
  // render so the API closure (installed once below) always reads fresh
  // values without us having to re-install it.
  const depsRef = useRef({
    connection,
    wallet,
    setWalletModalVisible,
  });
  depsRef.current.connection = connection;
  depsRef.current.wallet = wallet;
  depsRef.current.setWalletModalVisible = setWalletModalVisible;

  // Install window.kartchain exactly once, in an effect — never during render.
  // React 18 strict-mode double-mounts will see kartchain already present and
  // skip the second install.
  useEffect(() => {
    if (typeof window === "undefined") return;
    if (window.kartchain) return;
    window.kartchain = makeApi({
      walletSubs,
      netSubs,
      clientRef,
      lobbyRef,
      raceRef,
      getConnection: () => depsRef.current.connection,
      getWallet: () => depsRef.current.wallet,
      openWalletModal: () => depsRef.current.setWalletModalVisible(true),
    });
  }, []);

  // Push wallet changes to subscribers + Godot (as JSON strings, see emitWallet)
  useEffect(() => {
    const pubkey = wallet.publicKey?.toBase58() ?? "";
    const evt: WalletEvent = { type: "wallet:changed", pubkey };
    const json = JSON.stringify(evt);
    walletSubs.current.forEach((cb) => { try { cb(json); } catch (e) { console.error(e); } });

    // Auto-refresh owned NFT karts on connect/disconnect so SolanaBridge
    // doesn't need to poll. Empty pubkey → empty list.
    if (!pubkey) {
      const emptyJson = JSON.stringify({ type: "wallet:karts", karts: [] } as WalletEvent);
      walletSubs.current.forEach((cb) => { try { cb(emptyJson); } catch (e) { console.error(e); } });
      return;
    }
    fetchOwnedKarts(pubkey)
      .then((karts) => {
        const ke = JSON.stringify({ type: "wallet:karts", karts } as WalletEvent);
        walletSubs.current.forEach((cb) => { try { cb(ke); } catch (e) { console.error(e); } });
      })
      .catch((err) => console.error("[kartchain] auto-refresh karts failed:", err));
  }, [wallet.publicKey]);

  return null;
}

// Subscribers receive JSON strings (see emitNet / emitWallet rationale).
type WalletSub = (json: string) => void;
type NetSub    = (json: string) => void;

function makeApi(deps: {
  walletSubs: React.MutableRefObject<Array<WalletSub>>;
  netSubs:    React.MutableRefObject<Array<NetSub>>;
  clientRef:  React.MutableRefObject<Client | null>;
  lobbyRef:   React.MutableRefObject<Room   | null>;
  raceRef:    React.MutableRefObject<Room   | null>;
  getConnection: () => Connection;
  getWallet: () => ReturnType<typeof useWallet>;
  openWalletModal: () => void;
}): KartchainApi {
  const { walletSubs, netSubs, clientRef, lobbyRef, raceRef,
          getConnection, getWallet, openWalletModal } = deps;

  function ensureClient(): Client {
    if (!clientRef.current) clientRef.current = new Client(COLYSEUS_URL);
    return clientRef.current;
  }

  // We pass JSON strings across the Godot/JS boundary because GDScript
  // sees raw JS objects as `JavaScriptObject` (NOT Dictionary) — methods
  // like `.get("key", default)` silently no-op. Stringifying here and
  // JSON.parse_string-ing on the GDScript side gives us real Dictionaries.
  function emitNet(e: NetEvent) {
    const json = JSON.stringify(e);
    netSubs.current.forEach((cb) => { try { cb(json); } catch (err) { console.error(err); } });
  }
  function emitWallet(e: WalletEvent) {
    const json = JSON.stringify(e);
    walletSubs.current.forEach((cb) => { try { cb(json); } catch (err) { console.error(err); } });
  }

  return {
    getWallet() {
      const pk = getWallet().publicKey;
      return pk ? { pubkey: pk.toBase58() } : null;
    },

    getWalletJson() {
      const pk = getWallet().publicKey;
      return JSON.stringify(pk ? { pubkey: pk.toBase58() } : null);
    },

    async connectWallet() {
      openWalletModal();
      return await new Promise<{ pubkey: string }>((resolve, reject) => {
        const timeoutId = window.setTimeout(() => {
          walletSubs.current = walletSubs.current.filter((cb) => cb !== onChange);
          reject(new Error("wallet connect timeout"));
        }, 120_000);
        const onChange: WalletSub = (json: string) => {
          let e: WalletEvent | null = null;
          try { e = JSON.parse(json); } catch { return; }
          if (e && e.type === "wallet:changed" && e.pubkey) {
            window.clearTimeout(timeoutId);
            walletSubs.current = walletSubs.current.filter((cb) => cb !== onChange);
            resolve({ pubkey: e.pubkey });
          }
        };
        walletSubs.current.push(onChange);
      });
    },

    async signAndSendEnterRace({ raceId, entryFeeLamports, kartType }) {
      const w = getWallet();
      if (!w.publicKey || !w.signTransaction) throw new Error("wallet not connected");

      // Fetch escrow address from the Colyseus server REST API
      const escrowRes = await fetch(`${SERVER_URL}/api/escrow-address`);
      if (!escrowRes.ok) throw new Error(`escrow lookup failed: ${escrowRes.status}`);
      const { escrow } = await escrowRes.json();
      const escrowPk = new PublicKey(escrow);

      const conn = getConnection();
      const tx = new Transaction();
      tx.add(
        SystemProgram.transfer({
          fromPubkey: w.publicKey,
          toPubkey: escrowPk,
          lamports: entryFeeLamports,
        })
      );
      tx.add(new TransactionInstruction({
        keys: [],
        programId: MEMO_PROGRAM_ID,
        data: Buffer.from(JSON.stringify({ k: "enter_race", raceId }), "utf-8"),
      }));
      tx.feePayer = w.publicKey;
      const { blockhash, lastValidBlockHeight } = await conn.getLatestBlockhash();
      tx.recentBlockhash = blockhash;
      const signed = await w.signTransaction(tx);
      const sig = await conn.sendRawTransaction(signed.serialize());
      await conn.confirmTransaction({ signature: sig, blockhash, lastValidBlockHeight }, "confirmed");
      console.log(`[kartchain] entry tx confirmed: ${sig} — joining race ${raceId}`);
      // Auto-join the race room with the verified signature.
      // GameState.selected_kart_type is mirrored into the API via the
      // existing joinRace() call (sent from Godot side too).
      try {
        await (window as any).kartchain.net.joinRace(raceId, { entryTxSignature: sig, kartType: kartType ?? 0 });
      } catch (err) {
        console.error("[kartchain] join after pay failed:", err);
      }
      return { tx: sig };
    },

    async signAndSendClaimP2E(_args) {
      // In custodial mode the server mints P2E rewards directly after the
      // race ends. No user signature needed. Reserved for future on-chain
      // claim flow.
      return { tx: "" };
    },

    async getOwnedKarts() {
      const pk = getWallet().publicKey;
      if (!pk) return [];
      return await fetchOwnedKarts(pk.toBase58());
    },

    async getOwnedKartsJson() {
      const pk = getWallet().publicKey;
      if (!pk) return JSON.stringify([]);
      const karts = await fetchOwnedKarts(pk.toBase58());
      return JSON.stringify(karts);
    },

    refreshOwnedKarts() {
      const pk = getWallet().publicKey;
      if (!pk) {
        emitWallet({ type: "wallet:karts", karts: [] });
        return;
      }
      fetchOwnedKarts(pk.toBase58())
        .then((karts) => emitWallet({ type: "wallet:karts", karts }))
        .catch((err) => {
          console.error("[kartchain] refreshOwnedKarts failed:", err);
          emitWallet({ type: "wallet:karts", karts: [] });
        });
    },

    subscribe(cb) { walletSubs.current.push(cb); },

    net: {
      async joinLobby() {
        try {
          const client = ensureClient();
          if (lobbyRef.current) await lobbyRef.current.leave().catch(() => undefined);
          console.log("[kartchain] joining lobby...");
          const room = await client.joinOrCreate("lobby", {});
          lobbyRef.current = room;
          console.log("[kartchain] joined lobby:", room.roomId, "sessionId:", room.sessionId);

          const emitLobbies = () => {
            const state: any = room.state;
            const lobbies: any[] = [];
            // state.lobbies is a Colyseus ArraySchema; .forEach works,
            // but .map() may not depending on version.
            if (state?.lobbies && typeof state.lobbies.forEach === "function") {
              state.lobbies.forEach((l: any) => {
                lobbies.push({
                  id: l.id,
                  trackId: l.trackId,
                  trackName: l.trackName,
                  players: l.players,
                  maxPlayers: l.maxPlayers,
                  entryFeeLamports: l.entryFeeLamports,
                  status: l.status,
                });
              });
            }
            console.log(`[kartchain] lobby:state — ${lobbies.length} lobbies`, lobbies);
            emitNet({ type: "lobby:state", lobbies });
          };

          // Emit immediately for any state that's already been received,
          // then on every subsequent change.
          emitLobbies();
          room.onStateChange(() => emitLobbies());
          room.onError((code, message) => {
            console.error("[kartchain] lobby error", code, message);
            emitNet({ type: "error", code: String(code), message: message ?? "" });
          });
          room.onLeave((code) => {
            console.warn("[kartchain] lobby left, code:", code);
          });
        } catch (err) {
          console.error("[kartchain] joinLobby failed:", err);
          emitNet({ type: "error", code: "LOBBY_JOIN_FAILED", message: String(err) });
        }
      },

      async joinRace(raceId, opts) {
        const joinStartMs = Date.now();
        try {
          const client = ensureClient();
          if (raceRef.current) await raceRef.current.leave().catch(() => undefined);
          const w = getWallet();
          const wallet = w.publicKey?.toBase58() ?? "";
          console.log(`[kartchain] joinRace START raceId=${raceId} kartType=${opts?.kartType ?? 0} wallet=${wallet ? wallet.slice(0,8) : "(none)"} url=${COLYSEUS_URL}`);
          const room = await client.joinOrCreate("race", {
            raceId, wallet, kartType: opts?.kartType ?? 0,
            trackId: opts?.trackId,
            entryTxSignature: opts?.entryTxSignature,
            maxPlayers: opts?.maxPlayers,
          });
          const joinDurMs = Date.now() - joinStartMs;
          raceRef.current = room;
          console.log(`[kartchain] joinRace JOINED in ${joinDurMs}ms roomId=${room.roomId} sessionId=${room.sessionId}`);
          emitNet({ type: "race:self", sessionId: room.sessionId });

          const emitRaceState = () => {
            const state: any = room.state;
            // It's possible (depending on Colyseus version + timing) that
            // joinOrCreate's promise resolves before the first state sync.
            // Skip if state hasn't been populated yet — onStateChange.once()
            // below will catch it as soon as it arrives.
            if (!state) return;
            const karts: Record<string, any> = {};
            if (state?.karts && typeof state.karts.forEach === "function") {
              state.karts.forEach((k: any, id: string) => {
                karts[id] = {
                  playerId: k.playerId, wallet: k.wallet, kartType: k.kartType,
                  position: k.position, lap: k.lap,
                  x: k.x, y: k.y, z: k.z, yaw: k.yaw, speed: k.speed,
                  itemSlot: k.itemSlot, finished: k.finished,
                };
              });
            }
            const payload = {
              type: "race:state" as const,
              state: {
                phase: state?.phase ?? "waiting",
                trackId: state?.trackId ?? "",
                totalLaps: state?.totalLaps ?? 3,
                maxPlayers: state?.maxPlayers ?? 8,
                waitingUntilMs: state?.waitingUntilMs ?? 0,
                karts,
                hasSpawnOverride: !!state?.hasSpawnOverride,
                spawnX: state?.spawnOverrideX ?? 0,
                spawnY: state?.spawnOverrideY ?? 0,
                spawnZ: state?.spawnOverrideZ ?? 0,
              },
            };
            console.log("[kartchain] race:state emit", payload.state.phase,
              "trackId=", payload.state.trackId, "karts=", Object.keys(karts).length,
              "max=", payload.state.maxPlayers);
            emitNet(payload);
          };

          // BELT-AND-SUSPENDERS catch of the initial schema sync:
          //   1) Try emitting immediately — works if state arrived during the
          //      join handshake (Colyseus often does this).
          //   2) onStateChange.once() — guaranteed to fire on the FIRST sync,
          //      even if it arrives after joinOrCreate resolves.
          //   3) onStateChange() — every subsequent change.
          emitRaceState();
          let firstStateSeen = false;
          room.onStateChange.once((s: any) => {
            firstStateSeen = true;
            console.log("[kartchain] race onStateChange.once fired — initial state synced");
            emitRaceState();
          });
          room.onStateChange((s: any) => emitRaceState());

          // Safety net — if no state has arrived in 10s, the server is
          // probably not responding. Surface an error to the user instead
          // of leaving them stuck on the connecting overlay.
          window.setTimeout(() => {
            if (!firstStateSeen) {
              console.error("[kartchain] no race state after 10s — server likely unreachable");
              emitNet({
                type: "error",
                code: "RACE_NO_STATE",
                message: "No state from server after 10s. Check that the server is running and reachable.",
              });
            }
          }, 10_000);
          room.onMessage("countdown", (m: any) => emitNet({ type: "race:countdown", seconds: m.seconds }));
          room.onMessage("lap",       (m: any) => emitNet({ type: "race:lap", playerId: m.playerId, lapNumber: m.lapNumber, lapTime: m.lapTime }));
          room.onMessage("finish",    (m: any) => emitNet({ type: "race:finish", playerId: m.playerId, totalTime: m.totalTime, position: m.position }));
          room.onMessage("settled",   (m: any) => emitNet({ type: "race:settled", txSignature: m.txSignature }));
          room.onMessage("error",     (m: any) => emitNet({ type: "error", code: m.code, message: m.message }));
          room.onError((code, message) => {
            const lifeMs = Date.now() - joinStartMs;
            console.error(`[kartchain] race room ERROR code=${code} msg=${message} aliveFor=${lifeMs}ms`);
            emitNet({ type: "error", code: `RACE_ERR_${code}`, message: message ?? "" });
          });
          room.onLeave((code) => {
            const lifeMs = Date.now() - joinStartMs;
            console.warn(`[kartchain] race room LEFT code=${code} aliveFor=${lifeMs}ms firstStateSeen=${firstStateSeen}`);
            // Suppress the user-facing error if this disconnect happened AFTER
            // we saw state (race ended normally, or user navigated away). Only
            // surface it when something truly broke during/right after join.
            if (!firstStateSeen) {
              emitNet({
                type: "error",
                code: "RACE_LEFT",
                message: `Disconnected from race after ${lifeMs}ms (WS code ${code}). Server probably crashed onJoin — check Render logs.`,
              });
            }
          });
        } catch (err) {
          const dur = Date.now() - joinStartMs;
          console.error(`[kartchain] joinRace FAILED after ${dur}ms:`, err);
          emitNet({ type: "error", code: "RACE_JOIN_FAILED", message: String(err) });
        }
      },

      async leaveRoom() {
        if (raceRef.current) {
          await raceRef.current.leave().catch(() => undefined);
          raceRef.current = null;
        }
      },

      // Convenience wrapper called from Godot — kartType arrives as a plain
      // number, which avoids GDScript→JS dictionary conversion bugs.
      async joinRaceWithKart(raceId: string, kartType: number, maxPlayers: number = 0) {
        console.log("[kartchain] joinRaceWithKart raceId=%s kartType=%d maxPlayers=%d", raceId, kartType, maxPlayers);
        await (window as any).kartchain.net.joinRace(raceId, { kartType, maxPlayers: maxPlayers > 0 ? maxPlayers : undefined });
        // After room is joined, broadcast our own session id so Godot can
        // identify which Kart in the state map is "us".
        const room = raceRef.current;
        if (room) {
          console.log("[kartchain] my sessionId =", room.sessionId);
          emitNet({ type: "race:self", sessionId: room.sessionId });
        }
      },

      sendInput(input) { raceRef.current?.send("input", input); },
      sendReady()      { raceRef.current?.send("ready", {}); },
      useItem(slot)    { raceRef.current?.send("useItem", { slot }); },
      /** Broadcast a spawn-point override to every player in the room. */
      setSpawn(x: number, y: number, z: number) {
        raceRef.current?.send("setSpawn", { x, y, z });
      },

      subscribe(cb)    { netSubs.current.push(cb); },
    },
  };
}
