/**
 * Kart NFT minting (server-side, custodial).
 *
 * MVP stub. Recommended implementation: use Metaplex Core via its umi SDK
 * (`@metaplex-foundation/mpl-core` + `@metaplex-foundation/umi-bundle-defaults`)
 * to mint compressed-friendly assets owned by the player wallet.
 *
 * Plug-in points:
 *   - The `nftAuth` wallet (loaded by `loadWallets()`) signs the create ix.
 *   - Metadata JSON is uploaded to Arweave / Pinata / Shadow Drive beforehand;
 *     the URI is passed in.
 *   - Attributes plugin holds the kart stats (topSpeed/accel/handling/kartType)
 *     so the Colyseus server can fetch them at race-spawn time.
 *
 * For now this returns a fake signature so the rest of the system compiles.
 * Wire it up in a follow-up by adding @metaplex-foundation/mpl-core to
 * package.json and replacing the body of `mintKartNft`.
 */

import { loadWallets } from "./wallets.js";

export type MintKartArgs = {
  recipient: string;      // base58 pubkey
  name: string;           // "Bolt MK-3"
  metadataUri: string;    // arweave/ipfs URI
  attributes: {
    topSpeed: number;     // 0..100
    accel: number;        // 0..100
    handling: number;     // 0..100
    kartType: number;     // arbitrary id used by client to pick asset
  };
};

export type MintKartResult = {
  assetAddress: string;   // pubkey of the minted asset
  signature: string;
};

export async function mintKartNft(args: MintKartArgs): Promise<MintKartResult> {
  const { nftAuth } = loadWallets();
  if (!nftAuth) {
    throw new Error(
      "nftAuth keypair not configured. Set KART_NFT_AUTHORITY_KEYPAIR_PATH " +
      "to enable kart NFT minting."
    );
  }
  // TODO: replace with real Metaplex Core call:
  //
  //   import { create, mplCore } from "@metaplex-foundation/mpl-core";
  //   import { createUmi } from "@metaplex-foundation/umi-bundle-defaults";
  //   import { keypairIdentity } from "@metaplex-foundation/umi";
  //
  //   const umi = createUmi(RPC_URL).use(mplCore())
  //     .use(keypairIdentity(umi.eddsa.createKeypairFromSecretKey(nftAuth.secretKey)));
  //
  //   const asset = generateSigner(umi);
  //   await create(umi, {
  //     asset,
  //     name: args.name,
  //     uri: args.metadataUri,
  //     owner: publicKey(args.recipient),
  //     plugins: [{
  //       type: "Attributes",
  //       attributeList: [
  //         { key: "topSpeed", value: args.attributes.topSpeed.toString() },
  //         { key: "accel", value: args.attributes.accel.toString() },
  //         { key: "handling", value: args.attributes.handling.toString() },
  //         { key: "kartType", value: args.attributes.kartType.toString() },
  //       ]
  //     }],
  //   }).sendAndConfirm(umi);
  //
  //   return { assetAddress: asset.publicKey, signature: ... };
  console.warn("[nft] mintKartNft is a stub — wire up @metaplex-foundation/mpl-core");
  return {
    assetAddress: "STUB-asset-pubkey",
    signature: "STUB-signature",
  };
}

/**
 * Off-chain index helper. In production, replace with a Helius / Triton DAS
 * call to fetch owned Metaplex Core assets filtered by our collection.
 */
export async function fetchOwnedKarts(_wallet: string): Promise<Array<{
  mint: string; name: string; topSpeed: number; accel: number; handling: number;
  kartType: number; uri: string;
}>> {
  return [];
}
