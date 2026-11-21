# Morpheus Bug Bounty — Proof-of-Concept Tests

Foundry mainnet-fork PoCs for two Morpheus bug bounty reports submitted to
devs@mor.org under the Morpheus Bug Bounty Policy v2 (2026-08-07).

## Reports covered

1. **DepositPool — claim receiver redirection** (`test/A01ClaimForRedirection.t.sol`)
   Ethereum fork at block 26,460,185. A whitelisted claim sender can redirect a
   staker's/referrer's pending MOR rewards to any address when the victim has
   not pinned a claim receiver (`claimFor`), and always for referrer tier
   rewards (`claimReferrerTierFor`, which has no pinning mechanism). The test
   asserts, from the deployed contracts' own `UserClaimed` event, that the
   victim's full pending balance of 12,661.2338 MOR is minted to the attacker
   and the victim's pending balance is zeroed. A non-whitelisted caller control
   case reverts. Scaffolding is disclosed in the test header (fresh victim key,
   a 40 stETH Distributor donation standing in for Lido rebase yield, Chainlink
   answers pinned via `mockCall` to their fork-block values).

2. **LumerinDiamond — wildcard delegation session skim** (`test/D01WildcardDelegation.t.sol`)
   Base fork at block 60,172,000. The diamond's session authorization honours
   wildcard (empty-rights) delegate.xyz delegations for fund-moving session
   rights, so a victim's hot-wallet delegate — delegated for unrelated apps —
   can open/close sessions as the victim and have a provider paid out of the
   victim's escrowed MOR stake. The test asserts attacker gain == victim loss
   == 29.2188 MOR per session cycle. A no-delegation control case reverts on
   the identical call.

## Run

```shell
forge install foundry-rs/forge-std
forge test
```

Fork RPC endpoints are configured inside each test (`https://ethereum-rpc.publicnode.com`
for Ethereum, `https://mainnet.base.org` for Base). No transactions are
broadcast; both tests run entirely against forked state with unprivileged,
freshly created addresses.
