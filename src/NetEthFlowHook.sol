// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {ImmutableState} from "v4-periphery/src/base/ImmutableState.sol";

/// @title NetEthFlowHook
/// @author dex_cipher workshop PoC
/// @notice Tracks native ETH moving into and out of a single Uniswap v4 pool.
///
/// @dev This is a proof of concept. The goal is a simple on-chain signal that other
/// systems (treasury monitors, reserve dashboards, alerting pipelines) can read.
///
/// ETH direction convention:
///   inflow  = ETH enters the pool  (trader sells ETH for the paired token)
///   outflow = ETH leaves the pool  (trader buys ETH with the paired token)
///
/// We only use afterSwap for tracking. That callback receives the executed
/// BalanceDelta, which reflects what actually moved. beforeSwap estimates can
/// drift; we skip them in v1.
///
/// Deploy note: v4 encodes hook permissions in the contract address. You must
/// mine a CREATE2 salt (HookMiner) so the deployed address matches
/// hookPermissions() below. A plain `new NetEthFlowHook(...)` will revert in
/// the constructor unless the address already has the right flag bits.
contract NetEthFlowHook is IHooks, ImmutableState {
    using Hooks for IHooks;
    using BalanceDeltaLibrary for BalanceDelta;

    /// @notice Fallback epoch window when the deployer passes zero for `epochLengthSeconds`.
    uint256 public constant DEFAULT_EPOCH_LENGTH = 1 days;

    /// @notice Labels the ETH side of a tracked swap for events and off-chain indexing.
    enum FlowDirection {
        /// @dev Trader sold ETH; ETH moved into the pool.
        Inflow,
        /// @dev Trader bought ETH; ETH moved out of the pool.
        Outflow
    }

    // -------------------------------------------------------------------------
    // Storage
    // -------------------------------------------------------------------------

    /// @notice Length of each epoch window in seconds.
    /// @dev Epoch id is computed as `block.timestamp / epochLength`. No external oracle.
    uint256 public immutable epochLength;

    /// @notice Cumulative ETH that entered the pool across all time (trader sold ETH).
    uint256 public totalEthInflow;

    /// @notice Cumulative ETH that left the pool across all time (trader bought ETH).
    uint256 public totalEthOutflow;

    /// @notice ETH inflow recorded inside one epoch window, keyed by epoch id.
    mapping(uint256 epochId => uint256 amount) public epochEthInflow;

    /// @notice ETH outflow recorded inside one epoch window, keyed by epoch id.
    mapping(uint256 epochId => uint256 amount) public epochEthOutflow;

    /// @dev Last epoch id written to. Used to detect rollover between swaps.
    uint256 private lastRecordedEpoch;

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    /// @notice Emitted after every swap where native ETH movement is detected.
    /// @param epochId Epoch window the swap landed in.
    /// @param direction Whether ETH flowed in or out of the pool.
    /// @param amount Absolute ETH amount moved (always positive).
    /// @param sender Address that initiated the swap.
    /// @param timestamp `block.timestamp` when the swap was recorded.
    event SwapTracked(
        uint256 indexed epochId, FlowDirection direction, uint256 amount, address indexed sender, uint256 timestamp
    );

    /// @notice Emitted when the first swap after an epoch boundary opens a new window.
    /// @param previousEpochId Epoch id before the rollover.
    /// @param newEpochId Epoch id the swap landed in.
    /// @param timestamp `block.timestamp` when the rollover was detected.
    event EpochAdvanced(uint256 indexed previousEpochId, uint256 indexed newEpochId, uint256 timestamp);

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    /// @param manager The v4 PoolManager this hook is wired to.
    /// @param epochLengthSeconds Duration of one epoch in seconds. Pass `0` for `DEFAULT_EPOCH_LENGTH`.
    constructor(IPoolManager manager, uint256 epochLengthSeconds) ImmutableState(manager) {
        epochLength = epochLengthSeconds == 0 ? DEFAULT_EPOCH_LENGTH : epochLengthSeconds;
        IHooks(this).validateHookPermissions(hookPermissions());
    }

    /// @notice Declares which hook callbacks this contract uses.
    /// @dev v4 checks the deployed address against this struct in the constructor.
    ///      Only `afterSwap` is enabled for v1.
    /// @return permissions Flag struct consumed by `Hooks.validateHookPermissions`.
    function hookPermissions() public pure returns (Hooks.Permissions memory permissions) {
        permissions = Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // -------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------

    /// @notice Returns all-time net ETH flow (inflow minus outflow).
    /// @dev Derived on read. We never store a single signed counter in storage.
    /// @return netFlow Signed net flow. Positive means more ETH entered than left.
    function getNetFlow() external view returns (int256 netFlow) {
        netFlow = int256(totalEthInflow) - int256(totalEthOutflow);
    }

    /// @notice Returns the epoch id for the current block timestamp.
    /// @return epochId `block.timestamp / epochLength`.
    function getCurrentEpoch() public view returns (uint256 epochId) {
        epochId = block.timestamp / epochLength;
    }

    /// @notice Returns gross inflow and outflow for one epoch window.
    /// @param epochId Epoch to query. Use `getCurrentEpoch()` for the active window.
    /// @return inflow ETH that entered the pool during the epoch.
    /// @return outflow ETH that left the pool during the epoch.
    function getEpochFlows(uint256 epochId) external view returns (uint256 inflow, uint256 outflow) {
        inflow = epochEthInflow[epochId];
        outflow = epochEthOutflow[epochId];
    }

    // -------------------------------------------------------------------------
    // Disabled hooks (required by IHooks, never called with our permission set)
    // -------------------------------------------------------------------------

    /// @inheritdoc IHooks
    function beforeInitialize(address, PoolKey calldata, uint160) external pure override returns (bytes4) {
        return IHooks.beforeInitialize.selector;
    }

    /// @inheritdoc IHooks
    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure override returns (bytes4) {
        return IHooks.afterInitialize.selector;
    }

    /// @inheritdoc IHooks
    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        return IHooks.beforeAddLiquidity.selector;
    }

    /// @inheritdoc IHooks
    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure override returns (bytes4, BalanceDelta) {
        return (IHooks.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    /// @inheritdoc IHooks
    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        return IHooks.beforeRemoveLiquidity.selector;
    }

    /// @inheritdoc IHooks
    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure override returns (bytes4, BalanceDelta) {
        return (IHooks.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    /// @inheritdoc IHooks
    function beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        external
        pure
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    // -------------------------------------------------------------------------
    // afterSwap
    // -------------------------------------------------------------------------

    /// @inheritdoc IHooks
    /// @dev Parses the executed BalanceDelta, updates counters, and emits `SwapTracked`.
    ///      Skips swaps with no native ETH leg or zero ETH movement.
    function afterSwap(
        address swapper,
        PoolKey calldata poolKey,
        SwapParams calldata,
        BalanceDelta balanceDelta,
        bytes calldata
    ) external override onlyPoolManager returns (bytes4, int128) {
        int128 ethDelta = _readEthDelta(poolKey, balanceDelta);
        if (ethDelta == 0) {
            return (IHooks.afterSwap.selector, 0);
        }

        uint256 epochId = getCurrentEpoch();
        _emitEpochRolloverIfNeeded(epochId);

        if (ethDelta < 0) {
            _recordInflow(epochId, swapper, uint256(uint128(-ethDelta)));
        } else {
            _recordOutflow(epochId, swapper, uint256(uint128(ethDelta)));
        }

        return (IHooks.afterSwap.selector, 0);
    }

    // -------------------------------------------------------------------------
    // Internal tracking helpers
    // -------------------------------------------------------------------------

    /// @dev Reads the ETH leg from BalanceDelta, regardless of currency0/currency1 ordering.
    ///
    /// v4 reports delta from the swapper's perspective (see IHooks.afterSwap):
    ///   negative = swapper pays that token, so ETH enters the pool  (inflow)
    ///   positive = swapper receives that token, so ETH leaves the pool (outflow)
    ///
    /// @return ethDelta Signed ETH delta for the swapper. Zero if the pool has no native ETH side.
    function _readEthDelta(PoolKey calldata poolKey, BalanceDelta balanceDelta) private pure returns (int128 ethDelta) {
        if (Currency.unwrap(poolKey.currency0) == address(0)) {
            return balanceDelta.amount0();
        }
        if (Currency.unwrap(poolKey.currency1) == address(0)) {
            return balanceDelta.amount1();
        }
    }

    /// @dev Increments all-time and epoch inflow counters, then emits `SwapTracked`.
    function _recordInflow(uint256 epochId, address swapper, uint256 amount) private {
        totalEthInflow += amount;
        epochEthInflow[epochId] += amount;
        emit SwapTracked(epochId, FlowDirection.Inflow, amount, swapper, block.timestamp);
    }

    /// @dev Increments all-time and epoch outflow counters, then emits `SwapTracked`.
    function _recordOutflow(uint256 epochId, address swapper, uint256 amount) private {
        totalEthOutflow += amount;
        epochEthOutflow[epochId] += amount;
        emit SwapTracked(epochId, FlowDirection.Outflow, amount, swapper, block.timestamp);
    }

    /// @dev Emits `EpochAdvanced` once when the first swap crosses into a new epoch window.
    ///      Does not fire on the very first swap ever (when `lastRecordedEpoch` is zero).
    function _emitEpochRolloverIfNeeded(uint256 epochId) private {
        if (lastRecordedEpoch != 0 && epochId > lastRecordedEpoch) {
            emit EpochAdvanced(lastRecordedEpoch, epochId, block.timestamp);
        }
        lastRecordedEpoch = epochId;
    }

    // -------------------------------------------------------------------------
    // Remaining IHooks stubs
    // -------------------------------------------------------------------------

    /// @inheritdoc IHooks
    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        return IHooks.beforeDonate.selector;
    }

    /// @inheritdoc IHooks
    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        return IHooks.afterDonate.selector;
    }
}
