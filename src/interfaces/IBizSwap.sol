// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IBizSwap
/// @notice BizSwap RWA instruments on Arc Network — Phase 1 registry + Phase 2 USDC distributions.
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
        uint256 totalUsdcRaw;
        uint256 claimedUsdcRaw;
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

    event DistributionDeposited(address indexed from, uint8 indexed instrumentId, uint256 usdcRaw, uint256 poolBalance);

    event YieldRoundOpened(uint256 indexed roundId, uint256 usdcRaw, uint64 openedAt);

    event YieldRoundClosed(uint256 indexed roundId);

    event SchedulesLocked();

    event ClaimsPausedChanged(bool paused);

    event Claimed(address indexed to, uint256 indexed tokenId, uint8 instrumentId, uint256 usdcRaw);

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
    error EntitlementTooHigh();
    error RoundAlreadyClosed();
    error SchedulesAreLocked();
    error MaxYieldRoundsReached();

    function PLATFORM_FEE_BPS() external view returns (uint16);

    function BPS_DENOMINATOR() external view returns (uint16);

    function MAX_YIELD_ROUNDS() external view returns (uint256);

    function MINTER_ROLE() external view returns (bytes32);

    function DISTRIBUTOR_ROLE() external view returns (bytes32);

    function UPGRADER_ROLE() external view returns (bytes32);

    function revenueWallet() external view returns (address);

    function usdc() external view returns (address);

    function nextTokenId() external view returns (uint256);

    function distributionPoolUsdcRaw() external view returns (uint256);

    function creditPoolUsdcRaw() external view returns (uint256);

    function bondPoolUsdcRaw() external view returns (uint256);

    function totalYieldEntitlementBps() external view returns (uint256);

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

    function depositDistributionUsdc(uint8 instrumentId, uint256 usdcRaw) external;

    function openYieldRound(uint256 usdcRaw) external returns (uint256 roundId);

    function closeYieldRound(uint256 roundId) external;

    function lockSchedules() external;

    function claim(uint256 tokenId) external returns (uint256 usdcRawPaid);

    function claim(uint256 tokenId, uint256 maxRoundsToProcess) external returns (uint256 usdcRawPaid);

    function claimable(uint256 tokenId) external view returns (uint256 usdcRaw);

    function claimable(uint256 tokenId, uint256 maxRoundsToProcess) external view returns (uint256 usdcRaw);
}
