# Licensing

Kartchain mixes two license families. **Read this before committing assets.**

## 1. Code — MIT

Everything written by Kartchain contributors (Godot scripts, TypeScript,
Rust, Next.js components, CI) is MIT-licensed via [`/LICENSE`](../LICENSE).

You may use, fork, sell, and ship closed-source derivatives of the code.

## 2. Imported / derived art — CC-BY-SA 4.0

We reuse models, textures, sound effects, music, and track data from the
[SuperTuxKart assets repo](https://github.com/supertuxkart/stk-assets), which
is **Creative Commons Attribution-ShareAlike 4.0 International** unless an
individual file specifies otherwise.

**This means:**
- **Attribution required.** Every shipped build must credit the original
  contributors. Use [`/assets-import/ATTRIBUTION.md`](../assets-import/ATTRIBUTION.md)
  as the in-game/website credits page.
- **Share-alike.** Any **derivative of those assets** (a remix, retexture,
  re-rig, model edit) must itself be released under CC-BY-SA 4.0. Code that
  *uses* the assets is unaffected.
- **No DRM.** You may not apply technical measures that restrict others from
  exercising their CC-BY-SA rights on the assets.

## 3. NFT karts — the important nuance

You **may** mint an NFT that references a CC-BY-SA kart model (e.g. metadata
URI points to an on-chain or IPFS-hosted glTF of a remixed kart). The NFT itself
is just a token — ownership of a token does not grant exclusive copyright in
the underlying asset.

**Implications:**
- You cannot promise NFT holders "exclusive" rights to a derivative asset —
  the CC license already grants the world the right to use it.
- You **can** sell access (entry to paid races, cosmetic combinations,
  in-game perks, on-chain provenance, scarcity numbering).
- If you commission **fully original** kart art (not derived from STK), it
  can be licensed however you want and used for true exclusivity.

We recommend: ship STK-derived karts as **free starter karts** for everyone,
and gate paid/exclusive karts behind original commissioned art.

## 4. Trademarks

"SuperTuxKart" and the SuperTuxKart logo are unregistered trademarks of the
STK project. **Do not** use them in marketing, store listings, or NFT
collection names. Don't call your tracks/karts by their STK names if you've
modified them substantially.

## 5. Music

Music in `stk-assets/music/` is often a mix of CC-BY-SA and CC-BY licenses.
Check each track's `*.music` metadata file before shipping.

## 6. Quick checklist before launch

- [ ] In-game credits screen lists every imported asset's original author
- [ ] Website footer links to CC-BY-SA 4.0 license text
- [ ] `assets-import/ATTRIBUTION.md` is up to date and shipped with builds
- [ ] No use of "SuperTuxKart" name or logo
- [ ] Paid/exclusive NFTs use only original commissioned art
- [ ] Per-track music licenses double-checked
