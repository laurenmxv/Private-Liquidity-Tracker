# Private Liquidity Tracker

A Uniswap v4 hook that tracks liquidity changes using Fully Homomorphic Encryption (FHE), keeping pool metrics confidential until pool owners choose to reveal them.

## Overview

This hook demonstrates privacy-preserving DeFi by encrypting liquidity metrics on-chain. Pool owners can track cumulative liquidity additions and removals without exposing sensitive data to competitors or MEV bots.

### Key Features

- **Encrypted Liquidity Tracking**: All liquidity changes stored as encrypted values on-chain
- **Owner-Only Decryption**: Only pool owners can request and view decrypted metrics
- **Asynchronous Decryption**: Safe, two-step decryption process via Fhenix's decryption network
- **Reset Capability**: Pool owners can reset tracking for epoch-based analysis

## Technology Stack

- **Uniswap v4**: Next-generation AMM with hooks
- **Fhenix CoFHE**: Fully Homomorphic Encryption for confidential computation
- **Foundry**: Development framework for smart contracts

## Installation

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)
- Node.js v16+
- Git

### Setup

1. **Clone the repository**
```bash
git clone https://github.com/marronjo/fhe-hook-template.git liquidity-tracker
cd liquidity-tracker
```

2. **Install dependencies**

The template requires manual installation of Forge dependencies:
```bash
# Install npm packages (if any)
npm install

# Install Forge dependencies manually
forge install Uniswap/v4-core --no-commit
forge install Uniswap/v4-periphery --no-commit
forge install FhenixProtocol/fhenix-contracts --no-commit
forge install foundry-rs/forge-std --no-commit
forge install transmissions11/solmate --no-commit
```

3. **Verify installation**
```bash
# Check dependencies are installed
ls lib/

# Should see:
# - fhenix-contracts/
# - forge-std/
# - solmate/
# - v4-core/
# - v4-periphery/
```

4. **Update foundry.toml**

Ensure your `foundry.toml` has these settings:
```toml
[profile.default]
src = "src"
out = "out"
libs = ["lib"]
solc_version = "0.8.26"
evm_version = "cancun"
via_ir = true
optimizer = true
optimizer_runs = 200
auto_detect_remappings = true
```

5. **Build**
```bash
forge build --via-ir
```

6. **Run tests**
```bash
forge test --via-ir
```

## Usage

### Contract Interface

#### Initialize Pool Tracking

When a pool is initialized, the hook automatically:
- Sets the pool creator as the owner
- Initializes encrypted accumulators to zero
```solidity
// Happens automatically in _afterInitialize
// No manual action needed
```

#### Track Liquidity Changes

The hook automatically tracks liquidity additions and removals:
```solidity
// Adding liquidity
modifyLiquidity(
    poolKey,
    IPoolManager.ModifyLiquidityParams({
        tickLower: -60,
        tickUpper: 60,
        liquidityDelta: 1000e18,
        salt: bytes32(0)
    }),
    ""
);

// Removing liquidity
modifyLiquidity(
    poolKey,
    IPoolManager.ModifyLiquidityParams({
        tickLower: -60,
        tickUpper: 60,
        liquidityDelta: -500e18,  // Negative for removal
        salt: bytes32(0)
    }),
    ""
);
```

#### Request Decryption (Owner Only)
```solidity
// Step 1: Request decryption
hook.requestDecryption(poolKey);

// Step 2: Wait for decryption network to process
// (typically a few seconds to minutes)

// Step 3: Check if ready
(bool requested, bool ready) = hook.isDecryptionReady(poolKey);

// Step 4: Retrieve decrypted values
if (ready) {
    (uint128 token0Total, uint128 token1Total) = hook.getDecryptedMetrics(poolKey);
}
```

#### Reset Tracking (Owner Only)
```solidity
// Reset accumulators to zero
hook.resetTracking(poolKey);
```

## Architecture

### Hook Lifecycle
```
Pool Initialization
    ↓
afterInitialize → Set owner, initialize encrypted zeros
    ↓
Liquidity Addition
    ↓
beforeAddLiquidity → Track encrypted delta, update accumulator
    ↓
Liquidity Removal
    ↓
beforeRemoveLiquidity → Track encrypted delta, update accumulator
    ↓
Owner Requests Decryption
    ↓
requestDecryption → Submit to decryption network
    ↓
Wait for Processing
    ↓
getDecryptedMetrics → Retrieve plaintext values
```

### Key Components

**State Variables:**
- `token0Accumulator`: Encrypted cumulative changes for token0
- `token1Accumulator`: Encrypted cumulative changes for token1
- `poolOwner`: Address authorized to decrypt metrics
- `decryptionRequests`: Tracks pending decryption requests

**FHE Operations:**
- `FHE.asEuint128()`: Convert plaintext to encrypted
- `.add()` / `.sub()`: Homomorphic arithmetic
- `FHE.allowThis()`: Grant contract ACL permission
- `FHE.decrypt()`: Request asynchronous decryption
- `FHE.getDecryptResultSafe()`: Safely retrieve results

## Development

### Project Structure
```
liquidity-tracker/
├── src/
│   ├── Counter.sol                    # Template example (working reference)
│   └── PrivateLiquidityTracker.sol    # Our hook implementation
├── test/
│   ├── Counter.t.sol                  # Template tests
│   └── PrivateLiquidityTracker.t.sol  # Our hook tests
├── script/
│   └── Deploy.s.sol                   # Deployment script
├── lib/                               # Dependencies
├── foundry.toml                       # Foundry configuration
└── README.md
```

### Building
```bash
# Standard build
forge build --via-ir

# Clean build
forge clean && forge build --via-ir

# Build specific file
forge build src/PrivateLiquidityTracker.sol --via-ir
```

### Testing
```bash
# Run all tests
forge test --via-ir

# Run with verbosity
forge test --via-ir -vv

# Run specific test
forge test --via-ir --match-test test_TracksLiquidityAddition

# Run specific contract
forge test --via-ir --match-contract PrivateLiquidityTrackerTest
```

### Deploying

#### Local (Anvil)

**Terminal 1:**
```bash
anvil --code-size-limit 40000
```

**Terminal 2:**
```bash
forge script script/Deploy.s.sol \
    --rpc-url http://localhost:8545 \
    --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
    --broadcast
```

#### Testnet/Mainnet
```bash
# Set environment variables
export POOL_MANAGER_ADDRESS=<pool_manager_address>
export PRIVATE_KEY=<your_private_key>
export RPC_URL=<rpc_url>

# Deploy
forge script script/Deploy.s.sol \
    --rpc-url $RPC_URL \
    --private-key $PRIVATE_KEY \
    --broadcast \
    --verify
```

## Security Considerations

### Access Control

- **Decryption**: Only the pool owner (set at initialization) can request decryption
- **Reset**: Only the pool owner can reset tracking
- **ACL Management**: Always call `FHE.allowThis()` after modifying encrypted state

### Privacy

- **What's Encrypted**: All liquidity amounts and cumulative totals
- **What's Public**: Pool initialization, that a decryption was requested, pool owner address
- **Information Leakage**: Consider what revealing decrypted values exposes to observers

### Best Practices

1. **Always use `FHE.allowThis()`** after creating/modifying encrypted values
2. **Never store `InEuintXX` types** in contract state - convert immediately
3. **Use `FHE.select()`** instead of if/else on encrypted values for constant-time operations
4. **Minimize decryption** - only decrypt when absolutely necessary
5. **Test thoroughly** - FHE operations can fail silently if ACL permissions aren't set

## Common Issues

### 1. Empty lib/ Directory

**Problem:** Imports fail after cloning

**Solution:** Manually install dependencies:
```bash
forge install Uniswap/v4-core --no-commit
forge install Uniswap/v4-periphery --no-commit
forge install FhenixProtocol/fhenix-contracts --no-commit
forge install foundry-rs/forge-std --no-commit
forge install transmissions11/solmate --no-commit
```

### 2. Compilation Errors

**Problem:** `Identifier not found` or import errors

**Solution:** 
- Ensure `auto_detect_remappings = true` in foundry.toml
- Check that all dependencies are in `lib/`
- Always use `--via-ir` flag

### 3. ACLNotAllowed Error

**Problem:** Transaction reverts with ACL error

**Solution:** Make sure you called `FHE.allowThis()` after creating/modifying the encrypted value

### 4. Decryption Not Ready

**Problem:** Can't retrieve decrypted values

**Solution:** Wait longer - decryption is asynchronous. Use `isDecryptionReady()` to poll status.

## Advanced Usage

### Extending the Hook

**Per-User Tracking:**
```solidity
mapping(PoolId => mapping(address => euint128)) public userContributions;
```

**Threshold Alerts:**
```solidity
ebool exceedsThreshold = FHE.gt(accumulator, threshold);
```

**Time-Based Epochs:**
```solidity
struct Epoch {
    uint256 startTime;
    euint128 token0Total;
    euint128 token1Total;
}
```

**Multi-Pool Aggregation:**
```solidity
euint128 totalLiquidity = pool1Acc.add(pool2Acc).add(pool3Acc);
```

## Resources

### Documentation
- [CoFHE Developer Docs](https://cofhe-docs.fhenix.zone/docs/devdocs/)
- [Uniswap v4 Documentation](https://docs.uniswap.org/contracts/v4/overview)
- [fhe-hook-template](https://github.com/marronjo/fhe-hook-template)

### Examples
- `src/Counter.sol` - Working FHE hook example in this repository
- [Uniswap v4 Hook Examples](https://github.com/Uniswap/v4-periphery/tree/main/test)

### Community
- [Fhenix Discord](https://discord.gg/fhenix)
- [Uniswap Discord](https://discord.gg/uniswap)

## License

MIT

## Contributing

Contributions are welcome! Please:

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Add tests
5. Submit a pull request

## Acknowledgments

Built using:
- [fhe-hook-template](https://github.com/marronjo/fhe-hook-template) by @marronjo
- [Fhenix CoFHE Protocol](https://www.fhenix.io/)
- [Uniswap v4](https://uniswap.org/)

## Support

For issues and questions:
- Open an issue on GitHub
- Ask in Fhenix Discord #developers channel
- Check the [tutorial](./TUTORIAL.md) for detailed explanations

---

**⚠️ Disclaimer:** This is experimental software. Use at your own risk. Always audit smart contracts before deploying to mainnet.

## 📖 Resources

Fhenix 🔒
- [FHE Limit Order Hook](https://github.com/marronjo/iceberg-cofhe)
- [CoFhe docs](https://cofhe-docs.fhenix.zone/docs/devdocs/overview)
- [FHERC20 Token Docs](https://cofhe-docs.fhenix.zone/docs/devdocs/fherc/fherc20)

Uniswap 🦄
- [Hook Examples](https://github.com/Uniswap/v4-periphery/tree/example-contracts/contracts/hooks/examples)
- [Uniswap v4 docs](https://docs.uniswap.org/contracts/v4/overview)  
- [v4-periphery](https://github.com/uniswap/v4-periphery)  
- [v4-core](https://github.com/uniswap/v4-core)  
- [v4-by-example](https://v4-by-example.org)  

