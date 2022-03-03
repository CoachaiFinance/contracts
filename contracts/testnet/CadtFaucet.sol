// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.7.5;

import "../interfaces/IERC20.sol";
import "../types/Ownable.sol";

contract CadtFaucet is Ownable {
    IERC20 public cadt;

    constructor(address _cadt) {
        cadt = IERC20(_cadt);
    }

    function setCadt(address _cadt) external onlyOwner {
        cadt = IERC20(_cadt);
    }

    function dispense() external {
        cadt.transfer(msg.sender, 1e9);
    }
}
