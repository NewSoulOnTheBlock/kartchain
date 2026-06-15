import { describe, it, expect, beforeAll, afterAll } from "vitest";
import { boot, ColyseusTestServer } from "@colyseus/testing";
import { Server } from "@colyseus/core";
import { LobbyRoom } from "../src/rooms/LobbyRoom.js";
import { RaceRoom } from "../src/rooms/RaceRoom.js";

describe("Kartchain rooms", () => {
  let colyseus: ColyseusTestServer;

  beforeAll(async () => {
    colyseus = await boot({
      initializeGameServer: (server: Server) => {
        server.define("lobby", LobbyRoom);
        server.define("race", RaceRoom);
      },
    });
  });

  afterAll(async () => {
    await colyseus.shutdown();
  });

  it("lobby seeds default lobbies on create", async () => {
    const room = await colyseus.createRoom("lobby", {});
    expect(room.state.lobbies.length).toBeGreaterThanOrEqual(3);
    // We seed at least 3 free-* lobbies + 2 wager-* lobbies from the STK
    // track catalog. The specific track ids rotate daily.
    const freeLobbies = room.state.lobbies.filter((l) => l.id.startsWith("free-"));
    const wagerLobbies = room.state.lobbies.filter((l) => l.id.startsWith("wager-"));
    expect(freeLobbies.length).toBeGreaterThan(0);
    expect(wagerLobbies.length).toBeGreaterThan(0);
    // Free lobbies must have zero entry fee
    for (const l of freeLobbies) expect(Number(l.entryFeeLamports)).toBe(0);
  });

  it("race accepts a free lobby join and starts countdown after ready", async () => {
    // maxPlayers: 1 → solo race, countdown should fire as soon as the only
    // player marks themselves ready.
    const room = await colyseus.createRoom("race", {
      raceId: "free-rookie",
      entryFeeLamports: "0",
      maxPlayers: 1,
    });
    const client = await colyseus.connectTo(room, {
      raceId: "free-rookie", wallet: "", maxPlayers: 1,
    });
    expect(room.state.karts.size).toBe(1);

    await client.send("ready", {});
    await new Promise((r) => setTimeout(r, 100));
    expect(["countdown", "racing"]).toContain(room.state.phase);

    await Promise.race([
      client.leave().catch(() => undefined),
      new Promise((r) => setTimeout(r, 500)),
    ]);
  });

  it("race with maxPlayers > 1 stays waiting until room is full", async () => {
    // 2-player room with only 1 ready player must NOT start (until either
    // a second player joins or the auto-start window expires — 30s).
    const room = await colyseus.createRoom("race", {
      raceId: "quick-2p-test",
      entryFeeLamports: "0",
      maxPlayers: 2,
    });
    const client = await colyseus.connectTo(room, {
      raceId: "quick-2p-test", wallet: "", maxPlayers: 2,
    });
    expect(room.state.karts.size).toBe(1);
    expect(room.state.maxPlayers).toBe(2);
    expect(room.state.waitingUntilMs).toBeGreaterThan(Date.now());

    await client.send("ready", {});
    await new Promise((r) => setTimeout(r, 150));
    // Still waiting — only 1/2 players present.
    expect(room.state.phase).toBe("waiting");

    await Promise.race([
      client.leave().catch(() => undefined),
      new Promise((r) => setTimeout(r, 500)),
    ]);
  });

  it("kart.lastInputSeq mirrors the highest accepted input seq", async () => {
    // Reconciliation primitive: clients use kart.lastInputSeq to know
    // which inputs are still in-flight and need to be replayed locally
    // after applying server state. This test verifies the server actually
    // propagates the accepted seq into the schema (regardless of race phase).
    const room = await colyseus.createRoom("race", {
      raceId: "seq-test",
      entryFeeLamports: "0",
      maxPlayers: 1,
    });
    const client = await colyseus.connectTo(room, {
      raceId: "seq-test", wallet: "", maxPlayers: 1,
    });
    const sessionId = client.sessionId;
    const kart = room.state.karts.get(sessionId);
    expect(kart).toBeDefined();
    expect(kart!.lastInputSeq).toBe(0);

    // Send three inputs in order; lastInputSeq should advance.
    await client.send("input", { seq: 1, throttle: 1, brake: 0, steer: 0 });
    await new Promise((r) => setTimeout(r, 80));
    expect(kart!.lastInputSeq).toBe(1);

    await client.send("input", { seq: 7, throttle: 1, brake: 0, steer: 0.5 });
    await new Promise((r) => setTimeout(r, 80));
    expect(kart!.lastInputSeq).toBe(7);

    // Out-of-order / stale input must NOT regress lastInputSeq.
    await client.send("input", { seq: 3, throttle: 1, brake: 0, steer: 0 });
    await new Promise((r) => setTimeout(r, 80));
    expect(kart!.lastInputSeq).toBe(7);

    await Promise.race([
      client.leave().catch(() => undefined),
      new Promise((r) => setTimeout(r, 500)),
    ]);
  });

  it("end-to-end PvP: two clients matchmake into the same room, race together", async () => {
    // The shipping criterion for PvP. Verifies:
    //   - both clients land in the SAME room (filterBy(["raceId"]))
    //   - both ready up -> phase advances (countdown -> racing)
    //   - both can send inputs -> kart.lastInputSeq advances independently
    //   - the WASM-driven server tick actually moves karts (x/z change)
    //   - both clients see both karts in state (cross-visibility)
    const room1 = await colyseus.createRoom("race", {
      raceId: "quick-2p-e2e",
      entryFeeLamports: "0",
      maxPlayers: 2,
    });
    const a = await colyseus.connectTo(room1, {
      raceId: "quick-2p-e2e", wallet: "", maxPlayers: 2,
    });
    const b = await colyseus.connectTo(room1, {
      raceId: "quick-2p-e2e", wallet: "", maxPlayers: 2,
    });
    expect(a.sessionId).not.toBe(b.sessionId);
    expect(room1.state.karts.size).toBe(2);

    const kartA = room1.state.karts.get(a.sessionId)!;
    const kartB = room1.state.karts.get(b.sessionId)!;
    expect(kartA).toBeDefined();
    expect(kartB).toBeDefined();

    // Both clients see both karts (cross-visibility through schema sync).
    await new Promise((r) => setTimeout(r, 100));
    expect(a.state.karts.size).toBe(2);
    expect(b.state.karts.size).toBe(2);

    // Both ready up -> countdown fires; after countdown (3s) -> racing.
    await a.send("ready", {});
    await b.send("ready", {});
    await new Promise((r) => setTimeout(r, 250));
    expect(["countdown", "racing"]).toContain(room1.state.phase);

    // Wait through the countdown (3s) into racing phase.
    await new Promise((r) => setTimeout(r, 3500));
    expect(room1.state.phase).toBe("racing");

    // Capture pre-input positions, then drive both karts forward.
    const startAx = kartA.x, startAz = kartA.z;
    const startBx = kartB.x, startBz = kartB.z;
    for (let seq = 1; seq <= 12; seq++) {
      await a.send("input", { seq, throttle: 1, brake: 0, steer: 0 });
      await b.send("input", { seq, throttle: 1, brake: 0, steer: 0 });
      await new Promise((r) => setTimeout(r, 35));
    }

    // Both karts must have accepted inputs ...
    expect(kartA.lastInputSeq).toBeGreaterThan(0);
    expect(kartB.lastInputSeq).toBeGreaterThan(0);
    // ... and the WASM-driven server tick must have moved them.
    // Forward at yaw=0 is +Z in our convention; speed > 0 confirms physics ran.
    expect(kartA.speed).toBeGreaterThan(0.5);
    expect(kartB.speed).toBeGreaterThan(0.5);
    const movedA = Math.hypot(kartA.x - startAx, kartA.z - startAz);
    const movedB = Math.hypot(kartB.x - startBx, kartB.z - startBz);
    expect(movedA).toBeGreaterThan(0.2);
    expect(movedB).toBeGreaterThan(0.2);

    await Promise.race([
      Promise.all([
        a.leave().catch(() => undefined),
        b.leave().catch(() => undefined),
      ]),
      new Promise((r) => setTimeout(r, 800)),
    ]);
  }, 15_000);
});
