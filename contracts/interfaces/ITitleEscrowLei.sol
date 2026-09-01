// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

/**
 * @title ITitleEscrowLei
 * @notice Additive LEI (Legal Entity Identifier) overloads for TitleEscrow.
 * @dev Existing ITitleEscrow function and event signatures are unchanged.
 *      LEIs are not stored; they are emitted on IncomingLei when non-empty.
 *      Each LEI must be 0 to 20 bytes (ISO 17442 is 20 characters).
 */
interface ITitleEscrowLei {
  event IncomingLei(address indexed registry, uint256 indexed tokenId, bytes beneficiaryLei, bytes holderLei);

  function nominate(address nominee, bytes calldata remark, bytes calldata beneficiaryLei) external;

  function transferBeneficiary(address nominee, bytes calldata remark, bytes calldata beneficiaryLei) external;

  function transferHolder(address newHolder, bytes calldata remark, bytes calldata holderLei) external;

  function transferOwners(
    address nominee,
    address newHolder,
    bytes calldata remark,
    bytes calldata beneficiaryLei,
    bytes calldata holderLei
  ) external;
}
