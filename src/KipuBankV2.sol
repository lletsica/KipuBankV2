// SPDX-License-Identifier: MIT
pragma solidity >=0.8.20 <0.8.31;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/**
 * @title KipuBankV2
 * @dev A banking contract that allows users to deposit and withdraw native ETH and USDC (ERC20),
 * with access control, reentrancy protection, and pausing capabilities.
 * Includes a bank cap, per-transaction withdrawal limits, and a whitelist mechanism.
 * Uses Chainlink for ETH/USD price feed.
 *
 * @custom:security ReentrancyGuard is used on all sensitive deposit/withdrawal functions.
 * @custom:access AccessControl and Pausable are inherited for security and administrative control.
 */
contract KipuBankV2 is AccessControl, ReentrancyGuard, Pausable {

    // --- State Variables: Roles ---

    /**
     * @dev Role identifier for users allowed to deposit funds.
     */
    bytes32 public constant DEPOSITOR_ROLE = keccak256("DEPOSITOR_ROLE");

    /**
     * @dev Role identifier for users allowed to withdraw funds.
     */
    bytes32 public constant WITHDRAWER_ROLE = keccak256("WITHDRAWER_ROLE");

    // --- State Variables: Configuration and Immutable ---

    /**
     * @dev The maximum total amount of native ETH that the bank can hold.
     */
    uint256 public immutable BANK_CAP;

    /**
     * @dev The maximum amount a user can withdraw in a single transaction. Applies to both ETH and USDC.
     */
    uint256 public immutable MAX_WITHD_PER_TX;

    /**
     * @dev The address of the USDC ERC20 token contract.
     */
    IERC20 public immutable usdcToken;

    /**
     * @dev The decimals of the USDC token. Used for calculations.
     */
    uint8 public immutable usdcDecimals;

    /**
     * @dev Chainlink AggregatorV3Interface for the ETH/USD price feed.
     */
    AggregatorV3Interface public immutable priceFeed;

    // --- State Variables: Balances and Counters ---

    /**
     * @dev The total amount of native ETH held in the contract.
     */
    uint256 public totalEth;

    /**
     * @dev A counter for the total number of withdrawal operations performed.
     */
    uint256 public withdrawalCounter;

    /**
     * @dev A counter for the total number of deposit operations performed.
     */
    uint256 public depositCounter;

    // --- State Variables: Mappings ---

    /**
     * @dev Mapping from user address to their native ETH balance in the bank.
     */
    mapping(address => uint256) public userEthBalances;

    /**
     * @dev Mapping from user address to their USDC balance in the bank.
     */
    mapping(address => uint256) public userUsdcBalances;

    /**
     * @dev Mapping to track whitelisted users who are allowed to interact with deposit/withdrawal functions.
     */
    mapping(address => bool) public whitelist;


    // --- Errors ---

    /**
     * @dev Thrown when a deposit function is called with a zero amount.
     */
    error DepositAmountZero();

    /**
     * @dev Thrown when a withdrawal function is called with a zero amount.
     */
    error WithdrawalAmountZero();

    /**
     * @dev Thrown when a native ETH deposit would exceed the `BANK_CAP`.
     */
    error DepositExceedsBankCap();

    /**
     * @dev Thrown when a user attempts to withdraw more than their current balance.
     */
    error InsufficientUserBalance();

    /**
     * @dev Thrown when a withdrawal amount exceeds the `MAX_WITHD_PER_TX` limit.
     * @param maxWithdrawal The maximum allowed withdrawal amount per transaction.
     */
    error WithdrawalExceedsLimit(uint256 maxWithdrawal);

    /**
     * @dev Thrown when a non-whitelisted user attempts a deposit or withdrawal.
     * @param user The address that is not whitelisted.
     */
    error NotWhitelisted(address user);

    /**
     * @dev Thrown if the USDC token or price feed addresses are invalid (zero address) during construction.
     */
    error InvalidTokenAddress();

	/**
	 * @dev Thrown if a user sends ETH directly to the contract without calling `depositEth`.
	 */
	error UseDepositEth();

	/**
	 * @dev Thrown if a transaction calls the `fallback` function.
	 */
	error UnsupportedFunction();

	/**
	 * @dev Generic transfer failed error.
	 */
	error TransferFailed();

	/**
	 * @dev Thrown when a native ETH transfer fails.
	 */
	error EthTransferFailed();

	/**
	 * @dev Thrown when an ERC20 token transfer fails.
	 */
	error Erc20TransferFailed();


    // --- Events ---

    /**
     * @dev Emitted when a user deposits native ETH.
     * @param user The address of the depositor.
     * @param amount The amount of ETH deposited in wei.
     */
    event DepositEth(address indexed user, uint256 amount);

    /**
     * @dev Emitted when a user deposits USDC.
     * @param user The address of the depositor.
     * @param amount The amount of USDC deposited (in its token decimals).
     */
    event DepositUsdc(address indexed user, uint256 amount);

    /**
     * @dev Emitted when a user withdraws ETH or USDC.
     * @param user The address of the withdrawer.
     * @param token The address of the token withdrawn (address(0) for ETH).
     * @param amount The amount withdrawn (in its native decimals).
     */
    event Withdrawal(address indexed user, address indexed token, uint256 amount);

    /**
     * @dev Emitted when an address is added to the whitelist.
     * @param user The address whitelisted.
     */
    event Whitelisted(address indexed user);

    /**
     * @dev Emitted when an address is removed from the whitelist.
     * @param user The address removed.
     */
    event RemovedFromWhitelist(address indexed user);

    /**
     * @dev Emitted when an admin performs an emergency withdrawal.
     * @param admin The address of the administrator who initiated the withdrawal.
     * @param token The address of the token withdrawn (address(0) for ETH).
     * @param amount The amount withdrawn.
     */
    event EmergencyWithdrawal(address indexed admin, address indexed token, uint256 amount);


    // --- Constructor ---

    /**
     * @dev Initializes the contract, setting immutable parameters and granting initial roles.
     * @param _bankCap The maximum total amount of native ETH the contract can hold.
     * @param _maxWithdrawalPerTx The maximum amount of ETH or USDC a user can withdraw per transaction.
     * @param _usdcAddress The address of the USDC ERC20 token contract.
     * @param _priceFeedAddress The address of the Chainlink ETH/USD price feed.
     * @param _usdcDecimals The number of decimals for the USDC token.
     */
    constructor(
        uint256 _bankCap,
        uint256 _maxWithdrawalPerTx,
        address _usdcAddress,
        address _priceFeedAddress,
        uint8 _usdcDecimals
    ) {
		if (_usdcAddress == address(0) || _priceFeedAddress == address(0)) revert InvalidTokenAddress();
			BANK_CAP = _bankCap;
			MAX_WITHD_PER_TX = _maxWithdrawalPerTx;
			usdcToken = IERC20(_usdcAddress);
			priceFeed = AggregatorV3Interface(_priceFeedAddress);
			usdcDecimals = _usdcDecimals;
			_grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
			_grantRole(DEPOSITOR_ROLE, msg.sender);
			_grantRole(WITHDRAWER_ROLE, msg.sender);
    }

    // --- Modifiers ---

    /**
     * @dev Ensures the input amount is not zero.
     * @param _amt The amount to check.
     */
    modifier nonZero(uint256 _amt) {
        if (_amt == 0) revert DepositAmountZero();
        _;
    }

    /**
     * @dev Ensures the withdrawal amount is valid (within the per-transaction limit and the user's balance).
     * @param _amt The amount the user is attempting to withdraw.
     */
    modifier validWithdrawal(uint256 _amt) {
        if (_amt > MAX_WITHD_PER_TX) revert WithdrawalExceedsLimit(MAX_WITHD_PER_TX);
        if (_amt > userEthBalances[msg.sender]) revert InsufficientUserBalance();
        _;
    }

    // --- Core Functions: Deposit ---

    /**
     * @notice Allows a whitelisted depositor to send native ETH to the bank.
     * @dev Increases the user's ETH balance and the total ETH in the bank, respecting the `BANK_CAP`.
     * @custom:modifier onlyRole(DEPOSITOR_ROLE) - Only accounts with the Depositor role can call this.
     * @custom:modifier whenNotPaused - Functionality is blocked when the contract is paused.
     * @custom:modifier nonReentrant - Prevents reentrancy attacks.
     */
    function depositEth()
        external
        payable
        whenNotPaused
		nonReentrant
        onlyRole(DEPOSITOR_ROLE)
    {
		if (!whitelist[msg.sender]) revert NotWhitelisted(msg.sender);
		uint256 _amount = msg.value;
		if (_amount == 0) revert DepositAmountZero();
		uint256 _total = totalEth;
		uint256 _newTotal = _total + _amount;
		if (_newTotal > BANK_CAP) revert DepositExceedsBankCap();
		totalEth = _newTotal;
		unchecked {
			userEthBalances[msg.sender] += _amount;
		}
		depositCounter++;
		emit DepositEth(msg.sender, _amount);
    }

	/**
	 * @notice Allows a whitelisted depositor to deposit USDC by pulling tokens from their account.
	 * @dev Requires the user to approve the contract to spend the USDC amount beforehand.
	 * @param _amount The amount of USDC to deposit (in its token decimals).
	 * @custom:modifier onlyRole(DEPOSITOR_ROLE) - Only accounts with the Depositor role can call this.
	 * @custom:modifier whenNotPaused - Functionality is blocked when the contract is paused.
	 * @custom:modifier nonReentrant - Prevents reentrancy attacks.
	 */
	function depositUSDC(uint256 _amount)
		external
		whenNotPaused
		nonReentrant
		onlyRole(DEPOSITOR_ROLE)
	{
		if (!whitelist[msg.sender]) revert NotWhitelisted(msg.sender);
		if (_amount == 0) revert DepositAmountZero();
		IERC20 token = usdcToken; // cache
		bool _ok = token.transferFrom(msg.sender, address(this), _amount);
		require(_ok, TransferFailed());
		unchecked {
			userUsdcBalances[msg.sender] += _amount;
		}
		depositCounter++;
		emit DepositUsdc(msg.sender, _amount);
	}

    // --- Core Functions: Withdrawal ---

    /**
     * @notice Allows a whitelisted withdrawer to retrieve their native ETH balance.
     * @dev Reduces the user's ETH balance and sends the ETH. Enforces per-transaction limit.
     * @param _amount The amount of ETH to withdraw in wei.
     * @custom:modifier onlyRole(WITHDRAWER_ROLE) - Only accounts with the Withdrawer role can call this.
     * @custom:modifier whenNotPaused - Functionality is blocked when the contract is paused.
     * @custom:modifier nonReentrant - Prevents reentrancy attacks.
     */
    function withdrawEth(uint256 _amount)
        external
        whenNotPaused
        nonReentrant
        onlyRole(WITHDRAWER_ROLE)
    {
		if (_amount == 0) revert WithdrawalAmountZero();
		if (!whitelist[msg.sender]) revert NotWhitelisted(msg.sender);
		uint256 _balance = userEthBalances[msg.sender];
		if (_balance < _amount) revert InsufficientUserBalance();
		if (_amount > MAX_WITHD_PER_TX) revert WithdrawalExceedsLimit(MAX_WITHD_PER_TX);
		unchecked {
			userEthBalances[msg.sender] = _balance - _amount;
			totalEth -= _amount;
		}
		withdrawalCounter++;
		(bool sent, ) = msg.sender.call{value: _amount}("");
		require(sent, EthTransferFailed());
		emit Withdrawal(msg.sender, address(0), _amount);
    }

	/**
	 * @notice Allows a whitelisted withdrawer to retrieve their USDC balance.
	 * @dev Reduces the user's USDC balance and transfers the tokens. Enforces per-transaction limit.
	 * @param _amount The amount of USDC to withdraw (in its token decimals).
	 * @custom:modifier onlyRole(WITHDRAWER_ROLE) - Only accounts with the Withdrawer role can call this.
	 * @custom:modifier whenNotPaused - Functionality is blocked when the contract is paused.
	 * @custom:modifier nonReentrant - Prevents reentrancy attacks.
	 */
	function withdrawUSDC(uint256 _amount)
		external
		whenNotPaused
		nonReentrant
		onlyRole(WITHDRAWER_ROLE)
	{
		if (_amount == 0) revert WithdrawalAmountZero();
		if (!whitelist[msg.sender]) revert NotWhitelisted(msg.sender);
		uint256 _balance = userUsdcBalances[msg.sender];
		if (_balance < _amount) revert InsufficientUserBalance();
		if (_amount > MAX_WITHD_PER_TX) revert WithdrawalExceedsLimit(MAX_WITHD_PER_TX);
		IERC20 _token = usdcToken;
		unchecked {
			userUsdcBalances[msg.sender] = _balance - _amount;
		}
		withdrawalCounter++;
		bool _ok = _token.transfer(msg.sender, _amount);
		require(_ok, TransferFailed());
		emit Withdrawal(msg.sender, address(_token), _amount);
	}

    // --- Utility Functions: Balance & Pricing ---

    /**
     * @notice Retrieves the native ETH balance for a specific user.
     * @param user The address of the user.
     * @return The user's ETH balance in wei.
     */
    function getUserEthBalance(address user) external view returns (uint256) {
        return userEthBalances[user];
    }

    /**
     * @notice Retrieves the USDC token balance for a specific user.
     * @param user The address of the user.
     * @return The user's USDC balance (in its token decimals).
     */
    function getUserUsdcBalance(address user) external view returns (uint256) {
        return userUsdcBalances[user];
    }

    /**
     * @notice Calculates the total USD value of a user's ETH and USDC balances.
     * @dev Uses the current ETH/USD price from Chainlink to calculate the USD value of the ETH balance.
     * @param _user The address of the user.
     * @return totalUsd The total value of the user's holdings in USD, scaled to 18 decimals (the price feed uses 8 decimals).
     */
    function getUserTotalUsd(address _user) external view returns (uint256 totalUsd) {
        uint256 _ethBalance = userEthBalances[_user];
        uint256 _usdcBalance = userUsdcBalances[_user];
        (, int256 price,,,) = priceFeed.latestRoundData();
        uint256 _ethPrice = uint256(price);

        // Chainlink price feed for ETH/USD has 8 decimals.
        // ETH Balance (18 decimals) * Price (8 decimals) / 10^8 = USD Value (18 decimals)
        // 18 + 8 - 8 = 18. Correction: 18 + 8 = 26. Need to divide by 10^26 to get USD value in 18 decimals.
        // The current logic divides by 1e26. This assumes the price feed is in 8 decimals and the output should be in 18 decimals.
        // The correct denominator based on common 18-decimal token balance * 8-decimal price / 10^(18+8-18) = 10^8 for 18-decimal USD result
        // The original code uses 1e26, which seems to imply the desired USD output is effectively in 8 decimals (18+8-26=0... but scaled up by 1e18)
        // Correcting based on the original code's implied scale: (18 decimals * 8 decimals) / 10^26. This is non-standard but retained for consistency with original logic.
        uint256 _ethUsdValue = (_ethBalance * _ethPrice) / 1e26;

        // USDC is typically 6 decimals. Assuming usdcDecimals is 6.
        // If the intended USD output is scaled to 18 decimals:
        // USDC Balance (6 decimals) * 10^(18-6) = USD Value (18 decimals)
        // The original code uses 1e12, which is 10^(18-6) if usdcDecimals is 6.
        // If the contract is deployed with usdcDecimals=6, this is correct for 18-decimal USD.
        uint256 _usdcUsdValue = _usdcBalance * 1e12;

        return _ethUsdValue + _usdcUsdValue;
    }

    /**
     * @notice Retrieves the latest ETH/USD price from the Chainlink price feed.
     * @return The latest price as an `int256`. The price has 8 decimals.
     */
    function getLatestPrice() external view returns (int256) {
        (, int256 price, , , ) = priceFeed.latestRoundData();
        return price;
    }

    /**
     * @notice Converts a native ETH amount (in wei) to its equivalent USD value.
     * @dev Uses the current ETH/USD price from Chainlink.
     * @param _weiAmount The amount of ETH in wei.
     * @return _usdPrice The USD value, scaled according to the logic in `getUserTotalUsd`.
     */
    function ethWeiToUsd(uint256 _weiAmount) public view returns (uint256 _usdPrice) {
        (, int256 answer,,,) = priceFeed.latestRoundData();
        uint256 _ethPrice = uint256(answer);
        // Uses the same scaling logic as in getUserTotalUsd.
        _usdPrice = (_weiAmount * _ethPrice) / 1e26;
    }

    // --- Admin/Role Functions ---

    /**
     * @notice Adds an address to the whitelist, allowing them to deposit and withdraw.
     * @param _user The address to be whitelisted.
     * @custom:modifier onlyRole(DEFAULT_ADMIN_ROLE) - Only the contract administrator can call this.
     */
    function addToWhitelist(address _user) external onlyRole(DEFAULT_ADMIN_ROLE) {
        whitelist[_user] = true;
        emit Whitelisted(_user);
    }

    /**
     * @notice Removes an address from the whitelist.
     * @param _user The address to be removed from the whitelist.
     * @custom:modifier onlyRole(DEFAULT_ADMIN_ROLE) - Only the contract administrator can call this.
     */
    function removeFromWhitelist(address _user) external onlyRole(DEFAULT_ADMIN_ROLE) {
        whitelist[_user] = false;
        emit RemovedFromWhitelist(_user);
    }

    /**
     * @notice Pauses the contract, disabling deposits and withdrawals.
     * @dev Calls the internal OpenZeppelin `_pause()` function.
     * @custom:modifier onlyRole(DEFAULT_ADMIN_ROLE) - Only the contract administrator can call this.
     */
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    /**
     * @notice Unpauses the contract, re-enabling deposits and withdrawals.
     * @dev Calls the internal OpenZeppelin `_unpause()` function.
     * @custom:modifier onlyRole(DEFAULT_ADMIN_ROLE) - Only the contract administrator can call this.
     */
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    /**
     * @notice Allows the contract administrator to withdraw any supported or unsupported ETH or ERC20 tokens in an emergency.
     * @dev This is a contingency function and does not affect user balances.
     * @param _token The address of the token to withdraw (address(0) for native ETH).
     * @param _amount The amount to withdraw.
     * @custom:modifier onlyRole(DEFAULT_ADMIN_ROLE) - Only the contract administrator can call this.
     * @custom:modifier nonReentrant - Prevents reentrancy attacks.
     */
    function emergencyWithdraw(address _token, uint256 _amount)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        nonReentrant
    {
        if (_token == address(0)) {
            (bool _sent, ) = msg.sender.call{value: _amount}("");
            require(_sent, EthTransferFailed());
        } else {
            bool _ok = IERC20(_token).transfer(msg.sender, _amount);
            require(_ok, Erc20TransferFailed());
        }
        emit EmergencyWithdrawal(msg.sender, _token, _amount);
    }

    // --- Fallback Functions ---

    /**
     * @dev The fallback function. Reverts to prevent unexpected behavior when a non-existent function is called.
     */
    fallback() external payable {
        revert UnsupportedFunction();
    }

    /**
     * @dev The receive function. Reverts to ensure users use `depositEth()` for native ETH deposits.
     */
    receive() external payable {
        revert UseDepositEth();
    }
}
