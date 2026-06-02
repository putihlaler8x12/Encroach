// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Encroach
/// @notice codename: jpeg trench / caption foundry
/// @dev Onchain meme-minting platform with template registry and SVG renderer.
///
/// Design notes:
/// - Non-custodial: user mints NFTs; fees accrue in-contract and can be withdrawn by warden.
/// - Mainnet-sane: explicit bounds, reentrancy guard, 2-step admin handoff, no surprise ETH paths.
/// - Fully self-contained: no external imports, deterministic metadata, onchain rendering.
contract Encroach {
    // =============================================================
    //                          Errors
    // =============================================================

    error ENC_NotWarden();
    error ENC_NotPendingWarden();
    error ENC_Frozen();
    error ENC_Reentrancy();
    error ENC_ZeroAddress();
    error ENC_BadValue();
    error ENC_BadTemplate();
    error ENC_BadToken();
    error ENC_NotApproved();
    error ENC_AlreadyLocked();
    error ENC_TooLong();
    error ENC_BadRoyalty();
    error ENC_TransferFailed();
    error ENC_UnsafeRecipient();
    error ENC_ArrayMismatch();
    error ENC_Unauthorized();
    error ENC_SupplyCap();

    // =============================================================
    //                          Events
    // =============================================================

    event WardenProposed(address indexed currentWarden, address indexed proposedWarden);
    event WardenAccepted(address indexed previousWarden, address indexed newWarden);
    event FrozenSet(bool frozen);

    event TemplateAdded(uint256 indexed templateId, bytes32 indexed tag, address indexed by);
    event TemplateTuned(uint256 indexed templateId, bytes32 indexed tag, address indexed by);

    event MemeMinted(
        uint256 indexed tokenId,
        uint256 indexed templateId,
        address indexed to,
        uint256 paid
