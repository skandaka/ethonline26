#!/usr/bin/env bash
# Fetch exactly the contract dependencies this project compiles against.
#
# `git submodule update --init --recursive` pulls ~930MB here, because Uniswap's
# liquidity-launcher vendors uerc20-factory (150MB) and optimism (131MB) that nothing in this
# project imports. Naming the submodules we actually need brings that to ~69MB and about 20
# seconds.
#
# What is needed, and why:
#   continuous-clearing-auction        the protocol under test
#     ├── forge-std                    test harness
#     ├── solady                       FixedPointMathLib, SSTORE2, SafeTransferLib, Multicallable
#     ├── openzeppelin-contracts       IERC165, Create2, Math, ERC20 (test token)
#     ├── blocknumberish               BlockNumberish, the auction's L2-aware block number
#     ├── v4-periphery                 ActionConstants
#     ├── permit2                      referenced by the auction's transfer path
#     └── liquidity-launcher           IDistributor, IProtocolFeeController, ProtocolFeeLib
#           └── v4-core                Currency — ProtocolFeeLib imports @uniswap/v4-core
#
set -euo pipefail
cd "$(dirname "$0")/.."

git submodule update --init --depth 1 lib/continuous-clearing-auction

cd lib/continuous-clearing-auction
git submodule update --init --depth 1 \
  lib/forge-std \
  lib/solady \
  lib/openzeppelin-contracts \
  lib/blocknumberish \
  lib/v4-periphery \
  lib/permit2 \
  lib/liquidity-launcher

cd lib/liquidity-launcher
git submodule update --init --depth 1 lib/v4-core

echo "contract dependencies ready"
