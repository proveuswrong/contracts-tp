const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("Prove Me Wrong", () => {
  before("Deploying", async () => {
    [deployer, requester, challenger, innocentBystander] = await ethers.getSigners();
    ({ arbitrator, pmw } = await deployContracts(deployer));
    requesterAddress = await requester.getAddress();
  });

  describe("Default", () => {
    const REQUESTER_STAKE = 1_000_000_000;
    const CHALLENGER_STAKE = 1_000_000_000;
    const REQUEST_PERIOD = 1_000;
    const FUNDING_PERIOD = 1_000;

    it("Should create settings", async () => {
      const args = ["IPFSHASH", 0];

      await expect(pmw.connect(deployer).setArbitratorSettings(...args))
        .to.emit(pmw, "NewClaim")
        .withArgs(...args.slice(0, 2));
    });
  });
});

async function deployContracts(deployer) {
  const Arbitrator = await ethers.getContractFactory("Arbitrator", deployer);
  const arbitrator = await Arbitrator.deploy();
  await arbitrator.deployed();

  const PMW = await ethers.getContractFactory("ProveMeWrong", deployer);
  const pmw = await PMW.deploy({ arbitrator: arbitrator.address, arbitratorExtraData: "0x00" });
  await pmw.deployed();

  return {
    arbitrator,
    pmw,
  };
}
