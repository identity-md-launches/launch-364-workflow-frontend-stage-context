// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice Sepolia test game using HEDS. Withholding can bias this commit-reveal coin.
/// @dev Fully configured at construction; no administrative powers or ETH entry points.
contract CommitRevealCoinFlip is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant MIN_STAKE = 1 ether; // 18-decimal HEDS units, not ETH.
    uint256 public constant MAX_PLAYERS = 16;
    uint256 public constant JOIN_WINDOW = 1 hours;
    uint256 public constant REVEAL_WINDOW = 1 hours;
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    enum Phase {
        Join,
        Reveal,
        Reclaimable,
        AwaitingSettlement,
        Settled
    }

    struct Round {
        uint256 stake;
        uint256 joinDeadline;
        uint256 revealDeadline;
        uint256 playerCount;
        uint256 revealCount;
        bytes32 saltXor;
        bool settled;
        bool heads;
        uint256 winners;
        uint256 share;
    }

    struct Player {
        bytes32 commitment;
        bool joined;
        bool revealed;
        bool heads;
        bool reclaimed;
    }

    IERC20 public immutable token;
    uint256 public roundCount;
    uint256 public totalStaked;
    uint256 public totalWithdrawable;
    mapping(address => uint256) public withdrawable;

    mapping(uint256 => Round) private _rounds;
    mapping(uint256 => mapping(address => Player)) private _players;
    mapping(uint256 => address[]) private _participants;

    error InvalidToken();
    error InvalidStake();
    error InvalidRound();
    error JoinClosed();
    error AlreadyJoined();
    error RoundFull();
    error RevealClosed();
    error NotJoined();
    error AlreadyRevealed();
    error InvalidReveal();
    error TooFewPlayers();
    error NotReclaimable();
    error SettlementTooEarly();
    error AlreadySettled();
    error NothingToWithdraw();
    error UnexpectedTransferAmount();

    event RoundCreated(uint256 indexed roundId, uint256 stake, uint256 joinDeadline, uint256 revealDeadline);
    event Joined(uint256 indexed roundId, address indexed account, bytes32 commitment);
    event Revealed(uint256 indexed roundId, address indexed account, bool heads, bytes32 salt);
    event Settled(uint256 indexed roundId, bool heads, uint256 winners, uint256 share);
    event Reclaimed(uint256 indexed roundId, address indexed account, uint256 amount);
    event Withdrawn(address indexed account, uint256 amount);

    /// @param token_ The deployed LaunchToken address ($token), not a privileged account.
    constructor(address token_) {
        if (token_ == address(0) || token_.code.length == 0) revert InvalidToken();
        token = IERC20(token_);
    }

    /// @notice Creates an empty round. The creator must join separately to participate.
    function createRound(uint256 stake) external nonReentrant returns (uint256 roundId) {
        if (stake < MIN_STAKE || stake > type(uint256).max / MAX_PLAYERS) revert InvalidStake();
        roundId = ++roundCount;
        Round storage r = _rounds[roundId];
        r.stake = stake;
        r.joinDeadline = block.timestamp + JOIN_WINDOW;
        r.revealDeadline = r.joinDeadline + REVEAL_WINDOW;
        emit RoundCreated(roundId, stake, r.joinDeadline, r.revealDeadline);
    }

    /// @notice Approve this contract for the stake before calling.
    /// @param commitment keccak256(abi.encode(heads, salt, msg.sender, roundId)).
    function join(uint256 roundId, bytes32 commitment) external nonReentrant {
        Round storage r = _getRound(roundId);
        if (r.settled || block.timestamp >= r.joinDeadline) revert JoinClosed();
        Player storage p = _players[roundId][msg.sender];
        if (p.joined) revert AlreadyJoined();
        if (r.playerCount == MAX_PLAYERS) revert RoundFull();

        p.commitment = commitment;
        p.joined = true;
        _participants[roundId].push(msg.sender);
        ++r.playerCount;
        totalStaked += r.stake;

        uint256 beforeBalance = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), r.stake);
        if (token.balanceOf(address(this)) != beforeBalance + r.stake) revert UnexpectedTransferAmount();
        emit Joined(roundId, msg.sender, commitment);
    }

    /// @notice Reveal only during [joinDeadline, revealDeadline), in a round with >= 2 players.
    function reveal(uint256 roundId, bool heads, bytes32 salt) external nonReentrant {
        Round storage r = _getRound(roundId);
        if (r.settled || block.timestamp < r.joinDeadline || block.timestamp >= r.revealDeadline) {
            revert RevealClosed();
        }
        if (r.playerCount < 2) revert TooFewPlayers();
        Player storage p = _players[roundId][msg.sender];
        if (!p.joined) revert NotJoined();
        if (p.revealed) revert AlreadyRevealed();
        if (p.commitment != keccak256(abi.encode(heads, salt, msg.sender, roundId))) revert InvalidReveal();

        p.revealed = true;
        p.heads = heads;
        ++r.revealCount;
        r.saltXor ^= salt;
        emit Revealed(roundId, msg.sender, heads, salt);
    }

    /// @notice Credits the sole player's stake once joining has closed; collect using withdraw().
    function reclaim(uint256 roundId) external nonReentrant {
        Round storage r = _getRound(roundId);
        if (r.settled) revert AlreadySettled();
        if (block.timestamp < r.joinDeadline || r.playerCount >= 2) revert NotReclaimable();
        Player storage p = _players[roundId][msg.sender];
        if (!p.joined) revert NotJoined();

        r.settled = true;
        r.share = r.stake;
        p.reclaimed = true;
        totalStaked -= r.stake;
        _credit(msg.sender, r.stake);
        emit Reclaimed(roundId, msg.sender, r.stake);
    }

    /// @notice Permissionless finalization at or after revealDeadline, including empty rounds.
    /// @dev Winners means correct-side revealers; it stays zero for fallback splits/refunds.
    function settle(uint256 roundId) external nonReentrant {
        Round storage r = _getRound(roundId);
        if (r.settled) revert AlreadySettled();
        if (block.timestamp < r.revealDeadline) revert SettlementTooEarly();

        r.settled = true;
        r.heads = (uint256(r.saltXor) & 1) == 1;
        uint256 pot = r.playerCount * r.stake;
        totalStaked -= pot;
        address[] storage accounts = _participants[roundId];

        if (r.revealCount == 0) {
            // No division by zero for empty rounds. All-withhold rounds refund every player.
            r.share = r.playerCount == 0 ? 0 : r.stake;
            for (uint256 i; i < accounts.length; ++i) {
                _credit(accounts[i], r.stake);
            }
        } else {
            uint256 winners;
            for (uint256 i; i < accounts.length; ++i) {
                Player storage p = _players[roundId][accounts[i]];
                if (p.revealed && p.heads == r.heads) ++winners;
            }
            r.winners = winners;
            uint256 recipients = winners == 0 ? r.revealCount : winners;
            uint256 share = pot / recipients;
            r.share = share;
            for (uint256 i; i < accounts.length; ++i) {
                Player storage p = _players[roundId][accounts[i]];
                if (p.revealed && (winners == 0 || p.heads == r.heads)) _credit(accounts[i], share);
            }

            uint256 remainder = pot - recipients * share;
            // Only rounding dust goes out here; player payments always use withdraw().
            if (remainder != 0) token.safeTransfer(BURN_ADDRESS, remainder);
        }
        emit Settled(roundId, r.heads, r.winners, r.share);
    }

    /// @notice Collect all of the caller's accumulated credits. No third-party recipient.
    function withdraw() external nonReentrant {
        uint256 amount = withdrawable[msg.sender];
        if (amount == 0) revert NothingToWithdraw();
        withdrawable[msg.sender] = 0;
        totalWithdrawable -= amount;
        token.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    function round(uint256 roundId) external view returns (Round memory) {
        return _getRound(roundId);
    }

    function player(uint256 roundId, address account) external view returns (Player memory) {
        _getRound(roundId);
        return _players[roundId][account];
    }

    function phase(uint256 roundId) external view returns (Phase) {
        Round storage r = _getRound(roundId);
        if (r.settled) return Phase.Settled;
        if (block.timestamp < r.joinDeadline) return Phase.Join;
        if (r.playerCount < 2) return Phase.Reclaimable;
        if (block.timestamp < r.revealDeadline) return Phase.Reveal;
        return Phase.AwaitingSettlement;
    }

    function _getRound(uint256 roundId) private view returns (Round storage r) {
        if (roundId == 0 || roundId > roundCount) revert InvalidRound();
        return _rounds[roundId];
    }

    function _credit(address account, uint256 amount) private {
        withdrawable[account] += amount;
        totalWithdrawable += amount;
    }
}
