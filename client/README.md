# Kartchain Godot client

Godot 4.3+ project that builds to a single HTML5/WASM bundle under
`../web/public/game/`.

## Layout

| Path | Purpose |
|---|---|
| `scenes/Main.tscn` | Main menu (wallet connect + lobby) |
| `scenes/Race.tscn` | 3D race scene with HUD |
| `scenes/Kart.tscn` | `VehicleBody3D` kart prefab (4 wheels) |
| `scripts/Main.gd` | Main menu controller |
| `scripts/Race.gd` | Race scene root — spawns karts from server state |
| `scripts/Kart.gd` | Kart controller (local input or remote interp) |
| `scripts/GameState.gd` | Session-wide state (autoload) |
| `scripts/NetworkClient.gd` | Colyseus host-page bridge (autoload) |
| `scripts/SolanaBridge.gd` | Wallet/JS host-page bridge (autoload) |

## Bridges (window.kartchain on host page)

The Godot WASM never talks to Solana or Colyseus directly. It calls a JS
object provided by the Next.js host:

```ts
window.kartchain = {
  // wallet
  getWallet(): { pubkey: string } | null
  connectWallet(): Promise<{ pubkey: string }>
  signAndSendEnterRace(args: { raceId: string; entryFeeLamports: number }): Promise<{ tx: string }>
  signAndSendClaimP2E(args: { raceId: string; amount: number; attestation: string }): Promise<{ tx: string }>
  getOwnedKarts(): Promise<Kart[]>
  subscribe(cb: (evt: WalletEvent) => void): void

  // networking
  net: {
    joinLobby(): Promise<void>
    joinRace(raceId: string): Promise<void>
    leaveRoom(): Promise<void>
    sendInput(input: { seq: number; throttle: number; brake: number; steer: number; items: number }): void
    sendReady(): void
    useItem(slot: number): void
    subscribe(cb: (evt: NetEvent) => void): void
  }
}
```

## Build

```bash
godot --headless --export-release "Web" ../web/public/game/index.html
```

Outputs:
- `index.html` (game shell — overridden by Next.js page)
- `index.js`, `index.wasm`, `index.pck`, `index.audio.worklet.js`
