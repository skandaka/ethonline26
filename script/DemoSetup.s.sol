// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {CCAExitLens} from '../src/CCAExitLens.sol';
import {CCAExitRouter} from '../src/CCAExitRouter.sol';
import {TestToken} from '../test/utils/TestToken.sol';
import {ContinuousClearingAuction} from 'continuous-clearing-auction/ContinuousClearingAuction.sol';
import {AuctionParameters} from 'continuous-clearing-auction/interfaces/IContinuousClearingAuction.sol';
import {Script} from 'forge-std/Script.sol';
import {console2} from 'forge-std/console2.sol';

/// @notice Deploys a real CCA plus the lens and router, sized so the whole demo fits inside an
///         anvil account's default balance.
/// @dev Prices are Q96 "currency per token". A floor of `Q96 / 1000` is 0.001 ETH per token, so
///      clearing the entire 1000-token supply at the floor costs 1 ETH rather than thousands.
contract DemoSetup is Script {
    uint256 internal constant Q96 = 1 << 96;

    uint256 public constant FLOOR_PRICE = Q96 / 1_000; // 0.001 ETH / token
    uint256 public constant TICK_SPACING = Q96 / 10_000; // 0.0001 ETH / token
    uint128 public constant TOTAL_SUPPLY = 1_000e18;
    uint24 public constant MPS_1_PERCENT = 100_000;
    uint64 public constant AUCTION_DURATION = 100;

    function run() external returns (address auction, address lens, address router, address token) {
        vm.startBroadcast();

        CCAExitLens _lens = new CCAExitLens();
        CCAExitRouter _router = new CCAExitRouter(_lens);
        TestToken _token = new TestToken();

        uint64 startBlock = uint64(block.number);
        AuctionParameters memory params = AuctionParameters({
            currency: address(0), // ETH
            tokensRecipient: msg.sender,
            fundsRecipient: msg.sender,
            startBlock: startBlock,
            endBlock: startBlock + AUCTION_DURATION,
            claimBlock: startBlock + AUCTION_DURATION + 10,
            tickSpacing: TICK_SPACING,
            validationHook: address(0),
            floorPrice: FLOOR_PRICE,
            requiredCurrencyRaised: 0, // always graduates, so the demo is about exits
            auctionStepsData: abi.encodePacked(MPS_1_PERCENT, uint40(AUCTION_DURATION))
        });

        ContinuousClearingAuction _auction =
            new ContinuousClearingAuction(address(_token), TOTAL_SUPPLY, params, address(0));
        _token.mint(address(_auction), TOTAL_SUPPLY);
        _auction.onTokensReceived();

        vm.stopBroadcast();

        // Parsed by the demo driver.
        console2.log('AUCTION=%s', address(_auction));
        console2.log('LENS=%s', address(_lens));
        console2.log('ROUTER=%s', address(_router));
        console2.log('TOKEN=%s', address(_token));
        console2.log('START_BLOCK=%s', vm.toString(startBlock));
        console2.log('TICK2=%s', vm.toString(FLOOR_PRICE + TICK_SPACING));
        console2.log('TICK8=%s', vm.toString(FLOOR_PRICE + 7 * TICK_SPACING));

        return (address(_auction), address(_lens), address(_router), address(_token));
    }
}
