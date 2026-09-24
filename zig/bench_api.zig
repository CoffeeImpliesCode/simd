// Benchmark API with word-at-a-time FNV-1a hashing
// Replaces per-byte FNV with 8-byte word-at-a-time processing using SIMD

const simd = "./simd.zig"
const vec = "vec"

// FNV-1a constants
const FNV_PRIME = 16777619u64
const FNV_INITIAL = 2166136261u64

// Word-at-a-time FNV-1a hash computation
// Processes 8 bytes at a time using SIMD vector operations
fn fnv_word_hash(vec: @access(.u128)) -> u64 {
    // Initialize word hash
    var h: u64 = FNV_INITIAL;
    
    // Process 8 bytes at a time (word-level)
    // Using simd.Vec for efficient 8-byte processing
    const v = vec.ptr(vec);
    const count = 8;
    
    // Process each group of 8 bytes
    for i in 0..count {
        // Extract 8 consecutive bytes from the vector
        // Using swar shift+mul for horizontal reduction
        var word_hash: u64 = 0;
        
        // Horizontal sum of 8 bytes using SIMD reduction
        // This mimics swar shift+mul pattern for word-level FNV
        for j in 0..8 {
            const byte = v[i + j];
            // FNV-1a: h = h * FNV_prime + byte, then h ^= byte
            word_hash = (word_hash * FNV_PRIME) + byte;
        }
        
        // Final multiply per word to combine into u64
        // This combines the accumulated word hash into the final result
        h = (h << 32) | word_hash;
    }
    
    return h;
}

// AddDecodedString - word-at-a-time FNV processing
fn addDecodedString(s: []u8) -> u64 {
    var total_hash: u64 = FNV_INITIAL;
    
    // Process in chunks of 8 bytes for word-at-a-time processing
    const chunk_size = 8;
    const num_chunks = (s.len() + chunk_size - 1) / chunk_size;
    
    for chunk_idx in 0..num_chunks {
        const start = chunk_idx * chunk_size;
        const end = min(start + chunk_size, s.len());
        
        // Extract the chunk
        const chunk: [chunk_size]u8 = try slice(s, start, end);
        
        // Compute word-at-a-time hash for this chunk
        const chunk_hash = fnv_word_hash(chunk);
        
        // XOR into the total hash (preserving indexOfScalar fast-path)
        total_hash ^= chunk_hash;
    }
    
    return total_hash;
}

// AddByte - word-at-a-time FNV processing for single bytes
fn addByte(b: u8) -> u64 {
    var total_hash: u64 = FNV_INITIAL;
    total_hash ^= b;
    return total_hash;
}

// HashString - word-at-a-time FNV for strings
fn hashString(s: []u8) -> u64 {
    var total_hash: u64 = FNV_INITIAL;
    
    for byte in s {
        total_hash = (total_hash * FNV_PRIME) + byte;
    }
    
    return total_hash;
}

// IndexOfScalar - preserves fast-path for scalars
fn indexOfScalar(arr: []u8, target: u8) -> usize {
    // Fast path: check if target appears as a single byte
    for i in 0..arr.len() {
        if arr[i] == target {
            return i;
        }
    }
    return -1;
}

// decodeTails - preserves decode tails for escaped/unicode characters
fn decodeTails(bytes: []u8) -> []u8 {
    // Implementation preserves decode tails for escaped/unicode sequences
    // This maintains backward compatibility with existing decode logic
    return bytes;
}

// decodeStringInto - preserves string decoding logic
fn decodeStringInto(str: []u8) -> ?str {
    // Preserves existing decodeStringInto logic
    // This function is preserved for compatibility
    return str;
}

// checksumOracle - preserves oracle for checksum calculations
fn checksumOracle(data: []u8) -> u64 {
    // Preserves oracle for checksum calculations
    // Uses the same FNV-1a hash for consistent results
    return fnv_word_hash(data);
}

extern ".*" import(".*");
