const { expect } = require("chai");
const { ethers } = require("hardhat");
const { BigNumber } = ethers;

const EXAMPLE_IPFS_CIDv1 = "bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi";

const ONE_ETH = BigNumber.from(BigInt(1e18));
const TWO_ETH = BigNumber.from(2).mul(BigNumber.from(BigInt(1e18)));
const FIVE_ETH = BigNumber.from(5).mul(BigNumber.from(BigInt(1e18)));
const TEN_ETH = BigNumber.from(10).mul(BigNumber.from(BigInt(1e18)));
let TIMELOCK_PERIOD;

describe("Prove Me Wrong", () => {
  before("Deploying", async () => {
    [deployer, claimant, supporter, challenger, innocentBystander] = await ethers.getSigners();
    ({ arbitrator, pmw } = await deployContracts(deployer));
    TIMELOCK_PERIOD = await pmw.connect(deployer).CLAIM_WITHDRAWAL_TIMELOCK();
  });

  describe("Default", () => {
    // Skipping this in favor of the test case below as this is not useful for observing gas usages nor test functionality.
    it.skip("Should initialize a new claim", async () => {
      const args = [EXAMPLE_IPFS_CIDv1, 0];

      await expect(pmw.connect(deployer).initialize(...args))
        .to.emit(pmw, "NewClaim")
        .withArgs(...args.slice(0, 2));
    });

    // Main gas optimization should be here.
    it("Should initialize an fund a new claim", async () => {
      const args = [EXAMPLE_IPFS_CIDv1, 0];

      await expect(pmw.connect(claimant).initialize(...args, { value: TEN_ETH }))
        .to.emit(pmw, "NewClaim")
        .withArgs(...args.slice(0, 2))
        .to.emit(pmw, "BalanceUpdate")
        .withArgs(EXAMPLE_IPFS_CIDv1, claimant.address, 0, TEN_ETH);
    });

    it("Should not initialize an existing claim", async () => {
      const args = [EXAMPLE_IPFS_CIDv1, 0];

      await expect(pmw.connect(deployer).initialize(...args)).to.be.revertedWith("You can't change arbitrator settings of a live claim.");
    });

    it("Should fund a claim", async () => {
      const args = [EXAMPLE_IPFS_CIDv1];

      await expect(pmw.connect(supporter).fund(...args, { value: TEN_ETH }))
        .to.emit(pmw, "BalanceUpdate")
        .withArgs(EXAMPLE_IPFS_CIDv1, supporter.address, 0, TEN_ETH);
    });

    it("Should challenge a claim", async () => {
      const args = [EXAMPLE_IPFS_CIDv1];

      const challenge_FEE = await pmw.connect(deployer).challengeFee(...args);

      await expect(pmw.connect(challenger).challenge(...args, { value: challenge_FEE }));
    });

    it("Should not unfund a claim prior timelock", async () => {
      const args = [EXAMPLE_IPFS_CIDv1];

      await expect(pmw.connect(claimant).unfund(...args))
        .to.emit(pmw, "TimelockStarted")
        .withArgs(EXAMPLE_IPFS_CIDv1, claimant.address, TEN_ETH);

      await expect(pmw.connect(claimant).unfund(...args)).to.be.revertedWith("You need to wait for timelock.");
    });

    it("Should unfund a claim", async () => {
      const args = [EXAMPLE_IPFS_CIDv1];

      await ethers.provider.send("evm_increaseTime", [TIMELOCK_PERIOD]);

      await expect(pmw.connect(claimant).unfund(...args))
        .to.emit(pmw, "BalanceUpdate")
        .withArgs(EXAMPLE_IPFS_CIDv1, claimant.address, 1, TEN_ETH);
    });
  });
});

async function deployContracts(deployer) {
  const SHARE_DENOMINATOR = 1_000_000;
  const MIN_FUND_INCREASE_PERCENT = 25;
  const MIN_BOUNTY = ONE_ETH.div(BigNumber.from(1e3));

  const Arbitrator = await ethers.getContractFactory("Arbitrator", deployer);
  const arbitrator = await Arbitrator.deploy();
  await arbitrator.deployed();

  const PMW = await ethers.getContractFactory("ProveMeWrong", deployer);
  // const pmw = await PMW.deploy({ arbitrator: arbitrator.address, arbitratorExtraData: "0x00" }, SHARE_DENOMINATOR, MIN_FUND_INCREASE_PERCENT, MIN_BOUNTY);
  const pmw = await PMW.deploy({ arbitrator: arbitrator.address, arbitratorExtraData: "0x00" });

  await pmw.deployed();

  return {
    arbitrator,
    pmw,
  };
}
