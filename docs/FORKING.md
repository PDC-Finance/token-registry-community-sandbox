# Testing on a Forked Chain with Hardhat

This guide shows how to run a local copy of a live chain (a fork) with Hardhat and run tests against it. It is chain-agnostic. Any network in [`hardhat.config.ts`](../hardhat.config.ts), or any other EVM chain with an RPC endpoint, works the same way.

Fork testing covers two things the default test setup cannot:

1. **Chain compatibility.** The existing suite runs on the target chain's real state and EVM, not on an empty local chain.
2. **The deployed contracts.** You can call the contracts already deployed on that chain (Title Escrow Factory, Deployer, Token Implementation, listed in [`src/constants/contract-address.ts`](../src/constants/contract-address.ts)) at their real addresses: deploy registries through them, mint, transfer, and impersonate their owners. Nothing is sent to the real chain and no real funds are spent.

## Contents

- [How forking works](#how-forking-works)
- [Prerequisites](#prerequisites)
- [Step 1: Install and build](#step-1-install-and-build)
- [Step 2: Configure the environment](#step-2-configure-the-environment)
- [Step 3: Add fork settings to `hardhat.config.ts`](#step-3-add-fork-settings-to-hardhatconfigts)
- [Step 4: Run the existing test suite on the fork](#step-4-run-the-existing-test-suite-on-the-fork)
- [Step 5: Write tests against the deployed contracts](#step-5-write-tests-against-the-deployed-contracts)
- [Step 6: Run the fork tests](#step-6-run-the-fork-tests)
- [Option: run a persistent fork node](#option-run-a-persistent-fork-node)
- [Option: run the deploy tasks on the fork](#option-run-the-deploy-tasks-on-the-fork)
- [Troubleshooting](#troubleshooting)
- [Quick reference](#quick-reference)

## How forking works

When forking is enabled, Hardhat Network starts from a block of the remote chain instead of from an empty genesis:

- **Reads** (contract code, storage, balances) are fetched from the remote RPC as needed and cached locally.
- **Writes** (every transaction you send) happen only in the local Hardhat instance. The real chain is never touched.
- The usual Hardhat test accounts (`ethers.getSigners()`) are available and funded with 10,000 native tokens each.
- You can **impersonate** any address, such as a contract owner or a multisig, and send transactions as that address without its private key.
- `evm_snapshot`/`evm_revert`, and therefore `loadFixture`, work as normal.

You can fork in two ways. Both are covered below:

| Mode | How | Best for |
| --- | --- | --- |
| **In-process fork** | `networks.hardhat.forking` in the config, then `npx hardhat test` | Running test suites. One command, fresh fork on every run. |
| **Fork node** | `npx hardhat node --fork <url>` in one terminal, then `--network localhost` in another | Debugging, running scripts or tasks repeatedly against the same forked state, connecting a wallet or dApp. |

## Prerequisites

- **Node.js 18.** Use the version pinned in [`.nvmrc`](../.nvmrc) (`nvm use`).
- **An RPC URL for the chain you want to fork.** The public URLs in `hardhat.config.ts` are fine to start with. Keep in mind:
  - Public RPCs are often rate-limited. A full suite run makes many calls, so a dedicated or provider RPC (Infura, Alchemy, QuickNode, Ankr, …) is more reliable.
  - To pin the fork to an **older block number**, the RPC has to be an **archive node**. Most public RPCs only keep recent state. See [Troubleshooting](#troubleshooting).
- **The chain ID** of the chain you are forking. Some examples from this repo:

  | Network (config name) | Chain ID |
  | --- | --- |
  | Ethereum (`mainnet`) | 1 |
  | Sepolia (`sepolia`) | 11155111 |
  | Polygon (`polygon`) | 137 |
  | Polygon Amoy (`amoy`) | 80002 |
  | XDC (`xdc`) / Apothem (`xdcapothem`) | 50 / 51 |
  | Stability (`stability`) / Testnet (`stabilitytestnet`) | 101010 / 20180427 |
  | Astron (`astron`) / Testnet (`astrontestnet`) | 1338 / 21002 |
  | XRPL EVM (`xrplEvm`) / Testnet (`xrplEvmTestnet`) | 1440000 / 1449000 |

## Step 1: Install and build

```bash
git clone git@github.com:PDC-Finance/token-registry-community-sandbox.git
cd token-registry-community-sandbox
nvm use
npm install
```

`npm install` runs `prepare`, which runs the full build. To only compile contracts and regenerate the TypeChain types in `src/contracts`:

```bash
npm run build:sol
```

Then check that the normal (non-forked) suite passes before you add a fork. That way you have a baseline:

```bash
NODE_ENV=ci npm test
```

## Step 2: Configure the environment

`hardhat.config.ts` throws on startup unless **either**:

- `NODE_ENV=ci` is set (the config then uses a random throwaway key for the remote networks), **or**
- `.env` contains `INFURA_APP_ID` and one of `DEPLOYER_PK` / `MNEMONIC`.

Fork testing never needs a real deployer key, because the forked Hardhat network uses its own built-in test accounts. **Use `NODE_ENV=ci` for fork work** so that real keys never end up in a test run.

Add these fork variables to your `.env` (they are new, so also add them, empty, to `.env.sample`):

```dotenv
# --- Forking ---
# RPC of the chain to fork. Leave empty to disable forking.
FORK_URL=
# Optional: pin the fork to a block for reproducible runs (requires an archive RPC for old blocks).
FORK_BLOCK_NUMBER=
# Chain ID of the forked chain. Makes the local fork report the real chain ID.
FORK_CHAIN_ID=
```

Example for XRPL EVM Testnet:

```dotenv
FORK_URL=https://rpc.testnet.xrplevm.org
FORK_CHAIN_ID=1449000
```

Example for Polygon Amoy, pinned to a block:

```dotenv
FORK_URL=https://rpc-amoy.polygon.technology
FORK_BLOCK_NUMBER=<recent block number>
FORK_CHAIN_ID=80002
```

> [!TIP]
> You don't have to edit `.env` to switch chains. Pass the variables on the command line, which takes precedence for that one command:
> `FORK_URL=https://rpc.testnet.xrplevm.org FORK_CHAIN_ID=1449000 NODE_ENV=ci npm test`

### Why set `FORK_CHAIN_ID`?

By default, a forked Hardhat network reports chain ID **31337**, not the real one. Two things in this repo depend on the chain ID:

- `deploy:token` and the other tasks look up the deployed addresses with `contractAddress.<Contract>[chainId]`. With 31337 they find nothing.
- EIP-712 signatures (`TitleEscrowSignable`, `SigHelper`) include the chain ID in the domain.

Setting `FORK_CHAIN_ID` makes the fork report the real chain ID, so the fork behaves like the actual network.

## Step 3: Add fork settings to `hardhat.config.ts`

Make the `hardhat` network fork whenever `FORK_URL` is set. When it is unset, everything behaves exactly as it does today.

**3a.** Read the new variables next to the existing ones:

```ts
const {
  INFURA_APP_ID,
  MNEMONIC,
  DEPLOYER_PK,
  // ...existing variables...
  FORK_URL,
  FORK_BLOCK_NUMBER,
  FORK_CHAIN_ID,
} = process.env;
```

**3b.** Replace the `hardhat` entry under `networks`:

```ts
    /**
     * Development
     */
    hardhat: {
      allowUnlimitedContractSize: true,
      ...(FORK_URL && {
        forking: {
          url: FORK_URL,
          ...(FORK_BLOCK_NUMBER && { blockNumber: Number(FORK_BLOCK_NUMBER) }),
        },
      }),
      ...(FORK_URL &&
        FORK_CHAIN_ID && {
          chainId: Number(FORK_CHAIN_ID),
          // Hardhat only knows the hardfork history of a few well-known chains. For any other
          // chain it cannot run calls against blocks at or before the fork block unless told
          // which hardfork applies. Treating the whole history as Cancun is fine for testing.
          chains: {
            [Number(FORK_CHAIN_ID)]: {
              hardforkHistory: { cancun: 0 },
            },
          },
        }),
    },
```

**3c.** Forked runs are slower, because every new account or storage slot is fetched over the network. Raise the Mocha timeout (default 40s) by adding a top-level `mocha` key to `config`:

```ts
const config: HardhatUserConfig = {
  // ...solidity, typechain, etc...
  mocha: {
    timeout: FORK_URL ? 300_000 : 40_000,
  },
  // ...
};
```

**3d.** Optional: the gas reporter is always on (`enabled: true`). Its output is less useful on a fork and it slows runs down, so you can turn it off for forks:

```ts
  gasReporter: {
    coinmarketcap: COINMARKETCAP_API_KEY,
    currency: "USD",
    enabled: !FORK_URL,
  },
```

**Check the config.** With a fork configured, this should print the forked chain's ID and the current block:

```bash
NODE_ENV=ci npx hardhat console
> (await ethers.provider.getNetwork()).chainId
> await ethers.provider.getBlockNumber()
> await network.provider.send("hardhat_metadata")   // shows forkedNetwork { chainId, forkBlockNumber, ... }
```

## Step 4: Run the existing test suite on the fork

With `FORK_URL` (and ideally `FORK_CHAIN_ID`) set, the normal test command now runs on the fork:

```bash
NODE_ENV=ci npm test
```

Or without editing `.env`:

```bash
FORK_URL=https://rpc.testnet.xrplevm.org FORK_CHAIN_ID=1449000 NODE_ENV=ci npm test
```

Run a single file:

```bash
NODE_ENV=ci TS_NODE_TRANSPILE_ONLY=1 npx hardhat test test/TitleEscrow.test.ts
```

**What this does and doesn't cover.** The existing tests deploy **fresh** contracts through their fixtures (`test/fixtures`), so they don't touch the contracts already on the chain. Passing on the fork shows that the contracts compile, deploy and behave correctly on that chain's real state, chain ID and EVM. To test the deployed contracts, continue to Step 5.

**Reading the results:**

- Everything passes, same as the non-forked baseline: no chain-specific issues found.
- A test passes locally but fails on the fork: look into it as a possible chain-specific difference, for example in chain ID handling, precompiles or gas behavior. Re-run that single file with a pinned `FORK_BLOCK_NUMBER` to make it reproducible.
- Timeouts or `429`/`rate limit` errors are infrastructure, not test failures. See [Troubleshooting](#troubleshooting).

## Step 5: Write tests against the deployed contracts

Put fork-only tests in their own folder, `test/fork/`. `hardhat test` picks up every file under `test/` recursively, so **each fork test must skip itself when it isn't running on a fork**. Otherwise `npm test` fails on a normal local run.

### Detecting the fork and the real chain ID

Hardhat's `hardhat_metadata` RPC method reports whether the node is a fork and gives the **remote** chain ID. This works for both the in-process fork and a `hardhat node --fork` instance, and it does not depend on `FORK_CHAIN_ID`. Use it to decide whether to run and which addresses to load:

```ts
const getForkedChainId = async (): Promise<number | undefined> => {
  const metadata = await network.provider.send("hardhat_metadata", []);
  return metadata.forkedNetwork?.chainId;
};
```

### Example: `test/fork/DeployedContracts.fork.test.ts`

This file is a starting point. It checks the deployed contracts on whatever chain is forked and runs one full document lifecycle through them:

```ts
import { TDocDeployer, TitleEscrow, TitleEscrowFactory, TradeTrustTokenStandard } from "@tradetrust/contracts";
import { ethers, network } from "hardhat";
import { expect } from "..";
import { contractAddress } from "../../src/constants";
import { encodeInitParams, getEventFromReceipt } from "../../src/utils";
import { getTestUsers, impersonateAccount, stopImpersonatingAccount, TestUsers } from "../helpers";

const getForkedChainId = async (): Promise<number | undefined> => {
  const metadata = await network.provider.send("hardhat_metadata", []);
  return metadata.forkedNetwork?.chainId;
};

const addressFor = (contract: keyof typeof contractAddress, chainId: number) =>
  (contractAddress[contract] as Record<number, string>)[chainId];

const toRemark = (text: string) => ethers.hexlify(ethers.toUtf8Bytes(text));

describe("Fork: deployed TradeTrust contracts", () => {
  let users: TestUsers;
  let factoryAddress: string;
  let deployerAddress: string;
  let implAddress: string;

  let deployerContract: TDocDeployer;
  let factoryContract: TitleEscrowFactory;

  // Must be a `function`, not an arrow function, so `this.skip()` is available.
  before(async function () {
    const chainId = await getForkedChainId();
    if (!chainId) {
      this.skip(); // Not running on a fork.
      return;
    }

    factoryAddress = addressFor("TitleEscrowFactory", chainId);
    deployerAddress = addressFor("Deployer", chainId);
    implAddress = addressFor("TokenImplementation", chainId);
    if (!factoryAddress || !deployerAddress || !implAddress) {
      console.warn(`No deployed addresses for chain ${chainId} in contract-address.ts. Skipping.`);
      this.skip();
      return;
    }

    users = await getTestUsers();
    deployerContract = (await ethers.getContractAt("TDocDeployer", deployerAddress)) as unknown as TDocDeployer;
    factoryContract = (await ethers.getContractAt(
      "TitleEscrowFactory",
      factoryAddress
    )) as unknown as TitleEscrowFactory;
  });

  describe("Deployment sanity", () => {
    it("should have contract code at every configured address", async () => {
      for (const address of [factoryAddress, deployerAddress, implAddress]) {
        expect(await ethers.provider.getCode(address), address).to.not.equal("0x");
      }
    });

    it("should have the token implementation registered in the Deployer with the configured factory", async () => {
      const registeredFactory = await deployerContract.implementations(implAddress);

      expect(registeredFactory).to.equal(ethers.getAddress(factoryAddress));
    });
  });

  describe("Document lifecycle through the deployed contracts", () => {
    let registry: TradeTrustTokenStandard;
    let tokenId: bigint;

    beforeEach(async () => {
      // Deploy a new token registry clone through the real Deployer. The carrier is the admin.
      const params = encodeInitParams({ name: "Fork Test Token", symbol: "FTT", deployer: users.carrier.address });
      const tx = await deployerContract.connect(users.carrier).deploy(implAddress, params);
      const receipt = await tx.wait();
      const registryAddress = getEventFromReceipt<any>(receipt, "Deployment", deployerContract.interface).args
        .deployed;

      registry = (await ethers.getContractAt(
        "TradeTrustTokenStandard",
        registryAddress
      )) as unknown as TradeTrustTokenStandard;
      tokenId = BigInt(ethers.hexlify(ethers.randomBytes(32)));
    });

    it("should use the deployed Title Escrow Factory", async () => {
      expect(await registry.titleEscrowFactory()).to.equal(ethers.getAddress(factoryAddress));
    });

    it("should mint into a title escrow created by the deployed factory", async () => {
      await registry
        .connect(users.carrier)
        .mint(users.beneficiary.address, users.holder.address, tokenId, toRemark("fork mint"));

      const escrowAddress = await factoryContract.getEscrowAddress(await registry.getAddress(), tokenId);
      const escrow = (await ethers.getContractAt("TitleEscrow", escrowAddress)) as unknown as TitleEscrow;

      expect(await registry.ownerOf(tokenId)).to.equal(escrowAddress);
      expect(await escrow.beneficiary()).to.equal(users.beneficiary.address);
      expect(await escrow.holder()).to.equal(users.holder.address);
    });

    it("should allow the holder to transfer holdership", async () => {
      await registry
        .connect(users.carrier)
        .mint(users.beneficiary.address, users.holder.address, tokenId, toRemark("fork mint"));
      const escrowAddress = await factoryContract.getEscrowAddress(await registry.getAddress(), tokenId);
      const escrow = (await ethers.getContractAt("TitleEscrow", escrowAddress)) as unknown as TitleEscrow;
      const [newHolder] = users.others;

      await escrow.connect(users.holder).transferHolder(newHolder.address, toRemark("fork transfer"));

      expect(await escrow.holder()).to.equal(newHolder.address);
    });
  });

  describe("Owner-only actions via impersonation", () => {
    let ownerAddress: string;

    before(async () => {
      ownerAddress = await deployerContract.owner();
    });

    after(async () => {
      await stopImpersonatingAccount({ address: ownerAddress });
    });

    it("should let the real Deployer owner register a new implementation", async () => {
      // Impersonate the on-chain owner (EOA or multisig). The helper also funds it for gas.
      const ownerSigner = await impersonateAccount({ address: ownerAddress });
      const newImpl = await (await ethers.getContractFactory("TradeTrustTokenStandard")).deploy();
      const newImplAddress = await newImpl.getAddress();

      await deployerContract.connect(ownerSigner).addImplementation(newImplAddress, factoryAddress);

      expect(await deployerContract.implementations(newImplAddress)).to.equal(ethers.getAddress(factoryAddress));
    });

    it("should reject non-owners", async () => {
      const tx = deployerContract.connect(users.beneficiary).addImplementation(implAddress, factoryAddress);

      await expect(tx).to.be.revertedWithCustomError(deployerContract, "OwnableUnauthorizedAccount");
    });
  });
});
```

### Patterns worth knowing

All of these are already used in this repo or come with `@nomicfoundation/hardhat-network-helpers`:

| Need | How |
| --- | --- |
| Act as any address | `impersonateAccount({ address })` from `test/helpers` (also gives it 100 native tokens), or `ethers.getImpersonatedSigner(address)` |
| Give an address native tokens | `setBalance(address, ethers.parseEther("1000"))` from `@nomicfoundation/hardhat-network-helpers` |
| Move time forward | `time.increase(seconds)` / `time.increaseTo(timestamp)` |
| Mine blocks | `mine(n)` |
| Reset state between tests | `loadFixture(fn)`, which snapshots after the first run and reverts on later calls |
| Re-fork at a different block during a test | `reset(FORK_URL, blockNumber)` from `hardhat-network-helpers` |
| Attach to a deployed contract | `ethers.getContractAt("<ArtifactName>", address)`. The ABI comes from this repo's compiled artifacts. |
| Read an existing document on-chain | Attach `TradeTrustToken` at a known registry address, then `ownerOf(tokenId)` → escrow address → attach `TitleEscrow` |

> [!NOTE]
> `getContractAt` uses the ABI from your **local** artifacts. If the contracts in this repo have changed since the on-chain version was deployed, calls to new or changed functions will revert or decode wrongly. When results look wrong, check that the repo version matches the deployed one.

## Step 6: Run the fork tests

Fork tests only:

```bash
FORK_URL=https://rpc.testnet.xrplevm.org FORK_CHAIN_ID=1449000 NODE_ENV=ci TS_NODE_TRANSPILE_ONLY=1 \
  npx hardhat test test/fork/DeployedContracts.fork.test.ts
```

Everything (existing suite and fork tests) on the fork:

```bash
FORK_URL=https://rpc.testnet.xrplevm.org FORK_CHAIN_ID=1449000 NODE_ENV=ci npm test
```

Without a fork (the default local run), the fork tests show as **pending** (skipped) and everything else runs as before:

```bash
NODE_ENV=ci npm test
```

To test another chain, change `FORK_URL` and `FORK_CHAIN_ID`. The fork tests load the right addresses automatically. If the chain has no entry in `contract-address.ts`, the deployed-contract tests skip with a warning.

**Suggested workflow for a new chain or a contract change:**

1. `NODE_ENV=ci npm test` (local baseline)
2. Run the existing suite on a **testnet** fork
3. Run the fork tests on the **testnet** fork
4. Repeat steps 2 and 3 on a **mainnet** fork before any real mainnet deployment or upgrade

## Option: run a persistent fork node

Use this when you want to run several commands, scripts or tasks against the same forked state, or connect a wallet or frontend to it.

**Terminal 1**: start the node. `FORK_CHAIN_ID` from Step 3 still applies here, because the node reads the `hardhat` network config:

```bash
FORK_CHAIN_ID=1449000 NODE_ENV=ci npx hardhat node --fork https://rpc.testnet.xrplevm.org
# optionally: --fork-block-number <block>
```

The node listens on `http://127.0.0.1:8545` and prints its 20 funded test accounts with their private keys. **These keys are public. Never use them on a real network.**

**Terminal 2**: run tests against it:

```bash
NODE_ENV=ci TS_NODE_TRANSPILE_ONLY=1 npx hardhat test --network localhost
NODE_ENV=ci TS_NODE_TRANSPILE_ONLY=1 npx hardhat test test/fork/DeployedContracts.fork.test.ts --network localhost
```

The `localhost` network in the config uses `accounts: "remote"`, so tests sign with the node's unlocked test accounts. The fork tests detect the node as a fork through `hardhat_metadata`.

Notes:

- State **builds up** across runs on a persistent node (deployed registries, minted tokens, changed balances). Restart the node to get a clean fork.
- For a wallet such as MetaMask: add a custom network with RPC `http://127.0.0.1:8545` and the chain ID you set (`FORK_CHAIN_ID`, or 31337 if unset), then import one of the printed test keys.

## Option: run the deploy tasks on the fork

With a fork node running (and `FORK_CHAIN_ID` set so the address lookup works), you can rehearse the real deployment commands from the README:

```bash
# Deploys a token registry through the chain's real Deployer + Token Implementation
NODE_ENV=ci npx hardhat deploy:token --network localhost --name "Fork Rehearsal" --symbol FRH

# Standalone token with the chain's real Title Escrow Factory
NODE_ENV=ci npx hardhat deploy:token --network localhost --name "Fork Rehearsal" --symbol FRH --standalone

# Fresh factory / implementation
NODE_ENV=ci npx hardhat deploy:factory --network localhost
NODE_ENV=ci npx hardhat deploy:token:impl --network localhost
```

Do **not** pass `--verify` on a fork. There is nothing to verify on a block explorer.

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| `Infura key is not provided in env` / `Provide at least either deployer private key or mnemonic` | Config startup checks | Prefix commands with `NODE_ENV=ci` |
| `missing trie node`, `header not found`, `state not available`, `project ID does not have access to archive state` | Pinned `FORK_BLOCK_NUMBER` is older than the RPC keeps | Use a recent block, leave the block unpinned, or switch to an archive RPC |
| `No known hardfork for execution on historical block …` | Hardhat doesn't know this chain's hardfork history | Make sure `FORK_CHAIN_ID` is set so the `chains.hardforkHistory` block from Step 3 applies |
| `Timeout of 40000ms exceeded` | Slow RPC, many cold reads | Raise `mocha.timeout` (Step 3c), use a faster RPC, or pin a block so the cache is reused |
| `429 Too Many Requests` / `rate limit` | Public RPC throttling | Use a provider RPC with an API key, or run fewer test files at a time |
| Fork tests show as pending | Not running on a fork | Set `FORK_URL`, or pass `--network localhost` to a running fork node |
| Fork tests skipped with "No deployed addresses for chain …" | Chain has no entry in `contract-address.ts` | Expected for that chain. Add the addresses if the contracts are deployed there |
| `deploy:token` cannot find the Deployer/Implementation on the fork | Fork reports chain ID 31337 | Set `FORK_CHAIN_ID` to the real chain ID |
| EIP-712 signature checks fail only on the fork | Signature built for a different chain ID than the fork reports | Build the domain from `(await ethers.provider.getNetwork()).chainId`, as the existing tests do |
| Calls to deployed contracts revert unexpectedly or return garbage | Local artifact ABI differs from the deployed bytecode | Check the deployed version, or attach with the ABI that matches it |
| Errors while fetching blocks/transactions from non-Ethereum chains | Some chains return non-standard RPC fields | Try a different RPC for the same chain, pin to a recent block, and report the error with the RPC URL and block number |

To see every RPC call the fork makes, add `--verbose` to any Hardhat command.

## Quick reference

```bash
# One-off: run everything on a fork
FORK_URL=<rpc> FORK_CHAIN_ID=<id> NODE_ENV=ci npm test

# One-off: fork tests only, pinned block
FORK_URL=<rpc> FORK_CHAIN_ID=<id> FORK_BLOCK_NUMBER=<block> NODE_ENV=ci TS_NODE_TRANSPILE_ONLY=1 \
  npx hardhat test test/fork/DeployedContracts.fork.test.ts

# Persistent node + tests in another terminal
FORK_CHAIN_ID=<id> NODE_ENV=ci npx hardhat node --fork <rpc> [--fork-block-number <block>]
NODE_ENV=ci TS_NODE_TRANSPILE_ONLY=1 npx hardhat test --network localhost

# Inspect the fork
NODE_ENV=ci npx hardhat console        # then: await network.provider.send("hardhat_metadata")
```

Further reading: [Hardhat: Forking other networks](https://hardhat.org/hardhat-network/docs/guides/forking-other-networks) · [Hardhat Network Helpers](https://hardhat.org/hardhat-network-helpers/docs/overview)
