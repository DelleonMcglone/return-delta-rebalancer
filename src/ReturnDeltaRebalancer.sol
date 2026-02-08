// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Hooks} from "v4-core/libraries/Hooks.sol";
import {BaseTestHooks} from "v4-core/test/BaseTestHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";

/**
 * @title ReturnDeltaRebalancer
 * @notice Autonomous LP manager using Uniswap V4 hooks + Coinbase AgentKit
 */
contract ReturnDeltaRebalancer is BaseTestHooks {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    struct PositionMetrics {
        address owner;
        uint128 liquidity;
        uint256 initialValue;
        uint256 feesEarned0;
        uint256 feesEarned1;
        uint256 lastUpdateBlock;
        int256 returnDelta;
    }

    struct InternalReserves {
        uint256 amount0;
        uint256 amount1;
    }

    IPoolManager public immutable poolManager;

    int256 public constant REBALANCE_THRESHOLD = -200;
    uint256 public constant FEE_CAPTURE_BPS = 100;

    mapping(address => mapping(PoolId => PositionMetrics)) public positions;
    mapping(PoolId => InternalReserves) public reserves;
    mapping(PoolId => bool) private _rebalancing;

    event ReturnDeltaUpdated(
        address indexed owner,
        PoolId indexed poolId,
        int256 returnDelta,
        uint256 feesEarned0,
        uint256 feesEarned1,
        uint256 currentValue
    );

    event RebalanceThresholdBreached(
        address indexed owner,
        PoolId indexed poolId,
        int256 returnDelta,
        int256 thresholdBps
    );

    event PositionRebalanced(
        address indexed owner,
        PoolId indexed poolId,
        uint256 amount0Rebalanced,
        uint256 amount1Rebalanced,
        int256 newReturnDelta
    );

    event FeesCaptured(
        PoolId indexed poolId,
        uint256 amount0,
        uint256 amount1
    );

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: false,
            afterAddLiquidity: true,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: true,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function afterInitialize(
        address,
        PoolKey calldata key,
        uint160,
        int24
    ) external override returns (bytes4) {
        PoolId poolId = key.toId();
        reserves[poolId] = InternalReserves(0, 0);
        return BaseTestHooks.afterInitialize.selector;
    }

    function afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta,
        bytes calldata
    ) external override returns (bytes4, BalanceDelta) {
        PoolId poolId = key.toId();
        PositionMetrics storage position = positions[sender][poolId];

        if (position.owner == address(0)) {
            position.owner = sender;
            position.liquidity = uint128(uint256(int256(params.liquidityDelta)));
            position.initialValue = _estimatePositionValue(key, uint128(uint256(int256(params.liquidityDelta))));
            position.lastUpdateBlock = block.number;
            position.returnDelta = 0;
        } else {
            position.liquidity += uint128(uint256(int256(params.liquidityDelta)));
        }

        return (BaseTestHooks.afterAddLiquidity.selector, delta);
    }

    function afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta,
        bytes calldata
    ) external override returns (bytes4, BalanceDelta) {
        PoolId poolId = key.toId();
        PositionMetrics storage position = positions[sender][poolId];

        position.liquidity -= uint128(uint256(int256(-params.liquidityDelta)));

        if (position.liquidity == 0) {
            delete positions[sender][poolId];
        }

        return (BaseTestHooks.afterRemoveLiquidity.selector, delta);
    }

    function beforeSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata hookData
    ) external override returns (bytes4, BeforeSwapDelta, uint24) {
        PoolId poolId = key.toId();

        bool isRebalance = hookData.length > 0 && hookData[0] == 0x01;

        if (isRebalance && !_rebalancing[poolId]) {
            return _executeRebalance(sender, key, params);
        }

        return (BaseTestHooks.beforeSwap.selector, toBeforeSwapDelta(0, 0), 0);
    }

    function afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external override returns (bytes4, int128) {
        PoolId poolId = key.toId();

        int128 swapAmount = params.zeroForOne ? delta.amount1() : delta.amount0();
        uint256 feeAmount = (uint256(uint128(swapAmount < 0 ? -swapAmount : swapAmount)) * FEE_CAPTURE_BPS) / 10000;

        if (params.zeroForOne) {
            reserves[poolId].amount1 += feeAmount;
        } else {
            reserves[poolId].amount0 += feeAmount;
        }

        emit FeesCaptured(poolId, params.zeroForOne ? 0 : feeAmount, params.zeroForOne ? feeAmount : 0);

        _updatePositionMetrics(sender, key, feeAmount, params.zeroForOne);

        return (BaseTestHooks.afterSwap.selector, -int128(int256(feeAmount)));
    }

    function _executeRebalance(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params
    ) internal returns (bytes4, BeforeSwapDelta, uint24) {
        PoolId poolId = key.toId();
        PositionMetrics storage position = positions[sender][poolId];

        require(position.owner == sender, "Not position owner");
        require(position.liquidity > 0, "No position to rebalance");

        _rebalancing[poolId] = true;

        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        uint128 liquidity = poolManager.getLiquidity(poolId);

        InternalReserves storage poolReserves = reserves[poolId];

        uint256 amount0;
        uint256 amount1;

        if (params.zeroForOne) {
            amount0 = uint256(-params.amountSpecified);
            amount1 = poolReserves.amount1 > 0 ?
                _calculateSwapOutput(amount0, sqrtPriceX96, liquidity) : 0;

            if (amount1 > poolReserves.amount1) {
                amount1 = poolReserves.amount1;
            }
        } else {
            amount1 = uint256(-params.amountSpecified);
            amount0 = poolReserves.amount0 > 0 ?
                _calculateSwapOutput(amount1, sqrtPriceX96, liquidity) : 0;

            if (amount0 > poolReserves.amount0) {
                amount0 = poolReserves.amount0;
            }
        }

        if (amount0 > 0) poolReserves.amount0 -= amount0;
        if (amount1 > 0) poolReserves.amount1 -= amount1;

        BeforeSwapDelta beforeDelta = toBeforeSwapDelta(
            int128(int256(amount0)),
            -int128(int256(amount1))
        );

        _rebalancing[poolId] = false;

        emit PositionRebalanced(sender, poolId, amount0, amount1, position.returnDelta);

        return (BaseTestHooks.beforeSwap.selector, beforeDelta, 0);
    }

    function _updatePositionMetrics(
        address owner,
        PoolKey calldata key,
        uint256 feeAmount,
        bool zeroForOne
    ) internal {
        PoolId poolId = key.toId();
        PositionMetrics storage position = positions[owner][poolId];

        if (position.liquidity == 0) return;

        if (zeroForOne) {
            position.feesEarned1 += feeAmount;
        } else {
            position.feesEarned0 += feeAmount;
        }

        uint256 currentValue = _estimatePositionValue(key, position.liquidity);

        uint256 totalFees = position.feesEarned0 + position.feesEarned1;
        int256 netChange = int256(currentValue + totalFees) - int256(position.initialValue);
        position.returnDelta = (netChange * 10000) / int256(position.initialValue);

        position.lastUpdateBlock = block.number;

        emit ReturnDeltaUpdated(
            owner,
            poolId,
            position.returnDelta,
            position.feesEarned0,
            position.feesEarned1,
            currentValue
        );

        if (position.returnDelta < REBALANCE_THRESHOLD) {
            emit RebalanceThresholdBreached(
                owner,
                poolId,
                position.returnDelta,
                REBALANCE_THRESHOLD
            );
        }
    }

    function _estimatePositionValue(PoolKey calldata key, uint128 liquidity) internal view returns (uint256) {
        if (liquidity == 0) return 0;

        PoolId poolId = key.toId();
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);

        uint256 price = (uint256(sqrtPriceX96) * uint256(sqrtPriceX96)) >> 192;
        return uint256(liquidity) * price / 1e18;
    }

    function _calculateSwapOutput(
        uint256 amountIn,
        uint160 sqrtPriceX96,
        uint128 liquidity
    ) internal pure returns (uint256) {
        uint256 price = (uint256(sqrtPriceX96) * uint256(sqrtPriceX96)) >> 192;
        return (amountIn * price) / 1e18;
    }

    function getPositionMetrics(address owner, PoolId poolId)
        external
        view
        returns (PositionMetrics memory)
    {
        return positions[owner][poolId];
    }

    function getReserves(PoolId poolId)
        external
        view
        returns (InternalReserves memory)
    {
        return reserves[poolId];
    }
}
