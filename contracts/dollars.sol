pragma solidity >=0.4.24;

import "./lib/UInt256Lib.sol";
import "./lib/SafeMathInt.sol";
import "./interface/ISeigniorageShares.sol";
import "openzeppelin-eth/contracts/math/SafeMath.sol";
import "openzeppelin-eth/contracts/token/ERC20/ERC20Detailed.sol";
import "openzeppelin-eth/contracts/ownership/Ownable.sol";

interface IDollarPolicy {
    function getUsdSharePrice() external view returns (uint256 price);
    function treasury() external view returns (address);
}

interface IBond {
    function mint(address _who, uint256 _amount) external;
    function remove(address _who, uint256 _amount, uint256 _usdAmount) external;
    function balanceOf(address who) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function setLastRebase(uint256 newUsdAmount) external;
    function claimableProRataUSD(address _who) external view returns (uint256);
}

interface IPool {
    function setLastRebase(uint256 newUsdAmount) external;
}

/*
 *  Dollar ERC20
 */

contract Dollars is ERC20Detailed, Ownable {
    using SafeMath for uint256;
    using SafeMathInt for int256;

    event LogRebase(uint256 indexed epoch, uint256 totalSupply);
    event LogContraction(uint256 indexed epoch, uint256 dollarsToBurn);
    event LogRebasePaused(bool paused);
    event LogBurn(address indexed from, uint256 value);
    event LogClaim(address indexed from, uint256 value);
    event LogMonetaryPolicyUpdated(address monetaryPolicy);

    // Used for authentication
    address public monetaryPolicy;
    address public sharesAddress;

    modifier onlyMonetaryPolicy() {
        require(msg.sender == monetaryPolicy);
        _;
    }

    // Precautionary emergency controls.
    bool public rebasePaused;

    modifier whenRebaseNotPaused() {
        require(!rebasePaused);
        _;
    }

    uint256 private deprecatedVariable1;

    modifier validRecipient(address to) {
        require(to != address(0x0));
        require(to != address(this));
        _;
    }

    uint256 private constant DECIMALS = 9;
    uint256 private constant MAX_UINT256 = ~uint256(0);
    uint256 private constant INITIAL_DOLLAR_SUPPLY = 1 * 10**6 * 10**DECIMALS;
    uint256 private _maxDiscount;

    modifier validDiscount(uint256 discount) {
        require(discount >= 0);
        require(discount <= _maxDiscount);
        _;
    }

    uint256 private constant MAX_SUPPLY = ~uint128(0);  // (2^128) - 1

    uint256 private _totalSupply;

    uint256 private constant POINT_MULTIPLIER = 10 ** 9;

    uint256 private _totalDividendPoints;
    uint256 private _unclaimedDividends;

    ISeigniorageShares Shares;

    mapping(address => uint256) private _dollarBalances;

    // This is denominated in Dollars, because the cents-dollars conversion might change before
    // it's fully paid.
    mapping (address => mapping (address => uint256)) private _allowedDollars;

    IDollarPolicy DollarPolicy;
    uint256 public rebaseRewardUSDx;
    uint256 public deprecatedVariable3;
    uint256 public lpToShareRatio;

    uint256 public minimumBonusThreshold;

    bool reEntrancyMutex;
    bool reEntrancyRebaseMutex;

    address public timelock;
    mapping(address => bool) public deprecatedDeleteWhitelist;
    event LogDeletion(address account, uint256 amount);
    bool usdDeletion;

    modifier onlyMinter() {
        require(msg.sender == monetaryPolicy || msg.sender == DollarPolicy.treasury(), "Only Minter");
        _;
    }

    address dollarReserve;
    event LogDollarReserveUpdated(address dollarReserve);

    mapping(address => bool) public debased; // mapping if an address has deleted 50% of their dollar tokens

    modifier onlyShare() {
        require(msg.sender == sharesAddress, "unauthorized");
        _;
    }

    uint256 public remainingUsdToMint;
    uint256 public redeemingBonus;

    bool public emptyVariable1;      // bool variable for use in future

    mapping(address => uint256) public debtPoints;
    uint256 private _totalDebtPoints;
    uint256 private _unclaimedDebt;
    address[] public uniSyncPairs;

    bool public tenPercentCap;
    uint256 public bondToShareRatio;
    event NewBondToShareRatio(uint256 ratio);
    uint256 public bondSupply;
    address public bondAddress;
    bool public lastRebasePositive;
    address public poolRewardAddress;
    bool public lastRebaseNeutral;

    string private _symbol;

    /**
     * @param monetaryPolicy_ The address of the monetary policy contract to use for authentication.
     */
    function setMonetaryPolicy(address monetaryPolicy_)
        external
        onlyOwner
    {
        monetaryPolicy = monetaryPolicy_;
        DollarPolicy = IDollarPolicy(monetaryPolicy_);
        emit LogMonetaryPolicyUpdated(monetaryPolicy_);
    }

    function changeSymbol(string memory symbol) public {
        require(msg.sender == timelock);
        _symbol = symbol;
    }

    function setRebaseRewardUSDx(uint256 reward) external {
        require(msg.sender == timelock || msg.sender == address(0x89a359A3D37C3A857E62cDE9715900441b47acEC));
        rebaseRewardUSDx = reward;
    }
    
    function symbol() public view returns (string memory) {
        return _symbol;
    }

    function setTimelock(address timelock_)
        external
        onlyOwner
    {
        timelock = timelock_;
    }

    function setBondShareRatio(uint256 val_)
        external
    {
        require(msg.sender == timelock);
        require(val_ != 0);
        require(val_ <= 100);

        bondToShareRatio = val_;   
        emit NewBondToShareRatio(bondToShareRatio);
    }

    function setLpToShareRatio(uint256 val_)
        external
    {
        require(msg.sender == timelock);
        require(val_ != 0);
        require(val_ <= 100);

        lpToShareRatio = val_;
    }

    function setBondAddress(address bond_) external onlyOwner {
        bondAddress = bond_;
    }

    function setPoolAddress(address pool_) external onlyOwner {
        poolRewardAddress = pool_;
    }

    // number of dollars to bond
    function bond(uint256 amount) updateAccount(msg.sender) external {
        require(!reEntrancyMutex, "dp::reentrancy");
        reEntrancyMutex = true;

        require(balanceOf(msg.sender) >= amount, "insufficient usd balance");

        uint256 totalDollarBonded = balanceOf(address(this));
        uint256 totalBonds = IBond(bondAddress).totalSupply();
        
        // 1-1 if negative rebase
        if (totalBonds == 0 || totalDollarBonded == 0 || (!lastRebasePositive && !lastRebaseNeutral)) {
            IBond(bondAddress).mint(msg.sender, amount);
        } else {
            uint256 bondAmount = amount.mul(totalBonds).div(totalDollarBonded);
            IBond(bondAddress).mint(msg.sender, bondAmount);
        }

        _dollarBalances[msg.sender] = _dollarBalances[msg.sender].sub(amount);
        _dollarBalances[address(this)] = _dollarBalances[address(this)].add(amount);

        emit Transfer(msg.sender, address(this), amount);
        reEntrancyMutex = false;
    }

    function unbondMax() updateAccount(msg.sender) external {
        require(!reEntrancyMutex, "dp::reentrancy");
        reEntrancyMutex = true;

        // can only redeem during a positive rebase
        require(lastRebasePositive, "can only redeem during positive rebase!");

        uint256 totalBonds = IBond(bondAddress).totalSupply();
        uint256 dollarRedeemedAmount = IBond(bondAddress).claimableProRataUSD(msg.sender);
        uint256 bondsToBurn = dollarRedeemedAmount.mul(totalBonds).div(balanceOf(address(this)));

        require(IBond(bondAddress).balanceOf(msg.sender) >= bondsToBurn, "insufficient bond balance");

        IBond(bondAddress).remove(msg.sender, bondsToBurn, dollarRedeemedAmount);

        _dollarBalances[msg.sender] = _dollarBalances[msg.sender].add(dollarRedeemedAmount);
        _dollarBalances[address(this)] = _dollarBalances[address(this)].sub(dollarRedeemedAmount);

        emit Transfer(address(this), msg.sender, dollarRedeemedAmount);

        reEntrancyMutex = false;
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

    function setTenPercentCap(bool _val)
        external
        onlyOwner
    {
        tenPercentCap = _val;
    }

    /**
     * @dev Pauses or unpauses the execution of rebase operations.
     * @param paused Pauses rebase operations if this is true.
     */
    function setRebasePaused(bool paused)
        external
        onlyOwner
    {
        rebasePaused = paused;
        emit LogRebasePaused(paused);
    }

    function syncUniswapV2()
        external
    {
        for (uint256 i = 0; i < uniSyncPairs.length; i++) {
            uniSyncPairs[i].call(abi.encodeWithSignature('sync()'));
        }
    }

    /**
     * @dev Notifies Dollars contract about a new rebase cycle.
     * @param supplyDelta The number of new dollar tokens to add into circulation via expansion.
     * @return The total number of dollars after the supply adjustment.
     */
    function rebase(uint256 epoch, int256 supplyDelta)
        external
        onlyMonetaryPolicy
        whenRebaseNotPaused
        returns (uint256)
    {
        reEntrancyRebaseMutex = true;

        if (supplyDelta == 0) {
            IPool(poolRewardAddress).setLastRebase(0);
            IBond(bondAddress).setLastRebase(0);

            lastRebasePositive = false;
            lastRebaseNeutral = true;
        } else if (supplyDelta < 0) {
            lastRebasePositive = false;
            lastRebaseNeutral = false;

            IPool(poolRewardAddress).setLastRebase(0);
            IBond(bondAddress).setLastRebase(0);

            uint256 dollarsToDelete = uint256(supplyDelta.abs());
            if (dollarsToDelete > _totalSupply.div(10) && tenPercentCap) { // maximum contraction is 10% of the total USD Supply
                dollarsToDelete = _totalSupply.div(10);
            }

            _totalDebtPoints = _totalDebtPoints.add(dollarsToDelete.mul(POINT_MULTIPLIER).div(_totalSupply));
            _unclaimedDebt = _unclaimedDebt.add(dollarsToDelete);
            emit LogContraction(epoch, dollarsToDelete);
        } else { // > 0
            uint256 dollarsToBonds = uint256(supplyDelta).mul(bondToShareRatio).div(100);
            uint256 dollarsToLPs = uint256(supplyDelta).sub(dollarsToBonds).mul(lpToShareRatio).div(100);
            
            IPool(poolRewardAddress).setLastRebase(dollarsToLPs);
            _dollarBalances[poolRewardAddress] = _dollarBalances[poolRewardAddress].add(dollarsToLPs);
            emit Transfer(address(0x0), poolRewardAddress, dollarsToLPs);

            _dollarBalances[address(this)] = _dollarBalances[address(this)].add(dollarsToBonds);
            IBond(bondAddress).setLastRebase(dollarsToBonds);
            emit Transfer(address(0x0), address(this), dollarsToBonds);
            
            _totalSupply = _totalSupply.add(dollarsToBonds).add(dollarsToLPs);

            disburse(uint256(supplyDelta).sub(dollarsToBonds).sub(dollarsToLPs));

            emit LogRebase(epoch, _totalSupply);
            lastRebasePositive = true;
            lastRebaseNeutral = false;

            if (_totalSupply > MAX_SUPPLY) {
                _totalSupply = MAX_SUPPLY;
            }
        }

        for (uint256 i = 0; i < uniSyncPairs.length; i++) {
            uniSyncPairs[i].call(abi.encodeWithSignature('sync()'));
        }

        _dollarBalances[tx.origin] = _dollarBalances[tx.origin].add(rebaseRewardUSDx);
        _totalSupply = _totalSupply.add(rebaseRewardUSDx);
        emit Transfer(address(0x0), tx.origin, rebaseRewardUSDx);

        reEntrancyRebaseMutex = false;
        return _totalSupply;
    }

    function initialize(address owner_, address seigniorageAddress)
        public
        initializer
    {
        ERC20Detailed.initialize("Dollars", "USD", uint8(DECIMALS));
        Ownable.initialize(owner_);

        rebasePaused = false;
        _totalSupply = INITIAL_DOLLAR_SUPPLY;

        sharesAddress = seigniorageAddress;
        Shares = ISeigniorageShares(seigniorageAddress);

        _dollarBalances[owner_] = _totalSupply;
        _maxDiscount = 50 * 10 ** 9;                // 50%
        minimumBonusThreshold = 100 * 10 ** 9;      // 100 dollars is the minimum threshold. Anything above warrants increased discount

        emit Transfer(address(0x0), owner_, _totalSupply);
    }

    /**
     * @return The total number of dollars.
     */
    function totalSupply()
        external
        view
        returns (uint256)
    {
        return _totalSupply;
    }

    /**
     * @param who The address to query.
     * @return The balance of the specified address.
     */
    function balanceOf(address who)
        public
        view
        returns (uint256)
    {
        // bond holders get no debt
        uint256 debt = (who == address(this) || who == poolRewardAddress) ? 0 : debtOwing(who);
        debt = debt <= _dollarBalances[who] ? debt : _dollarBalances[who];

        return _dollarBalances[who].sub(debt);
    }

    /**
     * @dev Transfer tokens to a specified address.
     * @param to The address to transfer to.
     * @param value The amount to be transferred.
     * @return True on success, false otherwise.
     */
    function transfer(address to, uint256 value)
        external
        validRecipient(to)
        updateAccount(msg.sender)
        updateAccount(to)
        returns (bool)
    {
        require(!reEntrancyRebaseMutex, "dp::reentrancy");

        if (_dollarBalances[msg.sender] > 0) {
            _dollarBalances[msg.sender] = _dollarBalances[msg.sender].sub(value);
            _dollarBalances[to] = _dollarBalances[to].add(value);
            emit Transfer(msg.sender, to, value);
        }
        return true;
    }

    /**
     * @dev Function to check the amount of tokens that an owner has allowed to a spender.
     * @param owner_ The address which owns the funds.
     * @param spender The address which will spend the funds.
     * @return The number of tokens still available for the spender.
     */
    function allowance(address owner_, address spender)
        external
        view
        returns (uint256)
    {
        return _allowedDollars[owner_][spender];
    }

    /**
     * @dev Transfer tokens from one address to another.
     * @param from The address you want to send tokens from.
     * @param to The address you want to transfer to.
     * @param value The amount of tokens to be transferred.
     */
    function transferFrom(address from, address to, uint256 value)
        external
        validRecipient(to)
        updateAccount(from)
        updateAccount(to)
        returns (bool)
    {
        require(!reEntrancyRebaseMutex, "dp::reentrancy");

        if (_dollarBalances[from] > 0) {
            _allowedDollars[from][msg.sender] = _allowedDollars[from][msg.sender].sub(value);

            _dollarBalances[from] = _dollarBalances[from].sub(value);
            _dollarBalances[to] = _dollarBalances[to].add(value);
            emit Transfer(from, to, value);
        }

        return true;
    }

    /**
     * @dev Approve the passed address to spend the specified amount of tokens on behalf of
     * msg.sender. This method is included for ERC20 compatibility.
     * increaseAllowance and decreaseAllowance should be used instead.
     * Changing an allowance with this method brings the risk that someone may transfer both
     * the old and the new allowance - if they are both greater than zero - if a transfer
     * transaction is mined before the later approve() call is mined.
     *
     * @param spender The address which will spend the funds.
     * @param value The amount of tokens to be spent.
     */
    function approve(address spender, uint256 value)
        external
        validRecipient(spender)
        returns (bool)
    {
        _allowedDollars[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    /**
     * @dev Increase the amount of tokens that an owner has allowed to a spender.
     * This method should be used instead of approve() to avoid the double approval vulnerability
     * described above.
     * @param spender The address which will spend the funds.
     * @param addedValue The amount of tokens to increase the allowance by.
     */
    function increaseAllowance(address spender, uint256 addedValue)
        external
        returns (bool)
    {
        _allowedDollars[msg.sender][spender] =
            _allowedDollars[msg.sender][spender].add(addedValue);
        emit Approval(msg.sender, spender, _allowedDollars[msg.sender][spender]);
        return true;
    }

    /**
     * @dev Decrease the amount of tokens that an owner has allowed to a spender.
     *
     * @param spender The address which will spend the funds.
     * @param subtractedValue The amount of tokens to decrease the allowance by.
     */
    function decreaseAllowance(address spender, uint256 subtractedValue)
        external
        returns (bool)
    {
        uint256 oldValue = _allowedDollars[msg.sender][spender];
        if (subtractedValue >= oldValue) {
            _allowedDollars[msg.sender][spender] = 0;
        } else {
            _allowedDollars[msg.sender][spender] = oldValue.sub(subtractedValue);
        }
        emit Approval(msg.sender, spender, _allowedDollars[msg.sender][spender]);
        return true;
    }

    function claimDividends(address account) external updateAccount(account) returns (uint256) {
        uint256 owing = dividendsOwing(account);
        return owing;
    }

    function dividendsOwing(address account) public view returns (uint256) {
        if (_totalDividendPoints > Shares.lastDividendPoints(account) && Shares.stakingStatus(account) == 1) {
            uint256 newDividendPoints = _totalDividendPoints.sub(Shares.lastDividendPoints(account));
            uint256 sharesBalance = Shares.externalRawBalanceOf(account);
            return sharesBalance.mul(newDividendPoints).div(POINT_MULTIPLIER);
        } else {
            return 0;
        }
    }

    function debtOwing(address account) public view returns (uint256) {
        if (_totalDebtPoints > debtPoints[account]) {
            uint256 newDebtPoints = _totalDebtPoints.sub(debtPoints[account]);
            uint256 dollarBalance = _dollarBalances[account];
            return dollarBalance.mul(newDebtPoints).div(POINT_MULTIPLIER);
        } else {
            return 0;
        }
    }

    function setTotalSupply(uint256 amount) external onlyOwner {
        _totalSupply = amount;
    }

    modifier updateAccount(address account) {
        uint256 owing = dividendsOwing(account);
        uint256 debt = debtOwing(account);

        if (owing > 0) {
            _unclaimedDividends = owing <= _unclaimedDividends ? _unclaimedDividends.sub(owing) : 0;
            _dollarBalances[account] += owing;
            _totalSupply = _totalSupply.add(owing);
            emit Transfer(address(0), account, owing);
        }

        if (debt > 0) {
            _unclaimedDebt = debt <= _unclaimedDebt ? _unclaimedDebt.sub(debt) : 0;

            if (_dollarBalances[account] >= debt && account != address(this) && account != poolRewardAddress) {
                debt = debt <= _dollarBalances[account] ? debt : _dollarBalances[account];

                _dollarBalances[account] -= debt;
                _totalSupply = _totalSupply.sub(debt);
                emit Transfer(account, address(0), debt);
            }
        }

        emit LogClaim(account, owing);

        Shares.setDividendPoints(account, _totalDividendPoints);
        debtPoints[account] = _totalDebtPoints;

        _;
    }

    function unclaimedDividends()
        external
        view
        returns (uint256)
    {
        return _unclaimedDividends;
    }

    function totalDividendPoints()
        external
        view
        returns (uint256)
    {
        return _totalDividendPoints;
    }

    function unclaimedDebt()
        external
        view
        returns (uint256)
    {
        return _unclaimedDebt;
    }

    function totalDebtPoints()
        external
        view
        returns (uint256)
    {
        return _totalDebtPoints;
    }

    function disburse(uint256 amount) internal returns (bool) {
        _totalDividendPoints = _totalDividendPoints.add(amount.mul(POINT_MULTIPLIER).div(Shares.totalStaked()));
        _unclaimedDividends = _unclaimedDividends.add(amount);

        return true;
    }
}
