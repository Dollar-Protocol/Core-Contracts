pragma solidity >=0.4.24;

import "../interface/ICash.sol";
import "openzeppelin-eth/contracts/math/SafeMath.sol";
import "openzeppelin-eth/contracts/ownership/Ownable.sol";
import "openzeppelin-eth/contracts/token/ERC20/IERC20.sol";
import "openzeppelin-eth/contracts/utils/ReentrancyGuard.sol";

import "../lib/SafeMathInt.sol";

contract PoolReward is Ownable, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeMathInt for int256;

    // eslint-ignore
    ICash Dollars;

    struct PoolInfo {
        IERC20 lpToken;             // lp token
        uint256 allocPoint;         // points to dictate pool ratio
        uint256 totalShare;         // global supply of "share"
        uint256 totalDollarPoints;  // records the total amount of USD inputted to pool during rebases
    }

    PoolInfo[] public poolInfo;
    uint256 public totalAllocPoint;
    uint256 private constant POINT_MULTIPLIER = 10 ** 9;

    uint256 public lastReward; // timestamp of the last time USD seigniorage was deposited into this contract

    struct UserInfo {
        uint256 amount;             // LP tokens staked in pool
        uint256 lastClaimed;        // last timestamp claimed reward
        uint256 shareBalance;       // share balance directly used in calculating reward proportion
        uint256 lastDollarPoints;   // last period where user claimed dollars
    }

    mapping (uint256 => mapping (address => UserInfo)) public userInfo; // Info of each user that stakes LP tokens.

    uint256 public constant POINT_MULTIPLIER_BIG = 10 ** 18;

    address public timelock;
    bool public canRedeem;
    mapping (uint256 => mapping(address => uint256)) public lastUserAction; // pool -> user -> last action in seconds
    mapping (uint256 => uint256) public minimumStakingSeconds; // pool -> minimum seconds

    function setLastRebase(uint256 newUsdAmount) external {
        require(msg.sender == address(Dollars), "unauthorized");
        lastReward = block.timestamp;

        if (newUsdAmount == 0) canRedeem = false;
        else {
            canRedeem = true;

            for (uint256 i = 0; i < poolInfo.length; ++i) {
                PoolInfo storage pool = poolInfo[i];
                uint256 allocPoint = pool.allocPoint;
                uint256 usdAllocated = newUsdAmount.mul(allocPoint).div(totalAllocPoint);

                uint256 totalPoolLP = IERC20(address(pool.lpToken)).balanceOf(address(this));
                pool.totalDollarPoints = pool.totalDollarPoints.add(usdAllocated.mul(POINT_MULTIPLIER_BIG).div(totalPoolLP));
            }
        }
    }

    function setMinimumStakingSeconds(uint256 _poolID, uint256 _minSeconds) external {
        require(msg.sender == timelock, "unauthorized");
        minimumStakingSeconds[_poolID] = _minSeconds;
    }

    function setCanRedeem(bool val_) external onlyOwner {
        canRedeem = val_;
    }

    function setTimelock(address timelock_)
        external
        onlyOwner
    {
        timelock = timelock_;
    }

    function setPoolDollarPoints(uint256 _poolID, uint256 _val) external onlyOwner {
        PoolInfo storage pool = poolInfo[_poolID];
        pool.totalDollarPoints = _val;
    }

    function setUserDollarPoints(uint256 _poolID, address _user, uint256 _val) external onlyOwner {
        UserInfo storage user = userInfo[_poolID][_user];
        user.lastDollarPoints = _val;
    }

    function initialize(address owner_, address dollar_)
        public
        initializer
    {
        Ownable.initialize(owner_);
        ReentrancyGuard.initialize();
        Dollars = ICash(dollar_);
    }

    // add pool -> do not add same pool more than once
    function addPool(uint256 _allocPoint, IERC20 _lpToken) external returns (bool) {
        require(msg.sender == timelock, "unauthorized");
        totalAllocPoint = totalAllocPoint.add(_allocPoint);

        poolInfo.push(PoolInfo({
            lpToken: _lpToken,
            allocPoint: _allocPoint,
            totalShare: 0,
            totalDollarPoints: 0
        }));

        return true;
    }

    // change reward ratio distribution
    function setPool(uint256 _poolID, uint256 _allocPoint) external returns (bool) {
        require(msg.sender == timelock, "unauthorized");
        totalAllocPoint = totalAllocPoint.sub(poolInfo[_poolID].allocPoint).add(_allocPoint);
        poolInfo[_poolID].allocPoint = _allocPoint;

        return true;
    }

    // gets pending reward
    function pendingReward(address _user, uint256 _poolID) public view returns (uint256) {
        PoolInfo storage pool = poolInfo[_poolID];
        UserInfo storage user = userInfo[_poolID][_user];

        uint256 userStake = user.amount;
        uint256 poolAllocPoint = pool.allocPoint;

        uint256 dollarShareBalance = pool.totalDollarPoints.sub(user.lastDollarPoints);

        if (pool.totalDollarPoints > user.lastDollarPoints) {
            uint256 newDividendPoints = pool.totalDollarPoints.sub(user.lastDollarPoints);
            uint256 owedDollars =  userStake.mul(newDividendPoints).div(POINT_MULTIPLIER_BIG);

            owedDollars = owedDollars > Dollars.balanceOf(address(this)) ? Dollars.balanceOf(address(this)).div(2) : owedDollars;

            return owedDollars;
        } else {
            return 0;
        }
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    function getPoolAllocPoints(uint256 _poolID) external view returns (uint256) {
        return poolInfo[_poolID].allocPoint;
    }

    // get users staked LP amount in a pool
    function getStakedLP(address _user, uint256 _poolID) external view returns (uint256) {
        return userInfo[_poolID][_user].amount;
    }

    function getPoolToken(uint256 _poolID) external view returns (address) {
        return address(poolInfo[_poolID].lpToken);
    }

    // deposit LP token
    function deposit(uint256 _poolID, uint256 _amount) external nonReentrant returns (bool) {
        // validation checks to see if sufficient LP balance
        require(IERC20(address(poolInfo[_poolID].lpToken)).balanceOf(msg.sender) >= _amount, "insuffient balance");

        PoolInfo storage pool = poolInfo[_poolID];
        UserInfo storage user = userInfo[_poolID][msg.sender];

        require(IERC20(pool.lpToken).transferFrom(msg.sender, address(this), _amount), "LP transfer failed");

        // auto claim if user deposits more + update their lastDollarPoints
        claimRewardInternal(_poolID, msg.sender);
        user.amount = user.amount.add(_amount);

        lastUserAction[_poolID][msg.sender] = now;

        return true;
    }

    // withdraw all LP + reward
    function withdraw(uint256 _poolID) external nonReentrant returns (bool) {
        require(_poolID < poolInfo.length, "must use valid pool ID");
        require(lastUserAction[_poolID][msg.sender] + minimumStakingSeconds[_poolID] <= now, "must wait the minimum staking seconds for the pool before withdrawing");

        claimRewardInternal(_poolID, msg.sender);

        uint256 _amount = userInfo[_poolID][msg.sender].amount;
        require(poolInfo[_poolID].lpToken.transfer(msg.sender, _amount), "LP return transfer failed");

        resetUser(_poolID, msg.sender);

        lastUserAction[_poolID][msg.sender] = now;

        return true;
    }

    // internal function for resetting user share / pool share, and user LP balance
    function resetUser(uint256 _poolID, address _user) internal {
        UserInfo storage user = userInfo[_poolID][_user];
        PoolInfo storage pool = poolInfo[_poolID];

        user.amount = 0;
        user.shareBalance = 0;
    }

    // claim USD reward without withdrawing principle
    function claimRewardInternal(uint256 _poolID, address _user) internal returns (bool) {
        UserInfo storage user = userInfo[_poolID][_user];
        PoolInfo storage pool = poolInfo[_poolID];

        uint256 owedDollars = pendingReward(_user, _poolID);

        if (owedDollars > 0) require(Dollars.transfer(_user, owedDollars), "USD payout failed");
        user.lastDollarPoints = pool.totalDollarPoints;

        return true;
    }

    function claimReward(uint256 _poolID, address _user) public nonReentrant returns (bool) {
        UserInfo storage user = userInfo[_poolID][_user];
        PoolInfo storage pool = poolInfo[_poolID];

        uint256 owedDollars = pendingReward(_user, _poolID);

        if (owedDollars > 0) require(Dollars.transfer(_user, owedDollars), "USD payout failed");
        user.lastDollarPoints = pool.totalDollarPoints;

        return true;
    }
}
