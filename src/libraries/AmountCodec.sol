// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Converts product USDT cents (2 decimals) to ERC-20 raw units.
library AmountCodec {
    error InvalidDecimals();

    /// @dev raw = cents * 10^(tokenDecimals - 2). Requires tokenDecimals >= 2.
    function centsToRaw(uint256 cents, uint8 tokenDecimals) internal pure returns (uint256) {
        if (tokenDecimals < 2) revert InvalidDecimals();
        return cents * (10 ** (tokenDecimals - 2));
    }
}
