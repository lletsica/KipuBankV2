// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title KipuBank - Un contrato de boveda personal con limites de deposito y retiro.
/// @author lletsica
/// @notice Contrato que permite a los usuarios depositar y retirar tokens nativos (ETH).
contract KipuBank {

    /*///////////////////////////////////
           Variables de estado
    ///////////////////////////////////*/
    /// @notice Mapeo de direcciones con su saldo.
    mapping(address => uint256) public userBalances;
    /// @notice Limite global total de depósitos que puede contener el contrato.
    uint256 public immutable bankCap;
    /// @notice Limite máximo de ETH que se puede retirar en una sola transaccion.
    uint256 public immutable maxWithdrawalPerTx;
    /// @notice El saldo total de ETH depositado en el contrato.
    uint256 public totalEth;
    /// @notice Contador de retiros exitosos.
    uint256 public withdrawalCounter;
    /// @notice Contador de depositos exitosos.
    uint256 private depositCounter;
    /*///////////////////////////////////
               Eventos
    ///////////////////////////////////*/
    /// @dev Evento que se emite cuando un usuario deposita fondos exitosamente.
    /// @param user La direccion del usuario que hizo el deposito.
    /// @param amount La cantidad de ETH depositada.
    event Deposit(address indexed user, uint256 amount);
    /// @dev Evento que se emite cuando un usuario retira fondos exitosamente.
    /// @param user La direccion del usuario que hizo el retiro.
    /// @param amount La cantidad de ETH retirada.
    event Withdrawal(address indexed user, uint256 amount);

    /*///////////////////////////////////
                Errores Custom
    ///////////////////////////////////*/
    /// @dev Error para cuando el monto del deposito es cero.
    error DepositAmountZero();
    /// @dev Error para cuando el monto del retiro es cero.
    error WithdrawalAmountZero();
    /// @dev Error para cuando el deposito excede el limite global del banco.
    error DepositExceedsBankCap();
    /// @dev Error para Saldo Insuficiente.
    error InsufficientUserBalance();
    /// @dev Error para cuando el monto del retiro excede el limite por transaccion.
    error WithdrawalExceedsLimit(uint256 maxWithdrawal);

    /*///////////////////////////////////
            Modifiers
    ///////////////////////////////////*/
    /// @dev Modificador para validar que el monto del RETIRO no sea cero.
    modifier nonZeroWithdrawal(uint256 _amount) {
        if (_amount == 0) {
            revert WithdrawalAmountZero();
        }
        _;
    }
    /// @dev Modificador para validar que el monto del DEPOSITO no sea cero.
    modifier nonZeroDeposit() {
        if (msg.value == 0) {
            revert DepositAmountZero();
        }
        _;
    }
    /*/////////////////////////
            Constructor
    /////////////////////////*/
    /// @dev Constructor para inicializar el contrato.
    /// @param _bankCap El limite global de deposito en wei.
    /// @param _maxWithdrawalPerTx El limite de retiro por transaccion en wei.
    constructor(uint256 _bankCap, uint256 _maxWithdrawalPerTx) {
        bankCap = _bankCap;
        maxWithdrawalPerTx = _maxWithdrawalPerTx;
    }

    /*/////////////////////////
            External
    /////////////////////////*/
    /// @notice Permite a los usuarios depositar tokens nativos (ETH) en su boveda personal.
    /// @dev El deposito no puede ser cero y no puede exceder el limite global.
    /// @custom:security Respeta el patron checks-effects-interactions.
    /// @custom:event Emite un evento 'Deposit'.
    function deposit() external payable nonZeroDeposit() {
        if (totalEth + msg.value > bankCap) {
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
    /*/////////////////////////
        Private
    /////////////////////////*/
    /// @dev Funcion privada, no accesible desde el exterior
    /// @param _amount Monto del retiro
    /// @notice Valida el limite a retirar
    function _validateWithdrawalLimits(uint256 _amount) private view {
        if (_amount > maxWithdrawalPerTx) {
            revert WithdrawalExceedsLimit(maxWithdrawalPerTx);
        }
        if (_amount > userBalances[msg.sender]) {
            revert InsufficientUserBalance();
        }
    }

    /*/////////////////////////
          View & Pure
    /////////////////////////*/
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
