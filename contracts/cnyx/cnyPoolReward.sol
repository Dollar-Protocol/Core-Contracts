pragma solidity >=0.4.24;

import "../interface/ICash.sol";
import "openzeppelin-eth/contracts/math/SafeMath.sol";
import "openzeppelin-eth/contracts/ownership/Ownable.sol";
import "openzeppelin-eth/contracts/token/ERC20/IERC20.sol";
import "openzeppelin-eth/contracts/utils/ReentrancyGuard.sol";

import "../lib/SafeMathInt.sol";

contract CNYxPoolReward is Ownable, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeMathInt for int256;

    struct PoolInfo {
        IERC20 lpToken;                                                 // lp token
        uint256 allocPoint;                                             // points to dictate pool ratio
        uint256 totalSynthPoints;                                       // records the total amount of Synth inputted to pool during rebases
    }

    struct UserInfo {
        uint256 amount;                                                 // LP tokens staked in pool
        uint256 lastSynthPoints;                                        // last period where user claimed synths
    }

    ICash Synth;
    PoolInfo[] public poolInfo;

    uint256 public lastReward;                                          // timestamp of the last time Synth seigniorage was deposited into this contract
    uint256 public totalAllocPoint;
    uint256 public constant POINT_MULTIPLIER = 10 ** 18;

    mapping (uint256 => mapping (address => UserInfo)) public userInfo; // Info of each user that stakes LP tokens.
    mapping (uint256 => mapping(address => uint256)) public lastUserAction; // pool -> user -> last action in seconds
    mapping (uint256 => uint256) public minimumStakingSeconds; // pool -> minimum seconds
    mapping (uint256 => uint256) public minimumCoolingSeconds; // pool -> minimum cooling seconds
    mapping (uint256 => mapping(address => uint256)) public lastUserCooldownAction; // pool -> user -> last cooldown action in seconds
    mapping (uint256 => mapping(address => uint256)) public userStatus; // 0 = unstaked, 1 = staked, 2 = committed

    // constructor ========================================================================
    function initialize(address owner_, address synth_)
        public
        initializer
    {
        Ownable.initialize(owner_);
        ReentrancyGuard.initialize();
        Synth = ICash(synth_);
    }

    // view functions ========================================================================
    function pendingReward(address _user, uint256 _poolID) public view returns (uint256) {
        PoolInfo storage pool = poolInfo[_poolID];
        UserInfo storage user = userInfo[_poolID][_user];

        uint256 userStake = user.amount;

        // no rewards for committed users
        if (pool.totalSynthPoints > user.lastSynthPoints && userStatus[_poolID][_user] != 2) {
            uint256 newDividendPoints = pool.totalSynthPoints.sub(user.lastSynthPoints);
            uint256 owedSynth =  userStake.mul(newDividendPoints).div(POINT_MULTIPLIER);

            owedSynth = owedSynth > Synth.balanceOf(address(this)) ? Synth.balanceOf(address(this)).div(2) : owedSynth;

            return owedSynth;
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

    function getStakedLP(address _user, uint256 _poolID) external view returns (uint256) {
        return userInfo[_poolID][_user].amount;
    }

    function getPoolToken(uint256 _poolID) external view returns (address) {
        return address(poolInfo[_poolID].lpToken);
    }

    // external/public function ========================================================================
    function deposit(uint256 _poolID, uint256 _amount) external nonReentrant returns (bool) {
        // validation checks to see if sufficient LP balance
        require(userStatus[_poolID][msg.sender] != 2, 'users committed to withdraw cannot deposit');
        require(IERC20(address(poolInfo[_poolID].lpToken)).balanceOf(msg.sender) >= _amount, "insuffient balance");

        PoolInfo storage pool = poolInfo[_poolID];
        UserInfo storage user = userInfo[_poolID][msg.sender];

        require(IERC20(pool.lpToken).transferFrom(msg.sender, address(this), _amount), "LP transfer failed");

        // auto claim if user deposits more + update their lastSynthPoints
        claimRewardInternal(_poolID, msg.sender);
        user.amount = user.amount.add(_amount);

        lastUserAction[_poolID][msg.sender] = now;
        userStatus[_poolID][msg.sender] = 1;

        return true;
    }

    function setLastRebase(uint256 newSynthAmount) external {
        require(msg.sender == address(Synth), "unauthorized");
        lastReward = block.timestamp;

        if (newSynthAmount > 0) {
            for (uint256 i = 0; i < poolInfo.length; ++i) {
                PoolInfo storage pool = poolInfo[i];
                uint256 allocPoint = pool.allocPoint;
                uint256 synthAllocated = newSynthAmount.mul(allocPoint).div(totalAllocPoint);

                uint256 totalPoolLP = IERC20(address(pool.lpToken)).balanceOf(address(this));
                pool.totalSynthPoints = pool.totalSynthPoints.add(synthAllocated.mul(POINT_MULTIPLIER).div(totalPoolLP));
            }
        }
    }

    function commitToWithdraw(uint256 _poolID) external nonReentrant returns (bool) {
        UserInfo storage user = userInfo[_poolID][msg.sender];

        require(userStatus[_poolID][msg.sender] == 1 || (user.amount > 0 && userStatus[_poolID][msg.sender] != 2), 'user must be staked first');
        require(_poolID < poolInfo.length, "must use valid pool ID");
        require(lastUserAction[_poolID][msg.sender] + minimumStakingSeconds[_poolID] <= now, "must wait the minimum staking seconds for the pool before committing to withdraw");

        claimRewardInternal(_poolID, msg.sender);

        lastUserCooldownAction[_poolID][msg.sender] = now;
        userStatus[_poolID][msg.sender] = 2;

        return true;
    }   

    function withdraw(uint256 _poolID) external nonReentrant returns (bool) {
        require(userStatus[_poolID][msg.sender] == 2, "user must commit to withdrawing first");
        require(_poolID < poolInfo.length, "must use valid pool ID");
        require(lastUserCooldownAction[_poolID][msg.sender] + minimumCoolingSeconds[_poolID] <= now, "must wait the minimum cooldown seconds for the pool before withdrawing");

        claimRewardInternal(_poolID, msg.sender);

        uint256 _amount = userInfo[_poolID][msg.sender].amount;

        resetUser(_poolID, msg.sender);
        lastUserAction[_poolID][msg.sender] = now;

        require(poolInfo[_poolID].lpToken.transfer(msg.sender, _amount), "LP return transfer failed");

        userStatus[_poolID][msg.sender] = 0;

        return true;
    }

    function claimReward(uint256 _poolID, address _user) public nonReentrant returns (bool) {
        require(_user != address(0x0));
        UserInfo storage user = userInfo[_poolID][_user];
        PoolInfo storage pool = poolInfo[_poolID];

        uint256 owedSynth = pendingReward(_user, _poolID);

        if (owedSynth > 0) require(Synth.transfer(_user, owedSynth), "Synth payout failed");
        user.lastSynthPoints = pool.totalSynthPoints;

        return true;
    }

    // governance functions ========================================================================
    // add pool -> do not add same pool more than once
    function addPool(uint256 _allocPoint, IERC20 _lpToken) external onlyOwner returns (bool) {
        require(_lpToken != address(0x0));
        totalAllocPoint = totalAllocPoint.add(_allocPoint);

        poolInfo.push(PoolInfo({
            lpToken: _lpToken,
            allocPoint: _allocPoint,
            totalSynthPoints: 0
        }));

        return true;
    }
    
    function setPool(uint256 _poolID, uint256 _allocPoint) external onlyOwner returns (bool) {
        totalAllocPoint = totalAllocPoint.sub(poolInfo[_poolID].allocPoint).add(_allocPoint);
        poolInfo[_poolID].allocPoint = _allocPoint;

        return true;
    }

    function setMinimumStakingSeconds(uint256 _poolID, uint256 _minSeconds) external onlyOwner {
        minimumStakingSeconds[_poolID] = _minSeconds;
    }

    function setMinimumCoolingSeconds(uint256 _poolID, uint256 _minSeconds) external onlyOwner {
        minimumCoolingSeconds[_poolID] = _minSeconds;
    }

    // internal functions ========================================================================
    function resetUser(uint256 _poolID, address _user) internal {
        UserInfo storage user = userInfo[_poolID][_user];

        user.amount = 0;
    }

    function claimRewardInternal(uint256 _poolID, address _user) internal returns (bool) {
        UserInfo storage user = userInfo[_poolID][_user];
        PoolInfo storage pool = poolInfo[_poolID];

        uint256 owedSynth = pendingReward(_user, _poolID);

        if (owedSynth > 0) require(Synth.transfer(_user, owedSynth), "Synth payout failed");
        user.lastSynthPoints = pool.totalSynthPoints;

        return true;
    }
}
