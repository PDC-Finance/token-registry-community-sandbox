# Legal Entity Identifier (LEI) on Title Escrow

This document describes how LEI support is implemented in this community sandbox, and why the design is additive rather than a change to existing Title Escrow and token-registry ABIs.

## What an LEI is here

A [Legal Entity Identifier](https://www.gleif.org/en/about-lei/introducing-the-legal-entity-identifier-lei) (ISO 17442) is a 20-character alphanumeric code that identifies a legal entity. In an electronic Bill of Lading (eBL) flow, wallet addresses identify *who can act* on chain. An LEI identifies *which organisation* that wallet is acting for.

The contracts do **not** verify that an LEI is valid, checksummed, or bound to the caller. The caller supplies the LEI as `bytes` (typically UTF-8 of the 20-character code). On-chain checks are length only.

## Goals

1. Attach an LEI to the **incoming** beneficiary and/or holder when a function already takes those addresses.
2. Keep LEIs **off contract storage**. History lives in event logs, the same way full remark history does (remarks additionally keep a last-write slot; LEIs do not).
3. Allow **empty LEI** (`0x`) through to **20 bytes**. Longer values revert with `LeiLengthExceeded`.
4. Avoid **breaking** existing function signatures, event signatures, ERC-165 interface IDs, TypeChain callers, and subgraphs.

## Why existing events and functions were not changed

The first-cut idea was to append `bytes beneficiaryLei` / `bytes holderLei` to the current methods and events (`TokenReceived`, `Nomination`, `BeneficiaryTransfer`, and so on).

That is a breaking change on Ethereum:

- **Events:** `topic0` is `keccak256` of the full event signature, including types. Adding a `bytes` field produces a **new** event as far as indexers are concerned. Existing subgraph handlers that filter on `BeneficiaryTransfer(address,address,address,uint256,bytes)` would stop seeing new transfers.
- **Functions:** Adding parameters changes the selector. Every current `mint`, `nominate`, and transfer call would fail until every client was upgraded.
- **ERC-165:** `ITitleEscrow` and `ITradeTrustTokenMintable` interface IDs are the XOR of their function selectors. Adding methods to those interfaces would make `supportsInterface(oldId)` return false.
- **Gas:** Empty LEIs would still be ABI-encoded and written into every log, even when the caller has nothing to say.

The implemented design keeps the original ABI and adds **opt-in** overloads plus a **new** event.

## What was implemented

### Additive interfaces

Original interfaces are unchanged:

- `ITitleEscrow`
- `ITradeTrustTokenMintable`

New interfaces:

| Interface | File | Role |
|---|---|---|
| `ITitleEscrowLei` | `contracts/interfaces/ITitleEscrowLei.sol` | Overloads for nominate / transfer, plus `IncomingLei` |
| `ITradeTrustTokenMintableLei` | `contracts/interfaces/ITradeTrustTokenMintableLei.sol` | `mint(..., remark, beneficiaryLei, holderLei)` |

`TitleEscrow` and `TradeTrustTokenMintable` implement **both** the original and the new interface. `supportsInterface` returns true for the old ID and the new ID.

### Events only, no storage

There is no `beneficiaryLei` or `holderLei` state variable. `TitleEscrow.remark()` and the registry `remark()` slot are unrelated; they still store only the last remark.

When at least one LEI is non-empty, Title Escrow emits:

```solidity
event IncomingLei(
  address indexed registry,
  uint256 indexed tokenId,
  bytes beneficiaryLei,
  bytes holderLei
);
```

If both LEIs are empty, **no** `IncomingLei` is emitted. Legacy calls therefore pay no extra log cost.

`registry` and `tokenId` are indexed so a subgraph or explorer can filter LEIs for one document. The LEI bytes themselves are not indexed (dynamic `bytes` cannot be indexed usefully).

### Incoming party only

Only the party **being set** in that call carries an LEI:

| Action | LEI fields on `IncomingLei` |
|---|---|
| Mint | `beneficiaryLei` and `holderLei` |
| `nominate` | `beneficiaryLei` (nominee); `holderLei` is empty |
| `transferBeneficiary` | `beneficiaryLei`; `holderLei` is empty |
| `transferHolder` | `holderLei`; `beneficiaryLei` is empty |
| `transferOwners` | two events: beneficiary then holder (same pattern as the two inner transfers) |

Previous / outgoing parties are not annotated. Their LEI, if any, is already in an earlier `IncomingLei` for that token.

### Functions that take addresses

LEI overloads exist only where the public ABI already takes a beneficiary, holder, or nominee address:

```solidity
// Token registry
mint(address beneficiary, address holder, uint256 tokenId, bytes remark); // original
mint(address beneficiary, address holder, uint256 tokenId, bytes remark, bytes beneficiaryLei, bytes holderLei); // new

// Title Escrow
nominate(address nominee, bytes remark); // original
nominate(address nominee, bytes remark, bytes beneficiaryLei); // new

transferBeneficiary(address nominee, bytes remark); // original
transferBeneficiary(address nominee, bytes remark, bytes beneficiaryLei); // new

transferHolder(address newHolder, bytes remark); // original
transferHolder(address newHolder, bytes remark, bytes holderLei); // new

transferOwners(address nominee, address newHolder, bytes remark); // original
transferOwners(address nominee, address newHolder, bytes remark, bytes beneficiaryLei, bytes holderLei); // new
```

Original methods delegate to the same internals with empty LEI bytes, so behaviour is identical aside from not emitting `IncomingLei`.

### Explicitly out of scope

These do **not** take a beneficiary/holder address, so they have no LEI parameter:

- `rejectTransferBeneficiary` / `rejectTransferHolder` / `rejectTransferOwners`
- `returnToIssuer`
- `restore`
- `burn` / `shred`
- `pause` / `unpause`
- `transferFrom` on the token (moves the SBT between escrow, registry, and burn address, not beneficiary/holder roles)

`TitleEscrowSignable.transferBeneficiaryWithSig` is unchanged. The signed endorsement typehash does not include an LEI. The signable contract still **inherits** the Title Escrow overloads, so on-chain `nominate` / `transfer*` with LEI remain available; the off-chain signature path does not require one.

## How mint carries LEI into Title Escrow

Mint still uses ERC-721 `onERC721Received` data. The registry encodes:

```text
abi.encode(beneficiary, holder, remark, beneficiaryLei, holderLei)
```

The original three-field encoding `(beneficiary, holder, remark)` is still accepted. Title Escrow distinguishes them by the ABI offset of the first dynamic field (remark): `96` for the old tuple, `160` for the new five-field tuple. That keeps direct `onERC721Received` tests and any in-flight three-field payloads working.

Restore still passes remark bytes as receive data and is not a mint, so it does not go through this LEI decode path.

## Length and validation

| Rule | Behaviour |
|---|---|
| `0` bytes (`0x` or `""`) | Allowed. Treated as “no LEI”. No `IncomingLei` if both sides are empty. |
| `1`–`20` bytes | Allowed. Emitted as-is. |
| `> 20` bytes | Reverts `LeiLengthExceeded`. |

ISO 17442 is **exactly** 20 characters. The contract allows shorter values so callers can omit LEI or pass a truncated placeholder without a second encoding scheme. There is no character-set or GLEIF checksum check.

Remarks remain capped at **120** bytes, independently of LEI.

## Why this is the cheaper non-breaking option

Compared with rewriting existing events:

- Callers that never pass LEI keep the same calldata and the same logs.
- Callers that pass LEI pay extra calldata (two dynamic `bytes`, often 20 bytes of UTF-8 each) and one extra log, only on those transactions.
- Nothing is written to storage (a new `bytes` slot would cost ~20k gas on first write).
- Indexers that already consume `Nomination` / `BeneficiaryTransfer` / `HolderTransfer` / `TokenReceived` keep working. They can **add** a handler for `IncomingLei` in the same transaction to join LEI to the action.

The extra event is joined by transaction hash (and by indexed `tokenId`). `transferOwners` emits two `IncomingLei` logs in one transaction, matching the two existing transfer events.

## Usage

Encode the LEI as UTF-8 bytes, same as remarks:

```ts
import { ethers } from "ethers";

const beneficiaryLei = ethers.hexlify(ethers.toUtf8Bytes("5493001KJTIIGC8Y1R12"));
const holderLei = ethers.hexlify(ethers.toUtf8Bytes("213800WAVVOPS85N2205"));

await registry.mint(beneficiary, holder, tokenId, remark, beneficiaryLei, holderLei);

await escrow.nominate(nominee, remark, beneficiaryLei);
await escrow.transferBeneficiary(nominee, remark, beneficiaryLei);
await escrow.transferHolder(newHolder, remark, holderLei);
await escrow.transferOwners(nominee, newHolder, remark, beneficiaryLei, holderLei);
```

Omit LEI entirely by calling the original four-argument `mint` / two-argument Title Escrow methods. Passing `"0x"` into an overload is equivalent: no `IncomingLei` is emitted.

Because the methods are Solidity overloads, TypeChain exposes them as:

- `nominate(address,bytes)`
- `nominate(address,bytes,bytes)`

and similarly for the other functions. Ethers resolves by argument count.

## Reading history

`escrow.remark()` is **not** an LEI API. To reconstruct which organisation was named on each transfer:

1. Subscribe to `IncomingLei` on the Title Escrow (or factory clones).
2. Filter by `tokenId`.
3. Pair each log with the other Title Escrow events in the same transaction (`Nomination`, `BeneficiaryTransfer`, `HolderTransfer`, `TokenReceived`).

Empty fields on `IncomingLei` mean that side was not the incoming party for that call.

## Contract files touched

- `contracts/interfaces/ITitleEscrowLei.sol`
- `contracts/interfaces/ITradeTrustTokenMintableLei.sol`
- `contracts/interfaces/TitleEscrowErrors.sol` (`LeiLengthExceeded`)
- `contracts/interfaces/TradeTrustTokenErrors.sol` (`LeiLengthExceeded`)
- `contracts/TitleEscrow.sol`
- `contracts/base/TradeTrustTokenMintable.sol`
- `src/constants/contract-interfaces.ts` / `contract-interface-id.ts` (new interface IDs only; original IDs unchanged)
