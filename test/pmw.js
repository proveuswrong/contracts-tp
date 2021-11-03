const { expect } = require("chai");
const { ethers } = require("hardhat");
const { BigNumber } = ethers;

const EXAMPLE_IPFS_CIDv1 = "bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi";

const ONE_ETH = BigNumber.from(BigInt(1e18));
const TWO_ETH = BigNumber.from(2).mul(BigNumber.from(BigInt(1e18)));
const FIVE_ETH = BigNumber.from(5).mul(BigNumber.from(BigInt(1e18)));
const TEN_ETH = BigNumber.from(10).mul(BigNumber.from(BigInt(1e18)));

describe("Prove Me Wrong", () => {
  before("Deploying", async () => {
    [deployer, claimant, supporter, challenger, innocentBystander] = await ethers.getSigners();
    ({ arbitrator, pmw } = await deployContracts(deployer));
  });
  describe("Default", () => {
    it("Should create new claim", async () => {
      const args = [EXAMPLE_IPFS_CIDv1, 0];

      await expect(pmw.connect(deployer).initializeClaim(...args))
        .to.emit(pmw, "NewClaim")
        .withArgs(...args.slice(0, 2));
    });

    it("Should fund a claim", async () => {
      const args = [EXAMPLE_IPFS_CIDv1];

      await expect(pmw.connect(claimant).fund(...args, { value: TEN_ETH }))
        .to.emit(pmw, "BalanceUpdate")
        .withArgs(EXAMPLE_IPFS_CIDv1, claimant.address, 0, TEN_ETH);

      await expect(pmw.connect(supporter).fund(...args, { value: FIVE_ETH }));
    });

    it("Should unfund a claim", async () => {
      const args = [EXAMPLE_IPFS_CIDv1];

      // const oldBalance = await deployer.getBalance();

      await expect(pmw.connect(claimant).unfund(...args))
        .to.emit(pmw, "BalanceUpdate")
        .withArgs(EXAMPLE_IPFS_CIDv1, claimant.address, 1, TEN_ETH);

      await expect(pmw.connect(supporter).unfund(...args))
        .to.emit(pmw, "BalanceUpdate")
        .withArgs(EXAMPLE_IPFS_CIDv1, supporter.address, 1, FIVE_ETH);

      // const newBalance = await requester.getBalance();
      // expect(newBalance).to.equal(oldBalance.add(ONE_ETH), "Bad unfund");
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
