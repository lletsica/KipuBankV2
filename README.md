**KipuBank — Personal Vault Smart Contract**
KipuBank is a modular smart contract system for managing ETH and USDC balances with deposit/withdrawal limits, role-based access, and Chainlink price feed integration. It is designed to be secure, auditable, and extensible for creators, brands, and platforms seeking tokenized financial infrastructure
KipuBankV2
- Introduces USDC support via ERC20 interface
- Adds Chainlink price feed for ETH/USD conversion
- Implements role-based access control (DEPOSITOR_ROLE, WITHDRAWER_ROLE)
- Adds whitelist system for KYC or gated access
- Integrates Pausable and ReentrancyGuard for operational safety
- Tracks USD-equivalent balances for ETH and USDC
- Adds emergency withdrawal functionality for admins
**Deployment & Interaction in Remix**
Prerequisites
- Remix IDE (https://remix.ethereum.org)
- MetaMask or injected Web3 wallet
- ETH and USDC test tokens (e.g. via Sepolia)
Steps
- Import Contract
- Copy KipuBankV2.sol into a new Remix file
- Ensure OpenZeppelin and Chainlink interfaces are available via Remix's GitHub import system
- Compile
- Use Solidity version 0.8.26
- Enable optimization if desired
- Deploy
- Provide constructor parameters:
- bankCap: max ETH capacity (in wei) Example: 100000000000000000000 for 100ETH
- maxWithdrawalPerTx: max withdrawal per tx. Example: 5000000000000000000 for 5ETH
- usdcAddress: ERC20 token address Example: 0x1c7d4b196cb0c7b01d743fbc6116a902379c7238 //USDC Address in Sepolia Network
- priceFeedAddress: Chainlink ETH/USD feed- Example: 0x694AA1769357215DE4FAC081bf1f309aDC325306 //Sepolia Chainlink PriceFeed ETH/USDC 
- usdcDecimals: typically 6 for USDC
**- Interact**
- Use addToWhitelist(address) to enable users
- Use depositEth() and depositUSDC(amount) to fund vaults
- Use withdrawEth(amount) and withdrawUSDC(amount) to retrieve funds
- Use getUserTotalUsd(address) to view USD-equivalent balances
- Admins can pause(), unpause(), or emergencyWithdraw(token, amount, to)


