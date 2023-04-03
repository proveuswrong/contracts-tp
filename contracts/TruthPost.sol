/**
 * SPDX-License-Identifier: MIT
 * @authors: @0xferit
 * @reviewers: [@shalzz*, @jaybuidl*]
 * @auditors: []
 * @bounties: []
 * @deployments: []
 */

pragma solidity ^0.8.10;

import "@kleros/dispute-resolver-interface-contract/contracts/IDisputeResolver.sol";
import "./ITruthPost.sol";

/** @title  The Trust Post
    @notice Smart contract for a type of curation, where submitted items are on hold until they are withdrawn and the amount of security deposits are determined by submitters.
    @dev    Articles are not addressed with their identifiers. That enables us to reuse same storage address for another article later.
            Arbitrator is fixed, but subcourts, jury size and metaevidence are not.
            We prevent articles to get withdrawn immediately. This is to prevent submitter to escape punishment in case someone discovers an argument to debunk the article.
            Bounty amounts are compressed with a lossy compression method to save on storage cost.
 */
contract TruthPost is ITruthPost, IArbitrable, IEvidence {
  IArbitrator public immutable ARBITRATOR;
  uint256 public constant NUMBER_OF_RULING_OPTIONS = 2;
  uint256 public constant NUMBER_OF_LEAST_SIGNIFICANT_BITS_TO_IGNORE = 32; // To compress bounty amount to gain space in struct. Lossy compression.
  uint256 public immutable WINNER_STAKE_MULTIPLIER; // Multiplier of the arbitration cost that the winner has to pay as fee stake for a round in basis points.
  uint256 public immutable LOSER_STAKE_MULTIPLIER; // Multiplier of the arbitration cost that the loser has to pay as fee stake for a round in basis points.
  uint256 public constant LOSER_APPEAL_PERIOD_MULTIPLIER = 512; // Multiplier of the appeal period for losers (any other ruling options) in basis points. The loser is given less time to fund its appeal to defend against last minute appeal funding attacks.
  uint256 public constant MULTIPLIER_DENOMINATOR = 1024; // Denominator for multipliers.

  uint256 public challengeTaxRate = 16;
  uint256 public treasuryBalance;

  uint8 public categoryCounter = 0;

  address payable public admin = payable(msg.sender);

  modifier onlyAdmin() {
    require(msg.sender == admin);
    _;
  }

  struct DisputeData {
    address payable challenger;
    RulingOptions outcome;
    uint8 articleCategory;
    bool resolved; // To remove dependency to disputeStatus function of arbitrator. This function is likely to be removed in Kleros v2.
    uint80 articleStorageAddress; // 2^16 is sufficient. Just using extra available space.
    Round[] rounds; // Tracks each appeal round of a dispute.
  }

  struct Round {
    mapping(address => uint256[NUMBER_OF_RULING_OPTIONS + 1]) contributions;
    bool[NUMBER_OF_RULING_OPTIONS + 1] hasPaid; // True if the fees for this particular answer has been fully paid in the form hasPaid[rulingOutcome].
    uint256[NUMBER_OF_RULING_OPTIONS + 1] totalPerRuling;
    uint256 totalClaimableAfterExpenses;
  }

  struct Article {
    address payable owner;
    uint32 withdrawalPermittedAt; // Overflows in year 2106.
    uint56 bountyAmount; // 32-bits compression. Decompressed size is 88 bits.
    uint8 category;
  }

  bytes[64] public categoryToArbitratorExtraData;

  mapping(uint80 => Article) public articleStorage; // Key: Storage address of article. Articles are not addressed with their identifiers, to enable reusing a storage slot.
  mapping(uint256 => DisputeData) public disputes; // Key: Dispute ID as in arbitrator.

  constructor(
    IArbitrator _arbitrator,
    bytes memory _arbitratorExtraData,
    string memory _metaevidenceIpfsUri,
    uint256 _articleWithdrawalTimelock,
    uint256 _winnerStakeMultiplier,
    uint256 _loserStakeMultiplier
  ) ITruthPost(_articleWithdrawalTimelock) {
    ARBITRATOR = _arbitrator;
    WINNER_STAKE_MULTIPLIER = _winnerStakeMultiplier;
    LOSER_STAKE_MULTIPLIER = _loserStakeMultiplier;

    newCategory(_metaevidenceIpfsUri, _arbitratorExtraData);
  }

  /** @notice Initializes an article.
      @param _articleID Unique identifier of an article. Usually an IPFS content identifier.
      @param _category Article category. This changes which metaevidence will be used.
      @param _searchPointer Starting point of the search. Find a vacant storage slot before calling this function to minimize gas cost.
   */
  function initializeArticle(
    string calldata _articleID,
    uint8 _category,
    uint80 _searchPointer
  ) external payable override {
    require(_category < categoryCounter, "This category does not exist");

    Article storage article;
    do {
      article = articleStorage[_searchPointer++];
    } while (article.bountyAmount != 0);

    article.owner = payable(msg.sender);
    article.bountyAmount = uint56(msg.value >> NUMBER_OF_LEAST_SIGNIFICANT_BITS_TO_IGNORE);
    article.category = _category;

    require(article.bountyAmount > 0, "You can't initialize an article without putting a bounty.");

    uint256 articleStorageAddress = _searchPointer - 1;
    emit NewArticle(_articleID, _category, articleStorageAddress);
    emit BalanceUpdate(articleStorageAddress, uint256(article.bountyAmount) << NUMBER_OF_LEAST_SIGNIFICANT_BITS_TO_IGNORE);
  }

  /** @notice Lets you submit evidence as defined in evidence (ERC-1497) standard.
      @param _disputeID Dispute ID as in arbitrator.
      @param _evidenceURI IPFS content identifier of the evidence.
   */
  function submitEvidence(uint256 _disputeID, string calldata _evidenceURI) external override {
    emit Evidence(ARBITRATOR, _disputeID, msg.sender, _evidenceURI);
  }

  /** @notice Lets you increase a bounty of a live article.
      @param _articleStorageAddress The address of the article in the storage.
   */
  function increaseBounty(uint80 _articleStorageAddress) external payable override {
    Article storage article = articleStorage[_articleStorageAddress];
    require(msg.sender == article.owner, "Only author can increase bounty of an article.");
    // To prevent mistakes.

    article.bountyAmount += uint56(msg.value >> NUMBER_OF_LEAST_SIGNIFICANT_BITS_TO_IGNORE);

    emit BalanceUpdate(_articleStorageAddress, uint256(article.bountyAmount) << NUMBER_OF_LEAST_SIGNIFICANT_BITS_TO_IGNORE);
  }

  /** @notice Lets a author to start withdrawal process.
      @dev withdrawalPermittedAt has some special values: 0 indicates withdrawal possible but process not started yet, max value indicates there is a challenge and during challenge it's forbidden to start withdrawal process.
      @param _articleStorageAddress The address of the article in the storage.
   */
  function initiateWithdrawal(uint80 _articleStorageAddress) external override {
    Article storage article = articleStorage[_articleStorageAddress];
    require(msg.sender == article.owner, "Only author can withdraw an article.");
    require(article.withdrawalPermittedAt == 0, "Withdrawal already initiated or there is a challenge.");

    article.withdrawalPermittedAt = uint32(block.timestamp + ARTICLE_WITHDRAWAL_TIMELOCK);
    emit TimelockStarted(_articleStorageAddress);
  }

  /** @notice Executes a withdrawal. Can only be executed by author.
      @dev withdrawalPermittedAt has some special values: 0 indicates withdrawal possible but process not started yet, max value indicates there is a challenge and during challenge it's forbidden to start withdrawal process.
      @param _articleStorageAddress The address of the article in the storage.
   */
  function withdraw(uint80 _articleStorageAddress) external override {
    Article storage article = articleStorage[_articleStorageAddress];

    require(msg.sender == article.owner, "Only author can withdraw an article.");
    require(article.withdrawalPermittedAt != 0, "You need to initiate withdrawal first.");
    require(article.withdrawalPermittedAt <= block.timestamp, "You need to wait for timelock or wait until the challenge ends.");

    uint256 withdrawal = uint96(article.bountyAmount) << NUMBER_OF_LEAST_SIGNIFICANT_BITS_TO_IGNORE;
    article.bountyAmount = 0;
    // This is critical to reset.
    article.withdrawalPermittedAt = 0;
    // This too, otherwise new article inside the same slot can withdraw instantly.
    payable(msg.sender).transfer(withdrawal);
    emit ArticleWithdrawn(_articleStorageAddress);
  }

  /** @notice Challenges the article at the given storage address. Follow events to find out which article resides in which slot.
      @dev withdrawalPermittedAt has some special values: 0 indicates withdrawal possible but process not started yet, max value indicates there is a challenge and during challenge it's forbidden to start another challenge.
      @param _articleStorageAddress The address of the article in the storage.
   */
  function challenge(uint80 _articleStorageAddress) public payable override {
    Article storage article = articleStorage[_articleStorageAddress];
    require(article.withdrawalPermittedAt != type(uint32).max, "There is an ongoing challenge.");
    article.withdrawalPermittedAt = type(uint32).max;
    // Mark as challenged.

    require(msg.value >= challengeFee(_articleStorageAddress), "Insufficient funds to challenge.");

    treasuryBalance += (article.bountyAmount * challengeTaxRate) / MULTIPLIER_DENOMINATOR;

    // To prevent mistakes.
    require(article.bountyAmount > 0, "Nothing to challenge.");

    uint256 disputeID = ARBITRATOR.createDispute{value: msg.value}(NUMBER_OF_RULING_OPTIONS, categoryToArbitratorExtraData[article.category]);

    disputes[disputeID].challenger = payable(msg.sender);
    disputes[disputeID].rounds.push();
    disputes[disputeID].articleStorageAddress = uint80(_articleStorageAddress);
    disputes[disputeID].articleCategory = article.category;

    // Evidence group ID is dispute ID.
    emit Dispute(ARBITRATOR, disputeID, article.category, disputeID);
    // This event links the dispute to an article storage address.
    emit Challenge(_articleStorageAddress, msg.sender, disputeID);
  }

  /** @notice Lets you fund a crowdfunded appeal. In case of funding is incomplete, you will be refunded. Withdrawal will be carried out using withdrawFeesAndRewards function.
      @param _disputeID The dispute ID as in the arbitrator.
      @param _supportedRuling The supported ruling in this funding.
   */
  function fundAppeal(uint256 _disputeID, RulingOptions _supportedRuling) external payable override returns (bool fullyFunded) {
    DisputeData storage dispute = disputes[_disputeID];

    RulingOptions currentRuling = RulingOptions(ARBITRATOR.currentRuling(_disputeID));
    uint256 basicCost;
    uint256 totalCost;
    {
      (uint256 appealWindowStart, uint256 appealWindowEnd) = ARBITRATOR.appealPeriod(_disputeID);

      uint256 multiplier;

      if (_supportedRuling == currentRuling) {
        require(block.timestamp < appealWindowEnd, "Funding must be made within the appeal period.");

        multiplier = WINNER_STAKE_MULTIPLIER;
      } else {
        require(
          block.timestamp < (appealWindowStart + (((appealWindowEnd - appealWindowStart) * LOSER_APPEAL_PERIOD_MULTIPLIER) / MULTIPLIER_DENOMINATOR)),
          "Funding must be made within the first half appeal period."
        );

        multiplier = LOSER_STAKE_MULTIPLIER;
      }

      basicCost = ARBITRATOR.appealCost(_disputeID, categoryToArbitratorExtraData[dispute.articleCategory]);
      totalCost = basicCost + ((basicCost * (multiplier)) / MULTIPLIER_DENOMINATOR);
    }

    RulingOptions supportedRulingOutcome = RulingOptions(_supportedRuling);

    uint256 lastRoundIndex = dispute.rounds.length - 1;
    Round storage lastRound = dispute.rounds[lastRoundIndex];
    require(!lastRound.hasPaid[uint256(supportedRulingOutcome)], "Appeal fee has already been paid.");

    uint256 contribution;
    {
      uint256 paidSoFar = lastRound.totalPerRuling[uint256(supportedRulingOutcome)];

      if (paidSoFar >= totalCost) {
        contribution = 0;
        // This can happen if arbitration fee gets lowered in between contributions.
      } else {
        contribution = totalCost - paidSoFar > msg.value ? msg.value : totalCost - paidSoFar;
      }
    }

    emit Contribution(_disputeID, lastRoundIndex, _supportedRuling, msg.sender, contribution);

    lastRound.contributions[msg.sender][uint256(supportedRulingOutcome)] += contribution;
    lastRound.totalPerRuling[uint256(supportedRulingOutcome)] += contribution;

    if (lastRound.totalPerRuling[uint256(supportedRulingOutcome)] >= totalCost) {
      lastRound.totalClaimableAfterExpenses += lastRound.totalPerRuling[uint256(supportedRulingOutcome)];
      lastRound.hasPaid[uint256(supportedRulingOutcome)] = true;
      emit RulingFunded(_disputeID, lastRoundIndex, _supportedRuling);
    }

    if (lastRound.hasPaid[uint256(RulingOptions.ChallengeFailed)] && lastRound.hasPaid[uint256(RulingOptions.Debunked)]) {
      dispute.rounds.push();
      lastRound.totalClaimableAfterExpenses -= basicCost;
      ARBITRATOR.appeal{value: basicCost}(_disputeID, categoryToArbitratorExtraData[dispute.articleCategory]);
    }

    // Ignoring failure condition deliberately.
    if (msg.value - contribution > 0) payable(msg.sender).send(msg.value - contribution);

    return lastRound.hasPaid[uint256(supportedRulingOutcome)];
  }

  /** @notice For arbitrator to call, to execute it's ruling. In case arbitrator rules in favor of challenger, challenger wins the bounty. In any case, withdrawalPermittedAt will be reset.
      @param _disputeID The dispute ID as in the arbitrator.
      @param _ruling The ruling that arbitrator gave.
   */
  function rule(uint256 _disputeID, uint256 _ruling) external override {
    require(IArbitrator(msg.sender) == ARBITRATOR);

    DisputeData storage dispute = disputes[_disputeID];
    Round storage lastRound = dispute.rounds[dispute.rounds.length - 1];

    // Appeal overrides arbitrator ruling. If a ruling option was not fully funded and the counter ruling option was funded, funded ruling option wins by default.
    RulingOptions wonByDefault;
    if (lastRound.hasPaid[uint256(RulingOptions.ChallengeFailed)]) {
      wonByDefault = RulingOptions.ChallengeFailed;
    } else if (lastRound.hasPaid[uint256(RulingOptions.ChallengeFailed)]) {
      wonByDefault = RulingOptions.Debunked;
    }

    RulingOptions actualRuling = wonByDefault != RulingOptions.Tied ? wonByDefault : RulingOptions(_ruling);
    dispute.outcome = actualRuling;

    uint80 articleStorageAddress = dispute.articleStorageAddress;

    Article storage article = articleStorage[articleStorageAddress];

    if (actualRuling == RulingOptions.Debunked) {
      uint256 bounty = uint96(article.bountyAmount) << NUMBER_OF_LEAST_SIGNIFICANT_BITS_TO_IGNORE;
      article.bountyAmount = 0;

      emit Debunked(articleStorageAddress);
      disputes[_disputeID].challenger.send(bounty);
      // Ignoring failure condition deliberately.
    }
    // In case of tie, article stands.
    article.withdrawalPermittedAt = 0;
    // Unmark as challenged.
    dispute.resolved = true;

    emit Ruling(IArbitrator(msg.sender), _disputeID, _ruling);
  }

  /** @notice Allows to withdraw any rewards or reimbursable fees after the dispute gets resolved. For all rounds at once.
      This function has O(m) time complexity where m is number of rounds.
      It is safe to assume m is always less than 10 as appeal cost growth order is O(2^m).
      @param _disputeID ID of the dispute as in arbitrator.
      @param _contributor The address whose rewards to withdraw.
      @param _ruling Ruling that received contributions from contributor.
   */
  function withdrawFeesAndRewardsForAllRounds(
    uint256 _disputeID,
    address payable _contributor,
    RulingOptions _ruling
  ) external override {
    DisputeData storage dispute = disputes[_disputeID];

    uint256 noOfRounds = dispute.rounds.length;

    for (uint256 roundNumber = 0; roundNumber < noOfRounds; roundNumber++) {
      withdrawFeesAndRewards(_disputeID, _contributor, roundNumber, _ruling);
    }
  }

  /** @notice Allows to withdraw any reimbursable fees or rewards after the dispute gets solved.
      @param _disputeID ID of the dispute as in arbitrator.
      @param _contributor The address whose rewards to withdraw.
      @param _roundNumber The number of the round caller wants to withdraw from.
      @param _ruling Ruling that received contribution from contributor.
      @return amount The amount available to withdraw for given question, contributor, round number and ruling option.
   */
  function withdrawFeesAndRewards(
    uint256 _disputeID,
    address payable _contributor,
    uint256 _roundNumber,
    RulingOptions _ruling
  ) public override returns (uint256 amount) {
    DisputeData storage dispute = disputes[_disputeID];
    require(dispute.resolved, "There is no ruling yet.");

    Round storage round = dispute.rounds[_roundNumber];

    amount = getWithdrawableAmount(round, _contributor, _ruling, dispute.outcome);

    if (amount != 0) {
      round.contributions[_contributor][uint256(RulingOptions(_ruling))] = 0;
      _contributor.send(amount);
      // Ignoring failure condition deliberately.
      emit Withdrawal(_disputeID, _roundNumber, _ruling, _contributor, amount);
    }
  }

  /** @notice Lets you to transfer ownership of an article. This is useful when you want to change owner account without withdrawing and resubmitting.
   */
  function updateChallengeTaxRate(uint256 _newChallengeTaxRate) external onlyAdmin {
    require(challengeTaxRate > _newChallengeTaxRate, "You can't increase taxes.");
    challengeTaxRate = _newChallengeTaxRate;
  }

  /** @notice Lets you to transfer ownership of an article. This is useful when you want to change owner account without withdrawing and resubmitting.
   */
  function changeAdmin(address payable _newAdmin) external onlyAdmin {
    admin = _newAdmin;
  }

  /** @notice TODO. This function should use treasuryBalance to buy a token and send it to 0x0.
   */
  function buyAndBurn() external onlyAdmin {}

  /** @notice Initializes a category.
      @param _metaevidenceIpfsUri IPFS content identifier for metaevidence.
            @param _arbitratorExtraData Extra data of Kleros arbitrator, signaling subcourt and jury size selection.

   */
  function newCategory(string memory _metaevidenceIpfsUri, bytes memory _arbitratorExtraData) public {
    require(categoryCounter + 1 != 0, "No space left for a new category");
    emit MetaEvidence(categoryCounter, _metaevidenceIpfsUri);
    categoryToArbitratorExtraData[categoryCounter] = _arbitratorExtraData;

    categoryCounter++;
  }

  /** @notice Lets you to transfer ownership of an article. This is useful when you want to change owner account without withdrawing and resubmitting.
   */
  function transferOwnership(uint80 _articleStorageAddress, address payable _newOwner) external override {
    Article storage article = articleStorage[_articleStorageAddress];
    require(msg.sender == article.owner, "Only author can transfer ownership.");
    article.owner = _newOwner;
  }

  /** @notice Returns the total amount needs to be paid to challenge an article.
   */
  function challengeFee(uint80 _articleStorageAddress) public view override returns (uint256) {
    Article storage article = articleStorage[_articleStorageAddress];

    uint256 arbitrationFee = ARBITRATOR.arbitrationCost(categoryToArbitratorExtraData[article.category]);
    uint256 challengeTax = (article.bountyAmount * challengeTaxRate) / MULTIPLIER_DENOMINATOR;

    return arbitrationFee + challengeTax;
  }

  /** @notice Returns the total amount needs to be paid to appeal a dispute.
   */
  function appealFee(uint256 _disputeID) external view override returns (uint256 arbitrationFee) {
    DisputeData storage dispute = disputes[_disputeID];
    arbitrationFee = ARBITRATOR.appealCost(_disputeID, categoryToArbitratorExtraData[dispute.articleCategory]);
  }

  /** @notice Helper function to find a vacant slot for article. Use this function before calling initialize to minimize your gas cost.
   */
  function findVacantStorageSlot(uint80 _searchPointer) external view override returns (uint256 vacantSlotIndex) {
    Article storage article;
    do {
      article = articleStorage[_searchPointer++];
    } while (article.bountyAmount != 0);

    return _searchPointer - 1;
  }

  /** @notice Returns the sum of withdrawable amount.
      This function has O(m) time complexity where m is number of rounds.
      It is safe to assume m is always less than 10 as appeal cost growth order is O(m^2).
   */
  function getTotalWithdrawableAmount(
    uint256 _disputeID,
    address payable _contributor,
    RulingOptions _ruling
  ) external view override returns (uint256 sum) {
    DisputeData storage dispute = disputes[_disputeID];
    if (!dispute.resolved) return 0;
    uint256 noOfRounds = dispute.rounds.length;
    RulingOptions finalRuling = dispute.outcome;

    for (uint256 roundNumber = 0; roundNumber < noOfRounds; roundNumber++) {
      Round storage round = dispute.rounds[roundNumber];
      sum += getWithdrawableAmount(round, _contributor, _ruling, finalRuling);
    }
  }

  /** @notice Returns withdrawable amount for given parameters.
   */
  function getWithdrawableAmount(
    Round storage _round,
    address _contributor,
    RulingOptions _ruling,
    RulingOptions _finalRuling
  ) internal view returns (uint256 amount) {
    RulingOptions givenRuling = RulingOptions(_ruling);

    if (!_round.hasPaid[uint256(givenRuling)]) {
      // Allow to reimburse if funding was unsuccessful for this ruling option.
      amount = _round.contributions[_contributor][uint256(givenRuling)];
    } else {
      // Funding was successful for this ruling option.
      if (_ruling == _finalRuling) {
        // This ruling option is the ultimate winner.
        amount = _round.totalPerRuling[uint256(givenRuling)] > 0
          ? (_round.contributions[_contributor][uint256(givenRuling)] * _round.totalClaimableAfterExpenses) / _round.totalPerRuling[uint256(givenRuling)]
          : 0;
      } else if (!_round.hasPaid[uint256(RulingOptions(_finalRuling))]) {
        // The ultimate winner was not funded in this round. Contributions discounting the appeal fee are reimbursed proportionally.
        amount =
          (_round.contributions[_contributor][uint256(givenRuling)] * _round.totalClaimableAfterExpenses) /
          (_round.totalPerRuling[uint256(RulingOptions.ChallengeFailed)] + _round.totalPerRuling[uint256(RulingOptions.Debunked)]);
      }
    }
  }
}
