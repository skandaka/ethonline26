// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IContinuousClearingAuction} from 'continuous-clearing-auction/interfaces/IContinuousClearingAuction.sol';
import {Bid} from 'continuous-clearing-auction/libraries/BidLib.sol';
import {Checkpoint} from 'continuous-clearing-auction/libraries/CheckpointLib.sol';

/// @notice Which settlement call a bid should use right now.
enum ExitRoute {
    /// @notice The bid has already been exited. Nothing to do.
    ALREADY_EXITED,
    /// @notice The bid exists but cannot be exited at this block.
    /// @dev Either the auction is live and has not graduated, or the bid is still fully
    ///      filled (winning) and the auction has not reached its end block.
    NOT_YET_EXITABLE,
    /// @notice Call `exitBid(bidId)`. Requires no hints.
    EXIT_BID,
    /// @notice Call `exitPartiallyFilledBid(bidId, lastFullyFilledCheckpointBlock, outbidBlock)`.
    EXIT_PARTIALLY_FILLED
}

/// @notice A complete, ready-to-use settlement plan for a single bid.
struct ExitPlan {
    /// @notice The bid this plan describes.
    uint256 bidId;
    /// @notice The address that will receive the refund and the tokens.
    address owner;
    /// @notice Which auction function to call.
    ExitRoute route;
    /// @notice Hint #1: the last checkpoint whose clearing price is strictly below `bidMaxPrice`.
    /// @dev Only meaningful when `route == EXIT_PARTIALLY_FILLED`.
    uint64 lastFullyFilledCheckpointBlock;
    /// @notice Hint #2: the first checkpoint whose clearing price is strictly above `bidMaxPrice`.
    /// @dev Zero means the bid was never outbid. Only meaningful when `route == EXIT_PARTIALLY_FILLED`.
    uint64 outbidBlock;
    /// @notice False when the checkpoint walk ran out of hops before reaching a conclusion.
    /// @dev When false, `route` is not trustworthy. Resume with `resolveExitPlanPaged` and `cursor`.
    bool hintsResolved;
    /// @notice Resume point for a truncated walk. Only meaningful when `hintsResolved` is false.
    HintCursor cursor;
    /// @notice How many checkpoints the walk visited. Useful for sizing a paged walk.
    uint32 hops;
    /// @notice The bid's max price, in Q96.
    uint256 bidMaxPrice;
    /// @notice The auction's clearing price after checkpointing, in Q96.
    uint256 clearingPrice;
    /// @notice Whether the auction has met `requiredCurrencyRaised`.
    bool graduated;
    /// @notice Whether the auction has reached its end block.
    bool auctionOver;
}

/// @notice Resume state for a checkpoint walk that exceeded its hop budget.
struct HintCursor {
    /// @notice The next checkpoint block to visit. Zero means "start from the bid's start block".
    uint64 nextBlock;
    /// @notice The best `lastFullyFilledCheckpointBlock` found so far.
    uint64 lastFullyFilledCheckpointBlock;
}

/// @title CCAExitLens
/// @notice Resolves the checkpoint hints required by
///         `ContinuousClearingAuction.exitPartiallyFilledBid` in a single `eth_call`.
/// @dev A Continuous Clearing Auction stores its checkpoints as a sparse mapping from block
///      number to `Checkpoint`, threaded together by `prev`/`next` pointers. Reading
///      `checkpoints(n)` for an arbitrary block `n` returns a zeroed struct, so the list cannot
///      be binary searched from offchain — it can only be walked one pointer at a time, and each
///      hop needs the result of the previous hop. Doing that over JSON-RPC costs one sequential
///      round trip per checkpoint.
///
///      This lens performs the same walk inside the EVM, so the whole search costs one `eth_call`.
///      It is stateless and holds no funds, so a single deployment is safe to share across every
///      auction on a chain — the same deployment model as Uniswap's own `CCALens`.
///
///      The walk relies on a protocol invariant that the auction itself documents: the clearing
///      price never decreases between checkpoints. A bid's lifetime therefore splits into three
///      contiguous, monotonically ordered regions:
///
///          [ clearingPrice < maxPrice ] [ clearingPrice == maxPrice ] [ clearingPrice > maxPrice ]
///                 fully filled              partially filled                  outbid
///                            ^                                        ^
///          lastFullyFilledCheckpointBlock                        outbidBlock
///
///      which is exactly the pair of hints `exitPartiallyFilledBid` validates.
contract CCAExitLens {
    /// @notice Sentinel stored in `Checkpoint.next` for the newest checkpoint in the list.
    uint64 internal constant MAX_BLOCK_NUMBER = type(uint64).max;

    /// @notice Hop budget used by the unpaged entrypoints.
    /// @dev A checkpoint is only written on blocks that receive a bid, so this comfortably covers
    ///      auctions far longer than any deployed today. Auctions that exceed it are still
    ///      resolvable through `resolveExitPlanPaged`.
    uint32 public constant DEFAULT_MAX_HOPS = 20_000;

    /// @notice Resolve the settlement plan for a single bid.
    /// @dev Not a `view` function: it calls `auction.checkpoint()` first, exactly as
    ///      `exitPartiallyFilledBid` does, so that the returned hints are validated against the
    ///      same state the exit call will observe. Call it with `eth_call` (or from a contract,
    ///      as `CCAExitRouter` does) — it never mutates state that the caller keeps.
    /// @param auction The auction to inspect.
    /// @param bidId The bid to settle.
    /// @return plan The route to take and the hints to pass.
    function resolveExitPlan(IContinuousClearingAuction auction, uint256 bidId)
        public
        returns (ExitPlan memory plan)
    {
        return resolveExitPlanPaged(auction, bidId, HintCursor({nextBlock: 0, lastFullyFilledCheckpointBlock: 0}), DEFAULT_MAX_HOPS);
    }

    /// @notice Resolve the settlement plan for a bid, bounding the number of checkpoints visited.
    /// @dev If the returned plan has `hintsResolved == false`, call this again passing the
    ///      returned `cursor` to continue the walk where it stopped.
    /// @param auction The auction to inspect.
    /// @param bidId The bid to settle.
    /// @param resume Cursor from a previous truncated call, or a zeroed cursor to start fresh.
    /// @param maxHops Maximum number of checkpoints to visit in this call.
    /// @return plan The route to take and the hints to pass.
    function resolveExitPlanPaged(
        IContinuousClearingAuction auction,
        uint256 bidId,
        HintCursor memory resume,
        uint32 maxHops
    ) public returns (ExitPlan memory plan) {
        Bid memory bid = auction.bids(bidId);

        plan.bidId = bidId;
        plan.owner = bid.owner;
        plan.bidMaxPrice = bid.maxPrice;

        // Bring the auction up to date. `exitPartiallyFilledBid` checkpoints before it validates
        // the hints, and that checkpoint can itself be the one that outbids this bid, so the hints
        // must be computed against post-checkpoint state.
        //
        // This runs before the already-exited check so that every plan carries accurate auction
        // state, including plans for settled bids — a caller rendering a portfolio should not be
        // told an auction has not graduated simply because the bid it asked about is closed.
        uint256 clearing;
        try auction.checkpoint() returns (Checkpoint memory current) {
            clearing = current.clearingPrice;
        } catch {
            // The auction rejects checkpointing before it starts or before it is funded. Neither
            // state can have bids, but fall back to stored state rather than reverting a batch.
            clearing = auction.latestCheckpoint().clearingPrice;
        }

        plan.clearingPrice = clearing;
        plan.graduated = auction.isGraduated();
        // After checkpointing, the newest checkpoint sits at the end block if and only if the
        // auction has ended. This mirrors `onlyAfterAuctionIsOver` without re-deriving the
        // chain-specific block number that `BlockNumberish` resolves for the auction.
        plan.auctionOver = auction.lastCheckpointedBlock() >= auction.endBlock();

        if (bid.exitedBlock != 0) {
            plan.route = ExitRoute.ALREADY_EXITED;
            plan.hintsResolved = true;
            return plan;
        }

        if (!plan.graduated) {
            // A failed auction refunds in full through either exit function once it is over.
            // `exitBid` is the cheaper of the two and needs no hints.
            plan.route = plan.auctionOver ? ExitRoute.EXIT_BID : ExitRoute.NOT_YET_EXITABLE;
            plan.hintsResolved = true;
            return plan;
        }

        (uint64 lastFullyFilled, uint64 outbidBlock, bool resolved, HintCursor memory cursor, uint32 hops) =
            _walk(auction, bid, resume, maxHops);

        plan.lastFullyFilledCheckpointBlock = lastFullyFilled;
        plan.outbidBlock = outbidBlock;
        plan.hintsResolved = resolved;
        plan.cursor = cursor;
        plan.hops = hops;

        if (!resolved) {
            plan.route = ExitRoute.NOT_YET_EXITABLE;
            return plan;
        }

        if (outbidBlock != 0) {
            // The bid was outbid at a checkpoint. This is the one case that can be settled while
            // the auction is still running, which is what lets an outbid bidder recover capital
            // early instead of waiting for the end block.
            plan.route = ExitRoute.EXIT_PARTIALLY_FILLED;
        } else if (!plan.auctionOver) {
            // Still winning, and the auction has not ended. `exitBid` requires the end block and
            // `exitPartiallyFilledBid` would revert with CannotPartiallyExitBidBeforeEndBlock.
            plan.route = ExitRoute.NOT_YET_EXITABLE;
        } else if (clearing < bid.maxPrice) {
            // Fully filled for the whole auction: no partial-fill window, so no hints are needed.
            plan.route = ExitRoute.EXIT_BID;
        } else {
            // Final clearing price sits exactly at the bid's max price: settle the partial window
            // with a zero `outbidBlock`.
            plan.route = ExitRoute.EXIT_PARTIALLY_FILLED;
        }
    }

    /// @notice Resolve settlement plans for every bid in `[fromBidId, toBidId)` owned by `owner`.
    /// @dev Bids are stored in a flat, append-only mapping with no per-owner index, so finding a
    ///      wallet's bids means scanning ids. Doing that offchain is one round trip per bid; this
    ///      does the whole scan, and every hint walk it implies, in one `eth_call`.
    /// @param auction The auction to inspect.
    /// @param owner The bidder to filter on. Pass `address(0)` to keep every bid in range.
    /// @param fromBidId First bid id to scan, inclusive.
    /// @param toBidId Last bid id to scan, exclusive. Clamped to the auction's `nextBidId()`.
    /// @param maxHopsPerBid Hop budget applied to each bid's checkpoint walk.
    /// @return plans One plan per matching bid, in ascending bid id order.
    function resolveExitPlansForOwner(
        IContinuousClearingAuction auction,
        address owner,
        uint256 fromBidId,
        uint256 toBidId,
        uint32 maxHopsPerBid
    ) external returns (ExitPlan[] memory plans) {
        uint256 nextBidId = auction.nextBidId();
        if (toBidId > nextBidId) toBidId = nextBidId;
        if (fromBidId >= toBidId) return new ExitPlan[](0);

        ExitPlan[] memory buffer = new ExitPlan[](toBidId - fromBidId);
        HintCursor memory fresh;
        uint256 found;

        for (uint256 id = fromBidId; id < toBidId; ++id) {
            if (owner != address(0) && auction.bids(id).owner != owner) continue;
            buffer[found++] = resolveExitPlanPaged(auction, id, fresh, maxHopsPerBid);
        }

        plans = new ExitPlan[](found);
        for (uint256 i = 0; i < found; ++i) {
            plans[i] = buffer[i];
        }
    }

    /// @notice Walk the checkpoint list to locate the boundaries of the bid's partial-fill window.
    /// @dev The walk starts at the bid's start block, which is always checkpointed (a bid cannot be
    ///      submitted without checkpointing its block) and whose clearing price is always strictly
    ///      below the bid's max price (the auction rejects bids at or under the clearing price).
    ///      Because the clearing price never decreases, the first checkpoint above the bid's max
    ///      price is the outbid block, and the last one seen below it is the fully filled boundary.
    function _walk(
        IContinuousClearingAuction auction,
        Bid memory bid,
        HintCursor memory resume,
        uint32 maxHops
    )
        internal
        view
        returns (uint64 lastFullyFilled, uint64 outbidBlock, bool resolved, HintCursor memory cursor, uint32 hops)
    {
        uint256 maxPrice = bid.maxPrice;
        uint64 current = resume.nextBlock == 0 ? bid.startBlock : resume.nextBlock;
        lastFullyFilled = resume.lastFullyFilledCheckpointBlock;

        while (hops < maxHops) {
            Checkpoint memory checkpoint = auction.checkpoints(current);
            unchecked {
                ++hops;
            }

            uint256 price = checkpoint.clearingPrice;
            if (price > maxPrice) {
                // First checkpoint strictly above the bid. Its `prev` is the last checkpoint at or
                // below the bid, which is precisely what `exitPartiallyFilledBid` requires.
                return (lastFullyFilled, current, true, cursor, hops);
            }
            if (price < maxPrice) {
                lastFullyFilled = current;
            }
            // price == maxPrice: inside the partial-fill window. Keep walking to find its end.

            uint64 next = checkpoint.next;
            if (next == MAX_BLOCK_NUMBER || next == 0) {
                // Reached the newest checkpoint without the price ever passing the bid.
                return (lastFullyFilled, 0, true, cursor, hops);
            }
            current = next;
        }

        // Out of budget. Hand back everything needed to continue from exactly here.
        cursor = HintCursor({nextBlock: current, lastFullyFilledCheckpointBlock: lastFullyFilled});
        return (lastFullyFilled, 0, false, cursor, hops);
    }
}
