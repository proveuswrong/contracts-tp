//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "hardhat/console.sol";
import "@kleros/erc-792/contracts/IArbitrable.sol";
import "@kleros/erc-792/contracts/IArbitrator.sol";
import "@kleros/erc-792/contracts/erc-1497/IEvidence.sol";

contract ProveMeWrong is IArbitrable, IEvidence {
  uint8 constant AMOUNT_BITSHIFT = 32; // Not storing right-most 32 bits of contributions, this can lead value losses up to 4294967295 (2^32 -1) weis (0.000000004294967295 ether). Which is negligible.
  uint8 constant NUMBER_OF_RULING_OPTIONS = 2;
  uint24 immutable SHARE_DENOMINATOR;
  uint8 immutable MIN_FUND_INCREASE_PERCENT; // To prevent too many event emission. Ideally, we want less than 100 contributions per claim.
  uint24 immutable CLAIM_WITHDRAWAL_TIMELOCK; // To prevent claimants to act fast and escape punishment.
  uint64 immutable MIN_BOUNTY;

  event BalanceUpdate(string indexed claimID, address indexed actor, BalanceUpdateType indexed bat, uint256 balanceDelta);
  event NewSetting(uint24 index, IArbitrator indexed arbitrator, bytes arbitratorExtraData);
  event NewClaim(string indexed claimID, uint32 settingPointer);
  event Challange(string indexed claimID, address challanger);

  enum RulingOutcomes {
    ChallengeFailed,
    ProvedWrong
  }

  enum BalanceUpdateType {
    Fund,
    Unfund,
    Sweep
  }

  enum Status {
    Absent,
    Debunked,
    Withdrawn,
    Live,
    Challenged
    // Also Debunked and Withdrawn, but these statuses can be deduced via events and not required on chain.
    // Debunked: Absent but once was Live. Taken down with a challenge.
    // Withdrawn: Absent but once was Live. No fund left.
  }

  struct ArbitratorSetting {
    IArbitrator arbitrator;
    bytes arbitratorExtraData;
  }

  struct DisputeData {
    uint256 id;
    address payable challanger;
    uint16 metaevidenceID;
  }

  struct Contribution {
    uint256 amount;
    uint256 withdrawalPermittedAt;
  }

  struct Claim {
    uint256 bountyAmount;
    uint8 settingPointer;
    // DisputeData lastDispute;
  }

  uint16 metaevidenceCounter = 0;
  mapping(string => Claim) claims;
  ArbitratorSetting[] settings;
  mapping(uint256 => string) externalIDtoLocalID;
  mapping(string => mapping(address => Contribution)) contributions;

  constructor(ArbitratorSetting memory setting) {
    SHARE_DENOMINATOR = 1_000_000;
    MIN_FUND_INCREASE_PERCENT = 25;
    MIN_BOUNTY = 1_000_000 gwei;
    CLAIM_WITHDRAWAL_TIMELOCK = 2 weeks;

    settings.push(setting);

    emit NewSetting(uint24(settings.length - 1), setting.arbitrator, setting.arbitratorExtraData);
    emit MetaEvidence(metaevidenceCounter++, "0x00");
  }

  function fund(string calldata claimID) public payable {
    require(msg.value >= MIN_BOUNTY, "Minimum funding amount is not covered."); // We don't want dust claims.

    Claim storage claim = claims[claimID];

    contributions[claimID][msg.sender].amount += msg.value;
    claim.bountyAmount += msg.value;

    // console.log("%s contributed %s weis", msg.sender, msg.value);

    emit BalanceUpdate(claimID, msg.sender, BalanceUpdateType.Fund, msg.value);
  }

  function unfund(string calldata claimID) public {
    Claim storage claim = claims[claimID];
    require(claim.bountyAmount > 0, "Can't withdraw funds from a claim that has no funds.");
    // require(
    //   claim.contributions[msg.sender].withdrawalPermittedAt != 0 && claim.contributions[msg.sender].withdrawalPermittedAt <= block.timestamp,
    //   "You need to wait for timelock."
    // );
    require(claim.bountyAmount > 0, "Claim is not live.");

    uint256 withdrawal = uint256(contributions[claimID][msg.sender].amount);
    payable(msg.sender).transfer(withdrawal);

    // console.log("Trying to send %s weis to %s", withdrawal, msg.sender);
    emit BalanceUpdate(claimID, msg.sender, BalanceUpdateType.Unfund, withdrawal);
  }

  // function challengeClaim(string calldata claimID) public payable {
  //   Claim storage claim = claims[claimID];
  //   require(claim.bountyAmount > 0, "Claim is not live.");
  //   ArbitratorSetting storage setting = settings[claim.settingPointer];
  //
  //   uint256 arbitrationCost = setting.arbitrator.arbitrationCost(setting.arbitratorExtraData);
  //   require(msg.value >= arbitrationCost, "Not enough funds for this challenge.");
  //
  //   uint256 disputeID = setting.arbitrator.createDispute{value: msg.value}(NUMBER_OF_RULING_OPTIONS, setting.arbitratorExtraData);
  //   externalIDtoLocalID[disputeID] = claimID;
  //
  //   claim.lastDispute = DisputeData({id: disputeID, challanger: payable(msg.sender), metaevidenceID: metaevidenceCounter - 1});
  //
  //   uint256 metaEvidenceID = 0; // TODO
  //   emit Dispute(IArbitrator(setting.arbitrator), disputeID, metaEvidenceID, disputeID);
  //
  //   emit Challange(claimID, msg.sender);
  // }
  //
  // function submitEvidence(string calldata _claimID, string calldata _evidenceURI) public {
  //   Claim storage claim = claims[_claimID];
  //   ArbitratorSetting storage setting = settings[claim.settingPointer];
  //
  //   emit Evidence(setting.arbitrator, claim.lastDispute.id, msg.sender, _evidenceURI);
  // }
  //
  // function createNewArbitratorSettings(IArbitrator _arbitrator, bytes calldata _arbitratorExtraData) public payable {
  //   settings.push(ArbitratorSetting({arbitrator: _arbitrator, arbitratorExtraData: _arbitratorExtraData}));
  //
  //   emit NewSetting(uint24(settings.length - 1), _arbitrator, _arbitratorExtraData);
  // }
  //
  function initializeClaim(string calldata _claimID, uint8 _settingPointer) public payable {
    Claim storage claim = claims[_claimID];

    require(claim.bountyAmount < SHARE_DENOMINATOR, "You can't change arbitrator settings of a live claim.");
    claims[_claimID].settingPointer = _settingPointer;

    if (msg.value > 0) fund(_claimID);

    emit NewClaim(_claimID, _settingPointer);
  }

  function rule(uint256 _disputeID, uint256 _ruling) external override {
    string memory claimID = externalIDtoLocalID[_disputeID];
    Claim storage claim = claims[claimID];
    ArbitratorSetting storage setting = settings[claim.settingPointer];

    require(IArbitrator(msg.sender) == setting.arbitrator);
    emit Ruling(IArbitrator(msg.sender), _disputeID, _ruling);

    if (RulingOutcomes(_ruling) == RulingOutcomes.ProvedWrong) {
      uint256 bounty = claim.bountyAmount;
      claim.bountyAmount = 0;
      // emit BalanceUpdate(claimID, claim.lastDispute.challanger, BalanceUpdateType.Sweep, uint256(claim.bountyAmount));
      // claim.lastDispute.challanger.send(bounty);
    }
  }
}
