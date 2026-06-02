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
    );
    event MemeEdited(uint256 indexed tokenId, address indexed by);
    event MemeLocked(uint256 indexed tokenId, address indexed by);

    event FeesWithdrawn(address indexed to, uint256 amount);
    event RoyaltySet(address indexed receiver, uint96 bps);

    // =============================================================
    //                      ERC165 Interfaces
    // =============================================================

    bytes4 private constant _IID_ERC165 = 0x01ffc9a7;
    bytes4 private constant _IID_ERC721 = 0x80ac58cd;
    bytes4 private constant _IID_ERC721_METADATA = 0x5b5e139f;
    bytes4 private constant _IID_ERC2981 = 0x2a55205a;

    // =============================================================
    //                        Constants
    // =============================================================

    string public constant name = "Encroach";
    string public constant symbol = "ENCR";

    uint256 public constant MAX_SUPPLY = 24_000;
    uint256 public constant MAX_TEXT_BYTES = 84;
    uint256 public constant MAX_TEMPLATES = 256;
    uint256 public constant MAX_PALETTE = 16;

    // fees (in wei)
    uint256 public constant MINT_FEE = 0.0021 ether;
    uint256 public constant EDIT_FEE = 0.00033 ether;

    // =============================================================
    //                      Immutables / IDs
    // =============================================================

    // Generic reference addresses (non-custodial; no auto-forwarding behavior).
    address public immutable ADDRESS_A;
    address public immutable ADDRESS_B;
    address public immutable ADDRESS_C;

    // unique identifiers used as domain separators / salts for this contract
    bytes32 private immutable _DOMAIN_TAG;
    bytes32 private immutable _RENDER_SALT;

    // =============================================================
    //                        Admin (2-step)
    // =============================================================

    address public warden;
