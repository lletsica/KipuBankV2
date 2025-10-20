// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/// @title KipuBankV2
/// @author lletsica
/// @notice A personal vault contract that supports ETH and USDC deposits/withdrawals with role-based access control and Chainlink price feed integration.
/// @dev Uses OpenZeppelin's AccessControl and Chainlink's AggregatorV3Interface for secure role management and real-time ETH/USD pricing.
contract KipuBankV2 is AccessControl {
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
    event Withdrawal(address indexed user, uint256 amount);

    /// @notice Emitted when a user is added to the whitelist.
    event Whitelisted(address indexed user);

    /// @notice Emitted when a user is removed from the whitelist.
    event RemovedFromWhitelist(address indexed user);

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
    modifier nonZeroDeposit() {
        if (msg.value == 0) revert DepositAmountZero();
        _;
    }

    // ─────────────────────────────────────────────────────────────
    // External Payable Functions
    // ─────────────────────────────────────────────────────────────

    /// @notice Deposits ETH into the user's vault.
    /// @dev Requires DEPOSITOR_ROLE and non-zero deposit.
    function depositEth() external payable nonZeroDeposit onlyRole(DEPOSITOR_ROLE) {
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
    function depositUSDC(uint256 amount) external payable onlyRole(DEPOSITOR_ROLE) {
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
    // Private Functions
    // ─────────────────────────────────────────────────────────────

    /// @dev Validates ETH withdrawal limits and user balance.
    /// @param _amount The amount to validate.
    function _validateWithdrawalLimits(uint256 _amount) private view {
        if (_amount > MAX_WITHD_PER_TX) revert WithdrawalExceedsLimit(MAX_WITHD_PER_TX);
        if (_amount > userBalances[msg.sender]) revert InsufficientUserBalance();
    }

    // ─────────────────────────────────────────────────────────────
    // External View Functions
    // ─────────────────────────────────────────────────────────────

    /// @notice Returns the ETH balance of a user.
    /// @param _user The address to query.
    /// @return The ETH balance of the user.
    function getUserBalance(address _user) external view returns (uint256) {
        return userBalances[_user];
    }

    /// @notice Returns the total number of deposits made.
    /// @return The deposit counter value.
    function getDepositCounter() public view returns (uint256) {
        return depositCounter;
    }

    /// @notice Returns the latest ETH/USD price from Chainlink.
    /// @return ethPrice The current price of 1 ETH in USD (8 decimals).
    function getLatestEthPrice() public view returns (int ethPrice) {
        (, ethPrice, , , ) = priceFeed.latestRoundData();
    }

    // ─────────────────────────────────────────────────────────────
    // Additional External Functions
    // ─────────────────────────────────────────────────────────────

    /// @notice Withdraws ETH from the user's vault.
    /// @param _amount The amount of ETH to withdraw.
    /// @dev Requires WITHDRAWER_ROLE and sufficient balance.
    function withdrawEth(uint256 _amount) external nonZeroWithdrawal(_amount) onlyRole(WITHDRAWER_ROLE) {
        _validateWithdrawalLimits(_amount);
        unchecked {
            userBalances[msg.sender] -= _amount;
            totalEth -= _amount;
            ++withdrawalCounter;
        }
        (bool sent, ) = msg.sender.call{value: _amount}("");
        require(sent, "Failed to send Ether");
        emit Withdrawal(msg.sender, _amount);
    }

    /// @notice Withdraws USDC from the user's vault.
    /// @param amount The amount of USDC to withdraw.
    /// @dev Requires WITHDRAWER_ROLE and sufficient balance.
    function withdrawUSDC(uint256 amount) external onlyRole(WITHDRAWER_ROLE) {
        if (amount == 0) revert WithdrawalAmountZero();
        if (amount > userUsdcBalances[msg.sender]) revert InsufficientUserBalance();
        unchecked {
            userUsdcBalances[msg.sender] -= amount;
            ++withdrawalCounter;
        }
        bool success = usdcToken.transfer(msg.sender, amount);
        require(success, "USDC withdrawal failed");
        emit Withdrawal(msg.sender, amount);
    }
}
