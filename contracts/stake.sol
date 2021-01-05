pragma solidity >=0.4.24;

import "./interface/ICash.sol";
import "openzeppelin-eth/contracts/math/SafeMath.sol";
import "openzeppelin-eth/contracts/ownership/Ownable.sol";
import "openzeppelin-eth/contracts/utils/ReentrancyGuard.sol";

import "./lib/SafeMathInt.sol";

contract stakingUSDx is Ownable, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeMathInt for int256;

    // eslint-ignore
    ICash Dollars;

    struct Stake {
        uint256 lastDollarPoints;   // variable to keep track of pending payouts
        uint256 stakingSeconds;     // when user started staking
        uint256 stakingAmount;      // how much user deposited in USDx
        uint256 unstakingSeconds;   // when user starts to unstake
        uint256 stakingStatus;      // 0 = unstaked, 1 = staked, 2 = commit to unstake
    }

    address timelock;
    uint256 public totalStaked;                                 // value that tracks the total amount of USDx staked
    uint256 public totalDollarPoints;                           // variable for keeping track of payouts
    uint256 public stakingMinimumSeconds;                       // minimum amount of allocated staking time per user
    mapping (address => Stake) public userStake;
    uint256 public coolDownPeriodSeconds;                       // how long it takes for a user to get paid their money back
    uint256 public constant POINT_MULTIPLIER = 10 ** 18;

    function initialize(address owner_, address dollar_, address timelock_) public initializer {
        Ownable.initialize(owner_);
        ReentrancyGuard.initialize();
        Dollars = ICash(dollar_);

        timelock = timelock_;
        stakingMinimumSeconds = 432000;                          // 432000 seconds = 5 days
        coolDownPeriodSeconds = 432000;                         // 5 days for getting out principal
    }

    function changeStakingMinimumSeconds(uint256 seconds_) external {
        require(msg.sender == timelock, "unauthorized");
        stakingMinimumSeconds = seconds_;
    }

    function changeCoolDownSeconds(uint256 seconds_) external {
        require(msg.sender == timelock, "unauthorized");
        coolDownPeriodSeconds = seconds_;
    }

    function addRebaseFunds(uint256 newUsdAmount) external {
        require(msg.sender == address(Dollars), "unauthorized");
        totalDollarPoints += newUsdAmount.mul(POINT_MULTIPLIER).div(totalStaked);
    }

    function stake(uint256 amount) external nonReentrant updateAccount(msg.sender) {
        require(amount != 0, "invalid stake amount");
        require(amount <= Dollars.balanceOf(msg.sender), "insufficient balance");
        require(Dollars.transferFrom(msg.sender, address(this), amount), "staking failed");

        userStake[msg.sender].stakingSeconds = now;
        userStake[msg.sender].stakingAmount += amount;
        totalStaked += amount;
        userStake[msg.sender].stakingStatus = 1;
    }

    function commitUnstake() external nonReentrant updateAccount(msg.sender) {
        require(userStake[msg.sender].stakingSeconds + stakingMinimumSeconds < now, "minimum time unmet");
        require(userStake[msg.sender].stakingStatus == 1, "user must be staked first");

        userStake[msg.sender].stakingStatus = 2;
        userStake[msg.sender].unstakingSeconds = now;
        totalStaked -= userStake[msg.sender].stakingAmount; // remove staked from pool for rewards
    }

    function unstake() external nonReentrant updateAccount(msg.sender) {
        require(userStake[msg.sender].stakingStatus == 2, "user must commit to unstaking first");
        require(userStake[msg.sender].unstakingSeconds + coolDownPeriodSeconds < now, "minimum time unmet");

        userStake[msg.sender].stakingStatus = 0;
        require(Dollars.transfer(msg.sender, userStake[msg.sender].stakingAmount), "unstaking failed");

        userStake[msg.sender].stakingAmount = 0;
    }

    function pendingReward(address user_) public view returns (uint256) {
        if (totalDollarPoints > userStake[user_].lastDollarPoints && userStake[user_].stakingStatus == 1) {
            uint256 newDividendPoints = totalDollarPoints.sub(userStake[user_].lastDollarPoints);
            uint256 owedDollars = (userStake[user_].stakingAmount).mul(newDividendPoints).div(POINT_MULTIPLIER);

            return owedDollars > Dollars.balanceOf(address(this)) ? Dollars.balanceOf(address(this)).div(2) : owedDollars;
        } else {
            return 0;
        }
    }

    function claimReward(address user_) public {
        uint256 reward = pendingReward(user_);
        if (reward > 0) require(Dollars.transfer(user_, reward), "claiming reward failed");

        userStake[user_].lastDollarPoints = totalDollarPoints;
    }
 
    modifier updateAccount(address account) {
        Dollars.claimDividends(account);
        claimReward(account);
        _;
    }
}
