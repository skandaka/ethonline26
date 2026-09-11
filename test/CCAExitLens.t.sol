// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {CCAExitLens, ExitPlan, ExitRoute, HintCursor} from '../src/CCAExitLens.sol';
import {CCAExitTestBase} from './utils/CCAExitTestBase.sol';
import {IContinuousClearingAuction} from 'continuous-clearing-auction/interfaces/IContinuousClearingAuction.sol';

/// @notice End-to-end tests for `CCAExitLens` against real `ContinuousClearingAuction` deployments.
/// @dev Every test that produces hints also *spends* them on the real auction. A hint that the
///      auction rejects fails the test, so these are differential tests against the protocol
///      itself rather than assertions about a reimplementation of it.
contract CCAExitLensTest is CCAExitTestBase {
    /// @dev Demand large enough to clear the entire supply at `price`, several times over.
    function _floodAt(address who, uint256 price) internal returns (uint256) {
        return _bid(who, _costOf(3 * uint256(TOTAL_SUPPLY), price), price);
    }

    /// @dev Flood the book at `price` and record the resulting clearing price in a checkpoint.
    /// @dev `submitBid` checkpoints *before* it books the new demand, so a bid never moves the
    ///      clearing price of its own block. The new price is only observable from the next
    ///      checkpoint onward, which is also the first block at which an outbid bidder can exit.
    /// @return registeredAt The block whose checkpoint first carries the raised clearing price.
    function _floodAndRegister(address who, uint256 price) internal returns (uint64 registeredAt) {
        _floodAt(who, price);
        _advance(1);
        registeredAt = uint64(block.number);
        auction.checkpoint();
    }

    // ---------------------------------------------------------------------
    // The headline case: an outbid bidder recovers capital before the end.
    // ---------------------------------------------------------------------

    /// @notice An outbid bidder settles mid-auction using only hints the lens produced.
    function test_outbidMidAuction_settlesEarlyWithLensHints() public {
        _deployAuction(0);

        uint256 aliceBid = _bid(alice, _costOf(1e18, _price(2)), _price(2));
        _advance(10);
        uint64 floodBlock = uint64(block.number);
        uint64 outbidBlock = _floodAndRegister(bob, _price(8)); // lifts the clearing price above Alice

        // Still mid-auction: this is precisely the window where a bidder wants their money back.
        assertLt(block.number, endBlock, 'auction should still be live');

        ExitPlan memory plan = lens.resolveExitPlan(auction, aliceBid);

        assertTrue(plan.hintsResolved, 'hints should resolve');
        assertEq(uint8(plan.route), uint8(ExitRoute.EXIT_PARTIALLY_FILLED), 'route');
        assertEq(plan.outbidBlock, outbidBlock, 'outbid block hint');
        assertEq(plan.lastFullyFilledCheckpointBlock, floodBlock, 'last fully filled hint');
        assertEq(plan.owner, alice, 'owner');
        assertFalse(plan.auctionOver, 'auction should not be over');
        assertTrue(plan.graduated, 'auction should have graduated');

        uint256 balanceBefore = alice.balance;

        // Spend the hints on the real auction.
        auction.exitPartiallyFilledBid(aliceBid, plan.lastFullyFilledCheckpointBlock, plan.outbidBlock);

        assertGt(alice.balance, balanceBefore, 'alice should be refunded');
        assertGt(auction.bids(aliceBid).exitedBlock, 0, 'bid should be marked exited');
    }

    /// @notice The same bid, settled through the router, with the caller supplying no hints at all.
    function test_router_settlesOutbidBidWithoutHints() public {
        _deployAuction(0);

        uint256 aliceBid = _bid(alice, _costOf(1e18, _price(2)), _price(2));
        _advance(10);
        _floodAndRegister(bob, _price(8));

        uint256 balanceBefore = alice.balance;

        // Carol settles Alice's bid. Refunds always route to the bid owner, never the caller.
        vm.prank(carol);
        ExitRoute route = router.exit(auction, aliceBid);

        assertEq(uint8(route), uint8(ExitRoute.EXIT_PARTIALLY_FILLED), 'route');
        assertGt(alice.balance, balanceBefore, 'alice should be refunded');
        assertGt(auction.bids(aliceBid).exitedBlock, 0, 'bid should be exited');
    }

    // ---------------------------------------------------------------------
    // The three-region lifetime: fully filled -> partially filled -> outbid.
    // ---------------------------------------------------------------------

    /// @notice A bid that sits at the clearing price for several blocks before being outbid.
    function test_partialFillWindowThenOutbid() public {
        _deployAuction(0);

        uint256 alicePrice = _price(5);
        uint256 aliceBid = _bid(alice, _costOf(1e18, alicePrice), alicePrice);

        _advance(5);
        // Bob bids at Alice's own tick with enough demand to lift the clearing price onto it.
        uint64 windowStart = _floodAndRegister(bob, alicePrice);
        assertEq(auction.clearingPrice(), alicePrice, 'clearing price should sit on alice tick');

        _advance(5);
        auction.checkpoint();
        assertEq(auction.clearingPrice(), alicePrice, 'clearing price should stay on alice tick');

        _advance(5);
        uint64 outbidBlock = _floodAndRegister(carol, _price(9)); // lifts the price above Alice

        ExitPlan memory plan = lens.resolveExitPlan(auction, aliceBid);

        assertTrue(plan.hintsResolved, 'hints should resolve');
        assertEq(uint8(plan.route), uint8(ExitRoute.EXIT_PARTIALLY_FILLED), 'route');
        assertEq(plan.outbidBlock, outbidBlock, 'outbid block hint');
        // The last checkpoint strictly below Alice's price is the one before the window opened.
        assertLt(plan.lastFullyFilledCheckpointBlock, windowStart, 'hint must precede the window');

        uint256 balanceBefore = alice.balance;
        auction.exitPartiallyFilledBid(aliceBid, plan.lastFullyFilledCheckpointBlock, plan.outbidBlock);
        assertGt(alice.balance, balanceBefore, 'alice should be refunded');
    }

    // ---------------------------------------------------------------------
    // The other routes.
    // ---------------------------------------------------------------------

    /// @notice A bid that stays above the clearing price for the whole auction needs no hints.
    function test_fullyFilledBid_routesToExitBid() public {
        _deployAuction(0);

        uint256 aliceBid = _bid(alice, _costOf(1e18, _price(9)), _price(9));
        _advance(5);
        _bid(bob, _costOf(1e18, _price(2)), _price(2)); // never lifts the price to Alice

        _advance(uint256(AUCTION_DURATION));

        ExitPlan memory plan = lens.resolveExitPlan(auction, aliceBid);

        assertTrue(plan.auctionOver, 'auction should be over');
        assertEq(uint8(plan.route), uint8(ExitRoute.EXIT_BID), 'route');
        assertEq(plan.outbidBlock, 0, 'never outbid');

        // A bid that clears for the whole auction spends its currency on tokens rather than being
        // refunded, so the settlement to assert on is the fill, not the balance.
        auction.exitBid(aliceBid);
        assertGt(auction.bids(aliceBid).exitedBlock, 0, 'bid should be marked exited');
        assertGt(auction.bids(aliceBid).tokensFilled, 0, 'a fully filled bid should have bought tokens');
    }

    /// @notice A bid whose max price equals the final clearing price settles with a zero outbid hint.
    function test_finalClearingEqualsMaxPrice_routesToPartialWithZeroOutbidHint() public {
        _deployAuction(0);

        uint256 alicePrice = _price(5);
        uint256 aliceBid = _bid(alice, _costOf(1e18, alicePrice), alicePrice);

        _advance(5);
        _floodAt(bob, alicePrice); // parks the clearing price exactly on Alice's tick

        _advance(uint256(AUCTION_DURATION));
        auction.checkpoint();
        assertEq(auction.clearingPrice(), alicePrice, 'final clearing price should equal alice max');

        ExitPlan memory plan = lens.resolveExitPlan(auction, aliceBid);

        assertTrue(plan.auctionOver, 'auction should be over');
        assertEq(uint8(plan.route), uint8(ExitRoute.EXIT_PARTIALLY_FILLED), 'route');
        assertEq(plan.outbidBlock, 0, 'never outbid');

        auction.exitPartiallyFilledBid(aliceBid, plan.lastFullyFilledCheckpointBlock, plan.outbidBlock);
        assertGt(auction.bids(aliceBid).exitedBlock, 0, 'bid should be exited');
    }

    /// @notice An auction that misses its graduation threshold refunds in full.
    function test_notGraduated_routesToFullRefund() public {
        // A threshold no bid in this test can reach.
        _deployAuction(type(uint128).max);

        uint256 aliceBid = _bid(alice, _costOf(1e18, _price(2)), _price(2));
        _advance(uint256(AUCTION_DURATION));

        ExitPlan memory plan = lens.resolveExitPlan(auction, aliceBid);

        assertFalse(plan.graduated, 'auction should not have graduated');
        assertTrue(plan.auctionOver, 'auction should be over');
        assertEq(uint8(plan.route), uint8(ExitRoute.EXIT_BID), 'route');

        uint256 balanceBefore = alice.balance;
        auction.exitBid(aliceBid);
        assertEq(alice.balance, balanceBefore + _costOf(1e18, _price(2)), 'alice should be fully refunded');
    }

    /// @notice A live, not-yet-graduated auction offers no exit.
    function test_liveAuctionNotGraduated_isNotExitable() public {
        _deployAuction(type(uint128).max);

        uint256 aliceBid = _bid(alice, _costOf(1e18, _price(2)), _price(2));
        _advance(5);

        ExitPlan memory plan = lens.resolveExitPlan(auction, aliceBid);
        assertEq(uint8(plan.route), uint8(ExitRoute.NOT_YET_EXITABLE), 'route');

        vm.expectRevert();
        router.exit(auction, aliceBid);
    }

    /// @notice A bid that is still winning mid-auction cannot be settled yet.
    function test_stillWinningMidAuction_isNotExitable() public {
        _deployAuction(0);

        uint256 aliceBid = _bid(alice, _costOf(1e18, _price(9)), _price(9));
        _advance(5);
        _floodAt(bob, _price(3)); // graduates the auction but stays below Alice

        ExitPlan memory plan = lens.resolveExitPlan(auction, aliceBid);

        assertTrue(plan.graduated, 'auction should have graduated');
        assertFalse(plan.auctionOver, 'auction should still be live');
        assertEq(uint8(plan.route), uint8(ExitRoute.NOT_YET_EXITABLE), 'route');
    }

    /// @notice Once settled, a bid reports as already exited.
    function test_alreadyExited() public {
        _deployAuction(0);

        uint256 aliceBid = _bid(alice, _costOf(1e18, _price(2)), _price(2));
        _advance(10);
        _floodAndRegister(bob, _price(8));

        router.exit(auction, aliceBid);

        ExitPlan memory plan = lens.resolveExitPlan(auction, aliceBid);
        assertEq(uint8(plan.route), uint8(ExitRoute.ALREADY_EXITED), 'route');
        assertTrue(plan.hintsResolved, 'already-exited plans are terminal');

        // A settled bid must still report accurate auction state. Returning early without it would
        // tell a portfolio view that a graduated auction had not graduated.
        assertTrue(plan.graduated, 'graduated flag should survive the early return');
        assertEq(plan.clearingPrice, auction.clearingPrice(), 'clearing price should be populated');
        assertEq(plan.owner, alice, 'owner should be populated');
        assertEq(plan.bidMaxPrice, _price(2), 'bid max price should be populated');
    }

    // ---------------------------------------------------------------------
    // The hints are load-bearing: neighbouring values do not work.
    // ---------------------------------------------------------------------

    /// @notice Wrong hints are rejected by the auction, so the lens is doing real work.
    function test_wrongHints_areRejectedByTheAuction() public {
        _deployAuction(0);

        uint256 aliceBid = _bid(alice, _costOf(1e18, _price(2)), _price(2));
        _advance(10);
        _floodAndRegister(bob, _price(8));

        ExitPlan memory plan = lens.resolveExitPlan(auction, aliceBid);

        // The outbid checkpoint is not a valid "last fully filled" checkpoint.
        vm.expectRevert(IContinuousClearingAuction.InvalidLastFullyFilledCheckpointHint.selector);
        auction.exitPartiallyFilledBid(aliceBid, plan.outbidBlock, plan.outbidBlock);

        // Neither is the bid's own start block, which is not the *last* one below the bid.
        vm.expectRevert(IContinuousClearingAuction.InvalidLastFullyFilledCheckpointHint.selector);
        auction.exitPartiallyFilledBid(aliceBid, startBlock, plan.outbidBlock);

        // A checkpoint that is not the first one above the bid is not a valid outbid hint.
        vm.expectRevert(IContinuousClearingAuction.InvalidOutbidBlockCheckpointHint.selector);
        auction.exitPartiallyFilledBid(aliceBid, plan.lastFullyFilledCheckpointBlock, startBlock);

        // The correct pair still works.
        auction.exitPartiallyFilledBid(aliceBid, plan.lastFullyFilledCheckpointBlock, plan.outbidBlock);
        assertGt(auction.bids(aliceBid).exitedBlock, 0, 'bid should be exited');
    }

    // ---------------------------------------------------------------------
    // Pagination.
    // ---------------------------------------------------------------------

    /// @notice A truncated walk resumes to exactly the answer an unbounded walk gives.
    function test_pagedWalk_convergesToUnpagedAnswer() public {
        _deployAuction(0);

        uint256 aliceBid = _bid(alice, _costOf(1e18, _price(2)), _price(2));
        // Build a long checkpoint list so a one-hop budget is genuinely insufficient.
        for (uint256 i = 0; i < 12; ++i) {
            _advance(1);
            _bid(carol, _costOf(1e15, _price(3)), _price(3));
        }
        _advance(1);
        _floodAndRegister(bob, _price(8));

        ExitPlan memory expected = lens.resolveExitPlan(auction, aliceBid);
        assertTrue(expected.hintsResolved, 'reference walk should resolve');
        assertGt(expected.hops, 2, 'the list should be long enough to matter');

        // Walk it one checkpoint at a time.
        HintCursor memory cursor;
        ExitPlan memory paged;
        uint256 rounds;
        do {
            paged = lens.resolveExitPlanPaged(auction, aliceBid, cursor, 1);
            cursor = paged.cursor;
            ++rounds;
            assertLt(rounds, 100, 'paged walk should terminate');
        } while (!paged.hintsResolved);

        assertEq(paged.lastFullyFilledCheckpointBlock, expected.lastFullyFilledCheckpointBlock, 'lff hint');
        assertEq(paged.outbidBlock, expected.outbidBlock, 'outbid hint');
        assertEq(uint8(paged.route), uint8(expected.route), 'route');

        // And the paged hints settle the real bid.
        auction.exitPartiallyFilledBid(aliceBid, paged.lastFullyFilledCheckpointBlock, paged.outbidBlock);
        assertGt(auction.bids(aliceBid).exitedBlock, 0, 'bid should be exited');
    }

    // ---------------------------------------------------------------------
    // Owner scan.
    // ---------------------------------------------------------------------

    /// @notice The owner scan returns a plan per bid belonging to that wallet, and they all settle.
    function test_resolveExitPlansForOwner() public {
        _deployAuction(0);

        _bid(alice, _costOf(1e18, _price(2)), _price(2));
        _bid(bob, _costOf(1e18, _price(2)), _price(2));
        _bid(alice, _costOf(1e18, _price(3)), _price(3));
        _advance(10);
        _floodAndRegister(carol, _price(9));

        ExitPlan[] memory plans =
            lens.resolveExitPlansForOwner(auction, alice, 0, auction.nextBidId(), lens.DEFAULT_MAX_HOPS());

        assertEq(plans.length, 2, 'alice has two bids');
        for (uint256 i = 0; i < plans.length; ++i) {
            assertEq(plans[i].owner, alice, 'owner filter');
            assertEq(uint8(plans[i].route), uint8(ExitRoute.EXIT_PARTIALLY_FILLED), 'route');
            auction.exitPartiallyFilledBid(
                plans[i].bidId, plans[i].lastFullyFilledCheckpointBlock, plans[i].outbidBlock
            );
        }
    }

    // ---------------------------------------------------------------------
    // The capability an offchain indexer cannot have: settlement from a contract.
    // ---------------------------------------------------------------------

    /// @notice A keeper sweeps an auction and returns capital to bidders who never transact.
    /// @dev Discovery and settlement happen together, in one transaction, from a contract. An
    ///      indexer can tell you which bids are settleable but cannot settle them.
    function test_keeperSweepsAuctionAndRefundsEveryoneElse() public {
        _deployAuction(0);

        uint256 aliceBid = _bid(alice, _costOf(1e18, _price(2)), _price(2));
        uint256 bobBid = _bid(bob, _costOf(1e18, _price(3)), _price(3));
        _advance(10);
        _floodAndRegister(carol, _price(9)); // outbids both

        uint256 aliceBefore = alice.balance;
        uint256 bobBefore = bob.balance;

        // A keeper with no relationship to either bidder settles the whole auction.
        address keeper = makeAddr('keeper');
        vm.prank(keeper);
        uint256 settled = router.sweep(auction, 0, auction.nextBidId());

        assertEq(settled, 2, 'both outbid bids should settle');
        assertGt(alice.balance, aliceBefore, 'alice refunded without transacting');
        assertGt(bob.balance, bobBefore, 'bob refunded without transacting');
        assertGt(auction.bids(aliceBid).exitedBlock, 0, 'alice bid exited');
        assertGt(auction.bids(bobBid).exitedBlock, 0, 'bob bid exited');

        // The keeper moved no value to itself.
        assertEq(keeper.balance, 0, 'keeper should gain nothing');
        assertEq(address(router).balance, 0, 'router should hold nothing');
    }

    /// @notice A sweep skips bids that are not settleable instead of reverting.
    function test_sweepSkipsUnsettleableBids() public {
        _deployAuction(0);

        uint256 aliceBid = _bid(alice, _costOf(1e18, _price(2)), _price(2));
        _advance(10);
        _floodAndRegister(bob, _price(4)); // outbids alice, but bob himself is still winning

        uint256 settled = router.sweep(auction, 0, auction.nextBidId());

        assertEq(settled, 1, 'only the outbid bid should settle');
        assertGt(auction.bids(aliceBid).exitedBlock, 0, 'alice bid exited');

        // A second sweep is a no-op rather than a revert.
        assertEq(router.sweep(auction, 0, auction.nextBidId()), 0, 're-sweep settles nothing');
    }

    // ---------------------------------------------------------------------
    // Fuzz: whatever the lens says is settleable, the auction accepts.
    // ---------------------------------------------------------------------

    /// @notice For randomised bid ladders, every plan the lens marks settleable actually settles.
    /// @dev This is the core safety property. A wrong hint reverts inside the auction, so any
    ///      disagreement between the lens and the protocol fails the run.
    function testFuzz_everySettleablePlanSettles(uint256 seed, uint8 rawBidCount) public {
        _deployAuction(0);

        uint256 bidCount = uint256(rawBidCount) % 8 + 2;
        uint256[] memory bidIds = new uint256[](bidCount);
        address[] memory owners = new address[](bidCount);

        for (uint256 i = 0; i < bidCount; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            // Ticks 2..10, so every bid sits strictly above the floor price.
            uint256 tick = (seed % 9) + 2;
            uint256 tokens = ((seed >> 8) % 5e18) + 1e15;
            address owner = [alice, bob, carol][(seed >> 16) % 3];

            owners[i] = owner;
            bidIds[i] = _bid(owner, _costOf(tokens, _price(tick)), _price(tick));

            if ((seed >> 24) % 2 == 0) _advance(1 + ((seed >> 32) % 4));
            if (block.number >= endBlock - 1) break;
        }

        // Push the clearing price up so that some of the ladder is outbid.
        if (block.number < endBlock - 1) _floodAt(carol, _price(7));

        // Mid-auction pass.
        _settleEverythingSettleable(bidIds);

        // Post-auction pass.
        _advance(uint256(AUCTION_DURATION));
        _settleEverythingSettleable(bidIds);
    }

    /// @dev Asks the lens about every bid and spends any hints it hands back.
    function _settleEverythingSettleable(uint256[] memory bidIds) internal {
        for (uint256 i = 0; i < bidIds.length; ++i) {
            if (bidIds[i] == 0 && i > 0) continue; // unfilled slot from an early break
            ExitPlan memory plan = lens.resolveExitPlan(auction, bidIds[i]);
            assertTrue(plan.hintsResolved, 'walk should resolve within the default budget');

            if (plan.route == ExitRoute.EXIT_BID) {
                auction.exitBid(plan.bidId);
            } else if (plan.route == ExitRoute.EXIT_PARTIALLY_FILLED) {
                auction.exitPartiallyFilledBid(
                    plan.bidId, plan.lastFullyFilledCheckpointBlock, plan.outbidBlock
                );
            } else {
                continue;
            }

            assertGt(auction.bids(plan.bidId).exitedBlock, 0, 'settled bid should be marked exited');
        }
    }
}
