// SPDX-License-Identifier: MIT
pragma solidity >0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

/// @title KipuBankV2
/// @author lletsica
/// @notice A personal vault contract that supports ETH and USDC deposits/withdrawals with role-based access control and Chainlink price feed integration.
/// @dev Uses OpenZeppelin's AccessControl and Chainlink's AggregatorV3Interface for secure role management and real-time ETH/USD pricing.
contract KipuBankV2 is AccessControl, ReentrancyGuard, Pausable {
    // ─────────────────────────────────────────────────────────────
    // Immutable / Constant Variables
    // ─────────────────────────────────────────────────────────────

    /// @notice Global cap for total ETH deposits.
    uint256 public immutable BANK_CAP;

    /// @notice Maximum ETH withdrawal allowed per transaction.
    uint256 public immutable MAX_WITHD_PER_TX;

    /// @notice Role identifier for deposit permissions.
    bytes32 public constant DEPOSITOR_ROLE = keccak256("DEPOSITOR_ROLE");

    /// @notice Role identifier for withdrawal permissions.
    bytes32 public constant WITHDRAWER_ROLE = keccak256("WITHDRAWER_ROLE");

    // ─────────────────────────────────────────────────────────────
    // Storage Variables
    // ─────────────────────────────────────────────────────────────

    /// @notice Total ETH held in the contract.
    uint256 public totalEth;

    /// @notice Counter for successful ETH or USDC withdrawals.
    uint256 public withdrawalCounter;

    /// @notice Counter for successful ETH or USDC deposits.
    uint256 private depositCounter;

    /// @notice ERC20 token interface for USDC.
    IERC20 public usdcToken;

    /// @notice Chainlink price feed for ETH/USD.
    AggregatorV3Interface internal priceFeed;

    // ─────────────────────────────────────────────────────────────
    // Mappings
    // ─────────────────────────────────────────────────────────────

    /// @notice Mapping of user addresses to their ETH balances.
    mapping(address => uint256) public userBalances;

    /// @notice Mapping of user addresses to their USDC balances.
    mapping(address => uint256) public userUsdcBalances;

    /// @notice Mapping of whitelisted users who passed KYC.
    mapping(address => bool) public whitelist;

    // ─────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────

    /// @notice Emitted when a user successfully deposits ETH or USDC.
    event Deposit(address indexed user, uint256 amount);

    /// @notice Emitted when a user successfully withdraws ETH or USDC.
    event Withdrawal(address indexed user, address indexed token, uint256 amount);

    /// @notice Emitted when a user is added to the whitelist.
    event Whitelisted(address indexed user);

    /// @notice Emitted when a user is removed from the whitelist.
    event RemovedFromWhitelist(address indexed user);

    /// @notice Emitted when administrator makes an emergency withdrawal
    event EmergencyWithdrawal(address indexed admin, address indexed token, uint256 amount);

    // ─────────────────────────────────────────────────────────────
    // Custom Errors
    // ─────────────────────────────────────────────────────────────

    /// @dev Thrown when a deposit amount is zero.
    error DepositAmountZero();

    /// @dev Thrown when a withdrawal amount is zero.
    error WithdrawalAmountZero();

    /// @dev Thrown when a deposit exceeds the global ETH cap.
    error DepositExceedsBankCap();

    /// @dev Thrown when a user attempts to withdraw more than their balance.
    error InsufficientUserBalance();

    /// @dev Thrown when a withdrawal exceeds the per-transaction limit.
    error WithdrawalExceedsLimit(uint256 maxWithdrawal);

    error NotWhitelisted(address user);

    // ─────────────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────────────

    /// @notice Initializes the contract and assigns initial roles.
    /// @param _bankCap The maximum ETH the contract can hold.
    /// @param _maxWithdrawalPerTx The maximum ETH withdrawal per transaction.
    /// @param _usdcAddress The address of the USDC token contract.
    /// @param _priceFeedAddress The address of the Chainlink ETH/USD price feed.
    constructor(
        uint256 _bankCap,
        uint256 _maxWithdrawalPerTx,
        address _usdcAddress,
        address _priceFeedAddress
    ) {
        BANK_CAP = _bankCap;
        MAX_WITHD_PER_TX = _maxWithdrawalPerTx;
        usdcToken = IERC20(_usdcAddress);
        priceFeed = AggregatorV3Interface(_priceFeedAddress);

        _grantRole(DEPOSITOR_ROLE, msg.sender);
        _grantRole(WITHDRAWER_ROLE, msg.sender);
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    // ─────────────────────────────────────────────────────────────
    // Modifiers
    // ─────────────────────────────────────────────────────────────

    /// @dev Ensures the withdrawal amount is not zero.
    /// @param _amount The amount to withdraw.
    modifier nonZeroWithdrawal(uint256 _amount) {
        if (_amount == 0) revert WithdrawalAmountZero();
        _;
    }

    /// @dev Ensures the ETH deposit amount is not zero.
    modifier nonZero(uint256 _amount) {
        if (_amount == 0) revert DepositAmountZero();
        _;
    }

    modifier onlyWhitelisted(address _user) {
        if (!whitelist[_user]) revert NotWhitelisted(_user);
        _;
    }

    // ─────────────────────────────────────────────────────────────
    // External Payable Functions
    // ─────────────────────────────────────────────────────────────

    /// @notice Deposits ETH into the user's vault.
    /// @dev Requires DEPOSITOR_ROLE and non-zero deposit.
    function depositEth() external payable whenNotPaused onlyRole(DEPOSITOR_ROLE) onlyWhitelisted(msg.sender) nonZero(msg.value){
        if (totalEth + msg.value > BANK_CAP) revert DepositExceedsBankCap();
        unchecked {
            userBalances[msg.sender] += msg.value;
            totalEth += msg.value;
            ++depositCounter;
        }
        emit Deposit(msg.sender, msg.value);
    }

    /// @notice Deposits USDC into the user's vault.
    /// @param amount The amount of USDC to deposit.
    /// @dev Requires DEPOSITOR_ROLE and prior approval via ERC20 `approve`.
    function depositUSDC(uint256 amount) external whenNotPaused onlyRole(DEPOSITOR_ROLE) onlyWhitelisted(msg.sender) nonZero(amount) {
        if (amount == 0) revert DepositAmountZero();
        bool success = usdcToken.transferFrom(msg.sender, address(this), amount);
        require(success, "USDC transfer failed");
        unchecked {
            userUsdcBalances[msg.sender] += amount;
            ++depositCounter;
        }
        emit Deposit(msg.sender, amount);
    }

    // ─────────────────────────────────────────────────────────────
    // External View Functions
    // ─────────────────────────────────────────────────────────────

    /// @notice Returns the total number of deposits made.
    /// @return The deposit counter value.
    function getDepositCounter() public view returns (uint256) {
        return depositCounter;
    }

    /// @notice Retrieve a user's ETH balance held in the vault.
    /// @dev Reads the internal mapping that tracks ETH balances in wei.
    /// @param user The address whose ETH balance will be returned.
    /// @return balance The user's ETH balance in wei.
    function getUserEthBalance(address user) external view returns (uint256) {
        return userBalances[user];
    }

/// @notice Retrieve a user's USDC token balance held in the vault.
/// @dev Reads the internal mapping that tracks USDC balances in token units.
///      Callers should consider the USDC token's decimals when presenting this value.
/// @param user The address whose USDC balance will be returned.
/// @return balance The user's USDC balance in token units.
function getUserUsdcBalance(address user) external view returns (uint256) {
    return userUsdcBalances[user];
}

    // ─────────────────────────────────────────────────────────────
    // Additional External Functions
    // ─────────────────────────────────────────────────────────────

    /// @notice Withdraws ETH from the user's vault.
    /// @param _amount The amount of ETH to withdraw.
    /// @dev Requires WITHDRAWER_ROLE and sufficient balance.
    function withdrawEth(uint256 _amount) external nonZeroWithdrawal(_amount) whenNotPaused nonReentrant onlyRole(WITHDRAWER_ROLE) onlyWhitelisted(msg.sender) {
        _validateEthWithdrawal(msg.sender, _amount);

        unchecked {
            userBalances[msg.sender] -= _amount;
            totalEth -= _amount;
            ++withdrawalCounter;
        }

        (bool sent, ) = msg.sender.call{value: _amount}("");
        require(sent, "ETH transfer failed");
        emit Withdrawal(msg.sender, address(0), _amount);
    }

    /// @notice Withdraws USDC from the user's vault.
    /// @param amount The amount of USDC to withdraw.
    /// @dev Requires WITHDRAWER_ROLE and sufficient balance.
    function withdrawUSDC(uint256 amount) external whenNotPaused nonReentrant onlyRole(WITHDRAWER_ROLE) onlyWhitelisted(msg.sender) nonZeroWithdrawal(amount) {
        if (amount > userUsdcBalances[msg.sender]) revert InsufficientUserBalance();

        unchecked {
            userUsdcBalances[msg.sender] -= amount;
            ++withdrawalCounter;
        }

        usdcToken.transfer(msg.sender, amount);
        emit Withdrawal(msg.sender, address(usdcToken), amount);
    }

    /// @notice Add an address to the contract whitelist allowing KYC-verified actions.
    /// @dev Callable only by accounts with DEFAULT_ADMIN_ROLE. Sets `whitelist[user]` to true
    ///      and emits a Whitelisted event. Use this to grant on-chain permission tied to KYC
    ///      or other off-chain verification. Consider off-chain auditing of admin actions
    ///      and governance (multisig) for production deployments.
    /// @param user The address to add to the whitelist.
    /// @custom:role DEFAULT_ADMIN_ROLE
    /// @custom:emits Whitelisted
    function addToWhitelist(address user) external onlyRole(DEFAULT_ADMIN_ROLE) {
        whitelist[user] = true;
        emit Whitelisted(user);
    }

    /// @notice Remove an address from the contract whitelist, revoking KYC-verified actions.
    /// @dev Callable only by accounts with DEFAULT_ADMIN_ROLE. Sets `whitelist[user]` to false
    ///      and emits a RemovedFromWhitelist event. Removal should be logged and governed
    ///      appropriately since it affects users' ability to interact with protected flows.
    /// @param user The address to remove from the whitelist.
    /// @custom:role DEFAULT_ADMIN_ROLE
    /// @custom:emits RemovedFromWhitelist
    function removeFromWhitelist(address user) external onlyRole(DEFAULT_ADMIN_ROLE) {
        whitelist[user] = false;
        emit RemovedFromWhitelist(user);
    }


    /// @notice Pause contract operations protected by whenNotPaused.
    /// @dev Callable only by accounts with DEFAULT_ADMIN_ROLE. Uses OpenZeppelin
    ///      Pausable to block state-changing functions guarded by whenNotPaused.
    /// @custom:role DEFAULT_ADMIN_ROLE
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    /// @notice Resume contract operations previously paused.
    /// @dev Callable only by accounts with DEFAULT_ADMIN_ROLE. Uses OpenZeppelin
    ///      Pausable to re-enable functions guarded by whenNotPaused.
    /// @custom:role DEFAULT_ADMIN_ROLE
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    /// @notice Emergency withdrawal allowing admin to recover ETH or ERC20 tokens.
    /// @dev Callable only by accounts with DEFAULT_ADMIN_ROLE. This function is nonReentrant
    ///      and intended only for emergency fund recovery or contract migration;
    ///      governance should restrict access (e.g., multisig).
    /// @param token The token contract address to withdraw; use address(0) for ETH.
    /// @param amount The amount to withdraw; if token is ETH and amount is 0 the full
    ///               contract ETH balance will be sent; for ERC20 tokens amount must
    ///               be the token units to transfer.
    /// @param to The destination address receiving withdrawn funds; must not be zero.
    /// @custom:role DEFAULT_ADMIN_ROLE
    /// @custom:reverts Reverts if `to` is the zero address.
    /// @custom:reverts Reverts if ETH transfer fails when sending ETH.
    /// @custom:emits EmergencyWithdrawal
    function emergencyWithdraw(address token, uint256 amount, address to) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        require(to != address(0), "Invalid recipient");
        if (token == address(0)) {
            uint256 bal = address(this).balance;
            uint256 amt = amount == 0 ? bal : amount;
            (bool sent, ) = to.call{value: amt}("");
            require(sent, "ETH emergency transfer failed");
            emit EmergencyWithdrawal(msg.sender, address(0), amt);
            return;
        }
        IERC20(token).transfer(to, amount);
        emit EmergencyWithdrawal(msg.sender, token, amount);
    }

/// @notice Get the latest ETH price in USD from the configured Chainlink feed.
/// @dev Reads latestRoundData() and returns the price as an unsigned integer.
///      Chainlink standard for ETH/USD uses 8 decimals so the returned value is
///      USD * 1e8. Reverts if the oracle returns a non-positive price.
/// @return price The latest ETH price in USD with 8 decimals (USD * 1e8).
function getLatestEthPrice() public view returns (uint256) {
    (, int256 price, , , ) = priceFeed.latestRoundData();
    require(price > 0, "Invalid price");
    return uint256(price);
}

/// @notice Convert an amount of ETH denominated in wei to USD using the Chainlink price feed.
/// @dev Uses getLatestEthPrice() which returns price with 8 decimals. Calculation:
///      (weiAmount * price) / 1e18 => result has 8 decimals (USD * 1e8).
///      This preserves Chainlink's 8-decimal convention; callers should account for that
///      when displaying or comparing values. No rounding beyond Solidity integer math is applied.
/// @param weiAmount Amount of ETH in wei to convert.
/// @return usdAmount USD value corresponding to weiAmount, expressed with 8 decimals (USD * 1e8).
function ethWeiToUsd(uint256 weiAmount) public view returns (uint256) {
    uint256 ethPrice = getLatestEthPrice(); // price has 8 decimals
    // (weiAmount * price) / 1e18 => result has 8 decimals
    return (weiAmount * ethPrice) / 1e18;
}

    /// @notice Reject plain ETH transfers; instruct callers to use depositEth instead.
    /// @dev The receive function rejects direct ETH transfers to prevent accidental
    ///      deposits and to ensure deposits go through depositEth which enforces
    ///      role checks, KYC and accounting.
    /// @custom:reverts Always reverts with message "Use depositEth".
    receive() external payable {
        revert("Use depositEth");
    }

    /// @notice Reject all unknown calls and plain ETH sent to non-existent functions.
    /// @dev The fallback function reverts to avoid executing unexpected calldata,
    ///      prevent accidental gas consumption, and ensure only supported entrypoints
    ///      are used. It reverts with "Unsupported" for clarity.
    /// @custom:reverts Always reverts with message "Unsupported".
    fallback() external payable {
        revert("Unsupported");
    }

    function _validateEthWithdrawal(address user, uint256 _amount) private view {
        if (_amount > MAX_WITHD_PER_TX) revert WithdrawalExceedsLimit(MAX_WITHD_PER_TX);
        if (_amount > userBalances[user]) revert InsufficientUserBalance();
    }

}
