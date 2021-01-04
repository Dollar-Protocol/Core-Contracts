pragma solidity >=0.4.24;

import "../lib/SafeMathInt.sol";
import "../lib/UInt256Lib.sol";
import "./dollars.sol";

/*
 *  Dollar Policy
 */


interface IDecentralizedOracle {
    function update() external;
    function consult(address token, uint amountIn) external view returns (uint amountOut);
}


contract DollarsPolicy is Ownable {
    using SafeMath for uint256;
    using SafeMathInt for int256;
    using UInt256Lib for uint256;

    event LogRebase(
        uint256 indexed epoch,
        uint256 exchangeRate,
        uint256 cpi,
        int256 requestedSupplyAdjustment,
        uint256 timestampSec
    );

    Dollars public dollars;

    // Provides the current CPI, as an 18 decimal fixed point number.
    IDecentralizedOracle public sharesPerUsdOracle;
    IDecentralizedOracle public ethPerUsdOracle;
    IDecentralizedOracle public ethPerUsdcOracle;

    uint256 public deviationThreshold;

    uint256 public rebaseLag;

    uint256 private cpi;

    uint256 public minRebaseTimeIntervalSec;

    uint256 public lastRebaseTimestampSec;

    uint256 public rebaseWindowOffsetSec;

    uint256 public rebaseWindowLengthSec;

    uint256 public epoch;

    address public WETH_ADDRESS;
    address public SHARE_ADDRESS;

    uint256 private constant DECIMALS = 18;

    uint256 private constant MAX_RATE = 10**6 * 10**DECIMALS;
    uint256 private constant MAX_SUPPLY = ~(uint256(1) << 255) / MAX_RATE;

    address public orchestrator;
    bool private initializedOracle;

    modifier onlyOrchestrator() {
        require(msg.sender == orchestrator);
        _;
    }

    uint256 public minimumDollarCirculation;

    uint256 public constant MAX_SLIPPAGE_PARAM = 1180339 * 10**2; // max ~20% market impact
    uint256 public constant MAX_MINT_PERC_PARAM = 100 * 10**7; // max 100% of rebase can go to treasury

    uint256 public rebaseMintPerc;
    uint256 public maxSlippageFactor;
    address public treasury;

    address public public_goods;
    uint256 public public_goods_perc;

    event NewMaxSlippageFactor(uint256 oldSlippageFactor, uint256 newSlippageFactor);
    event NewRebaseMintPercent(uint256 oldRebaseMintPerc, uint256 newRebaseMintPerc);

    address public timelock;
    IDecentralizedOracle public usdxPerUsdcOracle;

    function getUsdSharePrice() external view returns (uint256) {
        uint256 sharePrice = sharesPerUsdOracle.consult(SHARE_ADDRESS, 1 * 10 ** 9);        // 10^9 decimals
        return sharePrice;
    }

    function setTimelock(address timelock_)
        external
        onlyOwner
    {
        timelock = timelock_;
    }

    function updatePrice() external {
        sharesPerUsdOracle.update();
        ethPerUsdOracle.update();
        ethPerUsdcOracle.update();
        usdxPerUsdcOracle.update();
    }

    function rebase() external onlyOrchestrator {
        require(inRebaseWindow(), "OUTISDE_REBASE");
        require(initializedOracle == true, 'ORACLE_NOT_INITIALIZED');

        require(lastRebaseTimestampSec.add(minRebaseTimeIntervalSec) < now, "MIN_TIME_NOT_MET");

        lastRebaseTimestampSec = now.sub(
            now.mod(minRebaseTimeIntervalSec)).add(rebaseWindowOffsetSec);

        epoch = epoch.add(1);

        sharesPerUsdOracle.update();
        ethPerUsdOracle.update();
        ethPerUsdcOracle.update();
        usdxPerUsdcOracle.update();

        // OLD Oracle (v1)
        // uint256 ethUsdcPrice = ethPerUsdcOracle.consult(WETH_ADDRESS, 1 * 10 ** 18);        // 10^18 decimals ropsten, 10^6 mainnet
        // uint256 ethUsdPrice = ethPerUsdOracle.consult(WETH_ADDRESS, 1 * 10 ** 18);          // 10^9 decimals
        // uint256 dollarCoinExchangeRate = ethUsdcPrice.mul(10 ** 21)                         // 10^18 decimals, 10**9 ropsten, 10**21 on mainnet
        //     .div(ethUsdPrice)

        uint256 usdxUsdcPrice = usdxPerUsdcOracle.consult(address(dollars), 1 * 10 ** 9);      // 1 Usdx = ? usdc
        uint256 dollarCoinExchangeRate = usdxUsdcPrice.mul(10 ** 12);                          // (10 ** 6) * (10 ** 12) = 10 ** 18

        uint256 targetRate = cpi;

        if (dollarCoinExchangeRate > MAX_RATE) {
            dollarCoinExchangeRate = MAX_RATE;
        }

        // dollarCoinExchangeRate & targetRate are 10^18 decimals
        int256 supplyDelta = computeSupplyDelta(dollarCoinExchangeRate, targetRate);        // supplyDelta = 10^9 decimals

        // Apply the Dampening factor.
        supplyDelta = supplyDelta.mul(10 ** 9).div(rebaseLag.toInt256Safe());

        // check on the expansionary side
        if (supplyDelta > 0 && dollars.totalSupply().add(uint256(supplyDelta)) > MAX_SUPPLY) {
            supplyDelta = (MAX_SUPPLY.sub(dollars.totalSupply())).toInt256Safe();
        }

        // check on the contraction side
        if (supplyDelta < 0 && uint256(supplyDelta.abs()) > MAX_SUPPLY) {
            supplyDelta = (MAX_SUPPLY).toInt256Safe();
        }

        // set minimum floor
        if (supplyDelta < 0 && dollars.totalSupply().add(dollars.totalDividendPoints()).sub(dollars.totalDebtPoints()).sub(uint256(supplyDelta.abs())) < minimumDollarCirculation) {
            supplyDelta = (dollars.totalSupply().add(dollars.totalDividendPoints()).sub(dollars.totalDebtPoints()).sub(minimumDollarCirculation)).toInt256Safe();
        }

        uint256 supplyAfterRebase;

        if (supplyDelta < 0) { // contraction, we send the amount of shares to mint
            uint256 dollarsToBurn = uint256(supplyDelta.abs());
            supplyAfterRebase = dollars.rebase(epoch, (dollarsToBurn).toInt256Safe().mul(-1));
        } else { // expansion, we send the amount of dollars to mint
            supplyAfterRebase = dollars.rebase(epoch, (uint256(supplyDelta)).toInt256Safe());
        }

        assert(supplyAfterRebase <= MAX_SUPPLY);
        emit LogRebase(epoch, dollarCoinExchangeRate, cpi, supplyDelta, now);
    }

    function setDeviationThreshold(uint256 deviationThreshold_)
        external
    {
        require(msg.sender == timelock);
        require(deviationThreshold_ != 0, "invalid deviationThreshold");
        require(deviationThreshold_ <= 10 * 10 ** (DECIMALS-2), "invalid deviationThreshold");
        deviationThreshold = deviationThreshold_;
    }

    function setCpi(uint256 cpi_)
        external
        onlyOwner
    {
        require(cpi_ > 0);
        cpi = cpi_;
    }

    function getCpi()
        external
        view
        returns (uint256)
    {
        return cpi;
    }

    function setRebaseLag(uint256 rebaseLag_)
        external
    {
        require(msg.sender == timelock);
        require(rebaseLag_ > 0);
        rebaseLag = rebaseLag_;
    }

    function initializeOracles(
        address sharesPerUsdOracleAddress,
        address ethPerUsdOracleAddress,
        address ethPerUsdcOracleAddress
    ) external onlyOwner {
        require(initializedOracle == false, 'ALREADY_INITIALIZED_ORACLE');
        sharesPerUsdOracle = IDecentralizedOracle(sharesPerUsdOracleAddress);
        ethPerUsdOracle = IDecentralizedOracle(ethPerUsdOracleAddress);
        ethPerUsdcOracle = IDecentralizedOracle(ethPerUsdcOracleAddress);

        initializedOracle = true;
    }

    function setSharePerUsdOracle(address sharesPerUsdOracleAddress) external onlyOwner {
        sharesPerUsdOracle = IDecentralizedOracle(sharesPerUsdOracleAddress);
    }

    function setUSDxPerUsdcOracle(address usdxPerUsdcOracleAddress) external onlyOwner {
        usdxPerUsdcOracle = IDecentralizedOracle(usdxPerUsdcOracleAddress);
    }

    function setEthPerUsdOracle(address ethPerUsdOracleAddress) external onlyOwner {
        ethPerUsdOracle = IDecentralizedOracle(ethPerUsdOracleAddress);
    }

    function setEthPerUsdcOracle(address ethPerUsdcOracleAddress) external onlyOwner {
        ethPerUsdcOracle = IDecentralizedOracle(ethPerUsdcOracleAddress);
    }

    function setMinimumDollarCirculation(uint256 minimumDollarCirculation_)
        external
        onlyOwner
    {
        minimumDollarCirculation = minimumDollarCirculation_;
    }

    function setRebaseTimingParameters(
        uint256 minRebaseTimeIntervalSec_,
        uint256 rebaseWindowOffsetSec_,
        uint256 rebaseWindowLengthSec_)
        external
        onlyOwner
    {
        require(minRebaseTimeIntervalSec_ > 0);
        require(rebaseWindowOffsetSec_ < minRebaseTimeIntervalSec_);

        minRebaseTimeIntervalSec = minRebaseTimeIntervalSec_;
        rebaseWindowOffsetSec = rebaseWindowOffsetSec_;
        rebaseWindowLengthSec = rebaseWindowLengthSec_;
    }

    function initialize(address owner_, Dollars dollars_)
        public
        initializer
    {
        Ownable.initialize(owner_);

        deviationThreshold = 5 * 10 ** (DECIMALS-2);

        rebaseLag = 50 * 10 ** 9;
        minRebaseTimeIntervalSec = 12 hours;
        rebaseWindowOffsetSec = 19800;  // with stock market, 19800 for 5:30am and 5:30pm UTC
        rebaseWindowLengthSec = 15 minutes;
        lastRebaseTimestampSec = 0;
        cpi = 1 * 10 ** 18;
        epoch = 0;
        minimumDollarCirculation = 1000000 * 10 ** 9; // 1M minimum dollar circulation

        dollars = dollars_;
    }

    function inRebaseWindow() public view returns (bool) {
        return (
            now.mod(minRebaseTimeIntervalSec) >= rebaseWindowOffsetSec &&
            now.mod(minRebaseTimeIntervalSec) < (rebaseWindowOffsetSec.add(rebaseWindowLengthSec))
        );
    }

    function computeSupplyDelta(uint256 rate, uint256 targetRate)
        private
        view
        returns (int256)
    {
        if (withinDeviationThreshold(rate, targetRate)) {
            return 0;
        }

        int256 targetRateSigned = targetRate.toInt256Safe();
        return dollars.totalSupply().toInt256Safe()
            .mul(rate.toInt256Safe().sub(targetRateSigned))
            .div(targetRateSigned);
    }

    function withinDeviationThreshold(uint256 rate, uint256 targetRate)
        private
        view
        returns (bool)
    {
        uint256 absoluteDeviationThreshold = targetRate.mul(deviationThreshold)
            .div(10 ** DECIMALS);

        return (rate >= targetRate && rate.sub(targetRate) < absoluteDeviationThreshold)
            || (rate < targetRate && targetRate.sub(rate) < absoluteDeviationThreshold);
    }
}
