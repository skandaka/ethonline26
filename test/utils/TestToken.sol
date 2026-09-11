// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from '@openzeppelin/contracts/token/ERC20/ERC20.sol';

/// @notice Plain mintable ERC20 used as the auctioned token in tests.
contract TestToken is ERC20 {
    constructor() ERC20('Auctioned Token', 'AUCT') {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
