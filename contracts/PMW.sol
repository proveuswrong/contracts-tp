/**
 * SPDX-License-Identifier: MIT
 * @authors: @ferittuncer
 * @reviewers: []
 * @auditors: []
 * @bounties: []
 * @deployments: []
 */

pragma solidity ^0.8.10;
import "@kleros/dispute-resolver-interface-contract/contracts/IDisputeResolver.sol";

/*
·---------------------------------------|---------------------------|--------------|-----------------------------·
|         Solc version: 0.8.10          ·  Optimizer enabled: true  ·  Runs: 1000  ·  Block limit: 30000000 gas  │
········································|···························|··············|······························
|  Methods                              ·               100 gwei/gas               ·       4061.85 usd/eth       │
·················|······················|·············|·············|··············|···············|··············
|  Contract      ·  Method              ·  Min        ·  Max        ·  Avg         ·  # calls      ·  usd (avg)  │
·················|······················|·············|·············|··············|···············|··············
|  Arbitrator    ·  createDispute       ·      82579  ·      99679  ·       84289  ·           20  ·      34.24  │
·················|······················|·············|·············|··············|···············|··············
|  Arbitrator    ·  executeRuling       ·      47668  ·      85533  ·       72911  ·            3  ·      29.62  │
·················|······················|·············|·············|··············|···············|··············
|  Arbitrator    ·  giveRuling          ·      78640  ·      98528  ·       93556  ·            4  ·      38.00  │
·················|······················|·············|·············|··············|···············|··············
|  ProveMeWrong  ·  challenge           ·     117627  ·     171727  ·      153694  ·            3  ·      62.43  │
·················|······················|·············|·············|··············|···············|··············
|  ProveMeWrong  ·  fundAppeal          ·     135691  ·     140752  ·      137715  ·            5  ·      55.94  │
·················|······················|·············|·············|··············|···············|··············
|  ProveMeWrong  ·  increaseBounty      ·          -  ·          -  ·       28513  ·            2  ·      11.58  │
·················|······················|·············|·············|··············|···············|··············
|  ProveMeWrong  ·  initialize          ·      32189  ·      51566  ·       39484  ·           10  ·      16.04  │
·················|······················|·············|·············|··············|···············|··············
|  ProveMeWrong  ·  initiateWithdrawal  ·          -  ·          -  ·       28002  ·            4  ·      11.37  │
·················|······················|·············|·············|··············|···············|··············
|  ProveMeWrong  ·  submitEvidence      ·          -  ·          -  ·       26094  ·            2  ·      10.60  │
·················|······················|·············|·············|··············|···············|··············
|  ProveMeWrong  ·  withdraw            ·          -  ·          -  ·       34985  ·            3  ·      14.21  │
·················|······················|·············|·············|··············|···············|··············
|  Deployments                          ·                                          ·  % of limit   ·             │
········································|·············|·············|··············|···············|··············
|  Arbitrator                           ·          -  ·          -  ·      877877  ·        2.9 %  ·     356.58  │
········································|·············|·············|··············|···············|··············
|  ProveMeWrong                         ·          -  ·          -  ·     2363274  ·        7.9 %  ·     959.93  │
·---------------------------------------|-------------|-------------|--------------|---------------|-------------·
*/

/** @title  Prove Me Wrong
    @notice Smart contract for a type of curation, where submitted items are on hold until they are withdrawn and the amount of security deposits are determined by submitters.
    @dev    Even though IDisputeResolver is implemented, submitEvidence function violates it.
            Claims are not addressed with their identifiers. That enables us to reuse same storage address for another claim later.
            Arbitrator and the extra data is fixed. Deploy another contract to change them.
            We prevent claims to get withdrawn immediately. This is to prevent submitter to escape punishment in case someone discovers an argument to debunk the claim.
 */
contract ProveMeWrong is IDisputeResolver {
  IArbitrator public immutable ARBITRATOR;
  uint256 public immutable CLAIM_WITHDRAWAL_TIMELOCK; // To prevent claimants to act fast and escape punishment.
  uint256 public constant NUMBER_OF_RULING_OPTIONS = 2;
  uint256 public constant NUMBER_OF_LEAST_SIGNIFICANT_BITS_TO_IGNORE = 40; // To compress bounty amount to gain space in struct. Lossy compression.
  uint256 public immutable WINNER_STAKE_MULTIPLIER; // Multiplier of the arbitration cost that the winner has to pay as fee stake for a round in basis points.
  uint256 public immutable LOSER_STAKE_MULTIPLIER; // Multiplier of the arbitration cost that the loser has to pay as fee stake for a round in basis points.
  uint256 public constant LOSER_APPEAL_PERIOD_MULTIPLIER = 5000; // Multiplier of the appeal period for losers (any other ruling options) in basis points. The loser is given less time to fund its appeal to defend against last minute appeal funding attacks.
  uint256 public constant MULTIPLIER_DENOMINATOR = 10000; // Denominator for multipliers.

  event NewClaim(string indexed claimID, uint256 claimAddress);
  event Debunked(uint256 claimAddress);
  event Withdrew(uint256 claimAddress);
  event BalanceUpdate(uint256 claimAddress, uint256 newTotal);
  event TimelockStarted(uint256 claimAddress);
  event Challenge(uint256 indexed claimAddress, address challanger);

  enum RulingOutcomes {
    Tied,
    ChallengeFailed,
    Debunked
  }

  struct DisputeData {
    uint256 id;
    address payable challenger;
    uint96 freeSpace; // Unused.
    Round[] rounds; // Tracks each appeal round of a dispute.
  }

  struct Round {
    mapping(address => mapping(RulingOutcomes => uint256)) contributions;
    mapping(RulingOutcomes => bool) hasPaid; // True if the fees for this particular answer has been fully paid in the form hasPaid[rulingOutcome].
    mapping(RulingOutcomes => uint256) totalPerRuling;
    uint256 totalClaimableAfterExpenses;
  }

  struct Claim {
    address payable owner; // 160 bit
    uint16 freeSpace; // Unused.
    uint32 withdrawalPermittedAt; // Overflows in year 2106
    uint48 bountyAmount; // 40-bits compression. Decompressed size is 88 bits.
  }

  bytes public ARBITRATOR_EXTRA_DATA; // Immutable.

  mapping(uint256 => Claim) public claimStorage; // Key: Address of claim. Claims are not addressed with their identifiers, to enable reusing a storage slot.
  mapping(uint256 => DisputeData) disputes; // Key: Address of claim. Usin claim address for identifying disputes has storage reuse benefit as well. New dispute of the same claim or new dispute a new claim will reuse same dispute storage slot.

  mapping(uint256 => uint256) public override externalIDtoLocalID; // Maps ARBITRATOR dispute ID to claim ID.

  constructor(
    IArbitrator _arbitrator,
    bytes memory _arbitratorExtraData,
    string memory _metaevidenceIpfsUri,
    uint256 _claimWithdrawalTimelock,
    uint256 _winnerStakeMultiplier,
    uint256 _loserStakeMultiplier
  ) {
    ARBITRATOR = _arbitrator;
    ARBITRATOR_EXTRA_DATA = _arbitratorExtraData;
    CLAIM_WITHDRAWAL_TIMELOCK = _claimWithdrawalTimelock;
    WINNER_STAKE_MULTIPLIER = _winnerStakeMultiplier;
    LOSER_STAKE_MULTIPLIER = _loserStakeMultiplier;

    emit MetaEvidence(0, _metaevidenceIpfsUri);
  }

  /** @notice Initializes a claim. Claim ID is also the IPFS URI. Automatically searches for a vacant slot in storage. Search will be done linearly, so caller is advised to pass a search pointer that points to a vacant slot, to minimize gas cost. You can find an index of such slot by calling findVacantStorageSlot function first.
      @dev    Do not confuse claimID with claimAddress.
   */
  function initialize(string calldata _claimID, uint256 _searchPointer) external payable {
    Claim storage claim;
    do {
      claim = claimStorage[_searchPointer++];
    } while (claim.bountyAmount != 0);

    require(claim.bountyAmount == 0, "You can't initialize a live claim.");

    claim.owner = payable(msg.sender);
    claim.bountyAmount = uint48(msg.value >> NUMBER_OF_LEAST_SIGNIFICANT_BITS_TO_IGNORE);

    require(claim.bountyAmount > 0, "You can't initialize a claim without putting a bounty.");

    uint256 claimAddress = _searchPointer - 1;
    emit NewClaim(_claimID, claimAddress);
    emit BalanceUpdate(claimAddress, uint256(claim.bountyAmount) << NUMBER_OF_LEAST_SIGNIFICANT_BITS_TO_IGNORE);
  }

  /** @notice Lets you submit evidence as defined in evidence (ERC-1497) standard.
      @dev Using disputeID as first argument will break IDisputeResolver because it is expecting externalIDtoLocalID[disputeID]. However, this saves 2K gas, and we don't really need Dispute Resolver user interface.
   */
  function submitEvidence(uint256 _disputeID, string calldata _evidenceURI) external override {
    emit Evidence(ARBITRATOR, _disputeID, msg.sender, _evidenceURI);
  }

  /** @notice Lets you increase a bounty of a live claim.
      @dev Using disputeID as first argument will break IDisputeResolver because it is expecting externalIDtoLocalID[disputeID]. However, this saves 2K gas, and we don't really need Dispute Resolver user interface.
   */
  function increaseBounty(uint256 _claimAddress) external payable {
    Claim storage claim = claimStorage[_claimAddress];
    require(msg.sender == claim.owner, "Only claimant can increase bounty of a claim."); // To prevent mistakes.

    claim.bountyAmount += uint48(msg.value >> NUMBER_OF_LEAST_SIGNIFICANT_BITS_TO_IGNORE);

    emit BalanceUpdate(_claimAddress, uint256(claim.bountyAmount) << NUMBER_OF_LEAST_SIGNIFICANT_BITS_TO_IGNORE);
  }

  /** @notice Lets a claimant to start withdrawal process.
      @dev withdrawalPermittedAt has some special values: 0 indicates withdrawal possible but process not started yet, max value indicates there is a challenge and during challenge it's forbidden to start withdrawal process. This value will overflow in year 2106.
   */
  function initiateWithdrawal(uint256 _claimAddress) external {
    Claim storage claim = claimStorage[_claimAddress];
    require(msg.sender == claim.owner, "Only claimant can withdraw a claim.");
    require(claim.withdrawalPermittedAt == 0, "Withdrawal already initiated or there is a challenge.");

    claim.withdrawalPermittedAt = uint32(block.timestamp + CLAIM_WITHDRAWAL_TIMELOCK);
    emit TimelockStarted(_claimAddress);
  }

  /** @notice Executes a withdrawal. Can only be executed by claimant.
      @dev withdrawalPermittedAt has some special values: 0 indicates withdrawal possible but process not started yet, max value indicates there is a challenge and during challenge it's forbidden to start withdrawal process. This value will overflow in year 2106.
   */
  function withdraw(uint256 _claimAddress) external {
    Claim storage claim = claimStorage[_claimAddress];

    require(msg.sender == claim.owner, "Only claimant can withdraw a claim.");
    require(claim.withdrawalPermittedAt != 0, "You need to initiate withdrawal first.");
    require(claim.withdrawalPermittedAt <= block.timestamp, "You need to wait for timelock or wait until the challenge ends.");

    uint256 withdrawal = uint88(claim.bountyAmount) << NUMBER_OF_LEAST_SIGNIFICANT_BITS_TO_IGNORE;
    claim.bountyAmount = 0; // This is critical to reset.
    claim.withdrawalPermittedAt = 0; // This too, otherwise new claim inside the same slot can withdraw instantly.
    // We could reset claim.owner as well, this refunds 4K gas. But not resetting it here and let it to be reset
    // during initialization of a claim using a previously used storage slot provides 17K gas refund. So net gain is 13K.
    payable(msg.sender).transfer(withdrawal);
    emit Withdrew(_claimAddress);
  }

  /** @notice Challenges the claim at the given storage address. Follow events to find out which claim resides in which slot.
      @dev withdrawalPermittedAt has some special values: 0 indicates withdrawal possible but process not started yet, max value indicates there is a challenge and during challenge it's forbidden to start withdrawal process. This value will overflow in year 2106.
   */
  function challenge(uint256 _claimAddress) public payable {
    Claim storage claim = claimStorage[_claimAddress];
    require(claim.withdrawalPermittedAt != type(uint32).max, "There is an ongoing challenge."); // To prevent mistakes.
    claim.withdrawalPermittedAt = type(uint32).max; // Mark as challenged.

    require(claim.bountyAmount > 0, "Nothing to challenge."); // To prevent mistakes.

    uint256 disputeID = ARBITRATOR.createDispute{value: msg.value}(NUMBER_OF_RULING_OPTIONS, ARBITRATOR_EXTRA_DATA);
    externalIDtoLocalID[disputeID] = _claimAddress;

    disputes[_claimAddress].id = disputeID;
    disputes[_claimAddress].challenger = payable(msg.sender);
    disputes[_claimAddress].rounds.push();

    emit Dispute(ARBITRATOR, disputeID, claim.freeSpace, disputeID);
    emit Challenge(_claimAddress, msg.sender);
  }

  /** @notice Lets you fund a crowdfunded appeal. In case of funding is incomplete, you will be refunded.
      @dev withdrawalPermittedAt has some special values: 0 indicates withdrawal possible but process not started yet, max value indicates there is a challenge and during challenge it's forbidden to start withdrawal process. This value will overflow in year 2106.
   */
  function fundAppeal(uint256 _claimAddress, uint256 _supportedRuling) external payable override returns (bool fullyFunded) {
    DisputeData storage dispute = disputes[_claimAddress];
    uint256 disputeID = dispute.id;
    uint256 currentRuling = ARBITRATOR.currentRuling(disputeID);
    uint256 basicCost;
    uint256 totalCost;
    {
      (uint256 appealWindowStart, uint256 appealWindowEnd) = ARBITRATOR.appealPeriod(disputeID);

      uint256 multiplier;

      if (_supportedRuling == currentRuling) {
        require(block.timestamp < appealWindowEnd, "Funding must be made within the appeal period.");

        multiplier = WINNER_STAKE_MULTIPLIER;
      } else {
        require(
          block.timestamp < (appealWindowStart + ((appealWindowEnd - appealWindowStart) / 2)),
          "Funding must be made within the first half appeal period."
        );

        multiplier = LOSER_STAKE_MULTIPLIER;
      }

      basicCost = ARBITRATOR.appealCost(disputeID, ARBITRATOR_EXTRA_DATA);
      totalCost = basicCost + ((basicCost * (multiplier)) / MULTIPLIER_DENOMINATOR);
    }

    RulingOutcomes supportedRulingOutcome = RulingOutcomes(_supportedRuling);

    uint256 lastRoundIndex = dispute.rounds.length - 1;
    Round storage lastRound = dispute.rounds[lastRoundIndex];
    require(!lastRound.hasPaid[supportedRulingOutcome], "Appeal fee has already been paid.");

    uint256 contribution = totalCost - (lastRound.totalPerRuling[supportedRulingOutcome]) > msg.value
      ? msg.value
      : totalCost - (lastRound.totalPerRuling[supportedRulingOutcome]);
    emit Contribution(_claimAddress, lastRoundIndex, uint256(_supportedRuling), msg.sender, contribution);

    lastRound.contributions[msg.sender][supportedRulingOutcome] += contribution;
    lastRound.totalPerRuling[supportedRulingOutcome] += contribution;

    if (lastRound.totalPerRuling[supportedRulingOutcome] >= totalCost) {
      lastRound.totalClaimableAfterExpenses += lastRound.totalPerRuling[supportedRulingOutcome];
      lastRound.hasPaid[supportedRulingOutcome] = true;
      emit RulingFunded(_claimAddress, lastRoundIndex, _supportedRuling);
    }

    if (lastRound.hasPaid[RulingOutcomes.ChallengeFailed] && lastRound.hasPaid[RulingOutcomes.Debunked]) {
      dispute.rounds.push();
      lastRound.totalClaimableAfterExpenses -= basicCost;
      ARBITRATOR.appeal{value: basicCost}(disputeID, ARBITRATOR_EXTRA_DATA);
    }

    // Sending extra value back to contributor. Note that it's impossible to deny the service by rejecting transfer on purpose, because the caller and beneficiary is the same.
    if (msg.value - contribution > 0) payable(msg.sender).transfer(msg.value - contribution);

    return lastRound.hasPaid[supportedRulingOutcome];
  }

  /** @notice Returns number of possible ruling options of disputes that arise from this contract. Does not count ruling option 0 (tied), as it's implicit.
      @dev withdrawalPermittedAt has some special values: 0 indicates withdrawal possible but process not started yet, max value indicates there is a challenge and during challenge it's forbidden to start withdrawal process. This value will overflow in year 2106.
   */
  function numberOfRulingOptions(uint256) external view override returns (uint256 count) {
    return uint256(type(RulingOutcomes).max);
  }

  /** @notice For arbitrator to call, to execute it's ruling. In case arbitrator rules in favor of challenger, challenger wins the bounty. Otherwise nothing happens.
      @dev withdrawalPermittedAt has some special values: 0 indicates withdrawal possible but process not started yet, max value indicates there is a challenge and during challenge it's forbidden to start withdrawal process. This value will overflow in year 2106.
   */
  function rule(uint256 _disputeID, uint256 _ruling) external override {
    require(IArbitrator(msg.sender) == ARBITRATOR);

    uint256 claimAddress = externalIDtoLocalID[_disputeID];
    Claim storage claim = claimStorage[claimAddress];

    if (RulingOutcomes(_ruling) == RulingOutcomes.Debunked) {
      uint256 bounty = uint88(claim.bountyAmount) << NUMBER_OF_LEAST_SIGNIFICANT_BITS_TO_IGNORE;
      claim.bountyAmount = 0;

      emit Debunked(claimAddress);
      disputes[_disputeID].challenger.send(bounty); // Ignoring failure condition deliberately.
    } // In case of tie, claim stands.
    claim.withdrawalPermittedAt = 0; // Unmark as challenged.

    emit Ruling(IArbitrator(msg.sender), _disputeID, _ruling);
  }

  /** @notice Allows to withdraw any rewards or reimbursable fees after the dispute gets resolved. For all rounds at once.
   *  This function has O(m) time complexity where m is number of rounds.
   *  It is safe to assume m is always less than 10 as appeal cost growth order is O(2^m).
   *  @param _claimAddress Address of storage of the claim.
   *  @param _contributor The address whose rewards to withdraw.
   *  @param _ruling Ruling that received contributions from contributor.
   */
  function withdrawFeesAndRewardsForAllRounds(
    uint256 _claimAddress,
    address payable _contributor,
    uint256 _ruling
  ) external override {
    DisputeData storage dispute = disputes[_claimAddress];
    uint256 noOfRounds = dispute.rounds.length;

    for (uint256 roundNumber = 0; roundNumber < noOfRounds; roundNumber++) {
      withdrawFeesAndRewards(_claimAddress, _contributor, roundNumber, _ruling);
    }
  }

  /** @notice Allows to withdraw any reimbursable fees or rewards after the dispute gets solved.
   *  @param _claimAddress Address of storage of the claim.
   *  @param _contributor The address whose rewards to withdraw.
   *  @param _roundNumber The number of the round caller wants to withdraw from.
   *  @param _ruling Ruling that received contribution from contributor.
   *  @return amount The amount available to withdraw for given question, contributor, round number and ruling option.
   */
  function withdrawFeesAndRewards(
    uint256 _claimAddress,
    address payable _contributor,
    uint256 _roundNumber,
    uint256 _ruling
  ) public override returns (uint256 amount) {
    DisputeData storage dispute = disputes[_claimAddress];
    require(ARBITRATOR.disputeStatus(dispute.id) == IArbitrator.DisputeStatus.Solved, "There is no ruling yet.");

    Round storage round = dispute.rounds[_roundNumber];

    amount = getWithdrawableAmount(round, _contributor, _ruling, ARBITRATOR.currentRuling(dispute.id));

    if (amount != 0) {
      round.contributions[_contributor][RulingOutcomes(_ruling)] = 0;
      _contributor.send(amount); // Ignoring failure condition deliberately.
      emit Withdrawal(_claimAddress, _roundNumber, _ruling, _contributor, amount);
    }
  }

  /** @notice Lets you to transfer ownership of a claim. This is useful when you want to change owner account without withdrawing and resubmitting.
      @dev withdrawalPermittedAt has some special values: 0 indicates withdrawal possible but process not started yet, max value indicates there is a challenge and during challenge it's forbidden to start withdrawal process. This value will overflow in year 2106.
   */
  function transferOwnership(uint256 _claimAddress, address payable _newOwner) external {
    Claim storage claim = claimStorage[_claimAddress];
    require(msg.sender == claim.owner, "Only claimant can transfer ownership.");
    claim.owner = _newOwner;
  }

  /** @notice Returns the total amount needs to be paid to challenge a claim.
   */
  function challengeFee() external view returns (uint256 arbitrationFee) {
    arbitrationFee = ARBITRATOR.arbitrationCost(ARBITRATOR_EXTRA_DATA);
  }

  /** @notice Returns the total amount needs to be paid to appeal a dispute.
   */
  function appealFee(uint256 _disputeID) external view returns (uint256 arbitrationFee) {
    arbitrationFee = ARBITRATOR.appealCost(_disputeID, ARBITRATOR_EXTRA_DATA);
  }

  /** @notice Helper function to find a vacant slot for claim. Use this function before calling initialize to minimize your gas cost.
   */
  function findVacantStorageSlot(uint256 _searchPointer) external view returns (uint256 vacantSlotIndex) {
    Claim storage claim;
    do {
      claim = claimStorage[_searchPointer++];
    } while (claim.bountyAmount != 0);

    return _searchPointer - 1;
  }

  /** @notice Returns multipliers for appeals.
   */
  function getMultipliers()
    external
    view
    override
    returns (
      uint256 _WINNER_STAKE_MULTIPLIER,
      uint256 _LOSER_STAKE_MULTIPLIER,
      uint256 _LOSER_APPEAL_PERIOD_MULTIPLIER,
      uint256 _DENOMINATOR
    )
  {
    return (WINNER_STAKE_MULTIPLIER, LOSER_STAKE_MULTIPLIER, LOSER_APPEAL_PERIOD_MULTIPLIER, MULTIPLIER_DENOMINATOR);
  }

  /** @notice Returns the sum of withdrawable amount.
   *  This function has O(m) time complexity where m is number of rounds.
   *  It is safe to assume m is always less than 10 as appeal cost growth order is O(m^2).
   */
  function getTotalWithdrawableAmount(
    uint256 _claimAddress,
    address payable _contributor,
    uint256 _ruling
  ) external view override returns (uint256 sum) {
    DisputeData storage dispute = disputes[_claimAddress];
    if (ARBITRATOR.disputeStatus(dispute.id) != IArbitrator.DisputeStatus.Solved) return 0;
    uint256 noOfRounds = dispute.rounds.length;
    uint256 finalRuling = ARBITRATOR.currentRuling(dispute.id);

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
    uint256 _ruling,
    uint256 _finalRuling
  ) internal view returns (uint256 amount) {
    RulingOutcomes givenRuling = RulingOutcomes(_ruling);

    if (!_round.hasPaid[givenRuling]) {
      // Allow to reimburse if funding was unsuccessful for this ruling option.
      amount = _round.contributions[_contributor][givenRuling];
    } else {
      // Funding was successful for this ruling option.
      if (_ruling == _finalRuling) {
        // This ruling option is the ultimate winner.
        amount = _round.totalPerRuling[givenRuling] > 0
          ? (_round.contributions[_contributor][givenRuling] * _round.totalClaimableAfterExpenses) / _round.totalPerRuling[givenRuling]
          : 0;
      } else if (!_round.hasPaid[givenRuling]) {
        // The ultimate winner was not funded in this round. Contributions discounting the appeal fee are reimbursed proportionally.
        amount =
          (_round.contributions[_contributor][givenRuling] * _round.totalClaimableAfterExpenses) /
          (_round.totalPerRuling[RulingOutcomes.ChallengeFailed] + _round.totalPerRuling[RulingOutcomes.Debunked]);
      }
    }
  }
}
