// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

contract KipuBankV2 is AccessControl {
    // 1. Immutable / Constant Variables
    uint256 public immutable BANK_CAP;
    uint256 public immutable MAX_WITHD_PER_TX;
    bytes32 public constant DEPOSITOR_ROLE = keccak256("DEPOSITOR_ROLE");
    bytes32 public constant WITHDRAWER_ROLE = keccak256("WITHDRAWER_ROLE");

    // 2. Storage Variables
    uint256 public totalEth;
    uint256 public withdrawalCounter;
    uint256 private depositCounter;
    IERC20 public usdcToken;
    AggregatorV3Interface internal priceFeed;

    // 3. Mappings
    mapping(address => uint256) public userBalances;
    mapping(address => uint256) public userUsdcBalances;
    mapping(address => bool) public whitelist;

    // 4. Events
    event Deposit(address indexed user, uint256 amount);
    event Withdrawal(address indexed user, uint256 amount);
    event Whitelisted(address indexed user);
    event RemovedFromWhitelist(address indexed user);

    // 5. Custom Errors
    error DepositAmountZero();
    error WithdrawalAmountZero();
    error DepositExceedsBankCap();
    error InsufficientUserBalance();
    error WithdrawalExceedsLimit(uint256 maxWithdrawal);

    // 6. Constructor
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

    // 7. Modifiers
    modifier nonZeroWithdrawal(uint256 _amount) {
        if (_amount == 0) revert WithdrawalAmountZero();
        _;
    }

    modifier nonZeroDeposit() {
        if (msg.value == 0) revert DepositAmountZero();
        _;
    }

    // 8. External Payable Function
    function deposit() external payable nonZeroDeposit onlyRole(DEPOSITOR_ROLE) {
        if (totalEth + msg.value > BANK_CAP) revert DepositExceedsBankCap();
        unchecked {
            userBalances[msg.sender] += msg.value;
            totalEth += msg.value;
            ++depositCounter;
        }
        emit Deposit(msg.sender, msg.value);
    }

    // 9. Private Function
    function _validateWithdrawalLimits(uint256 _amount) private view {
        if (_amount > MAX_WITHD_PER_TX) revert WithdrawalExceedsLimit(MAX_WITHD_PER_TX);
        if (_amount > userBalances[msg.sender]) revert InsufficientUserBalance();
    }

    // 10. External View Functions
    function getUserBalance(address _user) external view returns (uint256) {
        return userBalances[_user];
    }

    function getDepositCounter() public view returns (uint256) {
        return depositCounter;
    }

    function getLatestEthPrice() public view returns (int ethPrice) {
        (, ethPrice, , , ) = priceFeed.latestRoundData();
    }

    // External Non-Payable Functions (not part of strict order but included below)
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

    function depositUSDC(uint256 amount) external onlyRole(DEPOSITOR_ROLE) {
        if (amount == 0) revert Deposit
