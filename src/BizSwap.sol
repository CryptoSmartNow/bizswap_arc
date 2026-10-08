// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import {
    ERC721URIStorageUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721URIStorageUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IBizSwap} from "./interfaces/IBizSwap.sol";
import {AmountCodec} from "./libraries/AmountCodec.sol";

/// @title BizSwap
/// @notice Upgradeable RWA certificate registry + USDC distributions on Arc Network.
/// @dev Phase 1: mint/vest/fee. Phase 2: yield rounds, credit weekly, bond quarterly claims.
///      Purchase funds are off-chain; only distribution USDC is custody'd here.
///      Arc Dual-Interface Guard: Arc native gas is 18-decimal USDC. BizSwap explicitly interacts
///      with the 6-decimal ERC-20 USDC interface (canonical predeploy 0x3600000000000000000000000000000000000000)
///      for all balances and pool accounting, and rejects direct native value transfers.
contract BizSwap is
    Initializable,
    ERC721Upgradeable,
    ERC721URIStorageUpgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable,
    IBizSwap
{
    using SafeERC20 for IERC20;

    uint16 public constant PLATFORM_FEE_BPS = 50;
    uint16 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant MAX_YIELD_ROUNDS = 24;

    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant DISTRIBUTOR_ROLE = keccak256("DISTRIBUTOR_ROLE");

    uint8 public constant MAX_INSTRUMENT_ID = 2;
    uint8 public constant INSTRUMENT_BIZ_YIELD = 0;
    uint8 public constant INSTRUMENT_BIZ_CREDIT = 1;
    uint8 public constant INSTRUMENT_BIZ_BOND = 2;

    address public revenueWallet;
    address public usdc;
    uint8 public usdcDecimals;
    uint256 public nextTokenId;

    bool public claimsPaused;
    uint256 public creditPoolUsdcRaw;
    uint256 public bondPoolUsdcRaw;
    uint256 public nextYieldRoundId;
    uint256 public totalYieldEntitlementBps;

    // Credit schedule (product defaults: Jun 15 2026, 12 weeks, 104.04% total)
    uint64 public creditFirstPayment;
    uint64 public creditWeekSeconds;
    uint8 public creditWeekCount;
    uint256 public creditTotalReturnBps;

    // Bond schedule (2.5% per quarter, 90-day quarters)
    uint64 public bondQuarterSeconds;
    uint8 public bondMaxQuarters;
    uint256 public bondQuarterBps;

    bool public schedulesLocked;

    mapping(uint8 => Instrument) private _instruments;
    mapping(uint256 => Certificate) private _certificates;
    mapping(uint256 => YieldRound) private _yieldRounds;
    mapping(uint256 => mapping(uint256 => bool)) private _yieldRoundClaimed;
    mapping(uint256 => uint8) private _nextCreditWeek;
    mapping(uint256 => uint8) private _nextBondQuarter;
    mapping(uint256 => uint256) private _lastClaimedYieldRound;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize proxy state and default Phase 2 schedules.
    function initialize(
        address admin,
        address minter,
        address revenueWallet_,
        address usdc_,
        string memory name_,
        string memory symbol_
    ) external initializer {
        if (admin == address(0) || minter == address(0) || revenueWallet_ == address(0) || usdc_ == address(0)) {
            revert ZeroAddress();
        }

        __ERC721_init(name_, symbol_);
        __ERC721URIStorage_init();
        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(MINTER_ROLE, minter);
        _grantRole(DISTRIBUTOR_ROLE, admin);

        revenueWallet = revenueWallet_;
        usdc = usdc_;
        usdcDecimals = 6;
        nextTokenId = 1;
        nextYieldRoundId = 1;

        // Product schedule defaults (UTC)
        creditFirstPayment = 1_781_481_600; // 2026-06-15 00:00:00 UTC
        creditWeekSeconds = 7 days;
        creditWeekCount = 12;
        creditTotalReturnBps = 10_404; // 104.04% of principal

        bondQuarterSeconds = 90 days;
        bondMaxQuarters = 8;
        bondQuarterBps = 250; // 2.5% of principal per quarter

        // Default instruments setup
        _instruments[INSTRUMENT_BIZ_YIELD] = Instrument({
            configured: true,
            supplyCap: 1000,
            currentSupply: 0,
            minBuyInCents: 1_000,
            totalInvestedCents: 0,
            totalFeesCents: 0
        });
        emit InstrumentConfigured(INSTRUMENT_BIZ_YIELD, 1000, 1_000);

        _instruments[INSTRUMENT_BIZ_CREDIT] = Instrument({
            configured: true,
            supplyCap: 1000,
            currentSupply: 0,
            minBuyInCents: 10_000,
            totalInvestedCents: 0,
            totalFeesCents: 0
        });
        emit InstrumentConfigured(INSTRUMENT_BIZ_CREDIT, 1000, 10_000);

        _instruments[INSTRUMENT_BIZ_BOND] = Instrument({
            configured: true,
            supplyCap: 1000,
            currentSupply: 0,
            minBuyInCents: 100_000,
            totalInvestedCents: 0,
            totalFeesCents: 0
        });
        emit InstrumentConfigured(INSTRUMENT_BIZ_BOND, 1000, 100_000);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Views
    // ═════════════════════════════════════════════════════════════════════════

    function instruments(uint8 instrumentId) external view returns (Instrument memory) {
        return _instruments[instrumentId];
    }

    function certificates(uint256 tokenId) external view returns (Certificate memory) {
        _requireOwned(tokenId);
        return _certificates[tokenId];
    }

    function yieldRounds(uint256 roundId) external view returns (YieldRound memory) {
        return _yieldRounds[roundId];
    }

    function nextCreditWeek(uint256 tokenId) external view returns (uint8) {
        return _nextCreditWeek[tokenId];
    }

    function nextBondQuarter(uint256 tokenId) external view returns (uint8) {
        return _nextBondQuarter[tokenId];
    }

    /// @notice Platform fee: 0.5% of net for Yield/Bond; 0 for Credit.
    function quoteFee(uint8 instrumentId, uint256 netAmountCents) public pure returns (uint256 feeCents) {
        if (instrumentId == INSTRUMENT_BIZ_CREDIT) {
            return 0;
        }
        if (instrumentId > MAX_INSTRUMENT_ID) {
            return 0;
        }
        feeCents = (netAmountCents * PLATFORM_FEE_BPS) / BPS_DENOMINATOR;
    }

    function quoteGross(uint8 instrumentId, uint256 netAmountCents) public pure returns (uint256 grossCents) {
        grossCents = netAmountCents + quoteFee(instrumentId, netAmountCents);
    }

    function distributionPoolUsdcRaw() public view returns (uint256) {
        return creditPoolUsdcRaw + bondPoolUsdcRaw;
    }

    function claimable(uint256 tokenId) public view returns (uint256 usdcRaw) {
        return claimable(tokenId, 0);
    }

    function claimable(uint256 tokenId, uint256 maxRoundsToProcess) public view returns (uint256 usdcRaw) {
        _requireOwned(tokenId);
        Certificate storage cert = _certificates[tokenId];
        if (cert.status == Status.Redeemed) return 0;
        if (cert.status == Status.Vesting) return 0;

        if (cert.instrumentId == INSTRUMENT_BIZ_YIELD) {
            return _claimableYield(tokenId, cert, maxRoundsToProcess);
        }
        if (cert.instrumentId == INSTRUMENT_BIZ_CREDIT) {
            (usdcRaw,) = _creditDue(tokenId, cert);
            return usdcRaw;
        }
        if (cert.instrumentId == INSTRUMENT_BIZ_BOND) {
            (usdcRaw,) = _bondDue(tokenId, cert);
            return usdcRaw;
        }
        return 0;
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Admin / config
    // ═════════════════════════════════════════════════════════════════════════

    function configureInstrument(uint8 instrumentId, uint256 supplyCap, uint256 minBuyInCents)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (instrumentId > MAX_INSTRUMENT_ID) revert InvalidInstrument();
        if (supplyCap == 0) revert InvalidSupplyCap();

        Instrument storage inst = _instruments[instrumentId];
        if (inst.configured && inst.currentSupply > 0) {
            if (supplyCap < inst.currentSupply) revert InvalidSupplyCap();
            inst.supplyCap = supplyCap;
            inst.minBuyInCents = minBuyInCents;
        } else {
            inst.configured = true;
            inst.supplyCap = supplyCap;
            inst.minBuyInCents = minBuyInCents;
        }

        emit InstrumentConfigured(instrumentId, supplyCap, minBuyInCents);
    }

    function configureSchedules(
        uint64 creditFirstPayment_,
        uint64 creditWeekSeconds_,
        uint8 creditWeekCount_,
        uint256 creditTotalReturnBps_,
        uint64 bondQuarterSeconds_,
        uint8 bondMaxQuarters_,
        uint256 bondQuarterBps_
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (schedulesLocked) revert SchedulesAreLocked();
        if (creditWeekSeconds_ == 0 || creditWeekCount_ == 0 || creditTotalReturnBps_ == 0) {
            revert InvalidSchedule();
        }
        if (bondQuarterSeconds_ == 0 || bondMaxQuarters_ == 0 || bondQuarterBps_ == 0) {
            revert InvalidSchedule();
        }

        creditFirstPayment = creditFirstPayment_;
        creditWeekSeconds = creditWeekSeconds_;
        creditWeekCount = creditWeekCount_;
        creditTotalReturnBps = creditTotalReturnBps_;
        bondQuarterSeconds = bondQuarterSeconds_;
        bondMaxQuarters = bondMaxQuarters_;
        bondQuarterBps = bondQuarterBps_;

        emit SchedulesConfigured(
            creditFirstPayment_,
            creditWeekSeconds_,
            creditWeekCount_,
            creditTotalReturnBps_,
            bondQuarterSeconds_,
            bondMaxQuarters_,
            bondQuarterBps_
        );
    }

    /// @notice Permanently lock schedule parameters. One-way operation.
    function lockSchedules() external onlyRole(DEFAULT_ADMIN_ROLE) {
        schedulesLocked = true;
        emit SchedulesLocked();
    }

    function setRevenueWallet(address newRevenueWallet) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newRevenueWallet == address(0)) revert ZeroAddress();
        revenueWallet = newRevenueWallet;
        emit RevenueWalletUpdated(newRevenueWallet);
    }

    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    function setClaimsPaused(bool paused) external onlyRole(DEFAULT_ADMIN_ROLE) {
        claimsPaused = paused;
        emit ClaimsPausedChanged(paused);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Phase 1 — mint + unlock
    // ═════════════════════════════════════════════════════════════════════════

    function mintCertificate(
        address to,
        uint8 instrumentId,
        uint256 netAmountCents,
        uint256 entitlementBps,
        uint64 vestEnd,
        uint64 yieldStart,
        bytes32 cycle,
        string calldata uri
    ) external onlyRole(MINTER_ROLE) whenNotPaused returns (uint256 tokenId) {
        if (to == address(0)) revert ZeroAddress();
        if (instrumentId > MAX_INSTRUMENT_ID) revert InvalidInstrument();
        if (bytes(uri).length == 0) revert EmptyURI();

        Instrument storage inst = _instruments[instrumentId];
        if (!inst.configured) revert InstrumentNotConfigured();
        if (inst.currentSupply >= inst.supplyCap) revert CapExceeded();
        if (netAmountCents < inst.minBuyInCents) revert BelowMinBuyIn();
        if (instrumentId == INSTRUMENT_BIZ_YIELD) {
            if (totalYieldEntitlementBps + entitlementBps > BPS_DENOMINATOR) revert EntitlementTooHigh();
            totalYieldEntitlementBps += entitlementBps;
        } else {
            if (entitlementBps > BPS_DENOMINATOR) revert EntitlementTooHigh();
        }

        uint256 feeCents = quoteFee(instrumentId, netAmountCents);

        unchecked {
            inst.currentSupply += 1;
        }
        inst.totalInvestedCents += netAmountCents;
        inst.totalFeesCents += feeCents;

        tokenId = nextTokenId;
        unchecked {
            nextTokenId = tokenId + 1;
        }

        Status status = instrumentId == INSTRUMENT_BIZ_CREDIT ? Status.Active : Status.Vesting;

        _certificates[tokenId] = Certificate({
            instrumentId: instrumentId,
            amountCents: netAmountCents,
            feeCents: feeCents,
            entitlementBps: entitlementBps,
            purchaseTime: uint64(block.timestamp),
            vestEnd: vestEnd,
            yieldStart: yieldStart,
            status: status,
            serial: uint32(inst.currentSupply),
            cycle: cycle
        });

        _safeMint(to, tokenId);
        _setTokenURI(tokenId, uri);

        emit CertificateMinted(
            to, tokenId, instrumentId, netAmountCents, feeCents, uint32(inst.currentSupply), status, cycle
        );
    }

    function unlock(uint256 tokenId) external {
        _requireOwned(tokenId);
        Certificate storage cert = _certificates[tokenId];

        if (cert.status != Status.Vesting) {
            return;
        }
        if (block.timestamp < cert.vestEnd) {
            revert StillVesting();
        }

        cert.status = Status.Active;
        emit CertificateUnlocked(tokenId, cert.serial);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Phase 2 — fund + claim
    // ═════════════════════════════════════════════════════════════════════════

    /// @notice Pull USDC into the Credit or Bond distribution pool.
    function depositDistributionUsdc(uint8 instrumentId, uint256 usdcRaw)
        external
        onlyRole(DISTRIBUTOR_ROLE)
        nonReentrant
    {
        if (usdcRaw == 0) revert ZeroAmount();
        if (instrumentId == INSTRUMENT_BIZ_CREDIT) {
            IERC20(usdc).safeTransferFrom(msg.sender, address(this), usdcRaw);
            creditPoolUsdcRaw += usdcRaw;
            emit DistributionDeposited(msg.sender, instrumentId, usdcRaw, creditPoolUsdcRaw);
        } else if (instrumentId == INSTRUMENT_BIZ_BOND) {
            IERC20(usdc).safeTransferFrom(msg.sender, address(this), usdcRaw);
            bondPoolUsdcRaw += usdcRaw;
            emit DistributionDeposited(msg.sender, instrumentId, usdcRaw, bondPoolUsdcRaw);
        } else {
            revert InvalidInstrument();
        }
    }

    /// @notice Open a BizYield revenue round funded with USDC (escrowed per round). Max 24 rounds.
    function openYieldRound(uint256 usdcRaw)
        external
        onlyRole(DISTRIBUTOR_ROLE)
        nonReentrant
        returns (uint256 roundId)
    {
        if (usdcRaw == 0) revert ZeroAmount();
        if (nextYieldRoundId > MAX_YIELD_ROUNDS) revert MaxYieldRoundsReached();

        IERC20(usdc).safeTransferFrom(msg.sender, address(this), usdcRaw);

        roundId = nextYieldRoundId;
        unchecked {
            nextYieldRoundId = roundId + 1;
        }

        _yieldRounds[roundId] =
            YieldRound({totalUsdcRaw: usdcRaw, claimedUsdcRaw: 0, openedAt: uint64(block.timestamp), closed: false});

        emit YieldRoundOpened(roundId, usdcRaw, uint64(block.timestamp));
    }

    /// @notice Mark a yield round as closed (bookkeeping). Does NOT block holder claims.
    function closeYieldRound(uint256 roundId) external onlyRole(DISTRIBUTOR_ROLE) {
        YieldRound storage round = _yieldRounds[roundId];
        if (round.totalUsdcRaw == 0) revert InvalidRound();
        if (round.closed) revert RoundAlreadyClosed();

        round.closed = true;
        emit YieldRoundClosed(roundId);
    }

    /// @notice Claim all currently matured unpaid USDC for a certificate.
    function claim(uint256 tokenId) external nonReentrant returns (uint256 usdcRawPaid) {
        return _claim(tokenId, 0);
    }

    /// @notice Claim matured USDC with a bound on the number of yield rounds to process.
    function claim(uint256 tokenId, uint256 maxRoundsToProcess) external nonReentrant returns (uint256 usdcRawPaid) {
        return _claim(tokenId, maxRoundsToProcess);
    }

    function _claim(uint256 tokenId, uint256 maxRoundsToProcess) internal returns (uint256 usdcRawPaid) {
        if (claimsPaused) revert ClaimsPaused();

        address owner = _requireOwned(tokenId);
        if (msg.sender != owner) revert NotCertificateOwner();

        Certificate storage cert = _certificates[tokenId];
        if (cert.status == Status.Redeemed) revert AlreadyRedeemed();
        if (cert.status == Status.Vesting) revert StillVesting();

        if (cert.instrumentId == INSTRUMENT_BIZ_YIELD) {
            usdcRawPaid = _claimYield(tokenId, cert, maxRoundsToProcess);
        } else if (cert.instrumentId == INSTRUMENT_BIZ_CREDIT) {
            usdcRawPaid = _claimCredit(tokenId, cert);
        } else if (cert.instrumentId == INSTRUMENT_BIZ_BOND) {
            usdcRawPaid = _claimBond(tokenId, cert);
        } else {
            revert InvalidInstrument();
        }

        if (usdcRawPaid == 0) revert NothingToClaim();

        IERC20(usdc).safeTransfer(owner, usdcRawPaid);
        emit Claimed(owner, tokenId, cert.instrumentId, usdcRawPaid);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Internal claim engines
    // ═════════════════════════════════════════════════════════════════════════

    function _claimableYield(uint256 tokenId, Certificate storage cert, uint256 maxRoundsToProcess)
        internal
        view
        returns (uint256 due)
    {
        if (block.timestamp < cert.yieldStart) return 0;
        uint256 startRound = _lastClaimedYieldRound[tokenId] + 1;
        if (startRound == 0) startRound = 1;
        uint256 endRound = nextYieldRoundId;
        if (maxRoundsToProcess > 0 && startRound + maxRoundsToProcess < endRound) {
            endRound = startRound + maxRoundsToProcess;
        }
        for (uint256 roundId = startRound; roundId < endRound; ++roundId) {
            if (_yieldRoundClaimed[tokenId][roundId]) continue;
            YieldRound storage round = _yieldRounds[roundId];
            if (round.totalUsdcRaw == 0) continue;
            due += (round.totalUsdcRaw * cert.entitlementBps) / BPS_DENOMINATOR;
        }
    }

    function _claimYield(uint256 tokenId, Certificate storage cert, uint256 maxRoundsToProcess)
        internal
        returns (uint256 due)
    {
        if (block.timestamp < cert.yieldStart) revert YieldNotStarted();

        uint256 startRound = _lastClaimedYieldRound[tokenId] + 1;
        if (startRound == 0) startRound = 1;
        uint256 endRound = nextYieldRoundId;
        if (maxRoundsToProcess > 0 && startRound + maxRoundsToProcess < endRound) {
            endRound = startRound + maxRoundsToProcess;
        }

        for (uint256 roundId = startRound; roundId < endRound; ++roundId) {
            if (_yieldRoundClaimed[tokenId][roundId]) continue;
            YieldRound storage round = _yieldRounds[roundId];
            if (round.totalUsdcRaw == 0) continue;

            uint256 share = (round.totalUsdcRaw * cert.entitlementBps) / BPS_DENOMINATOR;
            if (share == 0) {
                _yieldRoundClaimed[tokenId][roundId] = true;
                continue;
            }

            // Solvency: skip round if it cannot cover this share
            if (round.claimedUsdcRaw + share > round.totalUsdcRaw) continue;

            _yieldRoundClaimed[tokenId][roundId] = true;
            round.claimedUsdcRaw += share;
            due += share;
        }

        // Advance _lastClaimedYieldRound only consecutively so skipped rounds remain eligible for future retry
        while (
            _lastClaimedYieldRound[tokenId] + 1 < nextYieldRoundId
                && _yieldRoundClaimed[tokenId][_lastClaimedYieldRound[tokenId] + 1]
        ) {
            _lastClaimedYieldRound[tokenId]++;
        }
    }

    function _creditDue(uint256 tokenId, Certificate storage cert)
        internal
        view
        returns (uint256 dueRaw, uint8 weeksToPay)
    {
        uint8 start = _nextCreditWeek[tokenId];
        if (start >= creditWeekCount) return (0, 0);

        uint256 totalPayoutCents = (cert.amountCents * creditTotalReturnBps) / BPS_DENOMINATOR;
        uint256 weeklyCents = totalPayoutCents / creditWeekCount;
        uint256 remainderCents = totalPayoutCents % creditWeekCount;
        uint256 weeklyRaw = AmountCodec.centsToRaw(weeklyCents, usdcDecimals);

        for (uint8 w = start; w < creditWeekCount; ++w) {
            uint64 payTime = creditFirstPayment + uint64(uint256(w) * uint256(creditWeekSeconds));
            if (block.timestamp < payTime) break;
            uint256 thisWeekRaw = weeklyRaw;
            if (w == creditWeekCount - 1 && remainderCents > 0) {
                thisWeekRaw += AmountCodec.centsToRaw(remainderCents, usdcDecimals);
            }
            dueRaw += thisWeekRaw;
            weeksToPay++;
        }
    }

    function _claimCredit(uint256 tokenId, Certificate storage cert) internal returns (uint256 dueRaw) {
        (uint256 due, uint8 weeksToPay) = _creditDue(tokenId, cert);
        if (due == 0) return 0;
        if (due > creditPoolUsdcRaw) revert InsufficientPool();

        creditPoolUsdcRaw -= due;
        _nextCreditWeek[tokenId] = _nextCreditWeek[tokenId] + weeksToPay;
        dueRaw = due;

        if (_nextCreditWeek[tokenId] >= creditWeekCount) {
            cert.status = Status.Redeemed;
            emit CertificateRedeemed(tokenId);
        }
    }

    function _bondDue(uint256 tokenId, Certificate storage cert)
        internal
        view
        returns (uint256 dueRaw, uint8 quartersToPay)
    {
        if (block.timestamp < cert.yieldStart) return (0, 0);

        uint8 start = _nextBondQuarter[tokenId];
        if (start >= bondMaxQuarters) return (0, 0);

        uint256 quarterCents = (cert.amountCents * bondQuarterBps) / BPS_DENOMINATOR;
        uint256 quarterRaw = AmountCodec.centsToRaw(quarterCents, usdcDecimals);

        for (uint8 q = start; q < bondMaxQuarters; ++q) {
            uint64 payTime = cert.yieldStart + uint64(uint256(q) * uint256(bondQuarterSeconds));
            if (block.timestamp < payTime) break;
            dueRaw += quarterRaw;
            quartersToPay++;
        }
    }

    function _claimBond(uint256 tokenId, Certificate storage cert) internal returns (uint256 dueRaw) {
        if (block.timestamp < cert.yieldStart) revert YieldNotStarted();

        (uint256 due, uint8 quartersToPay) = _bondDue(tokenId, cert);
        if (due == 0) return 0;
        if (due > bondPoolUsdcRaw) revert InsufficientPool();

        bondPoolUsdcRaw -= due;
        _nextBondQuarter[tokenId] = _nextBondQuarter[tokenId] + quartersToPay;
        dueRaw = due;

        if (_nextBondQuarter[tokenId] >= bondMaxQuarters) {
            cert.status = Status.Redeemed;
            emit CertificateRedeemed(tokenId);
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    // ERC-721
    // ═════════════════════════════════════════════════════════════════════════

    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        address from = _ownerOf(tokenId);
        if (from != address(0) && _certificates[tokenId].status == Status.Vesting) {
            if (block.timestamp >= _certificates[tokenId].vestEnd) {
                _certificates[tokenId].status = Status.Active;
                emit CertificateUnlocked(tokenId, _certificates[tokenId].serial);
            } else {
                revert TransferWhileVesting();
            }
        }
        return super._update(to, tokenId, auth);
    }

    function tokenURI(uint256 tokenId)
        public
        view
        override(ERC721Upgradeable, ERC721URIStorageUpgradeable)
        returns (string memory)
    {
        return super.tokenURI(tokenId);
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721Upgradeable, ERC721URIStorageUpgradeable, AccessControlUpgradeable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
