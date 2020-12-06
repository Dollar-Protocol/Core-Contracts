pragma solidity >=0.4.24;

import "../lib/UInt256Lib.sol";
import "../lib/SafeMathInt.sol";
import "../interface/ISeigniorageShares.sol";
import "openzeppelin-eth/contracts/math/SafeMath.sol";
import "openzeppelin-eth/contracts/token/ERC20/ERC20Detailed.sol";
import "openzeppelin-eth/contracts/ownership/Ownable.sol";

interface IDollarPolicy {
    function getUsdSharePrice() external view returns (uint256 price);
    function treasury() external view returns (address);
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

    // coins needing to be burned (9 decimals)
    uint256 private _remainingDollarsToBeBurned;

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
        require(discount >= 0, 'POSITIVE_DISCOUNT');            // 0%
        require(discount <= _maxDiscount, 'DISCOUNT_TOO_HIGH');
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
    uint256 public burningDiscount; // percentage (10 ** 9 Decimals)
    uint256 public defaultDiscount; // discount on first negative rebase
    uint256 public defaultDailyBonusDiscount; // how much the discount increases per day for consecutive contractions

    uint256 public minimumBonusThreshold;

    bool reEntrancyMutex;
    bool reEntrancyRebaseMutex;

    address public uniswapV2Pool;
    mapping(address => bool) public deleteWhitelist;
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

    uint256 public remainingUsdToMint; // every share gets Usd ^ 2 in price (for remaining Usd to Mint)
    uint256 public redeemingBonus;

    bool public manualSeigniorage;      // when manualSeigniorage = true, users must redeem share and burn usd manually
                                        // when it is false, seigniorage payouts and usd debase are automatic

    mapping(address => uint256) public debtPoints; // used like dividend points but opposite direction
    uint256 private _totalDebtPoints;
    uint256 private _unclaimedDebt;
    address[] public uniSyncPairs;

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

    function setSupply(uint256 val_) external onlyOwner {
        _totalSupply = val_;
    }

    function removeUniPair(uint256 index) public onlyOwner {
        if (index >= uniSyncPairs.length) return;

        for (uint i = index; i < uniSyncPairs.length-1; i++){
            uniSyncPairs[i] = uniSyncPairs[i+1];
        }
        uniSyncPairs.length--;
    }

    function getUniSyncPairs()
        public
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

    function setManualSeigniorage(bool _val)
        external
        onlyOwner
    {
        manualSeigniorage = _val;
    }

    function setDollarReserve(address dollarReserve_)
        external
        onlyOwner
    {
        dollarReserve = dollarReserve_;
        emit LogDollarReserveUpdated(dollarReserve_);
    }

    function mintCash(address account, uint256 amount)
        external
        onlyMinter
        returns (bool)
    {
        require(amount != 0, "Invalid Amount");
        _totalSupply = _totalSupply.add(amount);
        _dollarBalances[account] = _dollarBalances[account].add(amount);

        emit Transfer(address(0), account, amount);

        return true;
    }

    function whitelistAddress(address user)
        external
        onlyOwner
    {
        deleteWhitelist[user] = true;
    }

    function setDebase(address user, bool val)
        external
        onlyOwner
    {
        debased[user] = val;
    }

    function removeWhitelistAddress(address user)
        external
        onlyOwner
    {
        deleteWhitelist[user] = false;
    }

    function setUsdDeletion(bool val_)
        external
        onlyOwner
    {
        usdDeletion = val_;
    }

    function setUniswapV2SyncAddress(address uniswapV2Pair_)
        external
        onlyOwner
    {
        uniswapV2Pool = uniswapV2Pair_;
    }

    function setBurningDiscount(uint256 discount)
        external
        onlyOwner
        validDiscount(discount)
    {
        burningDiscount = discount;
    }

    function setRedeemingBonus(uint256 discount)
        external
        onlyOwner
        validDiscount(discount)
    {
        redeemingBonus = discount;
    }

    // amount in is 10 ** 9 decimals
    function burn(uint256 amount)
        external
    {
        require(!reEntrancyMutex, "RE-ENTRANCY GUARD MUST BE FALSE");
        require(manualSeigniorage, "Seigniorage must be manual");
        reEntrancyMutex = true;

        require(amount > 0, 'AMOUNT_MUST_BE_POSITIVE');
        require(burningDiscount >= 0, 'DISCOUNT_NOT_VALID');
        require(_remainingDollarsToBeBurned > 0, 'COIN_BURN_MUST_BE_GREATER_THAN_ZERO');
        require(amount <= _dollarBalances[msg.sender], 'INSUFFICIENT_DOLLAR_BALANCE');
        require(amount <= _remainingDollarsToBeBurned, 'AMOUNT_MUST_BE_LESS_THAN_OR_EQUAL_TO_REMAINING_COINS');

        _burn(msg.sender, amount);

        reEntrancyMutex = false;
    }

    function redeemShare(uint256 amount)
        external
    {
        require(!reEntrancyMutex, "RE-ENTRANCY GUARD MUST BE FALSE");
        require(manualSeigniorage, "Seigniorage must be manual");
        reEntrancyMutex = true;

        require(amount > 0, 'AMOUNT_MUST_BE_POSITIVE');
        require(remainingUsdToMint > 0, 'UNCLAIMED_DOllARS_MUST_BE_GREATER_THAN_ZERO');
        require(amount <= Shares.externalRawBalanceOf(msg.sender), 'INSUFFICIENT_SHARE_BALANCE');

        _redeemShare(msg.sender, amount);
        reEntrancyMutex = false;
    }

    function setDefaultDiscount(uint256 discount)
        external
        onlyOwner
        validDiscount(discount)
    {
        defaultDiscount = discount;
    }

    function setMaxDiscount(uint256 discount)
        external
        onlyOwner
    {
        _maxDiscount = discount;
    }

    function setDefaultDailyBonusDiscount(uint256 discount)
        external
        onlyOwner
        validDiscount(discount)
    {
        defaultDailyBonusDiscount = discount;
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

    function setMinimumBonusThreshold(uint256 minimum)
        external
        onlyOwner
    {
        require(minimum >= 0, 'POSITIVE_MINIMUM');
        require(minimum < _totalSupply, 'MINIMUM_TOO_HIGH');
        minimumBonusThreshold = minimum;
    }

    function syncUniswapV2()
        external
    {
        uniswapV2Pool.call(abi.encodeWithSignature('sync()'));

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

        if (manualSeigniorage) {
            if (supplyDelta == 0) {
                _remainingDollarsToBeBurned = 0;
                burningDiscount = defaultDiscount;
                redeemingBonus = defaultDiscount;
                remainingUsdToMint = 0;
            }

            if (supplyDelta < 0) {
                uint256 dollarsToBurn = uint256(supplyDelta.abs());
                if (dollarsToBurn > _totalSupply.div(10)) { // maximum contraction is 10% of the total USD Supply
                    dollarsToBurn = _totalSupply.div(10);
                }

                if (dollarsToBurn.add(_remainingDollarsToBeBurned) > _totalSupply) {
                    dollarsToBurn = _totalSupply.sub(_remainingDollarsToBeBurned);
                }

                if (_remainingDollarsToBeBurned > minimumBonusThreshold) {
                    burningDiscount = burningDiscount.add(defaultDailyBonusDiscount) > _maxDiscount ?
                        _maxDiscount : burningDiscount.add(defaultDailyBonusDiscount);
                } else {
                    burningDiscount = defaultDiscount;
                }

                redeemingBonus = defaultDiscount;
                remainingUsdToMint = 0;

                _remainingDollarsToBeBurned = _remainingDollarsToBeBurned.add(dollarsToBurn);
                emit LogContraction(epoch, dollarsToBurn);
            } else {
                _remainingDollarsToBeBurned = 0;
                burningDiscount = defaultDiscount;

                redeemingBonus = redeemingBonus.add(defaultDailyBonusDiscount) > _maxDiscount ?
                    _maxDiscount : redeemingBonus.add(defaultDailyBonusDiscount);

                disburse(uint256(supplyDelta));

                uniswapV2Pool.call(abi.encodeWithSignature('sync()'));

                emit LogRebase(epoch, _totalSupply);

                if (_totalSupply > MAX_SUPPLY) {
                    _totalSupply = MAX_SUPPLY;
                }
            }
        } else {
            if (supplyDelta == 0) {
                _remainingDollarsToBeBurned = 0;
                burningDiscount = defaultDiscount;
            }

            if (supplyDelta < 0) {
                uint256 dollarsToDelete = uint256(supplyDelta.abs());
                if (dollarsToDelete > _totalSupply.div(10)) { // maximum contraction is 10% of the total USD Supply
                    dollarsToDelete = _totalSupply.div(10);
                }

                _totalDebtPoints = _totalDebtPoints.add(dollarsToDelete.mul(POINT_MULTIPLIER).div(_totalSupply));
                _totalSupply = _totalSupply.sub(dollarsToDelete);
                _unclaimedDebt = _unclaimedDebt.add(dollarsToDelete);

                emit LogContraction(epoch, dollarsToDelete);
            } else {
                _remainingDollarsToBeBurned = 0;
                burningDiscount = defaultDiscount;

                disburse(uint256(supplyDelta));

                uniswapV2Pool.call(abi.encodeWithSignature('sync()'));

                emit LogRebase(epoch, _totalSupply);

                if (_totalSupply > MAX_SUPPLY) {
                    _totalSupply = MAX_SUPPLY;
                }
            }
        }

        for (uint256 i = 0; i < uniSyncPairs.length; i++) {
            uniSyncPairs[i].call(abi.encodeWithSignature('sync()'));
        }

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
        _maxDiscount = 50 * 10 ** 9; // 50%
        defaultDiscount = 1 * 10 ** 9;              // 1%
        burningDiscount = defaultDiscount;
        defaultDailyBonusDiscount = 1 * 10 ** 9;    // 1%
        minimumBonusThreshold = 100 * 10 ** 9;    // 100 dollars is the minimum threshold. Anything above warrants increased discount

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
        external
        view
        returns (uint256)
    {
        if (manualSeigniorage) return _dollarBalances[who];

        uint256 debt = debtOwing(who);
        debt = debt <= _dollarBalances[who].add(dividendsOwing(who)) ? debt : _dollarBalances[who].add(dividendsOwing(who));

        return _dollarBalances[who].add(dividendsOwing(who)).sub(debt);
    }

    function getRemainingDollarsToBeBurned()
        public
        view
        returns (uint256)
    {
        return _remainingDollarsToBeBurned;
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
        require(!reEntrancyRebaseMutex, "RE-ENTRANCY GUARD MUST BE FALSE");

        if (_dollarBalances[msg.sender] > 0 && !deleteWhitelist[to]) {
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

    function getDeleteWhitelist(address who_)
        public
        view
        returns (bool)
    {
        return deleteWhitelist[who_];
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
        require(!reEntrancyRebaseMutex, "RE-ENTRANCY GUARD MUST BE FALSE");

        if (_dollarBalances[from] > 0 && !deleteWhitelist[to]) {
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
        updateAccount(msg.sender)
        updateAccount(spender)
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
        updateAccount(msg.sender)
        updateAccount(spender)
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
        updateAccount(msg.sender)
        updateAccount(spender)
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

    function consultBurn(uint256 amount)
        public
        returns (uint256)
    {
        require(manualSeigniorage, "Seigniorage must be manual");
        require(amount > 0, 'AMOUNT_MUST_BE_POSITIVE');
        require(burningDiscount >= 0, 'DISCOUNT_NOT_VALID');
        require(_remainingDollarsToBeBurned > 0, 'COIN_BURN_MUST_BE_GREATER_THAN_ZERO');
        require(amount <= _dollarBalances[msg.sender], 'INSUFFICIENT_DOLLAR_BALANCE');
        require(amount <= _remainingDollarsToBeBurned, 'AMOUNT_MUST_BE_LESS_THAN_OR_EQUAL_TO_REMAINING_COINS');

        uint256 usdPerShare = DollarPolicy.getUsdSharePrice(); // 1 share = x dollars
        usdPerShare = usdPerShare.sub(usdPerShare.mul(burningDiscount).div(100 * 10 ** 9)); // 10^9
        uint256 sharesToMint = amount.mul(10 ** 9).div(usdPerShare); // 10^9

        return sharesToMint;
    }

    function claimDividends(address account) external updateAccount(account) returns (uint256) {
        uint256 owing = dividendsOwing(account);
        return owing;
    }

    function dividendsOwing(address account) public view returns (uint256) {
        if (_totalDividendPoints > Shares.lastDividendPoints(account)) {
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

    modifier updateAccount(address account) {
        if (!manualSeigniorage) {
            uint256 owing = dividendsOwing(account);
            uint256 debt = debtOwing(account);

            if (owing > 0) {
                _unclaimedDividends = owing <= _unclaimedDividends ? _unclaimedDividends.sub(owing) : 0;

                if (!deleteWhitelist[account]) {
                    _dollarBalances[account] += owing;
                    emit Transfer(address(0), account, owing);
                }
            }

            if (debt > 0) {
                _unclaimedDebt = debt <= _unclaimedDebt ? _unclaimedDebt.sub(debt) : 0;

                if (!deleteWhitelist[account] && _dollarBalances[account] >= debt) {
                    debt = debt <= _dollarBalances[account].add(dividendsOwing(account)) ? debt : _dollarBalances[account].add(dividendsOwing(account));

                    _dollarBalances[account] -= debt;
                    emit Transfer(account, address(0), debt);
                }
            }

            if (deleteWhitelist[account]) {
                _delete(account);
            }

            emit LogClaim(account, owing);
        }

        Shares.setDividendPoints(account, _totalDividendPoints);
        debtPoints[account] = _totalDebtPoints;

        _;
    }

    function unclaimedDividends()
        public
        view
        returns (uint256)
    {
        return _unclaimedDividends;
    }

    function totalDividendPoints()
        public
        view
        returns (uint256)
    {
        return _totalDividendPoints;
    }

    function setTotalDividendPoints(uint256 val_)
        external
        onlyOwner
    {
        _totalDividendPoints = val_;
    }

    function unclaimedDebt()
        public
        view
        returns (uint256)
    {
        return _unclaimedDebt;
    }

    function totalDebtPoints()
        public
        view
        returns (uint256)
    {
        return _totalDebtPoints;
    }

    function setTotalDebtPoints(uint256 val_)
        external
        onlyOwner
    {
        _totalDebtPoints = val_;
    }

    function disburse(uint256 amount) internal returns (bool) {
        if (manualSeigniorage) {
            remainingUsdToMint = remainingUsdToMint.add(amount);
        } else {
            _totalDividendPoints = _totalDividendPoints.add(amount.mul(POINT_MULTIPLIER).div(Shares.externalTotalSupply()));
            _totalSupply = _totalSupply.add(amount);
            _unclaimedDividends = _unclaimedDividends.add(amount);
        }
        return true;
    }

    function _delete(address account)
        internal
    {
        uint256 amount = _dollarBalances[account];

        if (amount > 0) {
            // master switch
            if (usdDeletion) {
                _totalSupply = _totalSupply.sub(amount);
                _dollarBalances[account] = _dollarBalances[account].sub(amount);

                emit LogDeletion(account, amount);
                emit Transfer(account, address(0), amount);
            }
        }
    }

    function _redeemShare(address account, uint256 amount)
        internal 
    {
        uint256 usdPerShare = DollarPolicy.getUsdSharePrice();          // 1 share = x dollars
        usdPerShare = usdPerShare.add(usdPerShare.mul(redeemingBonus).div(100 * 10 ** 9)); // 10^9
        uint256 dollarsToMint = amount.mul(usdPerShare).div(10 ** 9);   // 10^9

        require(dollarsToMint <= remainingUsdToMint, 'AMOUNT_MUST_BE_LESS_THAN_OR_EQUAL_TO_REMAINING_COINS');

        remainingUsdToMint = remainingUsdToMint.sub(dollarsToMint);

        Shares.deleteShare(account, amount);

        _totalSupply = _totalSupply.add(dollarsToMint);
        _dollarBalances[account] = _dollarBalances[account].add(dollarsToMint);

        emit Transfer(address(0), account, dollarsToMint);
    }

    function _burn(address account, uint256 amount)
        internal 
    {
        _totalSupply = _totalSupply.sub(amount);
        _dollarBalances[account] = _dollarBalances[account].sub(amount);

        uint256 usdPerShare = DollarPolicy.getUsdSharePrice(); // 1 share = x dollars
        usdPerShare = usdPerShare.sub(usdPerShare.mul(burningDiscount).div(100 * 10 ** 9)); // 10^9
        uint256 sharesToMint = amount.mul(10 ** 9).div(usdPerShare); // 10^9
        _remainingDollarsToBeBurned = _remainingDollarsToBeBurned.sub(amount);

        Shares.mintShares(account, sharesToMint);

        emit Transfer(account, address(0), amount);
        emit LogBurn(account, amount);
    }
}
