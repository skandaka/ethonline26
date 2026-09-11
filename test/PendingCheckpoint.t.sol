// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {CCAExitLens, ExitPlan, ExitRoute} from '../src/CCAExitLens.sol';
import {CCAExitTestBase} from './utils/CCAExitTestBase.sol';
import {Checkpoint} from 'continuous-clearing-auction/libraries/CheckpointLib.sol';
import {IContinuousClearingAuction} from 'continuous-clearing-auction/interfaces/IContinuousClearingAuction.sol';

/// @notice Proves the correctness gap between event-driven hint resolution and reading live state.
/// @dev A CCA checkpoints lazily: `submitBid` checkpoints *before* it books the new demand, so a
///      price-moving bid does not update the clearing price of its own block. The raised price is
///      only written when some later call checkpoints again.
///
///      That creates a window in which the checkpoint list on chain says a bid is still winning,
///      while the very next checkpoint — the one `exitPartiallyFilledBid` itself creates when it is
///      called — would show the bid as outbid.
///
///      Anything that derives hints from emitted `CheckpointUpdated` events (Uniswap's own
///      `cca-indexer` works this way) can only see checkpoints that have already been written. In
///      this window it necessarily reports "not outbid". `CCAExitLens` calls `checkpoint()` first,
///      exactly as the exit path does, so it observes the same state the exit call will.
contract PendingCheckpointTest is CCAExitTestBase {
    function _floodAt(address who, uint256 price) internal returns (uint256) {
        return _bid(who, _costOf(3 * uint256(TOTAL_SUPPLY), price), price);
    }

    /// @notice Walk the committed checkpoint list without checkpointing, i.e. exactly what an
    ///         event-driven indexer can know. Mirrors `cca-indexer`'s bookkeeping: the last
    ///         checkpoint whose clearing price is below the bid, and the first one above it.
    function _indexerView(uint256 bidMaxPrice, uint64 fromBlock)
        internal
        view
        returns (uint64 lastFullyFilled, uint64 outbidBlock)
    {
        uint64 cursor = fromBlock;
        for (uint256 i = 0; i < 500; ++i) {
            Checkpoint memory cp = auction.checkpoints(cursor);
            if (cp.clearingPrice > bidMaxPrice) return (lastFullyFilled, cursor);
            if (cp.clearingPrice < bidMaxPrice) lastFullyFilled = cursor;
            if (cp.next == type(uint64).max || cp.next == 0) break;
            cursor = cp.next;
        }
        return (lastFullyFilled, 0); // 0 == "never outbid", as the indexer would record
    }

    /// @notice In the pending-checkpoint window, indexer-derived hints revert and the lens's work.
    function test_lensSeesPendingCheckpointThatAnIndexerCannot() public {
        _deployAuction(0);

        uint256 alicePrice = _price(2);
        uint256 aliceBid = _bid(alice, _costOf(1e18, alicePrice), alicePrice);

        _advance(10);
        // Bob's flood raises demand far above Alice, but does NOT move the clearing price of its
        // own block: `submitBid` checkpointed before booking it.
        _floodAt(bob, _price(8));
        uint64 floodBlock = uint64(block.number);

        // Move one block forward. Nobody has checkpointed, so the raised price is still unwritten.
        _advance(1);
        uint64 pendingBlock = uint64(block.number);

        // --- What an event-driven indexer can see -------------------------------------------
        (uint64 idxLastFullyFilled, uint64 idxOutbidBlock) = _indexerView(alicePrice, startBlock);

        // Every committed checkpoint still shows Alice winning, so the indexer records "not outbid".
        assertEq(idxOutbidBlock, 0, 'indexer should believe the bid was never outbid');
        assertEq(idxLastFullyFilled, floodBlock, 'indexer lastFullyFilled hint');

        // Those hints are not merely stale, they are unusable: with `outbidBlock == 0` the auction
        // takes its "never outbid" branch, which requires the auction to have ended.
        vm.expectRevert(IContinuousClearingAuction.CannotPartiallyExitBidBeforeEndBlock.selector);
        auction.exitPartiallyFilledBid(aliceBid, idxLastFullyFilled, idxOutbidBlock);

        // --- What the lens sees ---------------------------------------------------------------
        ExitPlan memory plan = lens.resolveExitPlan(auction, aliceBid);

        assertTrue(plan.hintsResolved, 'hints should resolve');
        assertEq(uint8(plan.route), uint8(ExitRoute.EXIT_PARTIALLY_FILLED), 'lens should see the outbid');
        assertEq(plan.outbidBlock, pendingBlock, 'outbid block is the checkpoint the exit call creates');
        assertEq(plan.lastFullyFilledCheckpointBlock, floodBlock, 'last fully filled hint');

        // And they settle, in the same window where the indexer's hints could not.
        uint256 balanceBefore = alice.balance;
        auction.exitPartiallyFilledBid(aliceBid, plan.lastFullyFilledCheckpointBlock, plan.outbidBlock);

        assertGt(alice.balance, balanceBefore, 'alice should be refunded');
        assertGt(auction.bids(aliceBid).exitedBlock, 0, 'bid should be exited');
    }

    /// @notice The window closes as soon as anyone checkpoints; both views then agree.
    /// @dev This is the honest bound on the finding above: it is a freshness gap, not a permanent
    ///      divergence. Any call that checkpoints the auction reconciles the two.
    function test_onceCheckpointedBothViewsAgree() public {
        _deployAuction(0);

        uint256 alicePrice = _price(2);
        uint256 aliceBid = _bid(alice, _costOf(1e18, alicePrice), alicePrice);

        _advance(10);
        _floodAt(bob, _price(8));

        _advance(1);
        auction.checkpoint(); // anybody can do this; it commits the pending price

        (uint64 idxLastFullyFilled, uint64 idxOutbidBlock) = _indexerView(alicePrice, startBlock);
        ExitPlan memory plan = lens.resolveExitPlan(auction, aliceBid);

        assertEq(idxOutbidBlock, plan.outbidBlock, 'outbid hints should agree');
        assertEq(idxLastFullyFilled, plan.lastFullyFilledCheckpointBlock, 'lastFullyFilled hints should agree');

        // Both now settle the bid.
        auction.exitPartiallyFilledBid(aliceBid, idxLastFullyFilled, idxOutbidBlock);
        assertGt(auction.bids(aliceBid).exitedBlock, 0, 'bid should be exited');
    }

    /// @notice Across randomised ladders, the lens never disagrees with a *committed* checkpoint view.
    /// @dev Two independent implementations of the same hint search — one walking live state inside
    ///      the EVM, one reproducing the event-driven bookkeeping — must agree wherever the
    ///      event-driven one is not stale.
    function testFuzz_lensAgreesWithCommittedIndexerView(uint256 seed) public {
        _deployAuction(0);

        uint256 alicePrice = _price(2 + (seed % 4));
        uint256 aliceBid = _bid(alice, _costOf(1e18, alicePrice), alicePrice);

        uint256 rounds = (seed >> 8) % 6 + 1;
        for (uint256 i = 0; i < rounds; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            _advance(1 + (seed % 5));
            if (block.number >= endBlock - 2) break;
            _bid(carol, _costOf(((seed >> 16) % 2e18) + 1e15, _price(3)), _price(3));
        }

        if (block.number < endBlock - 2) {
            _floodAt(bob, _price(9));
            _advance(1);
        }
        // Commit everything pending so the two views are compared on equal footing.
        auction.checkpoint();

        (uint64 idxLastFullyFilled, uint64 idxOutbidBlock) = _indexerView(alicePrice, startBlock);
        ExitPlan memory plan = lens.resolveExitPlan(auction, aliceBid);

        assertTrue(plan.hintsResolved, 'hints should resolve');
        assertEq(plan.outbidBlock, idxOutbidBlock, 'outbid hints should agree');
        assertEq(plan.lastFullyFilledCheckpointBlock, idxLastFullyFilled, 'lastFullyFilled hints should agree');
    }
}
