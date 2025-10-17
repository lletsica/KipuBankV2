// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title KipuBank - A personal vault contract with deposit and withdrawal limits.
/// @author lletsica
/// @notice Contract that allows users to deposit and withdraw native tokens (ETH) and USDC.
contract KipuBankV2 {
    /// @notice Total global limit of deposits that the contract may contain.
    uint256 public immutable BANK_CAP;
    /// @notice Maximum amount of ETH that can be withdrawn in a single transaction.
    uint256 public immutable MAX_WITHD_PER_TX;
    
    /// @notice The total balance of ETH deposited into the contract.
    uint256 public totalEth;
    /// @notice Successful withdrawal counter.
    uint256 public withdrawalCounter;
    /// @notice Successful deposit counter.
    uint256 private depositCounter;
    
    /// @notice Mapping addresses with their balance.
    mapping(address => uint256) public userBalances;
    
    /// @dev Event Deposit: it is emitted when a user successfully deposits funds.
    /// @param user: The address of the user who made the deposit.
    /// @param amount: The amount of ETH deposited.
    event Deposit(address indexed user, uint256 amount);

    /// @dev Event Withdrawal: it is emitted when a user successfully withdraws funds.
    /// @param user The address of the user who made the withdrawal.
    /// @param amount is the amount of ETH withdrawn.
    event Withdrawal(address indexed user, uint256 amount);

    /// @dev Error that is thrown when the deposit amount is zero.
    error DepositAmountZero();
    /// @dev Error that is thrown when the withdrawal amount is zero.
    error WithdrawalAmountZero();
    /// @dev Error that is thrown when the deposit exceeds the bank's global limit.
    error DepositExceedsBankCap();
    /// @dev Error that is thrown when the balance is insufficient.
    error InsufficientUserBalance();
    /// @dev Error that is thrown when the withdrawal amount exceeds the transaction limit.
    error WithdrawalExceedsLimit(uint256 maxWithdrawal);

    /// @dev Constructor to initialize the contract.
    /// @param _bankCap The overall deposit limit (wei).
    /// @param _maxWithdrawalPerTx The withdrawal limit per transaction (wei).
    constructor(uint256 _bankCap, uint256 _maxWithdrawalPerTx) {
        BANK_CAP = _bankCap;
        MAX_WITHD_PER_TX = _maxWithdrawalPerTx;
    }

    /// @dev Modifier to validate that the WITHDRAWAL amount is not zero.
    /// @param _amount is the withdrawal amount
    modifier nonZeroWithdrawal(uint256 _amount) {
        if (_amount == 0) {
            revert WithdrawalAmountZero();
        }
        _;
    }
    
    /// @dev Modifier to validate that the DEPOSIT amount is not zero.
    modifier nonZeroDeposit() {
        if (msg.value == 0) {
            revert DepositAmountZero();
        }
        _;
    }

    /// @notice Permite a los usuarios depositar tokens nativos (ETH) en su boveda personal.
    /// @dev El deposito no puede ser cero y no puede exceder el limite global.
    /// @custom:security Respeta el patron checks-effects-interactions.
    /// @custom:event Emite un evento 'Deposit'.
    function deposit() external payable nonZeroDeposit() {
        if (totalEth + msg.value > BANK_CAP) {
            revert DepositExceedsBankCap();
        }
        userBalances[msg.sender] += msg.value;
        totalEth += msg.value;
        ++depositCounter;
        emit Deposit(msg.sender, msg.value);
    }

    /// @notice Permite a los usuarios retirar fondos de su boveda personal.
    /// @dev El retiro no puede ser cero, no puede exceder el limite por transaccion y el usuario debe tener fondos suficientes.
    /// @param _amount La cantidad de ETH a retirar en wei.
    /// @custom:security Respeta el patron checks-effects-interactions y transfiere de forma segura.
    /// @custom:event Emite un evento 'Withdrawal'.
    function withdraw(uint256 _amount) external nonZeroWithdrawal(_amount) {
        // Chequeos
        _validateWithdrawalLimits(_amount);
        // Descuenta el saldo del user que quiere retirar
        userBalances[msg.sender] -= _amount;
        totalEth -= _amount; //resta del total del  contrato
        ++withdrawalCounter;
        // Interacciones
        (bool sent,) = msg.sender.call{value: _amount}(""); //call no limita el gas
        require(sent, "Failed to send Ether"); //verifica si fue exitoso
        emit Withdrawal(msg.sender, _amount);
    }

    /// @dev Funcion privada, no accesible desde el exterior
    /// @param _amount Monto del retiro
    /// @notice Valida el limite a retirar
    function _validateWithdrawalLimits(uint256 _amount) private view {
        if (_amount > MAX_WITHD_PER_TX) {
            revert WithdrawalExceedsLimit(MAX_WITHD_PER_TX);
        }
        if (_amount > userBalances[msg.sender]) {
            revert InsufficientUserBalance();
        }
    }

    /// @notice Devuelve el saldo de ETH de un usuario.
    /// @param _user La direccion del usuario.
    /// @return El saldo de ETH del usuario.
    function getUserBalance(address _user) external view returns (uint256) {
        return userBalances[_user];
    }

    /// @notice Devuelve el numero total de depositos realizados.
    /// @return El conteo total de depositos.
    function getDepositCounter() public view returns (uint256) {
        return depositCounter;
    }
}
