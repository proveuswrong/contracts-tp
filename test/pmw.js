const { expect } = require("chai");
const { ethers } = require("hardhat");
const { BigNumber } = ethers;
const crypto = require("crypto");

const EXAMPLE_IPFS_CIDv1 = "bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi";
const ANOTHER_EXAMPLE_IPFS_CIDv1 = "bafybeigdyrzt5sfp7OKOKAHLSKASLK2LK3JLlqabf3oclgtqy55fbzdi";
const WINNER_STAKE_MULTIPLIER = 300;
const LOSER_STAKE_MULTIPLIER = 700;
const APPEAL_WINDOW = 1000;

const ONE_ETH = BigNumber.from(BigInt(1e18));
const TWO_ETH = BigNumber.from(2).mul(BigNumber.from(BigInt(1e18)));
const FIVE_ETH = BigNumber.from(5).mul(BigNumber.from(BigInt(1e18)));
const TEN_ETH = BigNumber.from(1000).mul(BigNumber.from(BigInt(1e18)));

const TIMELOCK_PERIOD = 1000000;

let NUMBER_OF_LEAST_SIGNIFICANT_BITS_TO_IGNORE, APPROX_ONE_ETH;
let disputeCounter = 0;

const RULING_OUTCOMES = Object.freeze({ Tied: 0, ChallengeFailed: 1, Debunked: 2 });

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

describe("Prove Me Wrong", () => {
  before("Deploying", async () => {
    [deployer, claimant, supporter, challenger, innocentBystander] = await ethers.getSigners();
    ({ arbitrator, pmw } = await deployContracts(deployer));
    await sleep(9000); // To wait for eth gas reporter to fetch data. Remove this line when the issue is fixed. https://github.com/cgewecke/hardhat-gas-reporter/issues/72
    NUMBER_OF_LEAST_SIGNIFICANT_BITS_TO_IGNORE = await pmw.connect(deployer).NUMBER_OF_LEAST_SIGNIFICANT_BITS_TO_IGNORE();
    MULTIPLIER_DENOMINATOR = await pmw.connect(deployer).MULTIPLIER_DENOMINATOR();

    APPROX_ONE_ETH = BigNumber.from(909_494).mul(BigNumber.from(2).pow(NUMBER_OF_LEAST_SIGNIFICANT_BITS_TO_IGNORE));
  });

  describe("Default", () => {
    // First claim, fresh slot.
    it("Should initialize a new claim", async () => {
      const args = [crypto.randomBytes(30).toString("hex"),0, 0];

      await expect(pmw.connect(deployer).initializeClaim(...args, { value: TEN_ETH }))
        .to.emit(pmw, "NewClaim")
        .withArgs(...args.slice(0, 3));
    });

    // Withdrawing the first claim, to create a vacant used slot.
    it("Should withdraw", async () => {
      await expect(pmw.connect(deployer).initiateWithdrawal(0)).to.emit(pmw, "TimelockStarted");
      // .withArgs(EXAMPLE_IPFS_CIDv1, claimant.address, BigNumber.from(2).mul(TEN_ETH));
      await ethers.provider.send("evm_increaseTime", [TIMELOCK_PERIOD]);

      await pmw.connect(deployer).withdraw(0);
    });

    // Second claim, using a vacant used slot. Gas usage should be less than 35K here.
    it("Should initialize and fund a new claim", async () => {
      const args = { claimID: crypto.randomBytes(30).toString("hex"), category:0, claimAddress: 0 };

      await expect(pmw.connect(claimant).initializeClaim(args.claimID, args.category, args.claimAddress, { value: TEN_ETH }))
        .to.emit(pmw, "NewClaim")
        .withArgs(args.claimID, args.category, args.claimAddress)
        .to.emit(pmw, "BalanceUpdate");
      // .withArgs(EXAMPLE_IPFS_CIDv1, TEN_ETH);
    });

    it("Should not initialize an existing claim", async () => {
      const args = { claimID: ANOTHER_EXAMPLE_IPFS_CIDv1, category:0, claimAddress: 0 };

      expect((await pmw.connect(deployer).claimStorage(args.claimAddress)).bountyAmount).to.be.not.equal(0, "This storage slot is not occupied.");

      const vacantSlotIndex = await pmw.connect(deployer).findVacantStorageSlot(0);

      expect(await pmw.connect(deployer).initializeClaim(args.claimID, args.category, args.claimAddress, { value: APPROX_ONE_ETH }))
        .to.emit(pmw, "NewClaim")
        .withArgs(args.claimID, args.category, vacantSlotIndex);
    });

    it("Should be able to increase bounty of a claim", async () => {
      const args = [0];

      await expect(pmw.connect(claimant).increaseBounty(...args, { value: TEN_ETH })).to.emit(pmw, "BalanceUpdate");
      // .withArgs(EXAMPLE_IPFS_CIDv1, BigNumber.from(2).mul(TEN_ETH));
    });

    it("For reference: create dispute gas cost.", async () => {
      for (; disputeCounter < 10; disputeCounter++) {
        expect(await arbitrator.connect(challenger).createDispute(...[1, "0x1212121212121212"], { value: BigNumber.from("1000000000000000000") }))
          .to.emit(arbitrator, "DisputeCreation")
          .withArgs(disputeCounter, challenger.address);
      }
    });

    it("Should challenge a claim", async () => {
      const CLAIM_ADDRESS = 0;

      const challengeFee = await pmw.connect(deployer).challengeFee(CLAIM_ADDRESS);

      await expect(pmw.connect(challenger).challenge(CLAIM_ADDRESS, { value: challengeFee }))
        .to.emit(arbitrator, "DisputeCreation")
        .withArgs(disputeCounter++, pmw.address);
    });

    it("Should submit evidence to a dispute", async () => {
      const args = [0, EXAMPLE_IPFS_CIDv1];

      await expect(pmw.connect(challenger).submitEvidence(...args));
      await expect(pmw.connect(challenger).submitEvidence(...args));
    });

    it("Should fund appeal of a dispute", async () => {
      const DISPUTE_ID = disputeCounter - 1;
      const CLAIM_ADDRESS = 0;

      await arbitrator.connect(deployer).giveRuling(DISPUTE_ID, RULING_OUTCOMES.ChallengeFailed, APPEAL_WINDOW);
      await ethers.provider.send("evm_increaseTime", [10]);

      const appealFee = await pmw.connect(deployer).appealFee(DISPUTE_ID);
      const WINNER_FUNDING = appealFee.add(appealFee.mul(WINNER_STAKE_MULTIPLIER).div(MULTIPLIER_DENOMINATOR));
      const LOSER_FUNDING = appealFee.add(appealFee.mul(LOSER_STAKE_MULTIPLIER).div(MULTIPLIER_DENOMINATOR));

      expect(await pmw.connect(challenger).fundAppeal(DISPUTE_ID, RULING_OUTCOMES.Debunked, { value: LOSER_FUNDING }))
        .to.emit(pmw, "RulingFunded")
        .withArgs(DISPUTE_ID, 0, RULING_OUTCOMES.Debunked);

      expect(await pmw.connect(challenger).fundAppeal(DISPUTE_ID, RULING_OUTCOMES.ChallengeFailed, { value: WINNER_FUNDING }))
        .to.emit(pmw, "RulingFunded")
        .withArgs(DISPUTE_ID, 0, RULING_OUTCOMES.ChallengeFailed)
        .to.emit(arbitrator, "AppealDecision")
        .withArgs(DISPUTE_ID, pmw.address);
    });

    it("Should not let withdraw a claim during a dispute", async () => {
      const args = { claimAddress: 0 };

      await expect(pmw.connect(claimant).initiateWithdrawal(args.claimAddress)).to.be.revertedWith("Withdrawal already initiated or there is a challenge.");
    });

    it("Should let arbitrator to execute a ruling", async () => {
      const DISPUTE_ID = disputeCounter - 1;
      await arbitrator.connect(deployer).giveRuling(DISPUTE_ID, RULING_OUTCOMES.ChallengeFailed, 100000000);
      const { start, end } = await arbitrator.connect(deployer).appealPeriod(DISPUTE_ID);
      await ethers.provider.send("evm_increaseTime", [end.toNumber()]);
      await arbitrator.connect(deployer).executeRuling(DISPUTE_ID);
    });

    it("Should not let withdraw a claim prior timelock", async () => {
      const args = { claimAddress: 0 };

      await expect(pmw.connect(claimant).initiateWithdrawal(args.claimAddress)).to.emit(pmw, "TimelockStarted");
      // .withArgs(EXAMPLE_IPFS_CIDv1, claimant.address, BigNumber.from(2).mul(TEN_ETH));

      await expect(pmw.connect(claimant).withdraw(args.claimAddress)).to.be.revertedWith("You need to wait for timelock or wait until the challenge ends.");
    });

    it("Should let withdraw a claim", async () => {
      const args = { claimAddress: 0 };

      await ethers.provider.send("evm_increaseTime", [TIMELOCK_PERIOD]);

      await expect(pmw.connect(claimant).withdraw(args.claimAddress)).to.emit(pmw, "ClaimWithdrawn").withArgs(args.claimAddress);
    });

    // Third claim, using a vacant used slot. Gas usage should be less than 35K here.
    it("Should initialize and fund a new claim", async () => {
      const args = { claimID: crypto.randomBytes(30).toString("hex"), category:0, claimAddress: 0 };

      await expect(pmw.connect(claimant).initializeClaim(args.claimID, args.category, args.claimAddress, { value: TEN_ETH }))
        .to.emit(pmw, "NewClaim")
        .withArgs(args.claimID, args.category, args.claimAddress)
        .to.emit(pmw, "BalanceUpdate");
      // .withArgs(EXAMPLE_IPFS_CIDv1, TEN_ETH);
    });

    it("Should let a challenger to win a bounty", async () => {
      disputeCounter++;
      const DISPUTE_ID = disputeCounter - 1;
      const CLAIM_ADDRESS = 0;

      const challengeFee = await pmw.connect(deployer).challengeFee(CLAIM_ADDRESS);

      await expect(pmw.connect(challenger).challenge(CLAIM_ADDRESS, { value: challengeFee }));
      expect(await arbitrator.connect(deployer).giveRuling(DISPUTE_ID, RULING_OUTCOMES.Debunked, APPEAL_WINDOW))
        .to.emit(arbitrator, "AppealPossible")
        .withArgs(DISPUTE_ID, pmw.address);
      const { start, end } = await arbitrator.connect(deployer).appealPeriod(DISPUTE_ID);
      await ethers.provider.send("evm_increaseTime", [end.toNumber()]);
      expect(await arbitrator.connect(deployer).executeRuling(DISPUTE_ID))
        .to.emit(pmw, "Debunked")
        .withArgs(CLAIM_ADDRESS);
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
  const pmw = await PMW.deploy(arbitrator.address, "0x00", "Metaevidence", TIMELOCK_PERIOD, WINNER_STAKE_MULTIPLIER, LOSER_STAKE_MULTIPLIER);

  await pmw.deployed();

  return {
    arbitrator,
    pmw,
  };
}
