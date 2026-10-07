// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";

import {BizSwap} from "../src/BizSwap.sol";
import {IBizSwap} from "../src/interfaces/IBizSwap.sol";

/// @notice Read-only smoke checks against a deployed BizSwap Arc Mainnet proxy.
contract SmokeMainnet is Script {
    uint256 internal constant CHAIN_ID = 5042;
    address internal constant EXPECTED_USDC = 0x3600000000000000000000000000000000000000;

    function run() external view {
        require(block.chainid == CHAIN_ID, "SmokeMainnet: wrong chainId (expected 5042 for Arc Mainnet)");

        address proxyAddr = vm.envAddress("PROXY_ADDRESS");
        BizSwap biz = BizSwap(proxyAddr);

        console2.log("Proxy:        ", proxyAddr);
        console2.log("Name:         ", biz.name());
        console2.log("USDC:         ", biz.usdc());
        console2.log("Revenue:      ", biz.revenueWallet());
        console2.log("Fee bps:      ", biz.PLATFORM_FEE_BPS());
        console2.log("Next tokenId: ", biz.nextTokenId());
        console2.log("Pool USDC:    ", biz.distributionPoolUsdcRaw());

        require(biz.usdc() == EXPECTED_USDC, "unexpected USDC address");
        require(biz.PLATFORM_FEE_BPS() == 50, "unexpected fee bps");

        for (uint8 i = 0; i < 3; i++) {
            IBizSwap.Instrument memory inst = biz.instruments(i);
            console2.log("--- instrument", i);
            console2.log("  configured", inst.configured);
            console2.log("  supplyCap", inst.supplyCap);
            console2.log("  minBuyIn", inst.minBuyInCents);
            require(inst.configured, "instrument not configured");
        }
    }
}
