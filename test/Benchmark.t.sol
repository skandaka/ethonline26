// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {CCAExitLens, ExitPlan, ExitRoute} from '../src/CCAExitLens.sol';
import {CCAExitTestBase} from './utils/CCAExitTestBase.sol';
import {console2} from 'forge-std/console2.sol';

/// @notice Quantifies what the lens replaces: one `eth_call` instead of one RPC round trip per
///         checkpoint in the bid's lifetime.
contract BenchmarkTest is CCAExitTestBase {
    /// @notice Build a long checkpoint list and report the cost of resolving hints across it.
    function test_benchmark_resolveOverLongCheckpointList() public {
        _deployAuction(0);

        uint256 aliceBid = _bid(alice, _costOf(1e18, _price(2)), _price(2));

        // One checkpoint per block for most of the auction.
        uint256 checkpointsBuilt = 1;
        while (block.number < endBlock - 3) {
            _advance(1);
            _bid(carol, _costOf(1e15, _price(3)), _price(3));
            ++checkpointsBuilt;
        }

        _floodAt(bob, _price(8));
        _advance(1);
        auction.checkpoint();

        uint256 gasBefore = gasleft();
        ExitPlan memory plan = lens.resolveExitPlan(auction, aliceBid);
        uint256 gasUsed = gasBefore - gasleft();

        assertTrue(plan.hintsResolved, 'hints should resolve in one call');
        assertEq(uint8(plan.route), uint8(ExitRoute.EXIT_PARTIALLY_FILLED), 'route');

        console2.log('checkpoints in the list      ', checkpointsBuilt);
        console2.log('checkpoints walked (hops)    ', plan.hops);
        console2.log('gas for one resolveExitPlan  ', gasUsed);
        console2.log('offchain RPC round trips saved', uint256(plan.hops));

        // The hints still settle the real bid.
        auction.exitPartiallyFilledBid(aliceBid, plan.lastFullyFilledCheckpointBlock, plan.outbidBlock);
        assertGt(auction.bids(aliceBid).exitedBlock, 0, 'bid should be exited');
    }

    /// @notice Measure how resolution cost scales with the length of the checkpoint list.
    /// @dev `DEFAULT_MAX_HOPS` is chosen by dividing a typical `eth_call` gas allowance by the
    ///      per-checkpoint cost, which is only sound if that cost is flat. This measures it at
    ///      several list lengths instead of extrapolating from one point.
    function test_benchmark_scaling() public {
        uint256[4] memory sizes = [uint256(10), 25, 50, 90];

        console2.log('checkpoints | hops |      gas | gas/checkpoint');
        for (uint256 i = 0; i < sizes.length; ++i) {
            (uint256 gasUsed, uint32 hops) = _measureAt(sizes[i]);
            console2.log(sizes[i], hops, gasUsed, gasUsed / hops);
        }
    }

    /// @dev Build an auction whose checkpoint list is `checkpointCount` long before the bid is
    ///      outbid, then measure one `resolveExitPlan` across it.
    function _measureAt(uint256 checkpointCount) internal returns (uint256 gasUsed, uint32 hops) {
        _deployAuction(0);

        uint256 aliceBid = _bid(alice, _costOf(1e18, _price(2)), _price(2));
        for (uint256 i = 1; i < checkpointCount; ++i) {
            _advance(1);
            _bid(carol, _costOf(1e15, _price(3)), _price(3));
        }

        _advance(1);
        _floodAt(bob, _price(8));
        _advance(1);
        auction.checkpoint();

        uint256 gasBefore = gasleft();
        ExitPlan memory plan = lens.resolveExitPlan(auction, aliceBid);
        gasUsed = gasBefore - gasleft();

        assertTrue(plan.hintsResolved, 'hints should resolve');
        assertEq(uint8(plan.route), uint8(ExitRoute.EXIT_PARTIALLY_FILLED), 'route');
        hops = plan.hops;
    }

    function _floodAt(address who, uint256 price) internal returns (uint256) {
        return _bid(who, _costOf(3 * uint256(TOTAL_SUPPLY), price), price);
    }
}
