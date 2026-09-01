// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

/**
 * @title ITradeTrustTokenMintableLei
 * @notice Additive mint overload that attaches incoming beneficiary and holder LEIs.
 * @dev Existing mint(address,address,uint256,bytes) is unchanged.
 */
interface ITradeTrustTokenMintableLei {
  function mint(
    address beneficiary,
    address holder,
    uint256 tokenId,
    bytes memory remark,
    bytes memory beneficiaryLei,
    bytes memory holderLei
  ) external returns (address);
}
