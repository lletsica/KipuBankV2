KipuBankV2 es un contrato de bóbeda personal que soporta depósitos y retiros en ETH y USDC con control de acceso por roles, whitelist (KYC), integración de precio en tiempo real vía Chainlink, pausabilidad y protección contra reentrancy. Principales características:
- Role-based access control (DEFAULT_ADMIN_ROLE, DEPOSITOR_ROLE, WITHDRAWER_ROLE).
- Depósitos ETH con tope global (BANK_CAP) y límite por retiro por transacción (MAX_WITHD_PER_TX).
- Depósitos/withdrawals de USDC.
- Whitelist para permitir solo usuarios KYC en flujos críticos.
- Chainlink ETH/USD para conversiones y visualización de valor.
- Pausable y emergencyWithdraw administrado por DEFAULT_ADMIN_ROLE (se recomienda multisig).
- ReentrancyGuard aplicado en rutas de retiro.

Prepara el contrato en Remix
- Abre https://remix.ethereum.org.
- Crea un nuevo espacio de trabajo/archivo y pega el código fuente del contrato KipuBankV2.
- Confirma que las líneas de importación usen las rutas de OpenZeppelin y Chainlink exactamente como en el código fuente
- En el explorador de archivos izquierdo, asegúrate de que todos los archivos del contrato se compilen sin errores de importación.

Configuración de compilación
- Ve a la pestaña "Compilador de Solidity".
- Configura el compilador a la versión 0.8.26 (coincidencia exacta) y activa "Autocompilación" o haz clic en "Compilar".
- Activa "Habilitar optimización" si se implementa en la red principal (configura las ejecuciones según tus necesidades, p. ej., 200).
- Confirma que el contrato compilado aparezca en "Detalles de la compilación" sin errores.

Seleccionar entorno y cuenta
- Abra la pestaña "Implementar y ejecutar transacciones".
- Elija el entorno:
- "Proveedor inyectado - MetaMask" para implementar con su cuenta MetaMask en una red de prueba/red principal.
- "Remix VM (Londres)" para pruebas efímeras locales.
- "Proveedor Web3" para una RPC personalizada (por ejemplo, localhost o un nodo de archivo).
- Seleccione la cuenta (el implementador) y confirme que la red en MetaMask coincida con la red de destino.

Implementar el contrato
- En "Implementar y ejecutar transacciones", seleccione el contrato KipuBankV2 compilado en el menú desplegable.
- Proporcione los argumentos del constructor en este orden:
- BANK_CAP como un entero en wei (ejemplo: use la conversión al estilo de ethers.js externamente o calcule manualmente; para 1000 ETH, use 1000 * 1e18). - MAX_WITHD_PER_TX en wei (p. ej., 5 * 1e18 para 5 ETH).
- _usdcAddress: la dirección del contrato del token ERC20 USDC en la red de destino.
- _priceFeedAddress: la dirección del feed de precios de Chainlink ETH/USD para esa red.
- _usdcDecimals (uint8), normalmente 6 para USDC.
- Haga clic en "Implementar" y confirme la transacción en MetaMask.
- Espere a que la transacción finalice y anote la dirección del contrato implementado que muestra Remix.

Para interactuar con el contrato:
Depósitos
- ETH:
- Llamar depositEth() enviando value en wei.
- Requisitos: msg.sender debe tener DEPOSITOR_ROLE y estar whitelist si está activado.
- Ejemplo (ethers.js): contract.connect(signer).depositEth({ value: ethers.utils.parseEther("0.1") })
- USDC:
- Primero approve al contrato: usdcContract.approve(kipuAddress, amount)
- Luego depositUSDC(amount) desde la cuenta aprobada.
- Usar SafeERC20; algunos tokens requieren gas extra al aprobar.
Retiros
- ETH:
- withdrawEth(amount) — caller debe tener WITHDRAWER_ROLE y estar whitelist si aplica.
- Se valida MAX_WITHD_PER_TX y balance del usuario.
- USDC:
- withdrawUSDC(amount) — similar condiciones; se transfiere en token units.
Whitelist (admin)
- addToWhitelist(address) — sólo DEFAULT_ADMIN_ROLE.
- removeFromWhitelist(address) — sólo DEFAULT_ADMIN_ROLE.
Administración
- pause() / unpause() — detener/reanudar funciones protegidas por whenNotPaused. Solo DEFAULT_ADMIN_ROLE.
- emergencyWithdraw(token, amount, to) — recuperar ETH o ERC20 en situación de emergencia. token = address(0) para ETH; amount = 0 para ETH envía balance completo. Usar sólo con multisig.
Consultas y utilidades
- getUserEthBalance(address) — balance ETH del usuario (wei).
- getUserUsdcBalance(address) — balance USDC en unidades de token.
- getLatestEthPrice() — precio ETH/USD de Chainlink con 8 decimales (USD * 1e8).
- ethWeiToUsd(weiAmount) — convierte wei a USD con 8 decimales (resultado = USD * 1e8).
