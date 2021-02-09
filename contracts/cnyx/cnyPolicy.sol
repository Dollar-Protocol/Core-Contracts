pragma solidity >=0.4.24;

import "../lib/SafeMathInt.sol";
import "../lib/UInt256Lib.sol";
import "./cnyx.sol";

/*
 *  CNYx Policy
 */

interface IDecentralizedOracle {
    function update() external;
    function consult(address token, uint amountIn) external view returns (uint amountOut);
}

interface IChainLink {
    function latestRoundData() external view returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

contract CNYxPolicy is Ownable {
    using SafeMath for uint256;
    using SafeMathInt for int256;
    using UInt256Lib for uint256;

    CNYx public synth;

    // Provides the current CPI, as an 18 decimal fixed point number.
    IDecentralizedOracle public cnyxPerUsdcOracle;

    uint256 private constant DECIMALS = 18;
    uint256 private constant MAX_SUPPLY = ~(uint256(1) << 255);

    uint256 public epoch;
    uint256 public rebaseLag;
    uint256 public deviationThreshold;
    uint256 public rebaseWindowOffsetSec;
    uint256 public rebaseWindowLengthSec;
    uint256 public lastRebaseTimestampSec;
    uint256 public minimumSynthCirculation;
    uint256 public minRebaseTimeIntervalSec;

    address public orchestrator;
    address public synthUsdChainLinkAddress;

    // modifiers
    modifier onlyOrchestrator() {
        require(msg.sender == orchestrator);
        _;
    }

    // events
    event LogRebase(
        uint256 indexed epoch,
        uint256 exchangeRate,
        int256 requestedSupplyAdjustment,
        uint256 timestampSec
    );

    // constructor
    function initialize(address owner_, address synthUsdChainLinkAddress_, address orchestrator_, CNYx synth_) public initializer {
        Ownable.initialize(owner_);
        orchestrator = orchestrator_;

        deviationThreshold = 1 * 10 ** (DECIMALS-2);
        synthUsdChainLinkAddress = synthUsdChainLinkAddress_;

        rebaseLag = 7 * 10 ** 9;
        minRebaseTimeIntervalSec = 12 hours;
        rebaseWindowOffsetSec = 3600;  // with asian time, 3600 for 1:00am and 1:00pm UTC (9am and 9pm for China)
        rebaseWindowLengthSec = 15 minutes;
        lastRebaseTimestampSec = 0;
        epoch = 0;
        minimumSynthCirculation = 1000 * 10 ** 9; // 1000 minimum synth circulation

        synth = synth_;
    }

    // view functions returns 10 ** 18 for USD / CNY ($0.15)
    function getTargetRate() public view returns (uint256) {
        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) = IChainLink(synthUsdChainLinkAddress).latestRoundData();
        return uint256(10 ** 26).div(uint256(answer));
    }

    function updatePrice() external {
        cnyxPerUsdcOracle.update();
    }

    function rebase() external onlyOrchestrator {
        require(inRebaseWindow(), "cnyx::outside_rebase");
        require(lastRebaseTimestampSec.add(minRebaseTimeIntervalSec) < now, "cnyx::min_time_not_met");

        lastRebaseTimestampSec = now.sub(now.mod(minRebaseTimeIntervalSec)).add(rebaseWindowOffsetSec);
        epoch = epoch.add(1);
        cnyxPerUsdcOracle.update();

        uint256 cnyxUsdcPrice = cnyxPerUsdcOracle.consult(address(synth), 1 * 10 ** 9);         // 1 CNYx = ? USDC
        uint256 synthCoinExchangeRate = cnyxUsdcPrice.mul(10 ** 12);                             // (10 ** 6) * (10 ** 12) = 10 ** 18
        uint256 targetRate = getTargetRate();                                                   // 10 ** 18 (CNY per USD)

        int256 supplyDelta = computeSupplyDelta(synthCoinExchangeRate, targetRate);             // supplyDelta = 10^9 decimals

        supplyDelta = supplyDelta.mul(10 ** 9).div(rebaseLag.toInt256Safe());                   // Apply the Dampening factor.

        if (supplyDelta > 0 && synth.totalSupply().add(uint256(supplyDelta)) > MAX_SUPPLY) {    // check on the expansionary side
            supplyDelta = (MAX_SUPPLY.sub(synth.totalSupply())).toInt256Safe();
        }

        if (supplyDelta < 0 && uint256(supplyDelta.abs()) > MAX_SUPPLY) {                       // check on the contraction side
            supplyDelta = (MAX_SUPPLY).toInt256Safe();
        }

        if (supplyDelta < 0 && synth.totalSupply().sub(uint256(supplyDelta.abs())) < minimumSynthCirculation) {
            supplyDelta = (synth.totalSupply().sub(minimumSynthCirculation)).toInt256Safe();
        }

        uint256 supplyAfterRebase;

        if (supplyDelta < 0) {
            uint256 synthToBurn = uint256(supplyDelta.abs());
            supplyAfterRebase = synth.rebase(epoch, (synthToBurn).toInt256Safe().mul(-1));      // contraction, we send the amount of synths to debase
        } else {
            supplyAfterRebase = synth.rebase(epoch, (uint256(supplyDelta)).toInt256Safe());     // expansion, we send the amount of synth to mint
        }

        assert(supplyAfterRebase <= MAX_SUPPLY);
        emit LogRebase(epoch, synthCoinExchangeRate, supplyDelta, now);
    }

    function setDeviationThreshold(uint256 deviationThreshold_) onlyOwner external {
        require(deviationThreshold_ != 0, "invalid deviationThreshold");
        require(deviationThreshold_ <= 10 * 10 ** (DECIMALS-2), "invalid deviationThreshold");
        deviationThreshold = deviationThreshold_;
    }

    function setRebaseLag(uint256 rebaseLag_) onlyOwner external {
        require(rebaseLag_ > 0);
        rebaseLag = rebaseLag_;
    }

    function setMinimumSynthCirculation(uint256 minimumSynthCirculation_) external onlyOwner {
        minimumSynthCirculation = minimumSynthCirculation_;
    }

    function setSynthPerUsdcOracle(address cnyxPerUsdcOracleAddress) external onlyOwner {
        require(cnyxPerUsdcOracleAddress != address(0x0));
        cnyxPerUsdcOracle = IDecentralizedOracle(cnyxPerUsdcOracleAddress);
    }

    function setRebaseTimingParameters(uint256 minRebaseTimeIntervalSec_, uint256 rebaseWindowOffsetSec_, uint256 rebaseWindowLengthSec_) onlyOwner external {
        require(minRebaseTimeIntervalSec_ > 0);
        require(rebaseWindowOffsetSec_ < minRebaseTimeIntervalSec_);

        minRebaseTimeIntervalSec = minRebaseTimeIntervalSec_;
        rebaseWindowOffsetSec = rebaseWindowOffsetSec_;
        rebaseWindowLengthSec = rebaseWindowLengthSec_;
    }

    // internal functions
    function inRebaseWindow() public view returns (bool) {
        return (
            now.mod(minRebaseTimeIntervalSec) >= rebaseWindowOffsetSec &&
            now.mod(minRebaseTimeIntervalSec) < (rebaseWindowOffsetSec.add(rebaseWindowLengthSec))
        );
    }

    function computeSupplyDelta(uint256 rate, uint256 targetRate) private view returns (int256) {
        if (withinDeviationThreshold(rate, targetRate)) {
            return 0;
        }

        int256 targetRateSigned = targetRate.toInt256Safe();
        return synth.totalSupply().toInt256Safe().mul(rate.toInt256Safe().sub(targetRateSigned)).div(targetRateSigned);
    }

    function withinDeviationThreshold(uint256 rate, uint256 targetRate) private view returns (bool) {
        uint256 absoluteDeviationThreshold = targetRate.mul(deviationThreshold)
            .div(10 ** DECIMALS);

        return (rate >= targetRate && rate.sub(targetRate) < absoluteDeviationThreshold)
            || (rate < targetRate && targetRate.sub(rate) < absoluteDeviationThreshold);
    }
}
