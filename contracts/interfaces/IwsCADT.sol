// SPDX-License-Identifier: AGPL-3.0
pragma solidity >=0.7.5;

import "./IERC20.sol";

// Old wsCADT interface
interface IwsCADT is IERC20 {
    function wrap(uint256 _amount) external returns (uint256);

    function unwrap(uint256 _amount) external returns (uint256);

    function wCADTTosCADT(uint256 _amount) external view returns (uint256);

    function sCADTTowCADT(uint256 _amount) external view returns (uint256);
}
