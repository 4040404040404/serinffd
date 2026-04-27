// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";

// Import the contract — use a path relative to the repo root
import "../FlashArbLeverage.sol";

/**
 * @title  DeployFlashArbLeverage
 * @notice Foundry broadcast script that deploys FlashArbLeverage and
 *         prints the deployed address.
 *
 * Usage:
 *   forge script script/Deploy.s.sol \
 *     --rpc-url $ETH_RPC_URL \
 *     --private-key $PRIVATE_KEY \
 *     --broadcast \
 *     --verify \
 *     -vvvv
 */
contract DeployFlashArbLeverage is Script {
    function run() external returns (FlashArbLeverage deployed) {
        vm.startBroadcast();
        deployed = new FlashArbLeverage();
        vm.stopBroadcast();

        console2.log("FlashArbLeverage deployed at:", address(deployed));
        console2.log("Owner:", deployed.owner());
    }
}
