// eslint-disable
const { deployProxy } = require('@openzeppelin/truffle-upgrades');
const Web3 = require('web3');

const Policy = artifacts.require('./CNYxPolicy.sol');
const Synth = artifacts.require('./CNYx.sol');
const Orchestrator = artifacts.require('./CNYxOrchestrator.sol');
const PoolReward = artifacts.require('./CNYxPoolReward.sol');

const web3 = new Web3(`https://mainnet.infura.io/v3/${process.env.INFURA_KEY}`);

async function initialize() {
  console.log('initialize...');
}

module.exports = async function (deployer) { 
  await initialize();
  
  const chainLinkOracle = ''; // fill in with correct oracle
  const initialSynthCirculating = 21000 * 10 ** 9;

  const shareAddress = '0x39795344CBCc76cC3Fb94B9D1b15C23c2070C66D';
  const initialOwner = '0x89a359A3D37C3A857E62cDE9715900441b47acEC';
  const timelockOwner = '0xf4a4534a9A049E5B3B6701e71b276b8a11F09139';
  const treasuryAddress = '0x4a7644f6dd90e91B66C489240cE1bF77cec1175d';
  const uniswapV2FactoryAddress = '0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f';
  const usdcAddress = '0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48';
  const synthUsdcAllocPoint = '1000';
  const minimumStakingSeconds = '259200'; // 3 days
  const minimumCoolingSeconds = '86400';  // 1 day

  const orchestrator_instance = await deployer.deploy(Orchestrator);
  const synth_instance = await deployProxy(Synth, initialOwner, initialSynthCirculating, shareAddress, { deployer });
  const policy_instance = await deployProxy(Policy, initialOwner, chainLinkOracle, orchestrator_instance.address, synth_instance.address);
  const poolreward_instance = await deployProxy(PoolReward, synth_instance.address);
  
  // create uniswap pool
  const uniswapLpContract = poolreward_instance.createUniswapPool(uniswapV2FactoryAddress, synth_instance.address, usdcAddress);

  // add liquidity uniswap (synth / usdc)
  // deploy TWAP oracle
  // update TWAP price to initialize
  // set TWAP oracle in Synth contract

  // modifications post initialization
  synth_instance.setPolicyAddress(policy_instance.address);
  synth_instance.setPoolAddress(poolreward_instance.address);
  synth_instance.addSyncPairs([uniswapLpContract]);
  synth_instance.setTreasury(treasuryAddress);

  // adding pool reward
  poolreward_instance.addPool(synthUsdcAllocPoint, uniswapLpContract);
  poolreward_instance.setMinimumStakingSeconds(minimumStakingSeconds);
  poolreward_instance.setMinimumCoolingSeconds(minimumCoolingSeconds);

  // switch owners when done
  synth_instance.transferProxyAdminOwnership(timelockOwner);
  policy_instance.transferProxyAdminOwnership(timelockOwner);
  poolreward_instance.transferProxyAdminOwnership(timelockOwner);

  // submit call to DP governance to add new synth
  // let targets = ['0x39795344CBCc76cC3Fb94B9D1b15C23c2070C66D'];
  // let values = [0];
  // let signatures = ['addSyntheticAsset(address)'];
  // let callData = web3.eth.abi.encodeParameters(['address'], [synth_instance.address]);
  // let callDatas = [callData];
  // let description = '# ' + 'Add CNYx (Chinese Yuan Renminbi)' + '\n\n## Proposal Details:\n\n' + 'This formalizes the addition of CNYx to the Dollar Protocol ecosystem and allows Share to govern CNYx.';
  
  // 0x59f83d677898f7e0d68ecb225395d41fb190cb35 governorAlpha
  // governorAlpha.propose(targets, values, signatures, callDatas, description);
};
