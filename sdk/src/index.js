/**
 * cca-exit-sdk — resolve Uniswap Continuous Clearing Auction bid exit hints in one eth_call.
 *
 * A CCA bidder who was outbid can recover their unspent currency before the auction ends, but
 * `exitPartiallyFilledBid` requires two checkpoint block-number hints. This wraps `CCAExitLens`,
 * which computes them by walking the checkpoint list inside the EVM — so resolving a position
 * costs one `eth_call` and needs no indexer, database or backfill.
 */

import { auctionAbi, lensAbi, routerAbi } from './abi.js';

/** Settlement routes, matching the `ExitRoute` enum in CCAExitLens.sol. */
export const ExitRoute = Object.freeze({
  ALREADY_EXITED: 0,
  NOT_YET_EXITABLE: 1,
  EXIT_BID: 2,
  EXIT_PARTIALLY_FILLED: 3,
});

const ROUTE_NAMES = ['ALREADY_EXITED', 'NOT_YET_EXITABLE', 'EXIT_BID', 'EXIT_PARTIALLY_FILLED'];

/** @param {number} route */
export const routeName = (route) => ROUTE_NAMES[route] ?? `UNKNOWN(${route})`;

/** True when the plan can be acted on at the block it was resolved against. */
export const isSettleable = (plan) =>
  plan.hintsResolved &&
  (plan.route === ExitRoute.EXIT_BID || plan.route === ExitRoute.EXIT_PARTIALLY_FILLED);

/**
 * Resolve the settlement plan for a single bid.
 *
 * The lens is deliberately not a `view` function: it calls `auction.checkpoint()` first, exactly as
 * `exitPartiallyFilledBid` does, so the hints are validated against the same state the exit call
 * will observe. `simulateContract` runs it as an `eth_call`, so nothing is written on chain.
 *
 * @param {import('viem').PublicClient} client
 * @param {{ lens: `0x${string}`, auction: `0x${string}`, bidId: bigint | number }} params
 */
export async function resolveExitPlan(client, { lens, auction, bidId }) {
  const { result } = await client.simulateContract({
    address: lens,
    abi: lensAbi,
    functionName: 'resolveExitPlan',
    args: [auction, BigInt(bidId)],
  });
  return result;
}

/**
 * Resolve plans for every bid belonging to `owner`.
 *
 * Bids are stored in a flat append-only mapping with no per-owner index, so this scans ids. The
 * scan — and every hint walk it implies — happens inside one `eth_call`.
 *
 * @param {import('viem').PublicClient} client
 * @param {{ lens: `0x${string}`, auction: `0x${string}`, owner: `0x${string}`,
 *           fromBidId?: bigint, toBidId?: bigint, maxHopsPerBid?: number }} params
 */
export async function resolveExitPlansForOwner(
  client,
  { lens, auction, owner, fromBidId = 0n, toBidId, maxHopsPerBid = 20_000 },
) {
  const to =
    toBidId ??
    (await client.readContract({ address: auction, abi: auctionAbi, functionName: 'nextBidId' }));

  const { result } = await client.simulateContract({
    address: lens,
    abi: lensAbi,
    functionName: 'resolveExitPlansForOwner',
    args: [auction, owner, BigInt(fromBidId), BigInt(to), maxHopsPerBid],
  });
  return result;
}

/**
 * Build the transaction that settles a plan directly against the auction, hints included.
 *
 * Use this when you want to call the auction yourself. `buildRouterExitCall` is simpler if you are
 * happy to route through `CCAExitRouter`.
 *
 * @returns {{ address: `0x${string}`, abi: unknown, functionName: string, args: unknown[] }}
 */
export function buildExitCall({ auction, plan }) {
  if (!plan.hintsResolved) {
    throw new Error(
      `hint walk was truncated for bid ${plan.bidId}; resume from block ${plan.cursor.nextBlock} ` +
        `with resolveExitPlanPaged before building a transaction`,
    );
  }

  switch (plan.route) {
    case ExitRoute.EXIT_BID:
      return { address: auction, abi: auctionAbi, functionName: 'exitBid', args: [plan.bidId] };
    case ExitRoute.EXIT_PARTIALLY_FILLED:
      return {
        address: auction,
        abi: auctionAbi,
        functionName: 'exitPartiallyFilledBid',
        args: [plan.bidId, plan.lastFullyFilledCheckpointBlock, plan.outbidBlock],
      };
    default:
      throw new Error(`bid ${plan.bidId} is not settleable right now (${routeName(plan.route)})`);
  }
}

/**
 * Build the router call, which resolves the hints on chain and settles atomically.
 *
 * Safe to send on somebody else's behalf: auction exits have no caller restriction and always pay
 * the bid's owner, never the caller.
 */
export function buildRouterExitCall({ router, auction, bidId }) {
  return {
    address: router,
    abi: routerAbi,
    functionName: 'exit',
    args: [auction, BigInt(bidId)],
  };
}

/** Render a plan as a human-readable block. */
export function formatPlan(plan) {
  const lines = [
    `bid ${plan.bidId}  owner ${plan.owner}`,
    `  route                          : ${routeName(plan.route)}`,
  ];

  if (plan.route === ExitRoute.EXIT_PARTIALLY_FILLED) {
    lines.push(
      `  lastFullyFilledCheckpointBlock : ${plan.lastFullyFilledCheckpointBlock}`,
      `  outbidBlock                    : ${
        plan.outbidBlock === 0n ? '0 (never outbid)' : plan.outbidBlock
      }`,
    );
  }

  lines.push(
    `  checkpoints walked             : ${plan.hops}`,
    `  bid max price (Q96)            : ${plan.bidMaxPrice}`,
    `  clearing price (Q96)           : ${plan.clearingPrice}`,
    `  graduated / over               : ${plan.graduated} / ${plan.auctionOver}`,
  );

  if (!plan.hintsResolved) {
    lines.push(`  ⚠ walk truncated, resume from block ${plan.cursor.nextBlock}`);
  }
  return lines.join('\n');
}

export { auctionAbi, lensAbi, routerAbi };
