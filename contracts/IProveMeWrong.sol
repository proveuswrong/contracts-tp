/**
 * SPDX-License-Identifier: MIT
 * @authors: @ferittuncer
 * @reviewers: [@jaybuidl]
 * @auditors: []
 * @bounties: []
 * @deployments: []
 */

pragma solidity ^0.8.10;

/** @title  Prove Me Wrong
    @notice Interface smart contract for a type of curation, where submitted items are on hold until they are withdrawn and the amount of security deposits are determined by submitters.
    @dev    Claims are not addressed with their identifiers. That enables us to reuse same storage address for another claim later.
            We prevent claims to get withdrawn immediately. This is to prevent submitter to escape punishment in case someone discovers an argument to debunk the claim. Front-ends should be able to take account only this interface and disregard implementation details.
 */
abstract contract IProveMeWrong {
  string public constant PMW_VERSION = "1.0.0";

  enum RulingOptions {
    Tied,
    ChallengeFailed,
    Debunked
  }

  uint256 public immutable CLAIM_WITHDRAWAL_TIMELOCK; // To prevent claimants to act fast and escape punishment.

  constructor(uint256 _claimWithdrawalTimelock) {
    CLAIM_WITHDRAWAL_TIMELOCK = _claimWithdrawalTimelock;
  }

  event NewClaim(string claimID, uint256 claimAddress);
  event Debunked(uint256 claimAddress);
  event Withdrew(uint256 claimAddress);
  event BalanceUpdate(uint256 claimAddress, uint256 newTotal);
  event TimelockStarted(uint256 claimAddress);
  event Challenge(uint256 indexed claimAddress, address challanger, uint256 disputeID);
  event Contribution(uint256 indexed claimStorageAddress, uint256 indexed round, RulingOptions ruling, address indexed contributor, uint256 amount);
  event Withdrawal(uint256 indexed claimStorageAddress, uint256 indexed round, RulingOptions ruling, address indexed contributor, uint256 reward);
  event RulingFunded(uint256 indexed claimStorageAddress, uint256 indexed round, RulingOptions indexed ruling);

  /** @notice Allows to submit evidence for a given dispute.
   *  @param _disputeID The dispute ID as in arbitrator.
   *  @param _evidenceURI IPFS path to evidence, example: '/ipfs/Qmarwkf7C9RuzDEJNnarT3WZ7kem5bk8DZAzx78acJjMFH/evidence.json'
   */
  function submitEvidence(uint256 _disputeID, string calldata _evidenceURI) external virtual;

  /** @notice Manages contributions and calls appeal function of the specified arbitrator to appeal a dispute. This function lets appeals be crowdfunded.
   *  @param _disputeID The dispute ID as in arbitrator.
   *  @param _ruling The ruling option to which the caller wants to contribute.
   *  @return fullyFunded True if the ruling option got fully funded as a result of this contribution.
   */
  function fundAppeal(uint256 _disputeID, RulingOptions _ruling) external payable virtual returns (bool fullyFunded);

  /** @notice Initializes a claim. Emits NewClaim. If bounty changed also emits BalanceUpdate.
      @dev    Do not confuse claimID with claimAddress.
      @param _claimID Unique identifier of a claim. Usually an IPFS content identifier.
      @param _category Claim category. This changes which metaevidence will be used.
      @param _searchPointer Starting point of the search. Find a vacant storage slot before calling this function to minimize gas cost.
   */
  function initializeClaim(string calldata _claimID, uint8 _category, uint80 _searchPointer) external payable virtual;

  /** @notice Lets claimant to increase a bounty of a live claim. Emits BalanceUpdate.
      @param _claimStorageAddress The address of the claim in the storage.
   */
  function increaseBounty(uint80 _claimStorageAddress) external payable virtual;

  /** @notice Lets a claimant to start withdrawal process. Emits TimelockStarted.
      @param _claimStorageAddress The address of the claim in the storage.
   */
  function initiateWithdrawal(uint80 _claimStorageAddress) external virtual;

  /** @notice Executes a withdrawal. Emits Withdrew.
      @param _claimStorageAddress The address of the claim in the storage.
   */
  function withdraw(uint80 _claimStorageAddress) external virtual;

  /** @notice Challenges the claim at the given storage address. Emit Challenge.
      @param _claimStorageAddress The address of the claim in the storage.
   */
  function challenge(uint80 _claimStorageAddress) public payable virtual;

  /** @notice Lets you to transfer ownership of a claim. This is useful when you want to change owner account without withdrawing and resubmitting.
      @param _claimStorageAddress The address of claim in the storage.
      @param _claimStorageAddress The new owner of the claim which resides in the storage address, provided by the previous parameter.
   */
  function transferOwnership(uint80 _claimStorageAddress, address payable _newOwner) external virtual;

  /** @notice Helper function to find a vacant slot for claim. Use this function before calling initialize to minimize your gas cost.
      @param _searchPointer Starting point of the search. If you do not have a guess, just pass 0.
   */
  function findVacantStorageSlot(uint80 _searchPointer) external view virtual returns (uint256 vacantSlotIndex);

  /** @notice Returns the total amount needs to be paid to challenge a claim.
   */
  function challengeFee(uint80 _claimStorageAddress) public view virtual returns (uint256 challengeFee);

  /** @notice Returns the total amount needs to be paid to appeal a dispute.
      @param _disputeID ID of the dispute as in arbitrator.
   */
  function appealFee(uint256 _disputeID) external view virtual returns (uint256 arbitrationFee);

  /** @dev Allows to withdraw any reimbursable fees or rewards after the dispute gets resolved.
   *  @param _disputeID The dispute ID as in arbitrator.
   *  @param _contributor Beneficiary of withdraw operation.
   *  @param _round Number of the round that caller wants to execute withdraw on.
   *  @param _ruling A ruling option that caller wants to execute withdraw on.
   *  @return sum The amount that is going to be transferred to contributor as a result of this function call.
   */
  function withdrawFeesAndRewards(
    uint256 _disputeID,
    address payable _contributor,
    uint256 _round,
    RulingOptions _ruling
  ) external virtual returns (uint256 sum);

  /** @dev Allows to withdraw any rewards or reimbursable fees after the dispute gets resolved for all rounds at once.
   *  @param _disputeID The dispute ID as in arbitrator.
   *  @param _contributor Beneficiary of withdraw operation.
   *  @param _ruling Ruling option that caller wants to execute withdraw on.
   */
  function withdrawFeesAndRewardsForAllRounds(
    uint256 _disputeID,
    address payable _contributor,
    RulingOptions _ruling
  ) external virtual;

  /** @dev Returns the sum of withdrawable amount.
   *  @param _disputeID The dispute ID as in arbitrator.
   *  @param _contributor Beneficiary of withdraw operation.
   *  @param _ruling Ruling option that caller wants to get withdrawable amount from.
   *  @return sum The total amount available to withdraw.
   */
  function getTotalWithdrawableAmount(
    uint256 _disputeID,
    address payable _contributor,
    RulingOptions _ruling
  ) external view virtual returns (uint256 sum);
}
