pragma solidity >=0.4.24;

import "../interface/ICash.sol";
import "openzeppelin-eth/contracts/math/SafeMath.sol";
import "openzeppelin-eth/contracts/ownership/Ownable.sol";
import "openzeppelin-eth/contracts/token/ERC20/ERC20Detailed.sol";
import "openzeppelin-eth/contracts/token/ERC20/IERC20.sol";
import "openzeppelin-eth/contracts/utils/ReentrancyGuard.sol";

import "../lib/SafeMathInt.sol";

/*
 *  xBond ERC20
 */


contract xBond is ERC20Detailed, Ownable, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeMathInt for int256;

    uint256 private constant DECIMALS = 9;
    uint256 private constant MAX_UINT256 = ~uint256(0);
    uint256 private constant INITIAL_BOND_SUPPLY = 0;

    uint256 private constant MAX_SUPPLY = ~uint128(0);  // (2^128) - 1

    uint256 private _totalSupply;

    // eslint-ignore
    ICash Dollars;

    mapping(address => uint256) private _bondBalances;
    mapping (address => mapping (address => uint256)) private _allowedBond;

    uint256 public claimableUSD;
    uint256 public lastRebase;
    mapping (address => uint256) public lastUserRebase;

    uint256 public constantUsdRebase;
    address public ethBondOracle;
    address public timelock;

    function initialize(address owner_, address timelock_, address dollar_)
        public
        initializer
    {
        ERC20Detailed.initialize("xBond", "xBond", uint8(DECIMALS));
        Ownable.initialize(owner_);
        ReentrancyGuard.initialize();
        Dollars = ICash(dollar_);
        timelock = timelock_;

        _totalSupply = INITIAL_BOND_SUPPLY;
        _bondBalances[owner_] = _totalSupply;

        emit Transfer(address(0x0), owner_, _totalSupply);
    }

     /**
     * @return The total number of Dollars.
     */
    function totalSupply()
        public
        view
        returns (uint256)
    {
        return _totalSupply;
    }

    // show balance minus shares
    function balanceOf(address who)
        public
        view
        returns (uint256)
    {
        return _bondBalances[who];
    }

    /**
     * @dev Transfer tokens to a specified address.
     * @param to The address to transfer to.
     * @param value The amount to be transferred.
     * @return True on success, false otherwise.
     */
    function transfer(address to, uint256 value)
        public
        updateAccount(msg.sender)
        updateAccount(to)
        validRecipient(to)
        returns (bool)
    {
        // make sure users cannot double claim if they have already claimed
        if (lastUserRebase[msg.sender] == lastRebase) lastUserRebase[to] = lastRebase;

        _bondBalances[msg.sender] = _bondBalances[msg.sender].sub(value);
        _bondBalances[to] = _bondBalances[to].add(value);
        emit Transfer(msg.sender, to, value);

        return true;
    }

    function setLastRebase(uint256 newUsdAmount) external {
        require(msg.sender == address(Dollars), "unauthorized");
        lastRebase = now;

        if (newUsdAmount == 0) {
            claimableUSD = 0;
            constantUsdRebase = 0;
        } else {
            claimableUSD = claimableUSD.add(newUsdAmount);
            constantUsdRebase = claimableUSD;
        }
    }

    function setTimelock(address timelock_) validRecipient(timelock_) external onlyOwner {
        timelock = timelock_;
    }

    function setEthBondOracle(address oracle_) validRecipient(oracle_) external onlyOwner {
        require(msg.sender == timelock);
        ethBondOracle = oracle_;
    }

    function mint(address _who, uint256 _amount) validRecipient(_who) public nonReentrant {
        require(msg.sender == address(Dollars), "unauthorized");

        _bondBalances[_who] = _bondBalances[_who].add(_amount);
        _totalSupply = _totalSupply.add(_amount);
        emit Transfer(address(0x0), _who, _amount);
    }

    function claimableProRataUSD(address _who) validRecipient(_who) public view returns (uint256) {
        return constantUsdRebase.mul(balanceOf(_who)).div(_totalSupply);
    }

    function remove(address _who, uint256 _amount, uint256 _usdAmount) validRecipient(_who) public nonReentrant {
        require(msg.sender == address(Dollars), "unauthorized");
        require(_usdAmount <= claimableUSD, "usd amount must be less than claimable usd");
        require(lastUserRebase[_who] != lastRebase, "user already claimed once - please wait until next rebase");

        uint256 proRataUsd = claimableProRataUSD(_who);
        require(_usdAmount <= proRataUsd, "usd amount exceeds pro-rata rights - please try a smaller amount");
        
        _bondBalances[_who] = _bondBalances[_who].sub(_amount);
        claimableUSD = claimableUSD.sub(_usdAmount);
        _totalSupply = _totalSupply.sub(_amount);

        lastUserRebase[_who] = lastRebase;
        emit Transfer(_who, address(0x0), _amount);
    }

    function setSupply(uint256 _amount) external onlyOwner {
        _totalSupply = _amount;
    }

    /**
     * @dev Function to check the amount of tokens that an owner has allowed to a spender.
     * @param owner_ The address which owns the funds.
     * @param spender The address which will spend the funds.
     * @return The number of tokens still available for the spender.
     */
    function allowance(address owner_, address spender)
        public
        view
        returns (uint256)
    {
        return _allowedBond[owner_][spender];
    }

    /**
     * @dev Transfer tokens from one address to another.
     * @param from The address you want to send tokens from.
     * @param to The address you want to transfer to.
     * @param value The amount of tokens to be transferred.
     */
    function transferFrom(address from, address to, uint256 value)
        public
        updateAccount(from)
        updateAccount(to)
        validRecipient(to)
        returns (bool)
    {
        // make sure users cannot double claim if they have already claimed
        if (lastUserRebase[from] == lastRebase) lastUserRebase[to] = lastRebase;

        _allowedBond[from][msg.sender] = _allowedBond[from][msg.sender].sub(value);

        _bondBalances[from] = _bondBalances[from].sub(value);
        _bondBalances[to] = _bondBalances[to].add(value);
        emit Transfer(from, to, value);

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
        public
        validRecipient(spender)
        returns (bool)
    {
        _allowedBond[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    modifier validRecipient(address to) {
        require(to != address(0x0));
        require(to != address(this));
        _;
    }

    /**
     * @dev Increase the amount of tokens that an owner has allowed to a spender.
     * This method should be used instead of approve() to avoid the double approval vulnerability
     * described above.
     * @param spender The address which will spend the funds.
     * @param addedValue The amount of tokens to increase the allowance by.
     */
    function increaseAllowance(address spender, uint256 addedValue)
        public
        returns (bool)
    {
        _allowedBond[msg.sender][spender] =
            _allowedBond[msg.sender][spender].add(addedValue);
        emit Approval(msg.sender, spender, _allowedBond[msg.sender][spender]);
        return true;
    }

    /**
     * @dev Decrease the amount of tokens that an owner has allowed to a spender.
     *
     * @param spender The address which will spend the funds.
     * @param subtractedValue The amount of tokens to decrease the allowance by.
     */
    function decreaseAllowance(address spender, uint256 subtractedValue)
        public

        returns (bool)    {
        uint256 oldValue = _allowedBond[msg.sender][spender];
        if (subtractedValue >= oldValue) {
            _allowedBond[msg.sender][spender] = 0;
        } else {
            _allowedBond[msg.sender][spender] = oldValue.sub(subtractedValue);
        }
        emit Approval(msg.sender, spender, _allowedBond[msg.sender][spender]);
        return true;
    }

    modifier updateAccount(address account) {
        Dollars.claimDividends(account);
        (bool success, ) = ethBondOracle.call(abi.encodeWithSignature('update()'));
        _;
    }
}
