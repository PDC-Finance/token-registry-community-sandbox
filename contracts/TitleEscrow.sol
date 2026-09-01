// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import { Initializable } from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { IERC165 } from "@openzeppelin/contracts/interfaces/IERC165.sol";
import { ITitleEscrow } from "./interfaces/ITitleEscrow.sol";
import { ITitleEscrowLei } from "./interfaces/ITitleEscrowLei.sol";
import { ITradeTrustToken } from "./interfaces/ITradeTrustToken.sol";
import { TitleEscrowErrors } from "./interfaces/TitleEscrowErrors.sol";

/**
 * @title TitleEscrow
 * @dev Title escrow contract for managing the beneficiaries and holders of a transferable record.
 */
contract TitleEscrow is Initializable, IERC165, TitleEscrowErrors, ITitleEscrow, ITitleEscrowLei {
  address public override registry;
  uint256 public override tokenId;

  address public override beneficiary;
  address public override holder;

  address public override prevBeneficiary;
  address public override prevHolder;

  address public override nominee;

  bool public override active;

  bytes public remark;

  constructor() initializer {}

  /**
   * @dev Modifier to make a function callable only by the beneficiary.
   */
  modifier onlyBeneficiary() {
    if (msg.sender != beneficiary) {
      revert CallerNotBeneficiary();
    }
    _;
  }

  /**
   * @dev Modifier to make a function callable only by the holder.
   */
  modifier onlyHolder() {
    if (msg.sender != holder) {
      revert CallerNotHolder();
    }
    _;
  }

  /**
   * @dev Modifier to ensure the contract is holding the token.
   */
  modifier whenHoldingToken() {
    if (!_isHoldingToken()) {
      revert TitleEscrowNotHoldingToken();
    }
    _;
  }

  /**
   * @dev Modifier to ensure the registry is not paused.
   */
  modifier whenNotPaused() {
    bool paused = Pausable(registry).paused();
    if (paused) {
      revert RegistryContractPaused();
    }
    _;
  }

  /**
   * @dev Modifier to ensure the title escrow is active.
   */
  modifier whenActive() {
    if (!active) {
      revert InactiveTitleEscrow();
    }
    _;
  }
  /**
   * @dev Modifier to check if the bytes length is within the limit
   */
  modifier remarkLengthLimit(bytes calldata _remark) {
    if (_remark.length > 120) revert RemarkLengthExceeded();
    _;
  }

  /**
   * @notice Initializes the TitleEscrow contract with the registry address and the tokenId
   * @param _registry The address of the registry
   * @param _tokenId The id of the token
   */
  function initialize(address _registry, uint256 _tokenId) public virtual initializer {
    __TitleEscrow_init(_registry, _tokenId);
  }

  /**
   * @notice Initializes the TitleEscrow contract with the registry address and the tokenId
   */
  function __TitleEscrow_init(address _registry, uint256 _tokenId) internal virtual onlyInitializing {
    registry = _registry;
    tokenId = _tokenId;
    active = true;
  }

  /**
   * @dev See {ERC165-supportsInterface}.
   */
  function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
    return interfaceId == type(ITitleEscrow).interfaceId || interfaceId == type(ITitleEscrowLei).interfaceId;
  }

  /**
   * @dev See {IERC721Receiver-onERC721Received}.
   */
  function onERC721Received(
    address /* operator */,
    address /* from */,
    uint256 _tokenId,
    bytes calldata data
  ) external virtual override whenNotPaused whenActive returns (bytes4) {
    if (_tokenId != tokenId) {
      revert InvalidTokenId(_tokenId);
    }
    if (msg.sender != address(registry)) {
      revert InvalidRegistry(msg.sender);
    }
    bool isMinting = false;
    if (beneficiary == address(0) || holder == address(0)) {
      if (data.length == 0) {
        revert EmptyReceivingData();
      }
      (
        address _beneficiary,
        address _holder,
        bytes memory _remark,
        bytes memory _beneficiaryLei,
        bytes memory _holderLei
      ) = _decodeReceivingData(data);
      if (_beneficiaryLei.length > 20 || _holderLei.length > 20) revert LeiLengthExceeded();
      if (_beneficiary == address(0) || _holder == address(0)) {
        revert InvalidTokenTransferToZeroAddressOwners(_beneficiary, _holder);
      }
      _setBeneficiary(_beneficiary, "");
      _setHolder(_holder, "");
      remark = _remark;
      isMinting = true;
      _emitIncomingLei(_beneficiaryLei, _holderLei);
    } else remark = data;

    emit TokenReceived(beneficiary, holder, isMinting, registry, tokenId, remark);
    return bytes4(keccak256("onERC721Received(address,address,uint256,bytes)"));
  }

  /**
   * @dev See {ITitleEscrow-nominate}.
   */
  function nominate(address _nominee, bytes calldata _remark) public virtual override(ITitleEscrow) {
    _nominate(_nominee, _remark, bytes(""));
  }

  /**
   * @dev See {ITitleEscrowLei-nominate}.
   */
  function nominate(
    address _nominee,
    bytes calldata _remark,
    bytes calldata _beneficiaryLei
  ) public virtual override(ITitleEscrowLei) {
    _nominate(_nominee, _remark, _beneficiaryLei);
  }

  /**
   * @dev See {ITitleEscrow-transferBeneficiary}.
   */
  function transferBeneficiary(address _nominee, bytes calldata _remark) public virtual override(ITitleEscrow) {
    _transferBeneficiary(_nominee, _remark, bytes(""));
  }

  /**
   * @dev See {ITitleEscrowLei-transferBeneficiary}.
   */
  function transferBeneficiary(
    address _nominee,
    bytes calldata _remark,
    bytes calldata _beneficiaryLei
  ) public virtual override(ITitleEscrowLei) {
    _transferBeneficiary(_nominee, _remark, _beneficiaryLei);
  }

  /**
   * @dev See {ITitleEscrow-transferHolder}.
   */
  function transferHolder(address newHolder, bytes calldata _remark) public virtual override(ITitleEscrow) {
    _transferHolder(newHolder, _remark, bytes(""));
  }

  /**
   * @dev See {ITitleEscrowLei-transferHolder}.
   */
  function transferHolder(
    address newHolder,
    bytes calldata _remark,
    bytes calldata _holderLei
  ) public virtual override(ITitleEscrowLei) {
    _transferHolder(newHolder, _remark, _holderLei);
  }

  /**
   * @dev See {ITitleEscrow-transferOwners}.
   */
  function transferOwners(
    address _nominee,
    address newHolder,
    bytes calldata _remark
  ) external virtual override(ITitleEscrow) {
    transferBeneficiary(_nominee, _remark);
    transferHolder(newHolder, _remark);
  }

  /**
   * @dev See {ITitleEscrowLei-transferOwners}.
   */
  function transferOwners(
    address _nominee,
    address newHolder,
    bytes calldata _remark,
    bytes calldata _beneficiaryLei,
    bytes calldata _holderLei
  ) external virtual override(ITitleEscrowLei) {
    transferBeneficiary(_nominee, _remark, _beneficiaryLei);
    transferHolder(newHolder, _remark, _holderLei);
  }

  function _nominate(
    address _nominee,
    bytes memory _remark,
    bytes memory _beneficiaryLei
  ) internal whenNotPaused whenActive onlyBeneficiary whenHoldingToken {
    if (_remark.length > 120) revert RemarkLengthExceeded();
    if (_beneficiaryLei.length > 20) revert LeiLengthExceeded();
    if (beneficiary == _nominee) {
      revert TargetNomineeAlreadyBeneficiary();
    }
    if (nominee == _nominee) {
      revert NomineeAlreadyNominated();
    }
    prevBeneficiary = address(0);
    if (beneficiary == holder) prevHolder = address(0);
    remark = _remark;

    _setNominee(_nominee, _remark);
    _emitIncomingLei(_beneficiaryLei, "");
  }

  function _transferBeneficiary(
    address _nominee,
    bytes memory _remark,
    bytes memory _beneficiaryLei
  ) internal whenNotPaused whenActive onlyHolder whenHoldingToken {
    if (_remark.length > 120) revert RemarkLengthExceeded();
    if (_beneficiaryLei.length > 20) revert LeiLengthExceeded();
    if (_nominee == address(0)) {
      revert InvalidTransferToZeroAddress();
    }
    if (!(beneficiary == holder || nominee == _nominee)) {
      revert InvalidNominee();
    }
    prevHolder = address(0);
    prevBeneficiary = beneficiary;
    remark = _remark;

    _setBeneficiary(_nominee, _remark);
    _emitIncomingLei(_beneficiaryLei, "");
  }

  function _transferHolder(
    address newHolder,
    bytes memory _remark,
    bytes memory _holderLei
  ) internal whenNotPaused whenActive onlyHolder whenHoldingToken {
    if (_remark.length > 120) revert RemarkLengthExceeded();
    if (_holderLei.length > 20) revert LeiLengthExceeded();
    if (newHolder == address(0)) {
      revert InvalidTransferToZeroAddress();
    }
    if (holder == newHolder) {
      revert RecipientAlreadyHolder();
    }
    if (beneficiary == holder) prevBeneficiary = address(0);
    prevHolder = holder;
    remark = _remark;

    _setHolder(newHolder, _remark);
    _emitIncomingLei("", _holderLei);
  }

  /**
   * @dev See {ITitleEscrow-rejectTransferBeneficiary}.
   */
  function rejectTransferBeneficiary(
    bytes calldata _remark
  ) public virtual override whenNotPaused whenActive onlyBeneficiary whenHoldingToken remarkLengthLimit(_remark) {
    if (prevBeneficiary == address(0)) {
      revert InvalidTransferToZeroAddress();
    }
    if (beneficiary == holder) {
      revert DualRoleRejectionRequired();
    }
    remark = _remark;
    address from = beneficiary;
    address to = prevBeneficiary;

    _setBeneficiary(to, _remark);
    prevBeneficiary = address(0);
    emit RejectTransferBeneficiary(from, to, registry, tokenId, _remark);
  }

  /**
   * @dev See {ITitleEscrow-rejectTransferHolder}.
   */
  function rejectTransferHolder(
    bytes calldata _remark
  ) public virtual override whenNotPaused whenActive onlyHolder whenHoldingToken remarkLengthLimit(_remark) {
    if (prevHolder == address(0)) {
      revert InvalidTransferToZeroAddress();
    }
    if (holder == beneficiary) {
      revert DualRoleRejectionRequired();
    }
    remark = _remark;
    address from = holder;
    address to = prevHolder;

    _setHolder(to, _remark);
    prevHolder = address(0);

    emit RejectTransferHolder(from, to, registry, tokenId, _remark);
  }

  /**
   * @dev See {ITitleEscrow-rejectTransferOwners}.
   */
  function rejectTransferOwners(
    bytes calldata _remark
  )
    external
    virtual
    override
    whenNotPaused
    whenActive
    whenHoldingToken
    onlyBeneficiary
    onlyHolder
    remarkLengthLimit(_remark)
  {
    if (prevBeneficiary == address(0) || prevHolder == address(0)) {
      revert InvalidTransferToZeroAddress();
    }
    remark = _remark;
    address fromHolder = holder;
    address toHolder = prevHolder;
    address fromBeneficiary = beneficiary;
    address toBeneficiary = prevBeneficiary;
    _setBeneficiary(toBeneficiary, _remark);
    _setHolder(toHolder, _remark);
    prevBeneficiary = address(0);
    prevHolder = address(0);
    emit RejectTransferOwners(fromBeneficiary, toBeneficiary, fromHolder, toHolder, registry, tokenId, _remark);
  }

  /**
   * @dev See {ITitleEscrow-returnToIssuer}.
   */
  function returnToIssuer(
    bytes calldata _remark
  )
    external
    virtual
    override
    whenNotPaused
    whenActive
    onlyBeneficiary
    onlyHolder
    whenHoldingToken
    remarkLengthLimit(_remark)
  {
    _setNominee(address(0), "");
    ITradeTrustToken(registry).transferFrom(address(this), registry, tokenId, "");
    remark = _remark;
    prevBeneficiary = address(0);
    prevHolder = address(0);

    emit ReturnToIssuer(msg.sender, registry, tokenId, _remark);
  }

  /**
   * @dev See {ITitleEscrow-shred}.
   */
  function shred(bytes calldata _remark) external virtual override whenNotPaused whenActive remarkLengthLimit(_remark) {
    if (_isHoldingToken()) {
      revert TokenNotReturnedToIssuer();
    }
    if (msg.sender != registry) {
      revert InvalidRegistry(msg.sender);
    }

    _setBeneficiary(address(0), "");
    _setHolder(address(0), "");
    active = false;
    remark = _remark;

    emit Shred(registry, tokenId, _remark);
  }

  /**
   * @dev See {ITitleEscrow-isHoldingToken}.
   */
  function isHoldingToken() external view override returns (bool) {
    return _isHoldingToken();
  }

  /**
   * @notice Internal function to check if the contract is holding a token
   * @return A boolean indicating whether the contract is holding a token
   */
  function _isHoldingToken() internal view returns (bool) {
    return ITradeTrustToken(registry).ownerOf(tokenId) == address(this);
  }

  /**
   * @notice Sets the nominee
   * @param newNominee The address of the new nominee
   */
  function _setNominee(address newNominee, bytes memory _remark) internal virtual {
    emit Nomination(nominee, newNominee, registry, tokenId, _remark);
    nominee = newNominee;
  }

  /**
   * @notice Sets the beneficiary
   * @param newBeneficiary The address of the new beneficiary
   */
  function _setBeneficiary(address newBeneficiary, bytes memory _remark) internal virtual {
    emit BeneficiaryTransfer(beneficiary, newBeneficiary, registry, tokenId, _remark);
    if (nominee != address(0)) _setNominee(address(0), "0x");
    beneficiary = newBeneficiary;
  }

  /**
   * @notice Sets the holder
   * @param newHolder The address of the new holder
   */
  function _setHolder(address newHolder, bytes memory _remark) internal virtual {
    emit HolderTransfer(holder, newHolder, registry, tokenId, _remark);
    holder = newHolder;
  }

  /**
   * @notice Decodes mint payload. Supports the original (beneficiary, holder, remark) encoding
   *         and the additive (..., beneficiaryLei, holderLei) encoding.
   */
  function _decodeReceivingData(
    bytes calldata data
  )
    internal
    pure
    returns (
      address beneficiary_,
      address holder_,
      bytes memory remark_,
      bytes memory beneficiaryLei_,
      bytes memory holderLei_
    )
  {
    if (data.length >= 96 && uint256(bytes32(data[64:96])) == 160) {
      return abi.decode(data, (address, address, bytes, bytes, bytes));
    }
    (beneficiary_, holder_, remark_) = abi.decode(data, (address, address, bytes));
  }

  /**
   * @notice Emits IncomingLei only when at least one LEI is non-empty, to avoid extra log cost on legacy calls.
   */
  function _emitIncomingLei(bytes memory _beneficiaryLei, bytes memory _holderLei) internal {
    if (_beneficiaryLei.length == 0 && _holderLei.length == 0) {
      return;
    }
    emit IncomingLei(registry, tokenId, _beneficiaryLei, _holderLei);
  }
}
