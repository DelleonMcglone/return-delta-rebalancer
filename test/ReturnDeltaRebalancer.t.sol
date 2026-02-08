// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ReturnDeltaRebalancer} from "../src/ReturnDeltaRebalancer.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";

contract ReturnDeltaRebalancerTest is Test {
    using PoolIdLibrary for PoolKey;

    ReturnDeltaRebalancer hook;

    // Mock PoolManager address (replace with actual address for testnet)
    address constant POOL_MANAGER = address(0x1);

    function setUp() public {
        // Deploy the hook
        hook = new ReturnDeltaRebalancer(IPoolManager(POOL_MANAGER));
    }

    function test_HookPermissions() public {
        Hooks.Permissions memory permissions = hook.getHookPermissions();

        assertTrue(permissions.afterInitialize);
        assertTrue(permissions.afterAddLiquidity);
        assertTrue(permissions.afterRemoveLiquidity);
        assertTrue(permissions.beforeSwap);
        assertTrue(permissions.afterSwap);
        assertTrue(permissions.beforeSwapReturnDelta);
        assertTrue(permissions.afterSwapReturnDelta);
    }

    function test_Constants() public {
        assertEq(hook.REBALANCE_THRESHOLD(), -200);
        assertEq(hook.FEE_CAPTURE_BPS(), 100);
    }

    function test_InitialState() public {
        // Create a dummy pool key
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0x2)),
            currency1: Currency.wrap(address(0x3)),
            fee: 3000,
            tickSpacing: 60,
            hooks: hook
        });

        PoolId poolId = key.toId();

        // Check initial reserves are zero
        ReturnDeltaRebalancer.InternalReserves memory reserves = hook.getReserves(poolId);
        assertEq(reserves.amount0, 0);
        assertEq(reserves.amount1, 0);
    }
}
