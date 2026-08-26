# Net ETH Flow Hook

Uniswap v4 hook that tracks how much native ETH flows into and out of one pool.

The hook exposes cumulative inflow, cumulative outflow, and per-epoch breakdowns on-chain. Off-chain tools (treasury monitors, reserve alerts, analytics jobs) can read the counters directly or index the events without reimplementing swap parsing.

Built with Foundry. Depends on [v4-core](https://github.com/Uniswap/v4-core) and [v4-periphery](https://github.com/Uniswap/v4-periphery).

## What it does

Every swap on a native ETH pool triggers `afterSwap`. The hook reads the executed `BalanceDelta`, finds the ETH leg, and updates:

- **All-time counters**: `totalEthInflow`, `totalEthOutflow`
- **Epoch counters**: `epochEthInflow[epochId]`, `epochEthOutflow[epochId]`
- **Events**: `SwapTracked` on every ETH swap, `EpochAdvanced` when a new epoch window opens

Net flow is never stored as a single signed value. It is derived on read via `getNetFlow()`.

## Direction convention

| Term | Meaning |
|------|---------|
| **Inflow** | ETH enters the pool. The trader sells ETH for the paired token. |
| **Outflow** | ETH leaves the pool. The trader buys ETH with the paired token. |
| **Net flow** | Inflow minus outflow (computed in a view function). |

Native ETH is detected by `address(0)` on either `currency0` or `currency1`. The hook does not hardcode ETH to token0.

## BalanceDelta sign convention

v4 passes `afterSwap` a `BalanceDelta` from the **swapper's perspective**:

| ETH delta sign | Pool effect | Our label |
|----------------|-------------|-----------|
| Negative | Swapper pays ETH in | **Inflow** |
| Positive | Swapper receives ETH out | **Outflow** |

This matches how v4 routers settle swaps: negative delta means the swapper pays (`settle`), positive means they receive (`take`).

## Epochs

Time is split into fixed windows for scoped totals:

- Set `epochLength` at deploy (default **1 day** if you pass `0`)
- `epochId = block.timestamp / epochLength` (no external oracle)
- Each epoch keeps its own inflow/outflow mappings, plus separate all-time totals
- The first swap in a new epoch emits `EpochAdvanced`

## Reading on-chain state

| Function / variable | Returns |
|---------------------|---------|
| `totalEthInflow` | All-time ETH into the pool |
| `totalEthOutflow` | All-time ETH out of the pool |
| `getNetFlow()` | All-time net as `int256` |
| `getCurrentEpoch()` | Active epoch id |
| `getEpochFlows(epochId)` | `(inflow, outflow)` for one epoch |

## Events for indexers

**`SwapTracked`** (every ETH swap):

```solidity
event SwapTracked(
    uint256 indexed epochId,
    FlowDirection direction,  // Inflow or OutflowNN
    uint256 amount,
    address indexed sender,
    uint256 timestamp
);
```

**`EpochAdvanced`** (first swap after a boundary):

```solidity
event EpochAdvanced(
    uint256 indexed previousEpochId,
    uint256 indexed newEpochId,
    uint256 timestamp
);
```

## Project layout

```
src/
  NetEthFlowHook.sol       Hook contract
test/
  NetEthFlowHook.t.sol     Foundry tests
lib/
  v4-periphery/            Uniswap v4 (includes nested v4-core)
  forge-std/
foundry.toml               Compiler + remappings
remappings.txt             Import paths
```

## Setup

Install Foundry, then pull dependencies:

```bash
forge install Uniswap/v4-core Uniswap/v4-periphery
```

If the libs are already in `lib/`, skip that step.

## Commands

```bash
# compile
forge build

# format
forge fmt

# run tests
forge test -vv

# gas report
forge test --gas-report
```

All **6 tests** should pass:

- ETH-in swap increments inflow
- ETH-out swap increments outflow
- Multiple swaps update cumulative and epoch totals
- Epoch rollover keeps old epoch data readable
- First swap does not emit spurious `EpochAdvanced`
- Fuzz on inflow amounts

## Deployment note

v4 encodes hook permissions in the **contract address**. You cannot deploy with a plain `new NetEthFlowHook(...)`.

Use CREATE2 with [HookMiner](lib/v4-periphery/test/shared/HookMiner.sol) to mine a salt where the address matches `afterSwap: true`. See `test/NetEthFlowHook.t.sol` for the pattern:

```solidity
uint160 flags = uint160(Hooks.AFTER_SWAP_FLAG);
bytes memory args = abi.encode(poolManager, epochLengthSeconds);
(, bytes32 salt) = HookMiner.find(deployer, flags, type(NetEthFlowHook).creationCode, args);
NetEthFlowHook hook = new NetEthFlowHook{salt: salt}(poolManager, epochLengthSeconds);
```

This repo uses the current v4 API:

- No `BaseHook` or `getHookPermissions()` in the installed deps
- Permissions live in `Hooks.Permissions`, checked via `validateHookPermissions()` in the constructor
- Our readable wrapper is `hookPermissions()` on the contract

## v1 scope and limits

This is a PoC. Intentionally out of scope:

- Multi-pool aggregation
- External price feeds
- Fee adjustment logic
- `beforeSwap` tracking
- Deployment scripts
- Dashboard / frontend

One pool, one hook, `afterSwap` only.

## Compiler settings

`foundry.toml` matches v4 where it matters:

- Solidity `0.8.26`
- EVM `cancun`
- `via_ir = true`

Remappings point `@uniswap/v4-core` at the nested copy inside `v4-periphery/lib/v4-core/` (the top-level `lib/v4-core` submodule may lag behind).

## License

MIT for the hook contract. Uniswap libraries under `lib/` keep their own licenses.
