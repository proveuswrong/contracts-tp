/**
 * SPDX-License-Identifier: MIT
 * @authors: @ferittuncer
 * @reviewers: []
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

  uint256 public immutable CLAIM_WITHDRAWAL_TIMELOCK; // To prevent claimants to act fast and escape punishment.

  constructor(uint256 _claimWithdrawalTimelock) {
    CLAIM_WITHDRAWAL_TIMELOCK = _claimWithdrawalTimelock;
  }

  event NewClaim(string indexed claimID, uint256 claimAddress);
  event Debunked(uint256 claimAddress);
  event Withdrew(uint256 claimAddress);
  event BalanceUpdate(uint256 claimAddress, uint256 newTotal);
  event TimelockStarted(uint256 claimAddress);
  event Challenge(uint256 indexed claimAddress, address challanger);

  /** @notice Initializes a claim. Emits NewClaim. If bounty changed also emits BalanceUpdate.
      @dev    Do not confuse claimID with claimAddress.
      @param _claimID Unique identifier of a claim. Usually an IPFS content identifier.
      @param _searchPointer Starting point of the search. Find a vacant storage slot before calling this function to minimize gas cost.
   */
  function initializeClaim(string calldata _claimID, uint256 _searchPointer) external payable virtual;

  /** @notice Lets claimant to increase a bounty of a live claim. Emits BalanceUpdate.
      @param _claimStorageAddress The address of the claim in the storage.
   */
  function increaseBounty(uint256 _claimStorageAddress) external payable virtual;

  /** @notice Lets a claimant to start withdrawal process. Emits TimelockStarted.
      @param _claimStorageAddress The address of the claim in the storage.
   */
  function initiateWithdrawal(uint256 _claimStorageAddress) external virtual;

  /** @notice Executes a withdrawal. Emits Withdrew.
      @param _claimStorageAddress The address of the claim in the storage.
   */
  function withdraw(uint256 _claimStorageAddress) external virtual;

  /** @notice Challenges the claim at the given storage address. Emit Challenge.
      @param _claimStorageAddress The address of the claim in the storage.
   */
  function challenge(uint256 _claimStorageAddress) public payable virtual;

  /** @notice Lets you to transfer ownership of a claim. This is useful when you want to change owner account without withdrawing and resubmitting.
      @param _claimStorageAddress The address of claim in the storage.
      @param _claimStorageAddress The new owner of the claim which resides in the storage address, provided by the previous parameter.
   */
  function transferOwnership(uint256 _claimStorageAddress, address payable _newOwner) external virtual;

  /** @notice Helper function to find a vacant slot for claim. Use this function before calling initialize to minimize your gas cost.
      @param _searchPointer Starting point of the search. If you do not have a guess, just pass 0.
   */
  function findVacantStorageSlot(uint256 _searchPointer) external view virtual returns (uint256 vacantSlotIndex);

  /** @notice Returns the total amount needs to be paid to challenge a claim.
   */
  function challengeFee() external view virtual returns (uint256 arbitrationFee);

  /** @notice Returns the total amount needs to be paid to appeal a dispute.
      @param _disputeID ID of the dispute as in arbitrator.
   */
  function appealFee(uint256 _disputeID) external view virtual returns (uint256 arbitrationFee);
}
