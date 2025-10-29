// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Uniswap Imports 
import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";

// FHE Imports
// euint128 is an encrypted 128-bit unsigned integer
// All operations on euint128 happen WITHOUT decryption
import {FHE, euint128} from "@fhenixprotocol/cofhe-contracts/FHE.sol";

/// @title PrivateLiquidityTracker
/// @notice Tracks cumulative liquidity changes using FHE
/// @dev Demonstrates privacy-preserving metrics in Uniswap v4 hooks
/// 
/// Key FHE Concepts:
/// 1. euint128 - Encrypted integers that can be computed on without decryption
/// 2. FHE.allowThis() - CRITICAL: Must be called after every encrypted state change
/// 3. Async Decryption - Two-step process: request → wait → retrieve
/// 4. ACL System - Access control for who can use encrypted values
contract PrivateLiquidityTracker is BaseHook {
    using PoolIdLibrary for PoolKey;
    
    // IMPORTANT: This enables clean syntax like: value.add(other)
    // Without this, you'd need: FHE.add(value, other)
    using FHE for uint256;

    // ============ STATE VARIABLES ============
    
    // FHE CONCEPT: euint128 stores encrypted values on-chain
    // - The actual value is hidden from everyone (including block explorers)
    // - Can perform arithmetic without decryption: add, sub, mul, etc.
    // - Uses 128 bits to handle large liquidity amounts without overflow
    mapping(PoolId => euint128) public token0Accumulator;
    mapping(PoolId => euint128) public token1Accumulator;
    
    // Access control: only this address can decrypt the metrics
    mapping(PoolId => address) public poolOwner;
    
    // Tracks pending decryption requests
    // FHE CONCEPT: Decryption is asynchronous and takes time to complete
    struct DecryptionRequest {
        euint128 token0Handle;  // Handle to the encrypted value
        euint128 token1Handle;
        bool requested;         // Whether decryption was requested
    }
    
    mapping(PoolId => DecryptionRequest) public decryptionRequests;
    
    // Events for off-chain tracking
    event LiquidityTracked(PoolId indexed poolId, bool isAddition);
    event DecryptionRequested(PoolId indexed poolId, address indexed owner);

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    /// @notice Defines which hook functions this contract implements
    /// @dev We use afterInitialize, beforeAddLiquidity, and beforeRemoveLiquidity
    function getHookPermissions() 
        public 
        pure 
        override 
        returns (Hooks.Permissions memory) 
    {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,      // Set owner and initialize encrypted zeros
            beforeAddLiquidity: true,   // Track liquidity additions
            afterAddLiquidity: false,
            beforeRemoveLiquidity: true, // Track liquidity removals
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ============ HOOK FUNCTIONS ============

    /// @notice Called after a pool is initialized
    /// @dev Sets up encrypted tracking for the new pool
    /// @dev IMPORTANT: This is _afterInitialize (internal with underscore)
    ///      BaseHook's public afterInitialize() calls this internal function
    function _afterInitialize(
        address,
        PoolKey calldata key,
        uint160,
        int24,
        bytes calldata
    ) internal returns (bytes4) {
        PoolId poolId = key.toId();
        
        // Set the transaction origin as the pool owner
        // Only this address can request decryption of metrics
        poolOwner[poolId] = tx.origin;
        
        // FHE STEP 1: Create encrypted zero
        // Even initializing to zero requires encryption
        euint128 zero = FHE.asEuint128(0);
        
        // FHE STEP 2: Store encrypted values
        token0Accumulator[poolId] = zero;
        token1Accumulator[poolId] = zero;
        
        // FHE STEP 3: CRITICAL - Grant ACL permission
        // Without this, future operations will revert with "ACLNotAllowed"
        // This tells the FHE system: "this contract is allowed to use this encrypted value"
        FHE.allowThis(zero);
        
        return BaseHook.afterInitialize.selector;
    }



    function _beforeAddLiquidity(
        address,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata
    ) internal override returns (bytes4) {
        PoolId poolId = key.toId();
        
        // Extract the liquidity change amount
        // Positive values = additions, Negative values = removals
        int256 liquidityDelta = params.liquidityDelta;
        
        // Only track positive changes (additions)
        if (liquidityDelta > 0) {
            // FHE STEP 1: Convert plaintext to encrypted
            // We know the amount being added (it's in the params)
            // But we encrypt it before adding to our accumulator
            euint128 encAmount = FHE.asEuint128(uint128(uint256(liquidityDelta)));
            
            // FHE STEP 2: Get current encrypted accumulator
            euint128 currentAcc = token0Accumulator[poolId];
            
            // FHE STEP 3: Perform encrypted addition
            // This is homomorphic encryption magic:
            // We're adding two encrypted numbers WITHOUT decrypting them!
            // The result is a new encrypted value
            euint128 newAcc = currentAcc.add(encAmount);
            
            // FHE STEP 4: Store the new encrypted value
            token0Accumulator[poolId] = newAcc;
            
            // FHE STEP 5: CRITICAL - Update ACL permissions
            // Every time you create a NEW encrypted value, you MUST call allowThis()
            // This grants the contract permission to use this new ciphertext
            // Forgetting this = your next transaction will fail with ACLNotAllowed
            FHE.allowThis(newAcc);
            
            emit LiquidityTracked(poolId, true);
        }
        
        return BaseHook.beforeAddLiquidity.selector;
    }

    /// @notice Called before liquidity is removed from the pool
    /// @dev Tracks the removal in encrypted form
    function _beforeRemoveLiquidity(
        address,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata
    ) internal override returns (bytes4) {
        PoolId poolId = key.toId();
        
        int256 liquidityDelta = params.liquidityDelta;
        
        // Only track negative changes (removals)
        if (liquidityDelta < 0) {
            // Convert negative to positive for subtraction
            uint128 absAmount = uint128(uint256(-liquidityDelta));
            
            // FHE STEP 1: Encrypt the removal amount
            euint128 encAmount = FHE.asEuint128(absAmount);
            
            // FHE STEP 2: Get current accumulator
            euint128 currentAcc = token0Accumulator[poolId];
            
            // FHE STEP 3: Perform encrypted subtraction
            // Again, this happens WITHOUT decryption
            euint128 newAcc = currentAcc.sub(encAmount);
            
            // FHE STEP 4: Store new value
            token0Accumulator[poolId] = newAcc;
            
            // FHE STEP 5: CRITICAL - Update ACL
            // Always call this after modifying encrypted state!
            FHE.allowThis(newAcc);
            
            emit LiquidityTracked(poolId, false);
        }
        
        return BaseHook.beforeRemoveLiquidity.selector;
    }

    // ============ DECRYPTION FUNCTIONS ============

    /// @notice Request decryption of the accumulated metrics (Step 1 of 2)
    /// @dev Only the pool owner can request decryption
    /// @dev FHE CONCEPT: Decryption is ASYNCHRONOUS
    ///      This function DOES NOT return the decrypted value
    ///      It submits a request to the decryption network
    ///      You must wait and then call getDecryptedMetrics() later
    function requestDecryption(PoolKey calldata key) external {
        PoolId poolId = key.toId();
        
        // Access control: only owner can decrypt
        require(msg.sender == poolOwner[poolId], "Only owner can decrypt");
        require(!decryptionRequests[poolId].requested, "Decryption already requested");
        
        // Get the current encrypted accumulators
        euint128 acc0 = token0Accumulator[poolId];
        euint128 acc1 = token1Accumulator[poolId];
        
        // FHE ASYNC DECRYPTION: Submit decryption request
        // This sends the request to Fhenix's decryption network
        // The network will process it and store the result on-chain
        // Processing time: typically seconds to minutes
        FHE.decrypt(acc0);
        FHE.decrypt(acc1);
        
        // Store the handles so we can retrieve the results later
        decryptionRequests[poolId] = DecryptionRequest({
            token0Handle: acc0,
            token1Handle: acc1,
            requested: true
        });
        
        emit DecryptionRequested(poolId, msg.sender);
    }

    /// @notice Retrieve decrypted metrics (Step 2 of 2)
    /// @dev Must be called AFTER requestDecryption() and AFTER decryption completes
    /// @dev FHE CONCEPT: Use "Safe" method to check if results are ready
    ///      Returns both the value AND a boolean indicating readiness
    function getDecryptedMetrics(PoolKey calldata key) 
        external 
        view 
        returns (uint128 token0Total, uint128 token1Total) 
    {
        PoolId poolId = key.toId();
        DecryptionRequest memory request = decryptionRequests[poolId];
        require(request.requested, "No decryption requested");
        
        // FHE SAFE RETRIEVAL: Get result with readiness check
        // Returns: (decryptedValue, isReady)
        // isReady = true when decryption network has processed the request
        (uint128 value0, bool ready0) = FHE.getDecryptResultSafe(request.token0Handle);
        (uint128 value1, bool ready1) = FHE.getDecryptResultSafe(request.token1Handle);
        
        // Revert with helpful message if not ready yet
        // Alternative: Use FHE.getDecryptResult() which reverts automatically if not ready
        require(ready0 && ready1, "Decryption not ready yet");
        
        return (value0, value1);
    }

    /// @notice Check if decryption results are ready without reverting
    /// @dev Useful for polling from frontend or automated systems
    /// @return requested Whether a decryption was requested
    /// @return ready Whether the decryption results are available
    function isDecryptionReady(PoolKey calldata key) 
        external 
        view 
        returns (bool requested, bool ready) 
    {
        PoolId poolId = key.toId();
        DecryptionRequest memory request = decryptionRequests[poolId];
        
        if (!request.requested) {
            return (false, false);
        }
        
        // Check if both decryptions are complete
        (, bool ready0) = FHE.getDecryptResultSafe(request.token0Handle);
        (, bool ready1) = FHE.getDecryptResultSafe(request.token1Handle);
        
        return (true, ready0 && ready1);
    }

    // ============ UTILITY FUNCTIONS ============

    /// @notice Reset the encrypted accumulators to zero
    /// @dev Useful for epoch-based tracking or periodic snapshots
    /// @dev Only the pool owner can reset
    function resetTracking(PoolKey calldata key) external {
        PoolId poolId = key.toId();
        require(msg.sender == poolOwner[poolId], "Only owner can reset");
        
        // FHE: Create new encrypted zero
        euint128 zero = FHE.asEuint128(0);
        
        // Reset both accumulators
        token0Accumulator[poolId] = zero;
        token1Accumulator[poolId] = zero;
        
        // FHE CRITICAL: Grant permission for the new zero value
        FHE.allowThis(zero);
        
        // Clear the decryption request state
        delete decryptionRequests[poolId];
    }
}

/*
 * ============================================================================
 * DEVELOPER NOTES: Critical FHE Concepts
 * ============================================================================
 * 
 * 1. ALWAYS CALL FHE.allowThis() AFTER MODIFYING ENCRYPTED STATE
 *    - Every encrypted operation creates a NEW ciphertext
 *    - Each new ciphertext needs ACL permission
 *    - Forgetting this = ACLNotAllowed error on next transaction
 * 
 * 2. DECRYPTION IS ASYNCHRONOUS
 *    - FHE.decrypt() submits request (doesn't return value)
 *    - Wait for decryption network to process
 *    - FHE.getDecryptResultSafe() retrieves result
 *    - Use isDecryptionReady() to poll status
 * 
 * 3. NEVER STORE InEuintXX TYPES IN STATE
 *    - InEuint128 = input type with metadata
 *    - euint128 = computation type
 *    - Always convert immediately: euint128 x = FHE.asEuint128(input)
 * 
 * 4. ENCRYPTED OPERATIONS ARE HOMOMORPHIC
 *    - Can compute on encrypted data without decryption
 *    - .add(), .sub(), .mul() work on ciphertexts directly
 *    - Result is also encrypted
 * 
 * 5. USE CONSTANT-TIME OPERATIONS
 *    - Never: if (encryptedValue > threshold) { ... }
 *    - Instead: result = FHE.select(condition, trueValue, falseValue)
 *    - Prevents information leakage through execution paths
 * 
 * 6. MINIMIZE DECRYPTION
 *    - Every decryption reveals information
 *    - Use encrypted comparisons when possible: FHE.gt(), FHE.eq()
 *    - Only decrypt for final user-facing results
 * 
 * 7. INTERNAL FUNCTIONS WITH UNDERSCORE
 *    - Use _beforeAddLiquidity not beforeAddLiquidity
 *    - BaseHook's public functions call your internal implementations
 *    - BaseHook handles caller validation (no need for onlyByManager)
 * 
 * ============================================================================
 * TESTING CONSIDERATIONS
 * ============================================================================
 * 
 * - Testing encrypted values is challenging (can't assert on ciphertext)
 * - Focus on: logic flow, access control, event emissions
 * - Test decryption request/retrieval separately
 * - Consider mocking FHE precompiles for unit tests
 * 
 * ============================================================================
 * SECURITY CONSIDERATIONS
 * ============================================================================
 * 
 * INFORMATION LEAKAGE:
 * - Consider what decrypting reveals to observers
 * - Transaction timing can leak information
 * - Event emissions are public
 * 
 * ACCESS CONTROL:
 * - Only poolOwner can decrypt metrics
 * - ACL system prevents unauthorized ciphertext usage
 * - Always verify caller permissions
 * 
 * PRIVACY BENEFITS:
 * - Competitors can't see pool activity
 * - MEV bots can't front-run based on metrics
 * - Trading strategies remain confidential
 * 
 * ============================================================================
 */
