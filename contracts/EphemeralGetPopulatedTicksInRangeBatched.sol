// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "./PoolUtils.sol";

/// @notice A lens that fetches chunks of tick data in a range for a Uniswap v3 pool with batching support
/// @author Aperture Finance
/// @dev The return data can be accessed externally by `eth_call` without a `to` address or internally by catching the
/// revert data, and decoded by `abi.decode(data, (PopulatedTick[], int24, bool, int24))`
/// The fourth return value indicates if there are more ticks beyond the batch limit
contract EphemeralGetPopulatedTicksInRangeBatched is PoolUtils {
    constructor(V3PoolCallee pool, int24 tickLower, int24 tickUpper, uint256 maxTicks) payable {
        (
            PopulatedTick[] memory populatedTicks,
            int24 tickSpacing,
            bool hasMore,
            int24 nextStartTick
        ) = getPopulatedTicksInRangeBatched(pool, tickLower, tickUpper, maxTicks);

        bytes memory returnData = abi.encode(populatedTicks, tickSpacing, hasMore, nextStartTick);
        assembly ("memory-safe") {
            revert(add(returnData, 0x20), mload(returnData))
        }
    }

    /// @notice Get tick data for populated ticks from tickLower to tickUpper with a maximum tick limit
    /// @param pool The address of the pool for which to fetch populated tick data
    /// @param tickLower The lower tick boundary of the populated ticks to fetch
    /// @param tickUpper The upper tick boundary of the populated ticks to fetch
    /// @param maxTicks Maximum number of ticks to return in this batch
    /// @return populatedTicks An array of tick data for the populated ticks
    /// @return tickSpacing The tick spacing of the pool
    /// @return hasMore Whether there are more ticks beyond the maxTicks limit
    /// @return nextStartTick The next tick to start from for the next batch (only valid if hasMore is true)
    function getPopulatedTicksInRangeBatched(
        V3PoolCallee pool,
        int24 tickLower,
        int24 tickUpper,
        uint256 maxTicks
    )
        public
        payable
        returns (PopulatedTick[] memory populatedTicks, int24 tickSpacing, bool hasMore, int24 nextStartTick)
    {
        require(tickLower <= tickUpper, "Invalid tick range");
        require(maxTicks > 0, "maxTicks must be greater than 0");

        tickSpacing = IUniswapV3Pool(V3PoolCallee.unwrap(pool)).tickSpacing();
        (int16 wordPosLower, int16 wordPosUpper) = getWordPositions(tickLower, tickUpper, tickSpacing);

        unchecked {
            (uint256[] memory tickBitmap, uint256 totalCount) = getTickBitmapAndCount(pool, wordPosLower, wordPosUpper);

            // If total count is within limit, use original logic
            if (totalCount <= maxTicks) {
                return _getFullRange(pool, tickSpacing, wordPosLower, wordPosUpper, tickBitmap, totalCount);
            }

            // Need to batch - process with limit
            return
                _getBatchedRange(
                    pool,
                    tickSpacing,
                    tickLower,
                    tickUpper,
                    wordPosLower,
                    wordPosUpper,
                    tickBitmap,
                    maxTicks
                );
        }
    }

    /// @notice Internal function to get all ticks when within limit
    function _getFullRange(
        V3PoolCallee pool,
        int24 tickSpacing,
        int16 wordPosLower,
        int16 wordPosUpper,
        uint256[] memory tickBitmap,
        uint256 totalCount
    ) internal view returns (PopulatedTick[] memory, int24, bool, int24) {
        PopulatedTick[] memory populatedTicks = new PopulatedTick[](totalCount);
        uint256 idx;

        for (int16 wordPos = wordPosLower; wordPos <= wordPosUpper; ++wordPos) {
            idx = populateTicksInWord(
                pool,
                wordPos,
                tickSpacing,
                tickBitmap[uint16(wordPos - wordPosLower)],
                populatedTicks,
                idx
            );
        }

        return (populatedTicks, tickSpacing, false, 0);
    }

    /// @notice Internal function to get batched ticks with limit
    function _getBatchedRange(
        V3PoolCallee pool,
        int24 tickSpacing,
        int24 tickLower,
        int24 tickUpper,
        int16 wordPosLower,
        int16 wordPosUpper,
        uint256[] memory tickBitmap,
        uint256 maxTicks
    ) internal view returns (PopulatedTick[] memory, int24, bool, int24) {
        PopulatedTick[] memory populatedTicks = new PopulatedTick[](maxTicks);
        uint256 tickCount = 0;

        for (int16 wordPos = wordPosLower; wordPos <= wordPosUpper; ++wordPos) {
            uint256 bitmap = tickBitmap[uint16(wordPos - wordPosLower)];

            for (uint256 bitPos; bitPos < 256; ++bitPos) {
                if (bitmap & (1 << bitPos) != 0) {
                    int24 tick;
                    assembly {
                        tick := mul(tickSpacing, add(shl(8, wordPos), bitPos))
                    }

                    if (tick >= tickLower) {
                        if (tick > tickUpper) {
                            // Resize and return - no more ticks
                            assembly {
                                mstore(populatedTicks, tickCount)
                            }
                            return (populatedTicks, tickSpacing, false, 0);
                        }

                        if (tickCount >= maxTicks) {
                            // Hit limit - return with hasMore=true
                            return (populatedTicks, tickSpacing, true, tick);
                        }

                        _populateSingleTick(pool, tick, populatedTicks, tickCount);
                        tickCount++;
                    }
                }
            }
        }

        // Resize to actual count and return
        assembly {
            mstore(populatedTicks, tickCount)
        }
        return (populatedTicks, tickSpacing, false, 0);
    }

    /// @notice Populate a single tick to avoid stack depth issues
    function _populateSingleTick(
        V3PoolCallee pool,
        int24 tick,
        PopulatedTick[] memory populatedTicks,
        uint256 index
    ) internal view {
        PoolCaller.TickInfo memory info = pool.ticks(tick);
        populatedTicks[index].tick = tick;
        populatedTicks[index].liquidityNet = info.liquidityNet;
        populatedTicks[index].liquidityGross = info.liquidityGross;
        populatedTicks[index].feeGrowthOutside0X128 = info.feeGrowthOutside0X128;
        populatedTicks[index].feeGrowthOutside1X128 = info.feeGrowthOutside1X128;
    }

    /// @notice Get the tick data for all populated ticks in a word of the tick bitmap
    function populateTicksInWord(
        V3PoolCallee pool,
        int16 wordPos,
        int24 tickSpacing,
        uint256 bitmap,
        PopulatedTick[] memory populatedTicks,
        uint256 idx
    ) internal view returns (uint256) {
        unchecked {
            for (uint256 bitPos; bitPos < 256; ++bitPos) {
                if (bitmap & (1 << bitPos) != 0) {
                    int24 tick;
                    assembly {
                        tick := mul(tickSpacing, add(shl(8, wordPos), bitPos))
                    }
                    _populateSingleTick(pool, tick, populatedTicks, idx++);
                }
            }
            return idx;
        }
    }
}
