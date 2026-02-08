// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {ReturnDeltaRebalancer} from "../src/ReturnDeltaRebalancer.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";

contract DeployScript is Script {
    // Unichain Sepolia PoolManager address
    // TODO: Update this with the actual Unichain Sepolia PoolManager address
    address constant POOL_MANAGER = 0x00b036b58a818b1bc34d502d3fe730db729e62ac; // Unichain Sepolia

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        // Deploy the hook
        ReturnDeltaRebalancer hook = new ReturnDeltaRebalancer(IPoolManager(POOL_MANAGER));

        console2.log("ReturnDeltaRebalancer deployed at:", address(hook));
        console2.log("Pool Manager:", POOL_MANAGER);

        // Log hook permissions for verification
        Hooks.Permissions memory permissions = hook.getHookPermissions();
        console2.log("Hook Permissions:");
        console2.log("  beforeSwap:", permissions.beforeSwap);
        console2.log("  afterSwap:", permissions.afterSwap);
        console2.log("  beforeSwapReturnDelta:", permissions.beforeSwapReturnDelta);
        console2.log("  afterSwapReturnDelta:", permissions.afterSwapReturnDelta);

        vm.stopBroadcast();
    }
}
