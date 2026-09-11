// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {CCAExitLens, ExitPlan, ExitRoute} from './CCAExitLens.sol';
import {IContinuousClearingAuction} from 'continuous-clearing-auction/interfaces/IContinuousClearingAuction.sol';

/// @title CCAExitRouter
/// @notice Settles Continuous Clearing Auction bids without the caller ever computing a hint.
/// @dev The router resolves the checkpoint hints with `CCAExitLens` and forwards the correct exit
///      call in the same transaction, so a bidder recovers their unspent currency with one call and
///      no offchain indexing.
///
///      This is safe to expose permissionlessly, and safe to call on behalf of somebody else,
///      because of two properties of the auction itself:
///
///        1. `exitBid` and `exitPartiallyFilledBid` have no caller restriction — anyone may settle
///           any bid; and
///        2. `_processExit` always pays the refund to `bid.owner`, never to `msg.sender`.
///
///      The router therefore cannot redirect value. It holds no funds and has no privileged state,
///      so a single deployment is safe to share across every auction on a chain.
contract CCAExitRouter {
    /// @notice The lens used to resolve checkpoint hints.
    CCAExitLens public immutable LENS;

    /// @notice Thrown when a bid cannot be settled at this block.
    error BidNotExitable(uint256 bidId, ExitRoute route);
    /// @notice Thrown when the hint walk exceeded its budget before reaching a conclusion.
    /// @dev Resolve the plan offchain with `CCAExitLens.resolveExitPlanPaged` and settle with
    ///      `exitWithHints`.
    error HintSearchTruncated(uint256 bidId, uint64 resumeBlock);

    /// @notice Emitted for each successfully settled bid.
    event BidSettled(address indexed auction, uint256 indexed bidId, address indexed owner, ExitRoute route);

    constructor(CCAExitLens lens) {
        LENS = lens;
    }

    /// @notice Resolve the hints for `bidId` and settle it in the same transaction.
    /// @param auction The auction holding the bid.
    /// @param bidId The bid to settle. The refund is always paid to the bid's owner.
    /// @return route The exit route that was taken.
    function exit(IContinuousClearingAuction auction, uint256 bidId) public returns (ExitRoute route) {
        ExitPlan memory plan = LENS.resolveExitPlan(auction, bidId);

        if (!plan.hintsResolved) revert HintSearchTruncated(bidId, plan.cursor.nextBlock);

        route = plan.route;
        if (route == ExitRoute.EXIT_BID) {
            auction.exitBid(bidId);
        } else if (route == ExitRoute.EXIT_PARTIALLY_FILLED) {
            auction.exitPartiallyFilledBid(bidId, plan.lastFullyFilledCheckpointBlock, plan.outbidBlock);
        } else {
            revert BidNotExitable(bidId, route);
        }

        emit BidSettled(address(auction), bidId, plan.owner, route);
    }

    /// @notice Settle several bids on the same auction.
    /// @dev Reverts if any bid in the list cannot be settled, so that a caller batching a wallet's
    ///      bids never half-settles. Use `exitSkippingFailures` to settle whatever is ready.
    /// @param auction The auction holding the bids.
    /// @param bidIds The bids to settle.
    /// @return routes The route taken for each bid, in the order given.
    function exitBatch(IContinuousClearingAuction auction, uint256[] calldata bidIds)
        external
        returns (ExitRoute[] memory routes)
    {
        routes = new ExitRoute[](bidIds.length);
        for (uint256 i = 0; i < bidIds.length; ++i) {
            routes[i] = exit(auction, bidIds[i]);
        }
    }

    /// @notice Settle every bid in the list that is currently settleable, skipping the rest.
    /// @param auction The auction holding the bids.
    /// @param bidIds The bids to attempt.
    /// @return settled Whether each bid was settled, in the order given.
    function exitSkippingFailures(IContinuousClearingAuction auction, uint256[] calldata bidIds)
        external
        returns (bool[] memory settled)
    {
        settled = new bool[](bidIds.length);
        for (uint256 i = 0; i < bidIds.length; ++i) {
            try this.exit(auction, bidIds[i]) returns (ExitRoute) {
                settled[i] = true;
            } catch {
                settled[i] = false;
            }
        }
    }

    /// @notice Settle every currently-settleable bid in a range, whoever owns them.
    /// @dev This is the capability an offchain indexer cannot provide at all: discovery and
    ///      settlement together, inside one transaction. A keeper can sweep an auction and return
    ///      capital to outbid bidders who never transact themselves — every refund goes to its own
    ///      `bid.owner`, so the keeper moves no value to itself and needs no trust.
    ///
    ///      Bids that are not settleable yet are skipped rather than reverting the sweep.
    /// @param auction The auction to sweep.
    /// @param fromBidId First bid id to consider, inclusive.
    /// @param toBidId Last bid id to consider, exclusive. Clamped to the auction's `nextBidId()`.
    /// @return settled How many bids were settled.
    function sweep(IContinuousClearingAuction auction, uint256 fromBidId, uint256 toBidId)
        external
        returns (uint256 settled)
    {
        uint256 nextBidId = auction.nextBidId();
        if (toBidId > nextBidId) toBidId = nextBidId;

        for (uint256 id = fromBidId; id < toBidId; ++id) {
            try this.exit(auction, id) returns (ExitRoute) {
                unchecked {
                    ++settled;
                }
            } catch {
                // Not settleable at this block, or already exited. Leave it for a later sweep.
            }
        }
    }

    /// @notice Settle a bid and, if the auction is already claimable, claim its tokens too.
    /// @dev The claim is attempted only after a successful exit and is allowed to fail: the auction
    ///      rejects claims before its claim block, and that must not undo the refund.
    /// @param auction The auction holding the bid.
    /// @param bidId The bid to settle.
    /// @return route The exit route that was taken.
    /// @return claimed Whether the token claim also went through.
    function exitAndClaim(IContinuousClearingAuction auction, uint256 bidId)
        external
        returns (ExitRoute route, bool claimed)
    {
        route = exit(auction, bidId);
        try auction.claimTokens(bidId) {
            claimed = true;
        } catch {
            claimed = false;
        }
    }

    /// @notice Settle a bid with hints the caller already resolved.
    /// @dev Escape hatch for auctions whose checkpoint list is too long to walk inside one call.
    ///      Resolve the plan with `CCAExitLens.resolveExitPlanPaged` across several `eth_call`s,
    ///      then pass the result here.
    /// @param auction The auction holding the bid.
    /// @param bidId The bid to settle.
    /// @param lastFullyFilledCheckpointBlock Hint #1.
    /// @param outbidBlock Hint #2, or zero if the bid was never outbid.
    function exitWithHints(
        IContinuousClearingAuction auction,
        uint256 bidId,
        uint64 lastFullyFilledCheckpointBlock,
        uint64 outbidBlock
    ) external {
        auction.exitPartiallyFilledBid(bidId, lastFullyFilledCheckpointBlock, outbidBlock);
        emit BidSettled(address(auction), bidId, auction.bids(bidId).owner, ExitRoute.EXIT_PARTIALLY_FILLED);
    }
}
