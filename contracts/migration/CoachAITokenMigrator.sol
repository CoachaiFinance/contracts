// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.7.5;

import "../interfaces/IERC20.sol";
import "../interfaces/IsCADT.sol";
import "../interfaces/IwsCADT.sol";
import "../interfaces/IgCADT.sol";
import "../interfaces/ITreasury.sol";
import "../interfaces/IStaking.sol";
import "../interfaces/IOwnable.sol";
import "../interfaces/IUniswapV2Router.sol";
import "../interfaces/IStakingV1.sol";
import "../interfaces/ITreasuryV1.sol";

import "../types/CoachAIAccessControlled.sol";

import "../libraries/SafeMath.sol";
import "../libraries/SafeERC20.sol";

contract CoachAITokenMigrator is CoachAIAccessControlled {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    using SafeERC20 for IgCADT;
    using SafeERC20 for IsCADT;
    using SafeERC20 for IwsCADT;

    /* ========== MIGRATION ========== */

    event TimelockStarted(uint256 block, uint256 end);
    event Migrated(address staking, address treasury);
    event Funded(uint256 amount);
    event Defunded(uint256 amount);

    /* ========== STATE VARIABLES ========== */

    IERC20 public immutable oldCADT;
    IsCADT public immutable oldsCADT;
    IwsCADT public immutable oldwsCADT;
    ITreasuryV1 public immutable oldTreasury;
    IStakingV1 public immutable oldStaking;

    IUniswapV2Router public immutable sushiRouter;
    IUniswapV2Router public immutable uniRouter;

    IgCADT public gCADT;
    ITreasury public newTreasury;
    IStaking public newStaking;
    IERC20 public newCADT;

    bool public cadtMigrated;
    bool public shutdown;

    uint256 public immutable timelockLength;
    uint256 public timelockEnd;

    uint256 public oldSupply;

    constructor(
        address _oldCADT,
        address _oldsCADT,
        address _oldTreasury,
        address _oldStaking,
        address _oldwsCADT,
        address _sushi,
        address _uni,
        uint256 _timelock,
        address _authority
    ) CoachAIAccessControlled(ICoachAIAuthority(_authority)) {
        require(_oldCADT != address(0), "Zero address: CADT");
        oldCADT = IERC20(_oldCADT);
        require(_oldsCADT != address(0), "Zero address: sCADT");
        oldsCADT = IsCADT(_oldsCADT);
        require(_oldTreasury != address(0), "Zero address: Treasury");
        oldTreasury = ITreasuryV1(_oldTreasury);
        require(_oldStaking != address(0), "Zero address: Staking");
        oldStaking = IStakingV1(_oldStaking);
        require(_oldwsCADT != address(0), "Zero address: wsCADT");
        oldwsCADT = IwsCADT(_oldwsCADT);
        require(_sushi != address(0), "Zero address: Sushi");
        sushiRouter = IUniswapV2Router(_sushi);
        require(_uni != address(0), "Zero address: Uni");
        uniRouter = IUniswapV2Router(_uni);
        timelockLength = _timelock;
    }

    /* ========== MIGRATION ========== */

    enum TYPE {
        UNSTAKED,
        STAKED,
        WRAPPED
    }

    // migrate CADTv1, sCADTv1, or wsCADT for CADTv2, sCADTv2, or gCADT
    function migrate(
        uint256 _amount,
        TYPE _from,
        TYPE _to
    ) external {
        require(!shutdown, "Shut down");

        uint256 wAmount = oldwsCADT.sCADTTowCADT(_amount);

        if (_from == TYPE.UNSTAKED) {
            require(cadtMigrated, "Only staked until migration");
            oldCADT.safeTransferFrom(msg.sender, address(this), _amount);
        } else if (_from == TYPE.STAKED) {
            oldsCADT.safeTransferFrom(msg.sender, address(this), _amount);
        } else {
            oldwsCADT.safeTransferFrom(msg.sender, address(this), _amount);
            wAmount = _amount;
        }

        if (cadtMigrated) {
            require(oldSupply >= oldCADT.totalSupply(), "CADTv1 minted");
            _send(wAmount, _to);
        } else {
            gCADT.mint(msg.sender, wAmount);
        }
    }

    // migrate all coatchai tokens held
    function migrateAll(TYPE _to) external {
        require(!shutdown, "Shut down");

        uint256 cadtBal = 0;
        uint256 sCADTBal = oldsCADT.balanceOf(msg.sender);
        uint256 wsCADTBal = oldwsCADT.balanceOf(msg.sender);

        if (oldCADT.balanceOf(msg.sender) > 0 && cadtMigrated) {
            cadtBal = oldCADT.balanceOf(msg.sender);
            oldCADT.safeTransferFrom(msg.sender, address(this), cadtBal);
        }
        if (sCADTBal > 0) {
            oldsCADT.safeTransferFrom(msg.sender, address(this), sCADTBal);
        }
        if (wsCADTBal > 0) {
            oldwsCADT.safeTransferFrom(msg.sender, address(this), wsCADTBal);
        }

        uint256 wAmount = wsCADTBal.add(oldwsCADT.sCADTTowCADT(cadtBal.add(sCADTBal)));
        if (cadtMigrated) {
            require(oldSupply >= oldCADT.totalSupply(), "CADTv1 minted");
            _send(wAmount, _to);
        } else {
            gCADT.mint(msg.sender, wAmount);
        }
    }

    // send preferred token
    function _send(uint256 wAmount, TYPE _to) internal {
        if (_to == TYPE.WRAPPED) {
            gCADT.safeTransfer(msg.sender, wAmount);
        } else if (_to == TYPE.STAKED) {
            newStaking.unwrap(msg.sender, wAmount);
        } else if (_to == TYPE.UNSTAKED) {
            newStaking.unstake(msg.sender, wAmount, false, false);
        }
    }

    // bridge back to CADT, sCADT, or wsCADT
    function bridgeBack(uint256 _amount, TYPE _to) external {
        if (!cadtMigrated) {
            gCADT.burn(msg.sender, _amount);
        } else {
            gCADT.safeTransferFrom(msg.sender, address(this), _amount);
        }

        uint256 amount = oldwsCADT.wCADTTosCADT(_amount);
        // error throws if contract does not have enough of type to send
        if (_to == TYPE.UNSTAKED) {
            oldCADT.safeTransfer(msg.sender, amount);
        } else if (_to == TYPE.STAKED) {
            oldsCADT.safeTransfer(msg.sender, amount);
        } else if (_to == TYPE.WRAPPED) {
            oldwsCADT.safeTransfer(msg.sender, _amount);
        }
    }

    /* ========== OWNABLE ========== */

    // halt migrations (but not bridging back)
    function halt() external onlyPolicy {
        require(!cadtMigrated, "Migration has occurred");
        shutdown = !shutdown;
    }

    // withdraw backing of migrated CADT
    function defund(address reserve) external onlyGovernor {
        require(cadtMigrated, "Migration has not begun");
        require(timelockEnd < block.number && timelockEnd != 0, "Timelock not complete");

        oldwsCADT.unwrap(oldwsCADT.balanceOf(address(this)));

        uint256 amountToUnstake = oldsCADT.balanceOf(address(this));
        oldsCADT.approve(address(oldStaking), amountToUnstake);
        oldStaking.unstake(amountToUnstake, false);

        uint256 balance = oldCADT.balanceOf(address(this));

        if (balance > oldSupply) {
            oldSupply = 0;
        } else {
            oldSupply -= balance;
        }

        uint256 amountToWithdraw = balance.mul(1e9);
        oldCADT.approve(address(oldTreasury), amountToWithdraw);
        oldTreasury.withdraw(amountToWithdraw, reserve);
        IERC20(reserve).safeTransfer(address(newTreasury), IERC20(reserve).balanceOf(address(this)));

        emit Defunded(balance);
    }

    // start timelock to send backing to new treasury
    function startTimelock() external onlyGovernor {
        require(timelockEnd == 0, "Timelock set");
        timelockEnd = block.number.add(timelockLength);

        emit TimelockStarted(block.number, timelockEnd);
    }

    // set gCADT address
    function setgCADT(address _gCADT) external onlyGovernor {
        require(address(gCADT) == address(0), "Already set");
        require(_gCADT != address(0), "Zero address: gCADT");

        gCADT = IgCADT(_gCADT);
    }

    // call internal migrate token function
    function migrateToken(address token) external onlyGovernor {
        _migrateToken(token, false);
    }

    /**
     *   @notice Migrate LP and pair with new CADT
     */
    function migrateLP(
        address pair,
        bool sushi,
        address token,
        uint256 _minA,
        uint256 _minB
    ) external onlyGovernor {
        uint256 oldLPAmount = IERC20(pair).balanceOf(address(oldTreasury));
        oldTreasury.manage(pair, oldLPAmount);

        IUniswapV2Router router = sushiRouter;
        if (!sushi) {
            router = uniRouter;
        }

        IERC20(pair).approve(address(router), oldLPAmount);
        (uint256 amountA, uint256 amountB) = router.removeLiquidity(
            token,
            address(oldCADT),
            oldLPAmount,
            _minA,
            _minB,
            address(this),
            block.timestamp
        );

        newTreasury.mint(address(this), amountB);

        IERC20(token).approve(address(router), amountA);
        newCADT.approve(address(router), amountB);

        router.addLiquidity(
            token,
            address(newCADT),
            amountA,
            amountB,
            amountA,
            amountB,
            address(newTreasury),
            block.timestamp
        );
    }

    // Failsafe function to allow owner to withdraw funds sent directly to contract in case someone sends non-cadt tokens to the contract
    function withdrawToken(
        address tokenAddress,
        uint256 amount,
        address recipient
    ) external onlyGovernor {
        require(tokenAddress != address(0), "Token address cannot be 0x0");
        require(tokenAddress != address(gCADT), "Cannot withdraw: gCADT");
        require(tokenAddress != address(oldCADT), "Cannot withdraw: old-CADT");
        require(tokenAddress != address(oldsCADT), "Cannot withdraw: old-sCADT");
        require(tokenAddress != address(oldwsCADT), "Cannot withdraw: old-wsCADT");
        require(amount > 0, "Withdraw value must be greater than 0");
        if (recipient == address(0)) {
            recipient = msg.sender; // if no address is specified the value will will be withdrawn to Owner
        }

        IERC20 tokenContract = IERC20(tokenAddress);
        uint256 contractBalance = tokenContract.balanceOf(address(this));
        if (amount > contractBalance) {
            amount = contractBalance; // set the withdrawal amount equal to balance within the account.
        }
        // transfer the token from address of this contract
        tokenContract.safeTransfer(recipient, amount);
    }

    // migrate contracts
    function migrateContracts(
        address _newTreasury,
        address _newStaking,
        address _newCADT,
        address _newsCADT,
        address _reserve
    ) external onlyGovernor {
        require(!cadtMigrated, "Already migrated");
        cadtMigrated = true;
        shutdown = false;

        require(_newTreasury != address(0), "Zero address: Treasury");
        newTreasury = ITreasury(_newTreasury);
        require(_newStaking != address(0), "Zero address: Staking");
        newStaking = IStaking(_newStaking);
        require(_newCADT != address(0), "Zero address: CADT");
        newCADT = IERC20(_newCADT);

        oldSupply = oldCADT.totalSupply(); // log total supply at time of migration

        gCADT.migrate(_newStaking, _newsCADT); // change gCADT minter

        _migrateToken(_reserve, true); // will deposit tokens into new treasury so reserves can be accounted for

        _fund(oldsCADT.circulatingSupply()); // fund with current staked supply for token migration

        emit Migrated(_newStaking, _newTreasury);
    }

    /* ========== INTERNAL FUNCTIONS ========== */

    // fund contract with gCADT
    function _fund(uint256 _amount) internal {
        newTreasury.mint(address(this), _amount);
        newCADT.approve(address(newStaking), _amount);
        newStaking.stake(address(this), _amount, false, true); // stake and claim gCADT

        emit Funded(_amount);
    }

    /**
     *   @notice Migrate token from old treasury to new treasury
     */
    function _migrateToken(address token, bool deposit) internal {
        uint256 balance = IERC20(token).balanceOf(address(oldTreasury));

        uint256 excessReserves = oldTreasury.excessReserves();
        uint256 tokenValue = oldTreasury.valueOf(token, balance);

        if (tokenValue > excessReserves) {
            tokenValue = excessReserves;
            balance = excessReserves * 10**9;
        }

        oldTreasury.manage(token, balance);

        if (deposit) {
            IERC20(token).safeApprove(address(newTreasury), balance);
            newTreasury.deposit(balance, token, tokenValue);
        } else {
            IERC20(token).safeTransfer(address(newTreasury), balance);
        }
    }
}
