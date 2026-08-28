// Swift's Hasher is salted per process, so anything that must pick the same thing on
// every launch (an avatar, a tint) hashes with this instead.
enum StableHash {
    // 64-bit FNV-1a over the UTF-8 bytes.
    static func fnv1a(_ text: String) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash
    }
}
