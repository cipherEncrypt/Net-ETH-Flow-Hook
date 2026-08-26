// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {HookMiner} from "v4-periphery/test/shared/HookMiner.sol";

import {NetEthFlowHook} from "../src/NetEthFlowHook.sol";

/// @notice Local Foundry tests for NetEthFlowHook.
contract NetEthFlowHookTest is Test, Deployers {
    NetEthFlowHook internal hook;

    uint256 internal constant EPOCH_LENGTH = 1 days;
    uint256 internal constant POOL_ETH = 10 ether;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        hook = _deployHook(EPOCH_LENGTH);
        _initNativePool();
    }

    // -------------------------------------------------------------------------
    // Phase 5: single-direction swap tracking
    // -------------------------------------------------------------------------

    function test_ethInflow_countsTraderSellingEth() public {
        uint256 inflowBefore = hook.totalEthInflow();

        swapNativeInput(nativeKey, true, -100, ZERO_BYTES, 100);

        assertEq(hook.totalEthInflow(), inflowBefore + 100, "inflow counter");
        assertEq(hook.totalEthOutflow(), 0, "no outflow yet");
        assertEq(hook.getNetFlow(), int256(100), "net flow");
    }

    function test_ethOutflow_countsTraderBuyingEth() public {
        uint256 outflowBefore = hook.totalEthOutflow();

        // Exact-output swap: trader receives 100 wei ETH from the pool.
        swapNativeInput(nativeKey, false, 100, ZERO_BYTES, 0);

        assertEq(hook.totalEthOutflow(), outflowBefore + 100, "outflow counter");
        assertEq(hook.totalEthInflow(), 0, "no inflow");
        assertEq(hook.getNetFlow(), int256(-100), "net flow");
    }

    // -------------------------------------------------------------------------
    // Phase 6: expanded coverage
    // -------------------------------------------------------------------------

    function test_multipleSwaps_updateCumulativeAndEpochTotals() public {
        uint256 epochId = hook.getCurrentEpoch();

        swapNativeInput(nativeKey, true, -100, ZERO_BYTES, 100);
        swapNativeInput(nativeKey, true, -50, ZERO_BYTES, 50);
        swapNativeInput(nativeKey, false, 30, ZERO_BYTES, 0);

        assertEq(hook.totalEthInflow(), 150);
        assertEq(hook.totalEthOutflow(), 30);
        assertEq(hook.getNetFlow(), int256(120));

        (uint256 epochInflow, uint256 epochOutflow) = hook.getEpochFlows(epochId);
        assertEq(epochInflow, 150);
        assertEq(epochOutflow, 30);
    }

    function test_epochRollover_keepsOldEpochReadable() public {
        NetEthFlowHook shortEpochHook = _deployHook(100);
        (nativeKey,) = initPoolAndAddLiquidityETH(
            CurrencyLibrary.ADDRESS_ZERO, currency1, shortEpochHook, 3000, SQRT_PRICE_1_1, POOL_ETH
        );
        hook = shortEpochHook;

        swapNativeInput(nativeKey, true, -100, ZERO_BYTES, 100);
        uint256 firstEpoch = hook.getCurrentEpoch();
        assertEq(hook.epochEthInflow(firstEpoch), 100);

        vm.warp(block.timestamp + 101);

        swapNativeInput(nativeKey, true, -200, ZERO_BYTES, 200);
        uint256 secondEpoch = hook.getCurrentEpoch();
        assertGt(secondEpoch, firstEpoch);

        assertEq(hook.epochEthInflow(firstEpoch), 100, "old epoch preserved");
        assertEq(hook.epochEthInflow(secondEpoch), 200, "new epoch starts clean");
        assertEq(hook.epochEthOutflow(secondEpoch), 0);
    }

    function test_firstSwap_doesNotEmitEpochAdvanced() public {
        vm.recordLogs();
        swapNativeInput(nativeKey, true, -100, ZERO_BYTES, 100);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 epochAdvancedTopic = keccak256("EpochAdvanced(uint256,uint256,uint256)");

        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != epochAdvancedTopic, "first swap should not roll epoch");
        }

        assertEq(hook.totalEthInflow(), 100);
    }

    function testFuzz_ethInflowAmount(uint128 amount) public {
        amount = uint128(bound(amount, 1, 0.01 ether));

        uint256 inflowBefore = hook.totalEthInflow();
        BalanceDelta delta = swapNativeInput(nativeKey, true, -int256(uint256(amount)), ZERO_BYTES, amount);
        uint256 executedEthIn = uint256(uint128(-delta.amount0()));

        assertEq(hook.totalEthInflow(), inflowBefore + executedEthIn);
        assertEq(hook.totalEthOutflow(), 0);
    }

    // -------------------------------------------------------------------------
    // Deploy helpers
    // -------------------------------------------------------------------------

    function _initNativePool() internal {
        (nativeKey,) =
            initPoolAndAddLiquidityETH(CurrencyLibrary.ADDRESS_ZERO, currency1, hook, 3000, SQRT_PRICE_1_1, POOL_ETH);
    }

    function _deployHook(uint256 epochLengthSeconds) internal returns (NetEthFlowHook deployed) {
        uint160 hookFlags = uint160(Hooks.AFTER_SWAP_FLAG);
        bytes memory constructorArgs = abi.encode(manager, epochLengthSeconds);

        (address expectedAddress, bytes32 salt) =
            HookMiner.find(address(this), hookFlags, type(NetEthFlowHook).creationCode, constructorArgs);

        deployed = new NetEthFlowHook{salt: salt}(manager, epochLengthSeconds);
        assertEq(address(deployed), expectedAddress, "hook address flags mismatch");
    }
}
