// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/// @title KipuBankV2 - A personal vault contract with deposit and withdrawal limits, role-based access, and Chainlink price feed integration.
/// @author lletsica
/// @notice This contract allows users to deposit and withdraw ETH and USDC, with access controlled via roles and KYC-based whitelisting. It also provides real-time ETH/USD pricing via Chainlink.
contract KipuBankV2 is AccessControl {
    bytes32 public constant DEPOSITOR_ROLE = keccak256("DEPOSITOR_ROLE");
    bytes32 public constant WITHDRAWER_ROLE = keccak256("WITHDRAWER_ROLE");

    IERC20 public usdcToken;
    AggregatorV3Interface internal priceFeed;

    mapping(address => uint256) public userUsdcBalances;
    mapping(address => bool) public whitelist;
    uint256 public immutable BANK_CAP;
    uint256 public immutable MAX_WITHD_PER_TX;
    uint256 public totalEth;
    uint256 public withdrawalCounter;
    uint256 private depositCounter;
    mapping(address => uint256) public userBalances;

    event Deposit(address indexed user, uint256 amount);
    event Withdrawal(address indexed user, uint256 amount);
    event Whitelisted(address indexed user);
    event RemovedFromWhitelist(address indexed user);

    error DepositAmountZero();
    error WithdrawalAmountZero();
    error DepositExceedsBankCap();
    error InsufficientUserBalance();
    error WithdrawalExceedsLimit(uint256 maxWithdrawal);

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

    modifier nonZeroWithdrawal(uint256 _amount) {
        if (_amount == 0) {
            revert WithdrawalAmountZero();
        }
        _;
    }

    modifier nonZeroDeposit() {
        if (msg.value == 0) {
            revert DepositAmountZero();
        }
        _;
    }

    /// @notice Deposits ETH into the user's vault.
    /// @dev Requires DEPOSITOR_ROLE and non-zero deposit.
    function deposit() external payable nonZeroDeposit onlyRole(DEPOSITOR_ROLE) {
        if (totalEth + msg.value > BANK_CAP) {
            revert DepositExceedsBankCap();
        }
        unchecked {
            userBalances[msg.sender] += msg.value;
            totalEth += msg.value;
            ++depositCounter;
        }
        emit Deposit(msg.sender, msg.value);
    }

    /// @notice Withdraws ETH from the user's vault.
    /// @param _amount The amount of ETH to withdraw.
    /// @dev Requires WITHDRAWER_ROLE and sufficient balance.
    function withdraw(uint256 _amount) external nonZeroWithdrawal(_amount) onlyRole(WITHDRAWER_ROLE) {
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

    /// @notice Deposits USDC into the user's vault.
    /// @param amount The amount of USDC to deposit.
    /// @dev Requires DEPOSITOR_ROLE and prior approval via ERC20 `approve`.
    function depositUSDC(uint256 amount) external onlyRole(DEPOSITOR_ROLE) {
        if (amount == 0) revert DepositAmountZero();
        bool success = usdcToken.transferFrom(msg.sender, address(this), amount);
        require(success, "USDC transfer failed");
        unchecked {
            userUsdcBalances[msg.sender] += amount;
            ++depositCounter;
        }
        emit Deposit(msg.sender, amount);
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

    /// @notice Adds a user to the whitelist and grants deposit/withdraw roles.
    /// @param user The address to whitelist.
    /// @dev Only callable by admin. Used after KYC approval.
    function addToWhitelist(address user) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(user != address(0), "Invalid address");
        require(!whitelist[user], "Already whitelisted");
        whitelist[user] = true;
        _grantRole(DEPOSITOR_ROLE, user);
        _grantRole(WITHDRAWER_ROLE, user);
        emit Whitelisted(user);
    }

    /// @notice Removes a user from the whitelist and revokes roles.
    /// @param user The address to remove.
    /// @dev Only callable by admin. Used for KYC revocation or bans.
    function removeFromWhitelist(address user) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(user != address(0), "Invalid address");
        require(whitelist[user], "User not whitelisted");
        whitelist[user] = false;
        if (hasRole(DEPOSITOR_ROLE, user)) {
            _revokeRole(DEPOSITOR_ROLE, user);
        }
        if (hasRole(WITHDRAWER_ROLE, user)) {
            _revokeRole(WITHDRAWER_ROLE, user);
        }
        emit RemovedFromWhitelist(user);
    }

    /// @notice Returns the latest ETH/USD price from Chainlink.
    /// @return ethPrice The current price of 1 ETH in USD (8 decimals).
    function getLatestEthPrice() public view returns (int ethPrice) {
        (, ethPrice, , , ) = priceFeed.latestRoundData();
    }

    /// @dev Validates ETH withdrawal limits and user balance.
    /// @param _amount The amount to validate.
    function _validateWithdrawalLimits(uint256 _amount) private view {
        if (_amount > MAX_WITHD_PER_TX) {
            revert WithdrawalExceedsLimit(MAX_WITHD_PER_TX);
        }
        if (_amount > userBalances[msg.sender]) {
            revert InsufficientUserBalance();
        }
    }

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
}
