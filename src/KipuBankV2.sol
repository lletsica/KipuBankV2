// SPDX-License-Identifier: MIT
pragma solidity >=0.8.20 <0.8.31;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/// @title KipuBankV2 - A dual-token custodial bank with whitelist and role-based access
/// @notice Supports ETH and USDC deposits/withdrawals with Chainlink price feed integration
/// @dev Uses OpenZeppelin for access control, pausing, and reentrancy protection
contract KipuBankV2 is AccessControl, ReentrancyGuard, Pausable {
    /// @notice Role identifier for depositors
    bytes32 public constant DEPOSITOR_ROLE = keccak256("DEPOSITOR_ROLE");

    /// @notice Role identifier for withdrawers
    bytes32 public constant WITHDRAWER_ROLE = keccak256("WITHDRAWER_ROLE");

    /// @notice Maximum ETH capacity allowed in the bank
    uint256 public immutable BANK_CAP;

    /// @notice Maximum withdrawal amount allowed per transaction
    uint256 public immutable MAX_WITHD_PER_TX;

    /// @notice ERC20 token interface for USDC
    IERC20 public immutable usdcToken;

    /// @notice Number of decimals used by USDC token
    uint8 public immutable usdcDecimals;

    /// @notice Total ETH held by the contract
    uint256 public totalEth;

    /// @notice Counter tracking total withdrawals
    uint256 public withdrawalCounter;

    /// @notice Counter tracking total deposits
    uint256 public depositCounter;

    /// @notice Chainlink price feed for ETH/USD
    AggregatorV3Interface public priceFeed;

    /// @notice Mapping of user ETH balances (in wei)
    mapping(address => uint256) public userEthBalances;

    /// @notice Mapping of user USDC balances (in token units)
    mapping(address => uint256) public userUsdcBalances;

    /// @notice Whitelist status for each user
    mapping(address => bool) public whitelist;

    /// @notice Emitted when ETH is deposited
    event DepositEth(address indexed user, uint256 amount);

    /// @notice Emitted when USDC is deposited
    event DepositUsdc(address indexed user, uint256 amount);

    /// @notice Emitted when a withdrawal occurs
    event Withdrawal(address indexed user, address indexed token, uint256 amount);

    /// @notice Emitted when a user is added to the whitelist
    event Whitelisted(address indexed user);

    /// @notice Emitted when a user is removed from the whitelist
    event RemovedFromWhitelist(address indexed user);

    /// @notice Emitted during emergency withdrawals by admin
    event EmergencyWithdrawal(address indexed admin, address indexed token, uint256 amount);

    /// @dev Thrown when deposit amount is zero
    error DepositAmountZero();

    /// @dev Thrown when withdrawal amount is zero
    error WithdrawalAmountZero();

    /// @dev Thrown when deposit exceeds bank capacity
    error DepositExceedsBankCap();

    /// @dev Thrown when user has insufficient balance
    error InsufficientUserBalance();

    /// @dev Thrown when withdrawal exceeds per-transaction limit
    error WithdrawalExceedsLimit(uint256 maxWithdrawal);

    /// @dev Thrown when user is not whitelisted
    error NotWhitelisted(address user);

    /// @dev Thrown when token address is invalid
    error InvalidTokenAddress();

    /// @notice Initializes the contract with configuration parameters
    /// @param _bankCap Maximum ETH capacity
    /// @param _maxWithdrawalPerTx Maximum withdrawal per transaction
    /// @param _usdcAddress USDC token contract address
    /// @param _priceFeedAddress Chainlink ETH/USD price feed address
    /// @param _usdcDecimals Number of decimals for USDC
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

    /// @dev Ensures deposit amount is non-zero
    modifier nonZero(uint256 _amt) {
        if (_amt == 0) revert DepositAmountZero();
        _;
    }

    /// @dev Ensures withdrawal amount is non-zero
    modifier nonZeroWithdrawal(uint256 _amt) {
        if (_amt == 0) revert WithdrawalAmountZero();
        _;
    }

    /// @dev Ensures user is whitelisted
    modifier onlyWhitelisted(address _user) {
        if (!whitelist[_user]) revert NotWhitelisted(_user);
        _;
    }

    /// @dev Validates withdrawal limits and user balance
    modifier validWithdrawal(uint256 _amt) {
        if (_amt > MAX_WITHD_PER_TX) revert WithdrawalExceedsLimit(MAX_WITHD_PER_TX);
        if (_amt > userEthBalances[msg.sender]) revert InsufficientUserBalance();
        _;
    }

    /// @notice Deposit ETH into the bank
    function depositEth()
        external
        payable
        whenNotPaused
        onlyRole(DEPOSITOR_ROLE)
        onlyWhitelisted(msg.sender)
        nonZero(msg.value)
    {
        uint256 incoming = msg.value;
        if (totalEth + incoming > BANK_CAP) revert DepositExceedsBankCap();

        unchecked {
            userEthBalances[msg.sender] += incoming;
            totalEth += incoming;
            ++depositCounter;
        }
        emit DepositEth(msg.sender, incoming);
    }

    /// @notice Returns ETH balance of a user
    /// @param user Address of the user
    /// @return ETH balance in wei
    function getUserEthBalance(address user) external view returns (uint256) {
        return userEthBalances[user];
    }

    /// @notice Returns USDC balance of a user
    /// @param user Address of the user
    /// @return USDC balance in token units
    function getUserUsdcBalance(address user) external view returns (uint256) {
        return userUsdcBalances[user];
    }

    /// @notice Returns total USD value of user's ETH and USDC holdings
    /// @param _user Address of the user
    /// @return totalUsd Total value in USD (8 decimals)
    function getUserTotalUsd(address _user) external view returns (uint256 totalUsd) {
        uint256 _ethBalance = userEthBalances[_user];
        uint256 _usdcBalance = userUsdcBalances[_user];
        uint256 _ethPrice = getLatestEthPrice();
        uint256 _ethUsdValue = (_ethBalance * _ethPrice) / 1e18;
        uint256 _usdcUsdValue = _usdcBalance * 1e2;
        return _ethUsdValue + _usdcUsdValue;
    }

    /// @notice Fetches latest ETH/USD price from Chainlink
    /// @return ETH price in USD with 8 decimals
    function getLatestEthPrice() public view returns (uint256) {
        (, int256 price, , , ) = priceFeed.latestRoundData();
        require(price > 0, "Invalid price");
        return uint256(price);
    }

    /// @notice Converts ETH amount in wei to USD
    /// @param weiAmount Amount in wei
    /// @return USD value with 8 decimals
    function ethWeiToUsd(uint256 weiAmount) public view returns (uint256) {
        uint256 ethPrice = getLatestEthPrice();
        return (weiAmount * ethPrice) / 1e18;
    }

    /// @notice Withdraw ETH from the bank
    /// @param _amount Amount in wei
    function withdrawEth(uint256 _amount)
        external
        nonZeroWithdrawal(_amount)
        validWithdrawal(_amount)
        whenNotPaused
        nonReentrant
        onlyRole(WITHDRAWER_ROLE)
        onlyWhitelisted(msg.sender)
    {
        unchecked {
            userEthBalances[msg.sender] -= _amount;
            totalEth -= _amount;
            ++withdrawalCounter;
        }
        (bool sent, ) = msg.sender.call{value: _amount}("");
        require(sent, "ETH transfer failed");
        emit Withdrawal(msg.sender, address(0), _amount);
    }

	/// @notice Allows a whitelisted user to withdraw USDC from their balance
	/// @dev Validates withdrawal limits and user balance before transferring tokens
	/// @param _amount Amount of USDC to withdraw (in token units)
	function withdrawUSDC(uint256 _amount)
		external
		whenNotPaused
		nonReentrant
		onlyRole(WITHDRAWER_ROLE)
		onlyWhitelisted(msg.sender)
		nonZeroWithdrawal(_amount)
	{
		if (_amount > userUsdcBalances[msg.sender]) revert InsufficientUserBalance();
		_validateWithdrawalUsdcLimits(_amount);

		unchecked {
			userUsdcBalances[msg.sender] -= _amount;
			++withdrawalCounter;
		}

		usdcToken.transfer(msg.sender, _amount);
		emit Withdrawal(msg.sender, address(usdcToken), _amount);
	}

	/// @notice Allows a whitelisted user to deposit USDC into the bank
	/// @dev Transfers USDC from sender and updates internal balance and counters
	/// @param _amount Amount of USDC to deposit (in token units)
	function depositUSDC(uint256 _amount)
		external
		whenNotPaused
		onlyRole(DEPOSITOR_ROLE)
		onlyWhitelisted(msg.sender)
		nonZero(_amount)
	{
		usdcToken.transferFrom(msg.sender, address(this), _amount);
		unchecked {
			userUsdcBalances[msg.sender] += _amount;
			++depositCounter;
		}
		emit DepositUsdc(msg.sender, _amount);
	}

	/// @notice Adds a user to the whitelist, enabling deposits and withdrawals
	/// @dev Only callable by admin
	/// @param _user Address to be whitelisted
	function addToWhitelist(address _user) external onlyRole(DEFAULT_ADMIN_ROLE) {
		whitelist[_user] = true;
		emit Whitelisted(_user);
	}

	/// @notice Removes a user from the whitelist, disabling deposits and withdrawals
	/// @dev Only callable by admin
	/// @param _user Address to be removed from whitelist
	function removeFromWhitelist(address _user) external onlyRole(DEFAULT_ADMIN_ROLE) {
		whitelist[_user] = false;
		emit RemovedFromWhitelist(_user);
	}

	/// @notice Pauses all deposit and withdrawal operations
	/// @dev Only callable by admin; uses OpenZeppelin's Pausable
	function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
		_pause();
	}

	/// @notice Unpauses all deposit and withdrawal operations
	/// @dev Only callable by admin; uses OpenZeppelin's Pausable
	function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
		_unpause();
	}

	/// @notice Allows admin to withdraw ETH or ERC20 tokens in emergency
	/// @dev If amount is zero, withdraws full balance. ETH uses low-level call.
	/// @param _token Address of token to withdraw (use address(0) for ETH)
	/// @param _amount Amount to withdraw (0 for full balance)
	/// @param _to Recipient address
	function emergencyWithdraw(address _token, uint256 _amount, address _to)
		external
		onlyRole(DEFAULT_ADMIN_ROLE)
		nonReentrant
	{
		require(_to != address(0), "Invalid recipient");

		if (_token == address(0)) {
			uint256 bal = address(this).balance;
			uint256 amt = _amount == 0 ? bal : _amount;
			(bool sent, ) = _to.call{value: amt}("");
			require(sent, "ETH emergency transfer failed");
			emit EmergencyWithdrawal(msg.sender, address(0), _amount);
			return;
		}

		IERC20(_token).transfer(_to, _amount);
		emit EmergencyWithdrawal(msg.sender, _token, _amount);
	}

	/// @notice Rejects direct ETH transfers
	/// @dev Use depositEth() instead
	receive() external payable {
		revert("Use depositEth");
	}

	/// @notice Rejects fallback calls
	/// @dev Prevents accidental or unsupported interactions
	fallback() external payable {
		revert("Unsupported");
	}

	/// @notice Validates USDC withdrawal limits and user balance
	/// @dev Internal helper used by withdrawUSDC
	/// @param _amount Amount of USDC to validate
	function _validateWithdrawalUsdcLimits(uint256 _amount) private view {
        uint256 usdMaxValue = MAX_WITHD_PER_TX * 1e2;
		if (_amount > usdMaxValue) {
			revert WithdrawalExceedsLimit(usdMaxValue);
		}
		if (_amount > userUsdcBalances[msg.sender]) {
			revert InsufficientUserBalance();
		}
	}
}
