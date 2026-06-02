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
    address public pendingWarden;
    bool public frozen;

    modifier onlyWarden() {
        if (msg.sender != warden) revert ENC_NotWarden();
        _;
    }

    modifier whenActive() {
        if (frozen) revert ENC_Frozen();
        _;
    }

    // =============================================================
    //                      Reentrancy Guard
    // =============================================================

    uint256 private _guard;
    modifier nonReentrant() {
        if (_guard == 1) revert ENC_Reentrancy();
        _guard = 1;
        _;
        _guard = 0;
    }

    // =============================================================
    //                           ERC721
    // =============================================================

    mapping(uint256 => address) private _ownerOf;
    mapping(address => uint256) private _balanceOf;
    mapping(uint256 => address) private _tokenApprovals;
    mapping(address => mapping(address => bool)) private _operatorApprovals;

    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event Approval(address indexed owner, address indexed spender, uint256 indexed tokenId);
    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);

    // =============================================================
    //                           Royalty
    // =============================================================

    address private _royaltyReceiver;
    uint96 private _royaltyBps;

    // =============================================================
    //                         Meme Platform
    // =============================================================

    struct Template {
        // a short tag to identify a template (not unique; used as metadata flavor)
        bytes32 tag;
        // background color (3 bytes) and accent color (3 bytes)
        bytes3 bg;
        bytes3 accent;
        // base font size in px (caption)
        uint16 fontPx;
        // stroke width in tenths of px (0..40)
        uint8 strokeTenthPx;
        // number of stickers (0..8)
        uint8 stickerCount;
        // 0: none, 1: warp, 2: wobble, 3: jitter
        uint8 effect;
        // svg fragments: header, stickers..., footer
        bytes header;
        bytes footer;
        bytes[] stickers;
    }

    struct Meme {
        uint32 templateId;
        uint16 hue; // 0..359
        uint16 grain; // 0..100
        bool locked;
        string top;
        string bottom;
        bytes32 spice; // per-token salt for deterministic jitter
    }

    uint256 public totalSupply;
    uint256 public templateCount;

    mapping(uint256 => Template) private _templates;
    mapping(uint256 => Meme) private _memes;

    // =============================================================
    //                         Constructor
    // =============================================================

    constructor() {
        // authority
        warden = msg.sender;

        // reference addresses (unique per contract)
        ADDRESS_A = 0x6aB6c1c59d6E3f2A9C29d7b3e40A0D9f0aC71E2b;
        ADDRESS_B = 0xD4c8bB3A07c6c1b82d6c89B50fF7B53cA6dE13a9;
        ADDRESS_C = 0x1f3C5E0dF8d2B5B4cC9E2a0A6b4E9D2d7fA3cB11;

        // unique tags
        _DOMAIN_TAG = 0x4a1e9b2e1dd5a2ef01a8c9c9b402cc7f4d93e0ef00f4a690c5be6a1f8f80ce71;
        _RENDER_SALT = 0xb6e5a2b9f33c7d1e4b8bfb3a45c0fd2a1b6d8b6b8a26edb55f7c1a2d9d6b8a10;

        // royalty defaults
        _royaltyReceiver = msg.sender;
        _royaltyBps = 420; // 4.20%

        // seed with a few templates so deploy is ready-to-mint
        _seedTemplates();
    }

    // =============================================================
    //                         ERC165
    // =============================================================

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return
            interfaceId == _IID_ERC165 ||
            interfaceId == _IID_ERC721 ||
            interfaceId == _IID_ERC721_METADATA ||
            interfaceId == _IID_ERC2981;
    }

    // =============================================================
    //                         Views (ERC721)
    // =============================================================

    function ownerOf(uint256 tokenId) public view returns (address) {
        address owner_ = _ownerOf[tokenId];
        if (owner_ == address(0)) revert ENC_BadToken();
        return owner_;
    }

    function balanceOf(address owner_) public view returns (uint256) {
        if (owner_ == address(0)) revert ENC_ZeroAddress();
        return _balanceOf[owner_];
    }

    function getApproved(uint256 tokenId) public view returns (address) {
        if (_ownerOf[tokenId] == address(0)) revert ENC_BadToken();
        return _tokenApprovals[tokenId];
    }

    function isApprovedForAll(address owner_, address operator) public view returns (bool) {
        return _operatorApprovals[owner_][operator];
    }

    // =============================================================
    //                         ERC721 Actions
    // =============================================================

    function approve(address spender, uint256 tokenId) external {
        address owner_ = ownerOf(tokenId);
        if (spender == owner_) revert ENC_BadValue();
        if (msg.sender != owner_ && !_operatorApprovals[owner_][msg.sender]) revert ENC_NotApproved();
        _tokenApprovals[tokenId] = spender;
        emit Approval(owner_, spender, tokenId);
    }

    function setApprovalForAll(address operator, bool approved) external {
        _operatorApprovals[msg.sender][operator] = approved;
        emit ApprovalForAll(msg.sender, operator, approved);
    }

    function transferFrom(address from, address to, uint256 tokenId) public {
        if (to == address(0)) revert ENC_ZeroAddress();
        address owner_ = ownerOf(tokenId);
        if (owner_ != from) revert ENC_BadValue();

        if (
            msg.sender != owner_ &&
            msg.sender != _tokenApprovals[tokenId] &&
            !_operatorApprovals[owner_][msg.sender]
        ) {
            revert ENC_NotApproved();
        }

        unchecked {
            _balanceOf[from] -= 1;
            _balanceOf[to] += 1;
        }
        _ownerOf[tokenId] = to;
        delete _tokenApprovals[tokenId];

        emit Transfer(from, to, tokenId);
    }

    function safeTransferFrom(address from, address to, uint256 tokenId) external {
        safeTransferFrom(from, to, tokenId, "");
    }

    function safeTransferFrom(address from, address to, uint256 tokenId, bytes memory data) public {
        transferFrom(from, to, tokenId);
        if (to.code.length != 0) {
            bytes4 retval = IERC721Receiver(to).onERC721Received(msg.sender, from, tokenId, data);
            if (retval != IERC721Receiver.onERC721Received.selector) revert ENC_UnsafeRecipient();
        }
    }

    // =============================================================
    //                       Platform Admin
    // =============================================================

    function proposeWarden(address nextWarden) external onlyWarden {
        if (nextWarden == address(0)) revert ENC_ZeroAddress();
        pendingWarden = nextWarden;
        emit WardenProposed(warden, nextWarden);
    }

    function acceptWarden() external {
        if (msg.sender != pendingWarden) revert ENC_NotPendingWarden();
        address prev = warden;
        warden = msg.sender;
        pendingWarden = address(0);
        emit WardenAccepted(prev, msg.sender);
    }

    function setFrozen(bool freeze) external onlyWarden {
        frozen = freeze;
        emit FrozenSet(freeze);
    }

    function setRoyalty(address receiver, uint96 bps) external onlyWarden {
        if (receiver == address(0)) revert ENC_ZeroAddress();
        if (bps > 2500) revert ENC_BadRoyalty(); // <= 25%
        _royaltyReceiver = receiver;
        _royaltyBps = bps;
        emit RoyaltySet(receiver, bps);
    }

    function withdrawFees(address payable to, uint256 amount) external onlyWarden nonReentrant {
        if (to == address(0)) revert ENC_ZeroAddress();
        if (amount == 0 || amount > address(this).balance) revert ENC_BadValue();
        (bool ok, ) = to.call{value: amount}("");
        if (!ok) revert ENC_TransferFailed();
        emit FeesWithdrawn(to, amount);
    }

    // =============================================================
    //                         Royalty (ERC2981)
    // =============================================================

    function royaltyInfo(uint256, uint256 salePrice) external view returns (address, uint256) {
        uint256 amt = (salePrice * uint256(_royaltyBps)) / 10_000;
        return (_royaltyReceiver, amt);
    }

    function royaltyConfig() external view returns (address receiver, uint96 bps) {
        return (_royaltyReceiver, _royaltyBps);
    }

    // =============================================================
    //                       Templates (Registry)
    // =============================================================

    function templateAt(uint256 templateId)
        external
        view
        returns (
            bytes32 tag,
            bytes3 bg,
            bytes3 accent,
            uint16 fontPx,
            uint8 strokeTenthPx,
            uint8 stickerCount,
            uint8 effect
        )
    {
        if (templateId >= templateCount) revert ENC_BadTemplate();
        Template storage t = _templates[templateId];
        return (t.tag, t.bg, t.accent, t.fontPx, t.strokeTenthPx, t.stickerCount, t.effect);
    }

    function templateSticker(uint256 templateId, uint256 idx) external view returns (bytes memory) {
        if (templateId >= templateCount) revert ENC_BadTemplate();
        Template storage t = _templates[templateId];
        if (idx >= t.stickers.length) revert ENC_BadValue();
        return t.stickers[idx];
    }

    function addTemplate(
        bytes32 tag,
        bytes3 bg,
        bytes3 accent,
        uint16 fontPx,
        uint8 strokeTenthPx,
        uint8 effect,
        bytes calldata header,
        bytes calldata footer,
        bytes[] calldata stickers
    ) external onlyWarden {
        if (templateCount >= MAX_TEMPLATES) revert ENC_BadValue();
        if (fontPx < 10 || fontPx > 64) revert ENC_BadValue();
        if (strokeTenthPx > 40) revert ENC_BadValue();
        if (effect > 3) revert ENC_BadValue();
        if (stickers.length > 8) revert ENC_BadValue();
        if (stickers.length > 0) {
            uint256 n = stickers.length;
            for (uint256 i; i < n; ) {
                if (stickers[i].length == 0) revert ENC_BadValue();
                unchecked {
                    ++i;
                }
            }
        }

        uint256 id = templateCount;
        Template storage t = _templates[id];
        t.tag = tag;
        t.bg = bg;
        t.accent = accent;
        t.fontPx = fontPx;
        t.strokeTenthPx = strokeTenthPx;
        t.effect = effect;
        t.header = header;
        t.footer = footer;

        uint256 m = stickers.length;
        if (m != 0) {
            t.stickers = new bytes[](m);
            for (uint256 j; j < m; ) {
                t.stickers[j] = stickers[j];
                unchecked {
                    ++j;
                }
            }
        }
        t.stickerCount = uint8(m);

        unchecked {
            templateCount = id + 1;
        }
        emit TemplateAdded(id, tag, msg.sender);
    }

    function tuneTemplate(
        uint256 templateId,
        bytes3 bg,
        bytes3 accent,
        uint16 fontPx,
        uint8 strokeTenthPx,
        uint8 effect
    ) external onlyWarden {
        if (templateId >= templateCount) revert ENC_BadTemplate();
        if (fontPx < 10 || fontPx > 64) revert ENC_BadValue();
        if (strokeTenthPx > 40) revert ENC_BadValue();
        if (effect > 3) revert ENC_BadValue();

        Template storage t = _templates[templateId];
        t.bg = bg;
        t.accent = accent;
        t.fontPx = fontPx;
        t.strokeTenthPx = strokeTenthPx;
        t.effect = effect;
        emit TemplateTuned(templateId, t.tag, msg.sender);
    }

    // =============================================================
    //                        Mint / Edit / Lock
    // =============================================================

    function quoteMint(uint256 templateId) public view returns (uint256) {
        if (templateId >= templateCount) revert ENC_BadTemplate();
        uint256 bump = 0;
        Template storage t = _templates[templateId];
        if (t.effect != 0) bump += 0.0002 ether;
        if (t.stickerCount > 2) bump += uint256(t.stickerCount - 2) * 0.00005 ether;
        return MINT_FEE + bump;
    }

    function quoteEdit(uint256 tokenId) public view returns (uint256) {
        if (_ownerOf[tokenId] == address(0)) revert ENC_BadToken();
        Meme storage m = _memes[tokenId];
        if (m.locked) revert ENC_AlreadyLocked();
        uint256 bump = 0;
        Template storage t = _templates[m.templateId];
        if (t.effect == 3) bump += 0.00006 ether;
        return EDIT_FEE + bump;
    }

    function mint(
        address to,
        uint256 templateId,
        string calldata top,
        string calldata bottom,
        uint16 hue,
        uint16 grain
    ) external payable whenActive nonReentrant returns (uint256 tokenId) {
        if (to == address(0)) revert ENC_ZeroAddress();
        if (templateId >= templateCount) revert ENC_BadTemplate();
        if (totalSupply >= MAX_SUPPLY) revert ENC_SupplyCap();

        _checkText(top);
        _checkText(bottom);
        if (hue >= 360) revert ENC_BadValue();
        if (grain > 100) revert ENC_BadValue();

        uint256 due = quoteMint(templateId);
        if (msg.value < due) revert ENC_BadValue();

        tokenId = totalSupply + 1;
        totalSupply = tokenId;

        _ownerOf[tokenId] = to;
        unchecked {
            _balanceOf[to] += 1;
        }
        emit Transfer(address(0), to, tokenId);

        Meme storage m = _memes[tokenId];
        m.templateId = uint32(templateId);
        m.top = top;
        m.bottom = bottom;
        m.hue = hue;
        m.grain = grain;
        m.locked = false;
        m.spice = _memeSpice(tokenId, to, templateId);

        emit MemeMinted(tokenId, templateId, to, due);

        // refund if overpaid
        if (msg.value > due) {
            uint256 refund = msg.value - due;
            (bool ok, ) = payable(msg.sender).call{value: refund}("");
            if (!ok) revert ENC_TransferFailed();
        }
    }

    function editMeme(
        uint256 tokenId,
        string calldata top,
        string calldata bottom,
        uint16 hue,
        uint16 grain
    ) external payable whenActive nonReentrant {
        address owner_ = ownerOf(tokenId);
        if (!_isApprovedOrOwner(owner_, msg.sender, tokenId)) revert ENC_Unauthorized();

        Meme storage m = _memes[tokenId];
        if (m.locked) revert ENC_AlreadyLocked();

        _checkText(top);
        _checkText(bottom);
        if (hue >= 360) revert ENC_BadValue();
        if (grain > 100) revert ENC_BadValue();

        uint256 due = quoteEdit(tokenId);
        if (msg.value < due) revert ENC_BadValue();

        m.top = top;
        m.bottom = bottom;
