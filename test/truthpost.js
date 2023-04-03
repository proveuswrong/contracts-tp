const { expect } = require("chai");
const { ethers } = require("hardhat");
const { BigNumber } = ethers;
const crypto = require("crypto");
const { constants } = require("ethers");

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

describe("The Truth Post", () => {
  before("Deploying", async () => {
    [deployer, author, supporter, challenger, innocentBystander] = await ethers.getSigners();
    ({ arbitrator, truthPost } = await deployContracts(deployer));
    await sleep(9000); // To wait for eth gas reporter to fetch data. Remove this line when the issue is fixed. https://github.com/cgewecke/hardhat-gas-reporter/issues/72
    NUMBER_OF_LEAST_SIGNIFICANT_BITS_TO_IGNORE = await truthPost.connect(deployer).NUMBER_OF_LEAST_SIGNIFICANT_BITS_TO_IGNORE();
    MULTIPLIER_DENOMINATOR = await truthPost.connect(deployer).MULTIPLIER_DENOMINATOR();

    APPROX_ONE_ETH = BigNumber.from(909_494).mul(BigNumber.from(2).pow(NUMBER_OF_LEAST_SIGNIFICANT_BITS_TO_IGNORE));
  });

  describe("Default", () => {
    // First article, fresh slot.
    it("Should initialize a new article", async () => {
      const args = [crypto.randomBytes(30).toString("hex"), 0, 0];

      await expect(truthPost.connect(deployer).initializeArticle(...args, { value: TEN_ETH }))
        .to.emit(truthPost, "NewArticle")
        .withArgs(...args.slice(0, 3));
    });

    // Withdrawing the first article, to create a vacant used slot.
    it("Should withdraw", async () => {
      await expect(truthPost.connect(deployer).initiateWithdrawal(0)).to.emit(truthPost, "TimelockStarted");
      // .withArgs(EXAMPLE_IPFS_CIDv1, author.address, BigNumber.from(2).mul(TEN_ETH));
      await ethers.provider.send("evm_increaseTime", [TIMELOCK_PERIOD]);

      await truthPost.connect(deployer).withdraw(0);
    });

    // Second article, using a vacant used slot. Gas usage should be less than 35K here.
    it("Should initialize and fund a new article", async () => {
      const args = { articleID: crypto.randomBytes(30).toString("hex"), category: 0, articleAddress: 0 };

      await expect(truthPost.connect(author).initializeArticle(args.articleID, args.category, args.articleAddress, { value: TEN_ETH }))
        .to.emit(truthPost, "NewArticle")
        .withArgs(args.articleID, args.category, args.articleAddress)
        .to.emit(truthPost, "BalanceUpdate");
      // .withArgs(EXAMPLE_IPFS_CIDv1, TEN_ETH);
    });

    it("Should not initialize an existing article", async () => {
      const args = { articleID: ANOTHER_EXAMPLE_IPFS_CIDv1, category: 0, articleAddress: 0 };

      expect((await truthPost.connect(deployer).articleStorage(args.articleAddress)).bountyAmount).to.be.not.equal(0, "This storage slot is not occupied.");

      const vacantSlotIndex = await truthPost.connect(deployer).findVacantStorageSlot(0);

      expect(await truthPost.connect(deployer).initializeArticle(args.articleID, args.category, args.articleAddress, { value: APPROX_ONE_ETH }))
        .to.emit(truthPost, "NewArticle")
        .withArgs(args.articleID, args.category, vacantSlotIndex);
    });

    it("Should be able to increase bounty of a article", async () => {
      const args = [0];

      await expect(truthPost.connect(author).increaseBounty(...args, { value: TEN_ETH })).to.emit(truthPost, "BalanceUpdate");
      // .withArgs(EXAMPLE_IPFS_CIDv1, BigNumber.from(2).mul(TEN_ETH));
    });

    it("For reference: create dispute gas cost.", async () => {
      for (; disputeCounter < 10; disputeCounter++) {
        expect(await arbitrator.connect(challenger).createDispute(...[1, "0x1212121212121212"], { value: BigNumber.from("1000000000000000000") }))
          .to.emit(arbitrator, "DisputeCreation")
          .withArgs(disputeCounter, challenger.address);
      }
    });

    it("Should challenge a article", async () => {
      const ARTICLE_ADDRESS = 0;

      const challengeFee = await truthPost.connect(deployer).challengeFee(ARTICLE_ADDRESS);

      await expect(truthPost.connect(challenger).challenge(ARTICLE_ADDRESS, { value: challengeFee }))
        .to.emit(arbitrator, "DisputeCreation")
        .withArgs(disputeCounter++, truthPost.address);
    });

    it("Should submit evidence to a dispute", async () => {
      const args = [0, EXAMPLE_IPFS_CIDv1];

      await expect(truthPost.connect(challenger).submitEvidence(...args));
      await expect(truthPost.connect(challenger).submitEvidence(...args));
    });

    it("Should fund appeal of a dispute", async () => {
      const DISPUTE_ID = disputeCounter - 1;
      const ARTICLE_ADDRESS = 0;

      await arbitrator.connect(deployer).giveRuling(DISPUTE_ID, RULING_OUTCOMES.ChallengeFailed, APPEAL_WINDOW);
      await ethers.provider.send("evm_increaseTime", [10]);

      const appealFee = await truthPost.connect(deployer).appealFee(DISPUTE_ID);
      const WINNER_FUNDING = appealFee.add(appealFee.mul(WINNER_STAKE_MULTIPLIER).div(MULTIPLIER_DENOMINATOR));
      const LOSER_FUNDING = appealFee.add(appealFee.mul(LOSER_STAKE_MULTIPLIER).div(MULTIPLIER_DENOMINATOR));

      expect(await truthPost.connect(challenger).fundAppeal(DISPUTE_ID, RULING_OUTCOMES.Debunked, { value: LOSER_FUNDING }))
        .to.emit(truthPost, "RulingFunded")
        .withArgs(DISPUTE_ID, 0, RULING_OUTCOMES.Debunked);

      expect(await truthPost.connect(challenger).fundAppeal(DISPUTE_ID, RULING_OUTCOMES.ChallengeFailed, { value: WINNER_FUNDING }))
        .to.emit(truthPost, "RulingFunded")
        .withArgs(DISPUTE_ID, 0, RULING_OUTCOMES.ChallengeFailed)
        .to.emit(arbitrator, "AppealDecision")
        .withArgs(DISPUTE_ID, truthPost.address);
    });

    it("Should return valid Round data", async () => {
      const DISPUTE_ID = disputeCounter - 1;
      const ARTICLE_ADDRESS = 0;

      await arbitrator.connect(deployer).giveRuling(DISPUTE_ID, RULING_OUTCOMES.ChallengeFailed, APPEAL_WINDOW);
      await ethers.provider.send("evm_increaseTime", [10]);

      const appealFee = await truthPost.connect(deployer).appealFee(DISPUTE_ID);
      const WINNER_FUNDING = appealFee.add(appealFee.mul(WINNER_STAKE_MULTIPLIER).div(MULTIPLIER_DENOMINATOR));
      const LOSER_FUNDING = appealFee.add(appealFee.mul(LOSER_STAKE_MULTIPLIER).div(MULTIPLIER_DENOMINATOR));

      await truthPost.connect(challenger).fundAppeal(DISPUTE_ID, RULING_OUTCOMES.Debunked, { value: LOSER_FUNDING });
      await truthPost.connect(challenger).fundAppeal(DISPUTE_ID, RULING_OUTCOMES.ChallengeFailed, { value: WINNER_FUNDING });

      const roundInfo = await truthPost.getRoundInfo(DISPUTE_ID, 0);
      expect(roundInfo.hasPaid[RULING_OUTCOMES.Debunked]).eq(true);
      expect(roundInfo.hasPaid[RULING_OUTCOMES.ChallengeFailed]).eq(true);

      expect(roundInfo.totalPerRuling[RULING_OUTCOMES.Debunked]).eq(LOSER_FUNDING);
      expect(roundInfo.totalPerRuling[RULING_OUTCOMES.ChallengeFailed]).eq(WINNER_FUNDING);

      expect(roundInfo.totalClaimableAfterExpenses).eq(WINNER_FUNDING.add(LOSER_FUNDING).sub(appealFee));
    });

    it("Should not let withdraw a article during a dispute", async () => {
      const args = { articleAddress: 0 };

      await expect(truthPost.connect(author).initiateWithdrawal(args.articleAddress)).to.be.revertedWith("Withdrawal already initiated or there is a challenge.");
    });

    it("Should let arbitrator to execute a ruling", async () => {
      const DISPUTE_ID = disputeCounter - 1;
      await arbitrator.connect(deployer).giveRuling(DISPUTE_ID, RULING_OUTCOMES.ChallengeFailed, 100000000);
      const { start, end } = await arbitrator.connect(deployer).appealPeriod(DISPUTE_ID);
      await ethers.provider.send("evm_increaseTime", [end.toNumber()]);
      await arbitrator.connect(deployer).executeRuling(DISPUTE_ID);
    });

    it("Should not let withdraw a article prior timelock", async () => {
      const args = { articleAddress: 0 };

      await expect(truthPost.connect(author).initiateWithdrawal(args.articleAddress)).to.emit(truthPost, "TimelockStarted");
      // .withArgs(EXAMPLE_IPFS_CIDv1, author.address, BigNumber.from(2).mul(TEN_ETH));

      await expect(truthPost.connect(author).withdraw(args.articleAddress)).to.be.revertedWith("You need to wait for timelock or wait until the challenge ends.");
    });

    it("Should let withdraw a article", async () => {
      const args = { articleAddress: 0 };

      await ethers.provider.send("evm_increaseTime", [TIMELOCK_PERIOD]);

      await expect(truthPost.connect(author).withdraw(args.articleAddress)).to.emit(truthPost, "ArticleWithdrawn").withArgs(args.articleAddress);
    });

    // Third article, using a vacant used slot. Gas usage should be less than 35K here.
    it("Should initialize and fund a new article", async () => {
      const args = { articleID: crypto.randomBytes(30).toString("hex"), category: 0, articleAddress: 0 };

      await expect(truthPost.connect(author).initializeArticle(args.articleID, args.category, args.articleAddress, { value: TEN_ETH }))
        .to.emit(truthPost, "NewArticle")
        .withArgs(args.articleID, args.category, args.articleAddress)
        .to.emit(truthPost, "BalanceUpdate");
      // .withArgs(EXAMPLE_IPFS_CIDv1, TEN_ETH);
    });

    it("Should let a challenger to win a bounty", async () => {
      disputeCounter++;
      const DISPUTE_ID = disputeCounter - 1;
      const ARTICLE_ADDRESS = 0;

      const challengeFee = await truthPost.connect(deployer).challengeFee(ARTICLE_ADDRESS);

      await expect(truthPost.connect(challenger).challenge(ARTICLE_ADDRESS, { value: challengeFee }));
      expect(await arbitrator.connect(deployer).giveRuling(DISPUTE_ID, RULING_OUTCOMES.Debunked, APPEAL_WINDOW))
        .to.emit(arbitrator, "AppealPossible")
        .withArgs(DISPUTE_ID, truthPost.address);
      const { start, end } = await arbitrator.connect(deployer).appealPeriod(DISPUTE_ID);
      await ethers.provider.send("evm_increaseTime", [end.toNumber()]);
      expect(await arbitrator.connect(deployer).executeRuling(DISPUTE_ID))
        .to.emit(truthPost, "Debunked")
        .withArgs(ARTICLE_ADDRESS);
    });

    it("Should validate difference b/w appeal periods of winner and loser sides", async () => {
      disputeCounter++;
      const DISPUTE_ID = disputeCounter - 1;

      const args = { articleID: crypto.randomBytes(30).toString("hex"), category: 0, articleAddress: 0 };
      await truthPost.connect(author).initializeArticle(args.articleID, args.category, args.articleAddress, { value: TEN_ETH });

      const challengeFee = await truthPost.challengeFee(args.articleAddress);

      await truthPost.connect(challenger).challenge(args.articleAddress, { value: challengeFee });
      // arbitrator gives rulin in favore of challenger (article is debunked)
      await arbitrator.connect(deployer).giveRuling(DISPUTE_ID, RULING_OUTCOMES.Debunked, APPEAL_WINDOW);

      const [start, end] = await truthPost.getAppealPeriod(DISPUTE_ID, RULING_OUTCOMES.Debunked);
      const [, loserEnd] = await truthPost.getAppealPeriod(DISPUTE_ID, RULING_OUTCOMES.ChallengeFailed);

      const winnerAppealPeriod = end.sub(start);
      const loserAppealPeriod = loserEnd.sub(start);
      expect(loserAppealPeriod.div(winnerAppealPeriod)).eq(BigNumber.from(LOSER_STAKE_MULTIPLIER).div(MULTIPLIER_DENOMINATOR));
    });

    it("Should validate remained amount to be raised for the current round", async () => {
      const DISPUTE_ID = disputeCounter - 1;
      await ethers.provider.send("evm_increaseTime", [10]);

      const appealFee = await truthPost.appealFee(DISPUTE_ID);
      const WINNER_FUNDING = appealFee.add(appealFee.mul(WINNER_STAKE_MULTIPLIER).div(MULTIPLIER_DENOMINATOR));
      const LOSER_FUNDING = appealFee.add(appealFee.mul(LOSER_STAKE_MULTIPLIER).div(MULTIPLIER_DENOMINATOR));

      await truthPost.connect(challenger).fundAppeal(DISPUTE_ID, RULING_OUTCOMES.Debunked, { value: WINNER_FUNDING });
      expect(await truthPost.getAmountRemainsToBeRaised(DISPUTE_ID, RULING_OUTCOMES.Debunked)).to.eq(constants.Zero);

      await truthPost.connect(deployer).fundAppeal(DISPUTE_ID, RULING_OUTCOMES.ChallengeFailed, { value: LOSER_FUNDING.mul(75).div(100) });
      expect(await truthPost.getAmountRemainsToBeRaised(DISPUTE_ID, RULING_OUTCOMES.ChallengeFailed)).to.eq(LOSER_FUNDING.mul(25).div(100));

      // dispute goes into the new Round
      await truthPost.connect(deployer).fundAppeal(DISPUTE_ID, RULING_OUTCOMES.ChallengeFailed, { value: LOSER_FUNDING.mul(25).div(100) });

      expect(await truthPost.getAmountRemainsToBeRaised(DISPUTE_ID, RULING_OUTCOMES.Debunked)).to.eq(WINNER_FUNDING);
      expect(await truthPost.getAmountRemainsToBeRaised(DISPUTE_ID, RULING_OUTCOMES.ChallengeFailed)).to.eq(LOSER_FUNDING);
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

  const TruthPost = await ethers.getContractFactory("TruthPost", deployer);
  // const truthPost = await PMW.deploy({ arbitrator: arbitrator.address, arbitratorExtraData: "0x00" }, SHARE_DENOMINATOR, MIN_FUND_INCREASE_PERCENT, MIN_BOUNTY);
  const truthPost = await TruthPost.deploy(arbitrator.address, "0x00", "Metaevidence", TIMELOCK_PERIOD, WINNER_STAKE_MULTIPLIER, LOSER_STAKE_MULTIPLIER);

  await truthPost.deployed();

  return {
    arbitrator,
    truthPost,
  };
}
