// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {CCAExitLens} from '../../src/CCAExitLens.sol';
import {CCAExitRouter} from '../../src/CCAExitRouter.sol';
import {TestToken} from './TestToken.sol';
import {ContinuousClearingAuction} from 'continuous-clearing-auction/ContinuousClearingAuction.sol';
import {AuctionParameters} from 'continuous-clearing-auction/interfaces/IContinuousClearingAuction.sol';
import {Test} from 'forge-std/Test.sol';

/// @notice Deploys a real `ContinuousClearingAuction` funded with ETH bids.
/// @dev Everything under test runs against the unmodified Uniswap contracts vendored in
///      `lib/continuous-clearing-auction`, not against a reimplementation of the mechanism.
abstract contract CCAExitTestBase is Test {
    uint256 internal constant Q96 = 1 << 96;

    uint64 internal constant AUCTION_DURATION = 100;
    uint64 internal constant CLAIM_OFFSET = 10;
    uint256 internal constant TICK_SPACING = 100 * Q96;
    uint256 internal constant FLOOR_PRICE = 1000 * Q96;
    uint128 internal constant TOTAL_SUPPLY = 1000e18;
    /// @dev One percent of the supply per block, for one hundred blocks.
    uint24 internal constant MPS_1_PERCENT = 100_000;

    ContinuousClearingAuction internal auction;
    TestToken internal token;
    CCAExitLens internal lens;
    CCAExitRouter internal router;

    address internal alice = makeAddr('alice');
    address internal bob = makeAddr('bob');
    address internal carol = makeAddr('carol');
    address internal tokensRecipient = makeAddr('tokensRecipient');
    address internal fundsRecipient = makeAddr('fundsRecipient');

    uint64 internal startBlock;
    uint64 internal endBlock;

    /// @notice Deploy the lens, router, token and a funded auction.
    /// @param requiredCurrencyRaised Graduation threshold. Pass 0 for an auction that always graduates.
    function _deployAuction(uint128 requiredCurrencyRaised) internal {
        lens = new CCAExitLens();
        router = new CCAExitRouter(lens);
        token = new TestToken();

        // Start from a realistic block height so block numbers are never degenerate.
        vm.roll(1_000_000);
        startBlock = uint64(block.number);
        endBlock = startBlock + AUCTION_DURATION;

        AuctionParameters memory params = AuctionParameters({
            currency: address(0), // ETH
            tokensRecipient: tokensRecipient,
            fundsRecipient: fundsRecipient,
            startBlock: startBlock,
            endBlock: endBlock,
            claimBlock: endBlock + CLAIM_OFFSET,
            tickSpacing: TICK_SPACING,
            validationHook: address(0),
            floorPrice: FLOOR_PRICE,
            requiredCurrencyRaised: requiredCurrencyRaised,
            auctionStepsData: abi.encodePacked(MPS_1_PERCENT, uint40(AUCTION_DURATION))
        });

        auction = new ContinuousClearingAuction(address(token), TOTAL_SUPPLY, params, address(0));
        token.mint(address(auction), TOTAL_SUPPLY);
        auction.onTokensReceived();

        // Demand is normalised across the whole remaining supply, so clearing the auction at a
        // given tick costs roughly `TOTAL_SUPPLY * price`. Fund bidders well past that.
        vm.deal(alice, 1e10 ether);
        vm.deal(bob, 1e10 ether);
        vm.deal(carol, 1e10 ether);
    }

    /// @notice Q96 price of the nth tick, where tick 1 is the floor price.
    function _price(uint256 tickNumber) internal pure returns (uint256) {
        return FLOOR_PRICE + (tickNumber - 1) * TICK_SPACING;
    }

    /// @notice Currency needed to buy at least `tokens` at `maxPrice`.
    function _costOf(uint256 tokens, uint256 maxPrice) internal pure returns (uint128) {
        return uint128(Math.ceilDiv(tokens * maxPrice, Q96));
    }

    /// @notice Submit an ETH bid on behalf of `owner`.
    function _bid(address owner, uint128 amount, uint256 maxPrice) internal returns (uint256 bidId) {
        vm.prank(owner);
        bidId = auction.submitBid{value: amount}(maxPrice, amount, owner, FLOOR_PRICE, bytes(''));
    }

    /// @notice Advance the chain by `blocks` blocks.
    function _advance(uint256 blocks) internal {
        vm.roll(block.number + blocks);
    }
}

/// @dev Local copy so the base does not depend on an OpenZeppelin import path for one helper.
library Math {
    function ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        return a == 0 ? 0 : (a - 1) / b + 1;
    }
}
