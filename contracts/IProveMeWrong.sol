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
    @notice Smart contract for a type of curation, where submitted items are on hold until they are withdrawn and the amount of security deposits are determined by submitters.
    @dev    Even though IDisputeResolver is implemented, submitEvidence function violates it.
            Claims are not addressed with their identifiers. That enables us to reuse same storage address for another claim later.
            Arbitrator and the extra data is fixed. Deploy another contract to change them.
            We prevent claims to get withdrawn immediately. This is to prevent submitter to escape punishment in case someone discovers an argument to debunk the claim.
 */
abstract contract IProveMeWrong {
  string public constant PMW_VERSION = "1.0.0";

  event NewClaim(string indexed claimID, uint256 claimAddress);
  event Debunked(uint256 claimAddress);
  event Withdrew(uint256 claimAddress);
  event BalanceUpdate(uint256 claimAddress, uint256 newTotal);
  event TimelockStarted(uint256 claimAddress);
  event Challenge(uint256 indexed claimAddress, address challanger);

  function initialize(string calldata _claimID, uint256 _searchPointer) external payable virtual;

  function increaseBounty(uint256 _claimStorageAddress) external payable virtual;

  function initiateWithdrawal(uint256 _claimStorageAddress) external virtual;

  function withdraw(uint256 _claimStorageAddress) external virtual;

  function challenge(uint256 _claimStorageAddress) public payable virtual;

  function transferOwnership(uint256 _claimStorageAddress, address payable _newOwner) external virtual;

  function findVacantStorageSlot(uint256 _searchPointer) external view virtual returns (uint256 vacantSlotIndex);

  function challengeFee() external view virtual returns (uint256 arbitrationFee);

  function appealFee(uint256 _disputeID) external view virtual returns (uint256 arbitrationFee);
}
