// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.7.5;

import "../interfaces/IERC20.sol";
import "../interfaces/IOwnable.sol";
import "../types/Ownable.sol";
import "../libraries/SafeERC20.sol";

contract CrossChainMigrator is Ownable {
    using SafeERC20 for IERC20;

    IERC20 internal immutable wsCADT; // v1 token
    IERC20 internal immutable gCADT; // v2 token

    constructor(address _wsCADT, address _gCADT) {
        require(_wsCADT != address(0), "Zero address: wsCADT");
        wsCADT = IERC20(_wsCADT);
        require(_gCADT != address(0), "Zero address: gCADT");
        gCADT = IERC20(_gCADT);
    }

    // migrate wsCADT to gCADT - 1:1 like kind
    function migrate(uint256 amount) external {
        wsCADT.safeTransferFrom(msg.sender, address(this), amount);
        gCADT.safeTransfer(msg.sender, amount);
    }

    // withdraw wsCADT so it can be bridged on ETH and returned as more gCADT
    function replenish() external onlyOwner {
        wsCADT.safeTransfer(msg.sender, wsCADT.balanceOf(address(this)));
    }

    // withdraw migrated wsCADT and unmigrated gCADT
    function clear() external onlyOwner {
        wsCADT.safeTransfer(msg.sender, wsCADT.balanceOf(address(this)));
        gCADT.safeTransfer(msg.sender, gCADT.balanceOf(address(this)));
    }
}
