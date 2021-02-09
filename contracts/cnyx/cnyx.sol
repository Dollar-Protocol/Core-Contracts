pragma solidity >=0.4.24;

import "../lib/UInt256Lib.sol";
import "../lib/SafeMathInt.sol";
import "../interface/ISeigniorageShares.sol";
import "openzeppelin-eth/contracts/math/SafeMath.sol";
import "openzeppelin-eth/contracts/token/ERC20/ERC20Detailed.sol";
import "openzeppelin-eth/contracts/ownership/Ownable.sol";
import "openzeppelin-eth/contracts/utils/ReentrancyGuard.sol";

interface IPool {
    function setLastRebase(uint256 newUsdAmount) external;
}

/*
 *  CNYx ERC20
 */

contract CNYx is ERC20Detailed, Ownable, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeMathInt for int256;

    uint256 private constant DECIMALS = 9;
    uint256 private constant MAX_SUPPLY = ~uint128(0);  // (2^128) - 1
    uint256 private constant POINT_MULTIPLIER = 10 ** 9;

    uint256 public percentToTreasury;
    uint256 private _totalSupply;
    uint256 private _totalDividendPoints;
    uint256 private _unclaimedDividends;
    uint256 public rebaseRewardSynth;
    uint256 public debaseBoolean;   // 1 is true, 0 is false
    uint256 public lpToShareRatio;
    
    address[] public uniSyncPairs;

    uint256 private _totalDebtPoints;
    uint256 private _unclaimedDebt;
    
    ISeigniorageShares Shares;

    address public monetaryPolicy;
    address public sharesAddress;
    address public treasury;
    address public poolRewardAddress;

    bool public rebasePaused;
    bool public tenPercentCap;
    bool public lastRebasePositive;
    bool public lastRebaseNeutral;

    string private _symbol;

    mapping(address => uint256) public debtPoints;
    mapping(address => bool) public debaseWhitelist;
    mapping(address => uint256) private _synthBalances;
    mapping (address => mapping (address => uint256)) private _allowedSynth;
    
    // Modifiers
    modifier onlyShare() {
        require(msg.sender == sharesAddress, "unauthorized");
        _;
    }

    modifier onlyMonetaryPolicy() {
        require(msg.sender == monetaryPolicy, "unauthorized");
        _;
    }

    modifier whenRebaseNotPaused() {
        require(!rebasePaused, "paused");
        _;
    }

    modifier validRecipient(address to) {
        require(to != address(0x0));
        require(to != address(this));
        _;
    }

    modifier updateAccount(address account) {
        uint256 owing = dividendsOwing(account);
        uint256 debt = debtOwing(account);

        if (owing > 0) {
            _unclaimedDividends = owing <= _unclaimedDividends ? _unclaimedDividends.sub(owing) : 0;
            _synthBalances[account] = _synthBalances[account].add(owing);
            _totalSupply = _totalSupply.add(owing);
            emit Transfer(address(0), account, owing);
        }

        if (debt > 0) {
            _unclaimedDebt = debt <= _unclaimedDebt ? _unclaimedDebt.sub(debt) : 0;

            // only debase non-whitelisted users
            if (!debaseWhitelist[account]) {
                debt = debt <= _synthBalances[account] ? debt : _synthBalances[account];

                _synthBalances[account] = _synthBalances[account].sub(debt);
                _totalSupply = _totalSupply.sub(debt);
                emit Transfer(account, address(0), debt);
            }
        }

        emit LogClaim(account, owing);

        Shares.setSyntheticDividendPoints(address(this), account, _totalDividendPoints);
        debtPoints[account] = _totalDebtPoints;

        _;
    }

    // Events
    event LogRebase(uint256 indexed epoch, uint256 totalSupply);
    event LogContraction(uint256 indexed epoch, uint256 synthToBurn);
    event LogRebasePaused(bool paused);
    event LogClaim(address indexed from, uint256 value);
    event LogDebaseWhitelist(address user, bool value);

    // constructor ======================================================================================================
    function initialize(address owner_, uint256 initialDistribution_, address seigniorageAddress)
        public
        initializer
    {
        ERC20Detailed.initialize("Chinese Yuan Renminbi", "CNYx", uint8(DECIMALS));
        ReentrancyGuard.initialize();
        Ownable.initialize(owner_);

        rebasePaused = false;
        debaseBoolean = 1;
        _totalSupply = 0;
        tenPercentCap = true;

        rebaseRewardSynth = 2000 * 10 ** DECIMALS;
        lpToShareRatio = 85;

        sharesAddress = seigniorageAddress;
        Shares = ISeigniorageShares(seigniorageAddress);

        disburse(initialDistribution_);
    }

    // view functions ======================================================================================================
    function symbol() public view returns (string memory) {
        return _symbol;
    }

    function totalSupply()
        external
        view
        returns (uint256)
    {
        return _totalSupply;
    }

    function balanceOf(address who)
        public
        view
        returns (uint256)
    {
        uint256 debt = debtOwing(who);
        debt = debt <= _synthBalances[who] ? debt : _synthBalances[who];

        return _synthBalances[who].sub(debt);
    }

    function allowance(address owner_, address spender)
        external
        view
        returns (uint256)
    {
        return _allowedSynth[owner_][spender];
    }

    function dividendsOwing(address account) public view returns (uint256) {
        if (_totalDividendPoints > Shares.lastSyntheticDividendPoints(address(this), account) && Shares.stakingStatus(account) == 1) {
            uint256 newDividendPoints = _totalDividendPoints.sub(Shares.lastSyntheticDividendPoints(address(this), account));
            uint256 sharesBalance = Shares.externalRawBalanceOf(account);
            return sharesBalance.mul(newDividendPoints).div(POINT_MULTIPLIER);
        } else {
            return 0;
        }
    }

    function debtOwing(address account) public view returns (uint256) {
        if (_totalDebtPoints > debtPoints[account] && !debaseWhitelist[account]) {
            uint256 newDebtPoints = _totalDebtPoints.sub(debtPoints[account]);
            uint256 dollarBalance = _synthBalances[account];
            return dollarBalance.mul(newDebtPoints).div(POINT_MULTIPLIER);
        } else {
            return 0;
        }
    }

    // external/public function ======================================================================================================
    function syncUniswapV2()
        external
    {
        for (uint256 i = 0; i < uniSyncPairs.length; i++) {
            (bool success, ) = uniSyncPairs[i].call(abi.encodeWithSignature('sync()'));
        }
    }

    function rebase(uint256 epoch, int256 supplyDelta)
        external
        nonReentrant
        onlyMonetaryPolicy
        whenRebaseNotPaused
        updateAccount(tx.origin)
        returns (uint256)
    {
        if (supplyDelta == 0) {
            IPool(poolRewardAddress).setLastRebase(0);

            lastRebasePositive = false;
            lastRebaseNeutral = true;
        } else if (supplyDelta < 0) {
            lastRebasePositive = false;
            lastRebaseNeutral = false;

            IPool(poolRewardAddress).setLastRebase(0);

            if (debaseBoolean == 1) {
                negativeRebaseHelper(epoch, supplyDelta);
            }
        } else { // > 0
            positiveRebaseHelper(supplyDelta);

            emit LogRebase(epoch, _totalSupply);
            lastRebasePositive = true;
            lastRebaseNeutral = false;

            if (_totalSupply > MAX_SUPPLY) {
                _totalSupply = MAX_SUPPLY;
            }
        }

        for (uint256 i = 0; i < uniSyncPairs.length; i++) {
            (bool success, ) = uniSyncPairs[i].call(abi.encodeWithSignature('sync()'));
        }

        _synthBalances[tx.origin] = _synthBalances[tx.origin].add(rebaseRewardSynth);
        _totalSupply = _totalSupply.add(rebaseRewardSynth);
        emit Transfer(address(0x0), tx.origin, rebaseRewardSynth);

        return _totalSupply;
    }

    function transfer(address to, uint256 value)
        external
        nonReentrant
        validRecipient(to)
        updateAccount(msg.sender)
        updateAccount(to)
        returns (bool)
    {
        _synthBalances[msg.sender] = _synthBalances[msg.sender].sub(value);
        _synthBalances[to] = _synthBalances[to].add(value);
        emit Transfer(msg.sender, to, value);

        return true;
    }

    function transferFrom(address from, address to, uint256 value)
        external
        nonReentrant
        validRecipient(to)
        updateAccount(from)
        updateAccount(to)
        returns (bool)
    {
        _allowedSynth[from][msg.sender] = _allowedSynth[from][msg.sender].sub(value);

        _synthBalances[from] = _synthBalances[from].sub(value);
        _synthBalances[to] = _synthBalances[to].add(value);
        emit Transfer(from, to, value);

        return true;
    }

    function approve(address spender, uint256 value)
        external
        validRecipient(spender)
        returns (bool)
    {
        _allowedSynth[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function increaseAllowance(address spender, uint256 addedValue)
        external
        returns (bool)
    {
        _allowedSynth[msg.sender][spender] =
            _allowedSynth[msg.sender][spender].add(addedValue);
        emit Approval(msg.sender, spender, _allowedSynth[msg.sender][spender]);
        return true;
    }

    function decreaseAllowance(address spender, uint256 subtractedValue)
        external
        returns (bool)
    {
        uint256 oldValue = _allowedSynth[msg.sender][spender];
        if (subtractedValue >= oldValue) {
            _allowedSynth[msg.sender][spender] = 0;
        } else {
            _allowedSynth[msg.sender][spender] = oldValue.sub(subtractedValue);
        }
        emit Approval(msg.sender, spender, _allowedSynth[msg.sender][spender]);
        return true;
    }

    function claimDividends(address account) external updateAccount(account) returns (bool) {
        return true;
    }

    // governance functions ======================================================================================================
    function setDebaseWhitelist(address user, bool val) onlyOwner {
        debaseWhitelist[user] = val;
        emit LogDebaseWhitelist(user, val);
    }

    function changeSymbol(string memory symbol) public onlyOwner {
        _symbol = symbol;
    }

    function setRebaseRewardCNYx(uint256 reward) external onlyOwner {
        rebaseRewardSynth = reward;
    }

    function setTreasuryPercent(uint256 percent) external onlyOwner {
        require(percent <= 100 * 10 ** 9, 'percent too high');
        percentToTreasury = percent;
    }

    function setLpToShareRatio(uint256 val_)
        external onlyOwner
    {
        require(val_ <= 100);

        lpToShareRatio = val_;
    }

    function setTenPercentCap(bool _val)
        external onlyOwner
    {
        tenPercentCap = _val;
    }

    function setRebasePaused(bool paused)
        external onlyOwner
    {
        rebasePaused = paused;
        emit LogRebasePaused(paused);
    }

    function setDebaseBoolean(uint256 val_)
        external onlyOwner
    {
        require(val_ <= 1, "value must be 0 or 1");
        debaseBoolean = val_;
    }

    // owner functions
    function setTreasury(address treasury_) external onlyOwner {
        treasury = treasury_;
    }

    function setPoolAddress(address pool_) external onlyOwner {
        poolRewardAddress = pool_;
    }

    function setPolicyAddress(address policy_) external onlyOwner {
        monetaryPolicy = policy_;
    }

    function removeUniPair(uint256 index) external onlyOwner {
        if (index >= uniSyncPairs.length) return;

        for (uint i = index; i < uniSyncPairs.length-1; i++){
            uniSyncPairs[i] = uniSyncPairs[i+1];
        }
        uniSyncPairs.length--;
    }

    function getUniSyncPairs()
        external
        view
        returns (address[] memory)
    {
        address[] memory pairs = uniSyncPairs;
        return pairs;
    }

    function addSyncPairs(address[] memory uniSyncPairs_)
        public
        onlyOwner
    {
        for (uint256 i = 0; i < uniSyncPairs_.length; i++) {
            uniSyncPairs.push(uniSyncPairs_[i]);
        }
    }

    // internal functions ======================================================================================================
    function negativeRebaseHelper(uint256 epoch, int256 supplyDelta) internal {
        uint256 synthToDelete = uint256(supplyDelta.abs());
        if (synthToDelete > _totalSupply.div(10) && tenPercentCap) {
            synthToDelete = _totalSupply.div(10);
        }

        _totalDebtPoints = _totalDebtPoints.add(synthToDelete.mul(POINT_MULTIPLIER).div(_totalSupply));
        _unclaimedDebt = _unclaimedDebt.add(synthToDelete);
        emit LogContraction(epoch, synthToDelete);
    }

    function positiveRebaseHelper(int256 supplyDelta) internal {
        uint256 synthToTreasury = uint256(supplyDelta).mul(percentToTreasury).div(100 * 10 ** 9);
        uint256 synthToLPs = uint256(supplyDelta).sub(synthToTreasury).mul(lpToShareRatio).div(100);
        
        _synthBalances[treasury] = _synthBalances[treasury].add(synthToTreasury);
        emit Transfer(address(0x0), treasury, synthToTreasury);

        IPool(poolRewardAddress).setLastRebase(synthToLPs);
        _synthBalances[poolRewardAddress] = _synthBalances[poolRewardAddress].add(synthToLPs);
        emit Transfer(address(0x0), poolRewardAddress, synthToLPs);
        
        _totalSupply = _totalSupply.add(synthToTreasury).add(synthToLPs);

        disburse(uint256(supplyDelta).sub(synthToTreasury).sub(synthToLPs));
    }

    function disburse(uint256 amount) internal returns (bool) {
        _totalDividendPoints = _totalDividendPoints.add(amount.mul(POINT_MULTIPLIER).div(Shares.totalStaked()));
        _unclaimedDividends = _unclaimedDividends.add(amount);

        return true;
    }
}
