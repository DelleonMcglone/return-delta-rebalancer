# Return Delta Rebalancer

An autonomous liquidity management system for Uniswap v4 that uses Return Delta Hooks and Coinbase AgentKit to automatically rebalance LP positions when returns degrade.

## Overview

The Return Delta Rebalancer is a Uniswap v4 hook that:
- **Tracks LP position performance** by calculating return delta (fees earned vs. impermanent loss)
- **Monitors return thresholds** and emits events when positions fall below -2% return
- **Enables autonomous rebalancing** via Coinbase AgentKit agents that respond to on-chain events
- **Captures swap fees** (1% of volume) into internal reserves for efficient rebalancing
- **Uses Return Delta hooks** to atomically rebalance positions without leaving the PoolManager

Demonstrating agent-driven financial systems on Uniswap v4.

## Architecture

### Hook Contract (`ReturnDeltaRebalancer.sol`)

**Key Features:**
- Tracks position metrics: liquidity, fees earned, initial value, return delta
- Calculates return delta in basis points: `(current_value + fees - initial_value) / initial_value * 10000`
- Emits `RebalanceThresholdBreached` event when return delta < -200 bps (-2%)
- Uses `beforeSwapReturnDelta` to intercept and modify swap execution
- Maintains internal reserves from captured fees for gas-efficient rebalancing

**Hook Permissions:**
```solidity
afterInitialize: true
afterAddLiquidity: true
afterRemoveLiquidity: true
beforeSwap: true
afterSwap: true
beforeSwapReturnDelta: true
afterSwapReturnDelta: true
```

### Agent Integration (Coming Soon)

The Coinbase AgentKit Python agent will:
1. Monitor `RebalanceThresholdBreached` events via websocket
2. Analyze position health and determine rebalancing strategy
3. Execute rebalancing transaction with `hookData = 0x01` flag
4. Confirm success via `PositionRebalanced` event

## Project Structure
```
return-delta-rebalancer/
├── src/
│   └── ReturnDeltaRebalancer.sol    # Main hook contract
├── test/
│   └── ReturnDeltaRebalancer.t.sol  # Foundry tests
├── script/
│   └── Deploy.s.sol                 # Deployment script
├── lib/                              # Dependencies (v4-core, v4-periphery)
└── foundry.toml                      # Foundry configuration
```

## Getting Started

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)
- [Git](https://git-scm.com/downloads)
- Unichain Sepolia ETH for deployment

### Installation
```bash
# Clone the repository
git clone https://github.com/DelleonMcglone/return-delta-rebalancer.git
cd return-delta-rebalancer

# Install dependencies
forge install

# Build the project
forge build
```

### Testing
```bash
# Run all tests
forge test

# Run tests with verbosity
forge test -vv

# Run specific test
forge test --match-test test_HookPermissions -vvv
```

**Test Results:**
```
[PASS] test_Constants() (gas: 6437)
[PASS] test_HookPermissions() (gas: 8649)
[PASS] test_InitialState() (gas: 10527)
```

## Deployment

### 1. Set up environment variables

Create a `.env` file:
```bash
PRIVATE_KEY=your_private_key_here
UNICHAIN_SEPOLIA_RPC=https://sepolia.unichain.org
```

### 2. Deploy to Unichain Sepolia
```bash
# Load environment variables
source .env

# Deploy the hook
forge script script/Deploy.s.sol:DeployScript \
  --rpc-url $UNICHAIN_SEPOLIA_RPC \
  --broadcast \
  --verify \
  -vvvv
```

## Contract Addresses

### Unichain Sepolia Testnet (Chain ID: 1301)
- **PoolManager**: `0x00b036b58a818b1bc34d502d3fe730db729e62ac`
- **Universal Router**: `0xf70536b3bcc1bd1a972dc186a2cf84cc6da6be5d`
- **PositionManager**: `0xf969aee60879c54baaed9f3ed26147db216fd664`

## Key Events

The hook emits the following events for agent monitoring:
```solidity
// Emitted after every swap with updated metrics
event ReturnDeltaUpdated(
    address indexed owner,
    PoolId indexed poolId,
    int256 returnDelta,
    uint256 feesEarned0,
    uint256 feesEarned1,
    uint256 currentValue
);

// Emitted when rebalancing threshold is breached (AGENT TRIGGER)
event RebalanceThresholdBreached(
    address indexed owner,
    PoolId indexed poolId,
    int256 returnDelta,
    int256 thresholdBps
);

// Emitted when rebalancing is executed
event PositionRebalanced(
    address indexed owner,
    PoolId indexed poolId,
    uint256 amount0Rebalanced,
    uint256 amount1Rebalanced,
    int256 newReturnDelta
);

// Emitted when fees are captured
event FeesCaptured(
    PoolId indexed poolId,
    uint256 amount0,
    uint256 amount1
);
```

## Usage Example

### For LPs:

1. Add liquidity to a Uniswap v4 pool with this hook enabled
2. The hook tracks your position's return delta automatically
3. When returns fall below -2%, the hook emits `RebalanceThresholdBreached`
4. An AgentKit agent detects the event and executes rebalancing
5. Your position is automatically optimized without manual intervention

### For Agents:
```python
# Coming soon: AgentKit integration example
# Monitor events, analyze position, execute rebalancing
```

## Technical Details

### Return Delta Calculation
```solidity
// Simplified formula
currentValue = estimatePositionValue(liquidity)
totalFees = feesEarned0 + feesEarned1
netChange = (currentValue + totalFees) - initialValue
returnDelta = (netChange * 10000) / initialValue  // in basis points
```

### Rebalancing Mechanism

1. Agent detects `RebalanceThresholdBreached` event
2. Agent calls swap with `hookData = 0x01` (rebalance flag)
3. Hook's `beforeSwap` intercepts and checks flag
4. Hook uses internal reserves to facilitate swap
5. Hook adjusts position using `beforeSwapReturnDelta`
6. Transaction completes atomically

### Fee Capture

- Captures 1% of swap volume via `afterSwapReturnDelta`
- Stores fees in internal reserves per pool
- Uses reserves for gas-efficient rebalancing
- No external token transfers needed during rebalancing

## Development

### Format code
```bash
forge fmt
```

### Generate gas snapshots
```bash
forge snapshot
```

### Interact with contracts using Cast
```bash
# Get position metrics
cast call <HOOK_ADDRESS> "getPositionMetrics(address,bytes32)" <OWNER> <POOL_ID> --rpc-url $UNICHAIN_SEPOLIA_RPC

# Get internal reserves
cast call <HOOK_ADDRESS> "getReserves(bytes32)" <POOL_ID> --rpc-url $UNICHAIN_SEPOLIA_RPC
```

## Resources

- [Uniswap v4 Docs](https://docs.uniswap.org/contracts/v4/overview)
- [Uniswap v4 Return Delta Hooks](https://github.com/Uniswap/v4-core)
- [Coinbase AgentKit](https://docs.cdp.coinbase.com/agentkit/docs/welcome)
- [Foundry Book](https://book.getfoundry.sh/)

## Contributing

Built by [Delleon McGlone](https://github.com/DelleonMcglone).

## License

MIT

## Acknowledgments

- Uniswap Labs for v4 architecture
- Coinbase for AgentKit
- Foundry team for development tools
