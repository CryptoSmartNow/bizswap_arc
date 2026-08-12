// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IBizSwap
/// @notice BizSwap RWA instruments on BOT Chain — Phase 1 registry + Phase 2 USDT distributions.
interface IBizSwap {
    enum Status {
        Vesting,
        Active,
        Redeemed
    }

    struct Instrument {
        bool configured;
        uint256 supplyCap;
        uint256 currentSupply;
        uint256 minBuyInCents;
        uint256 totalInvestedCents;
        uint256 totalFeesCents;
    }

    struct Certificate {
        uint8 instrumentId;
        uint256 amountCents;
        uint256 feeCents;
        uint256 entitlementBps;
        uint64 purchaseTime;
        uint64 vestEnd;
        uint64 yieldStart;
        Status status;
        uint32 serial;
        bytes32 cycle;
    }

    struct YieldRound {
        uint256 totalUsdtRaw;
        uint256 claimedUsdtRaw;
        uint64 openedAt;
        bool closed;
    }

    event CertificateMinted(
        address indexed to,
        uint256 indexed tokenId,
        uint8 indexed instrumentId,
        uint256 amountCents,
        uint256 feeCents,
        uint32 serial,
        Status status,
        bytes32 cycle
    );

    event CertificateUnlocked(uint256 indexed tokenId, uint32 serial);

    event CertificateRedeemed(uint256 indexed tokenId);

    event InstrumentConfigured(uint8 indexed instrumentId, uint256 supplyCap, uint256 minBuyInCents);

    event RevenueWalletUpdated(address indexed revenueWallet);

    event SchedulesConfigured(
        uint64 creditFirstPayment,
        uint64 creditWeekSeconds,
        uint8 creditWeekCount,
        uint256 creditTotalReturnBps,
        uint64 bondQuarterSeconds,
        uint8 bondMaxQuarters,
        uint256 bondQuarterBps
    );

    event DistributionDeposited(address indexed from, uint256 usdtRaw, uint256 poolBalance);

    event YieldRoundOpened(uint256 indexed roundId, uint256 usdtRaw, uint64 openedAt);

    event Claimed(address indexed to, uint256 indexed tokenId, uint8 instrumentId, uint256 usdtRaw);

    error ZeroAddress();
    error InvalidInstrument();
    error InstrumentNotConfigured();
    error CapExceeded();
    error BelowMinBuyIn();
    error TransferWhileVesting();
    error StillVesting();
    error EmptyURI();
    error InvalidSupplyCap();
    error ClaimsPaused();
    error NothingToClaim();
    error YieldNotStarted();
    error NotCertificateOwner();
    error RoundAlreadyClaimed();
    error InvalidRound();
    error InsufficientPool();
    error AlreadyRedeemed();
    error ZeroAmount();
    error InvalidSchedule();

    function PLATFORM_FEE_BPS() external view returns (uint16);

    function BPS_DENOMINATOR() external view returns (uint16);

    function MINTER_ROLE() external view returns (bytes32);

    function DISTRIBUTOR_ROLE() external view returns (bytes32);

    function revenueWallet() external view returns (address);

    function usdt() external view returns (address);

    function nextTokenId() external view returns (uint256);

    function instruments(uint8 instrumentId) external view returns (Instrument memory);

    function certificates(uint256 tokenId) external view returns (Certificate memory);

    function quoteFee(uint8 instrumentId, uint256 netAmountCents) external pure returns (uint256 feeCents);

    function quoteGross(uint8 instrumentId, uint256 netAmountCents) external pure returns (uint256 grossCents);

    function configureInstrument(uint8 instrumentId, uint256 supplyCap, uint256 minBuyInCents) external;

    function mintCertificate(
        address to,
        uint8 instrumentId,
        uint256 netAmountCents,
        uint256 entitlementBps,
        uint64 vestEnd,
        uint64 yieldStart,
        bytes32 cycle,
        string calldata uri
    ) external returns (uint256 tokenId);

    function unlock(uint256 tokenId) external;

    function setRevenueWallet(address newRevenueWallet) external;

    function pause() external;

    function unpause() external;

    function setClaimsPaused(bool paused) external;

    function depositDistributionUsdt(uint256 usdtRaw) external;

    function openYieldRound(uint256 usdtRaw) external returns (uint256 roundId);

    function claim(uint256 tokenId) external returns (uint256 usdtRawPaid);

    function claimable(uint256 tokenId) external view returns (uint256 usdtRaw);
}
