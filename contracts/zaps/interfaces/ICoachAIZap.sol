// SPDX-License-Identifier: WTFPL
pragma solidity ^0.8.0;

import "./IStaking.sol";

interface ICoachAIZap {
    function update_Staking(IStaking _staking) external;

    function update_sCADT(address _sCADT) external;

    function update_wsCADT(address _wsCADT) external;

    function update_gCADT(address _gCADT) external;

    function update_BondDepository(address principal, address depository) external;
}
