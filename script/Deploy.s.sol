// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {CCAExitLens} from '../src/CCAExitLens.sol';
import {CCAExitRouter} from '../src/CCAExitRouter.sol';
import {Script} from 'forge-std/Script.sol';
import {console2} from 'forge-std/console2.sol';

/// @notice Deploys the lens and the router.
/// @dev Both are stateless and hold no funds, so one deployment per chain serves every auction on
///      it — the same deployment model as Uniswap's own `CCALens`.
///
///      forge script script/Deploy.s.sol --rpc-url <RPC> --broadcast
contract Deploy is Script {
    function run() external returns (CCAExitLens lens, CCAExitRouter router) {
        vm.startBroadcast();
        lens = new CCAExitLens();
        router = new CCAExitRouter(lens);
        vm.stopBroadcast();

        console2.log('CCAExitLens  ', address(lens));
        console2.log('CCAExitRouter', address(router));
    }
}
