// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.7.5;

import "./libraries/SafeMath.sol";
import "./libraries/SafeERC20.sol";

import "./interfaces/IERC20.sol";
import "./interfaces/IsCADT.sol";
import "./interfaces/IgCADT.sol";
import "./interfaces/IDistributor.sol";

import "./types/CoachAIAccessControlled.sol";

contract CoachAIStaking is CoachAIAccessControlled {
    /* ========== DEPENDENCIES ========== */

    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    using SafeERC20 for IsCADT;
    using SafeERC20 for IgCADT;

    /* ========== EVENTS ========== */

    event DistributorSet(address distributor);
    event WarmupSet(uint256 warmup);

    /* ========== DATA STRUCTURES ========== */

    struct Epoch {
        uint256 length; // in seconds
        uint256 number; // since inception
        uint256 end; // timestamp
        uint256 distribute; // amount
    }

    struct Claim {
        uint256 deposit; // if forfeiting
        uint256 gons; // staked balance
        uint256 expiry; // end of warmup period
        bool lock; // prevents malicious delays for claim
    }

    /* ========== STATE VARIABLES ========== */

    IERC20 public immutable CADT;
    IsCADT public immutable sCADT;
    IgCADT public immutable gCADT;

    Epoch public epoch;

    IDistributor public distributor;

    mapping(address => Claim) public warmupInfo;
    uint256 public warmupPeriod;
    uint256 private gonsInWarmup;

    /* ========== CONSTRUCTOR ========== */

    constructor(
        address _cadt,
        address _sCADT,
        address _gCADT,
        uint256 _epochLength,
        uint256 _firstEpochNumber,
        uint256 _firstEpochTime,
        address _authority
    ) CoachAIAccessControlled(ICoachAIAuthority(_authority)) {
        require(_cadt != address(0), "Zero address: CADT");
        CADT = IERC20(_cadt);
        require(_sCADT != address(0), "Zero address: sCADT");
        sCADT = IsCADT(_sCADT);
        require(_gCADT != address(0), "Zero address: gCADT");
        gCADT = IgCADT(_gCADT);

        epoch = Epoch({length: _epochLength, number: _firstEpochNumber, end: _firstEpochTime, distribute: 0});
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    /**
     * @notice stake CADT to enter warmup
     * @param _to address
     * @param _amount uint
     * @param _claim bool
     * @param _rebasing bool
     * @return uint
     */
    function stake(
        address _to,
        uint256 _amount,
        bool _rebasing,
        bool _claim
    ) external returns (uint256) {
        CADT.safeTransferFrom(msg.sender, address(this), _amount);
        _amount = _amount.add(rebase()); // add bounty if rebase occurred
        if (_claim && warmupPeriod == 0) {
            return _send(_to, _amount, _rebasing);
        } else {
            Claim memory info = warmupInfo[_to];
            if (!info.lock) {
                require(_to == msg.sender, "External deposits for account are locked");
            }

            warmupInfo[_to] = Claim({
                deposit: info.deposit.add(_amount),
                gons: info.gons.add(sCADT.gonsForBalance(_amount)),
                expiry: epoch.number.add(warmupPeriod),
                lock: info.lock
            });

            gonsInWarmup = gonsInWarmup.add(sCADT.gonsForBalance(_amount));

            return _amount;
        }
    }

    /**
     * @notice retrieve stake from warmup
     * @param _to address
     * @param _rebasing bool
     * @return uint
     */
    function claim(address _to, bool _rebasing) public returns (uint256) {
        Claim memory info = warmupInfo[_to];

        if (!info.lock) {
            require(_to == msg.sender, "External claims for account are locked");
        }

        if (epoch.number >= info.expiry && info.expiry != 0) {
            delete warmupInfo[_to];

            gonsInWarmup = gonsInWarmup.sub(info.gons);

            return _send(_to, sCADT.balanceForGons(info.gons), _rebasing);
        }
        return 0;
    }

    /**
     * @notice forfeit stake and retrieve CADT
     * @return uint
     */
    function forfeit() external returns (uint256) {
        Claim memory info = warmupInfo[msg.sender];
        delete warmupInfo[msg.sender];

        gonsInWarmup = gonsInWarmup.sub(info.gons);

        CADT.safeTransfer(msg.sender, info.deposit);

        return info.deposit;
    }

    /**
     * @notice prevent new deposits or claims from ext. address (protection from malicious activity)
     */
    function toggleLock() external {
        warmupInfo[msg.sender].lock = !warmupInfo[msg.sender].lock;
    }

    /**
     * @notice redeem sCADT for CADTs
     * @param _to address
     * @param _amount uint
     * @param _trigger bool
     * @param _rebasing bool
     * @return amount_ uint
     */
    function unstake(
        address _to,
        uint256 _amount,
        bool _trigger,
        bool _rebasing
    ) external returns (uint256 amount_) {
        amount_ = _amount;
        uint256 bounty;
        if (_trigger) {
            bounty = rebase();
        }
        if (_rebasing) {
            sCADT.safeTransferFrom(msg.sender, address(this), _amount);
            amount_ = amount_.add(bounty);
        } else {
            gCADT.burn(msg.sender, _amount); // amount was given in gCADT terms
            amount_ = gCADT.balanceFrom(amount_).add(bounty); // convert amount to CADT terms & add bounty
        }

        require(amount_ <= CADT.balanceOf(address(this)), "Insufficient CADT balance in contract");
        CADT.safeTransfer(_to, amount_);
    }

    /**
     * @notice convert _amount sCADT into gBalance_ gCADT
     * @param _to address
     * @param _amount uint
     * @return gBalance_ uint
     */
    function wrap(address _to, uint256 _amount) external returns (uint256 gBalance_) {
        sCADT.safeTransferFrom(msg.sender, address(this), _amount);
        gBalance_ = gCADT.balanceTo(_amount);
        gCADT.mint(_to, gBalance_);
    }

    /**
     * @notice convert _amount gCADT into sBalance_ sCADT
     * @param _to address
     * @param _amount uint
     * @return sBalance_ uint
     */
    function unwrap(address _to, uint256 _amount) external returns (uint256 sBalance_) {
        gCADT.burn(msg.sender, _amount);
        sBalance_ = gCADT.balanceFrom(_amount);
        sCADT.safeTransfer(_to, sBalance_);
    }

    /**
     * @notice trigger rebase if epoch over
     * @return uint256
     */
    function rebase() public returns (uint256) {
        uint256 bounty;
        if (epoch.end <= block.timestamp) {
            sCADT.rebase(epoch.distribute, epoch.number);

            epoch.end = epoch.end.add(epoch.length);
            epoch.number++;

            if (address(distributor) != address(0)) {
                distributor.distribute();
                bounty = distributor.retrieveBounty(); // Will mint cadt for this contract if there exists a bounty
            }
            uint256 balance = CADT.balanceOf(address(this));
            uint256 staked = sCADT.circulatingSupply();
            if (balance <= staked.add(bounty)) {
                epoch.distribute = 0;
            } else {
                epoch.distribute = balance.sub(staked).sub(bounty);
            }
        }
        return bounty;
    }

    /* ========== INTERNAL FUNCTIONS ========== */

    /**
     * @notice send staker their amount as sCADT or gCADT
     * @param _to address
     * @param _amount uint
     * @param _rebasing bool
     */
    function _send(
        address _to,
        uint256 _amount,
        bool _rebasing
    ) internal returns (uint256) {
        if (_rebasing) {
            sCADT.safeTransfer(_to, _amount); // send as sCADT (equal unit as CADT)
            return _amount;
        } else {
            gCADT.mint(_to, gCADT.balanceTo(_amount)); // send as gCADT (convert units from CADT)
            return gCADT.balanceTo(_amount);
        }
    }

    /* ========== VIEW FUNCTIONS ========== */

    /**
     * @notice returns the sCADT index, which tracks rebase growth
     * @return uint
     */
    function index() public view returns (uint256) {
        return sCADT.index();
    }

    /**
     * @notice total supply in warmup
     */
    function supplyInWarmup() public view returns (uint256) {
        return sCADT.balanceForGons(gonsInWarmup);
    }

    /**
     * @notice seconds until the next epoch begins
     */
    function secondsToNextEpoch() external view returns (uint256) {
        return epoch.end.sub(block.timestamp);
    }

    /* ========== MANAGERIAL FUNCTIONS ========== */

    /**
     * @notice sets the contract address for LP staking
     * @param _distributor address
     */
    function setDistributor(address _distributor) external onlyGovernor {
        distributor = IDistributor(_distributor);
        emit DistributorSet(_distributor);
    }

    /**
     * @notice set warmup period for new stakers
     * @param _warmupPeriod uint
     */
    function setWarmupLength(uint256 _warmupPeriod) external onlyGovernor {
        warmupPeriod = _warmupPeriod;
        emit WarmupSet(_warmupPeriod);
    }
}
