/**
 * Fetch the NFT karts owned by a wallet.
 *
 * MVP stub. Replace with a Helius/Triton DAS (Digital Asset Standard) call:
 *
 *   POST https://devnet.helius-rpc.com/?api-key=...
 *   { jsonrpc:"2.0", id:1, method:"getAssetsByOwner",
 *     params: { ownerAddress: wallet, page: 1, limit: 100 } }
 *
 * Then filter the returned assets to your Metaplex Core collection address
 * and map each asset's Attributes plugin → kart stats.
 */

export type OwnedKart = {
  mint: string;
  name: string;
  topSpeed: number;
  accel: number;
  handling: number;
  kartType: number;
  uri: string;
};

export async function fetchOwnedKarts(_wallet: string): Promise<OwnedKart[]> {
  return [];
}
