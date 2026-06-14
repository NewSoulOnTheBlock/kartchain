// Smoke test: connect to Colyseus server from Node and confirm the
// lobby room sends down its seeded lobby list.
// Run from server/: node scripts/smoke-lobby.mjs
import { Client } from "colyseus.js";

const url = process.env.COLYSEUS_URL ?? "ws://localhost:2567";
console.log(`[smoke] connecting to ${url}`);

const client = new Client(url);
const room = await client.joinOrCreate("lobby", {});
console.log(`[smoke] joined lobby roomId=${room.roomId}, sessionId=${room.sessionId}`);

const dump = () => {
  const state = room.state;
  const list = [];
  state?.lobbies?.forEach?.((l) => {
    list.push({
      id: l.id,
      players: l.players,
      maxPlayers: l.maxPlayers,
      entryFeeLamports: Number(l.entryFeeLamports),
      status: l.status,
    });
  });
  console.log(`[smoke] state.lobbies (${list.length}):`, JSON.stringify(list, null, 2));
};

// Dump on every change
room.onStateChange(() => dump());

// Also dump on first state arrival
room.onStateChange.once(() => dump());

// Hold open 4 s so we get the periodic refresh tick
setTimeout(async () => {
  await room.leave().catch(() => undefined);
  process.exit(0);
}, 4000);
