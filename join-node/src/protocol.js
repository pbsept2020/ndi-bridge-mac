/**
 * NDI Bridge Protocol - Header parsing and constants
 * Compatible with Swift NetworkSender (38-byte header v2)
 */

// Protocol constants
const MAGIC = 0x4E444942; // "NDIB" in ASCII
const HEADER_SIZE = 38;
const VERSION = 2;

// Media types
const MediaType = {
    VIDEO: 0,
    AUDIO: 1
};

// Timestamp scale (10 million ticks per second)
const TIMESTAMP_SCALE = 10_000_000;

/**
 * Parse packet header from buffer
 * @param {Buffer} buffer - Raw UDP packet
 * @returns {Object|null} Parsed header or null if invalid
 */
function parseHeader(buffer) {
    if (buffer.length < HEADER_SIZE) {
        return null;
    }

    const magic = buffer.readUInt32BE(0);
    if (magic !== MAGIC) {
        return null;
    }

    const version = buffer.readUInt8(4);
    if (version < 1 || version > 2) {
        return null;
    }

    // Version 1 has 28-byte header (legacy, video only)
    // Version 2 has 38-byte header (video + audio)
    const headerSize = version === 1 ? 28 : 38;

    return {
        magic,
        version,
        mediaType: buffer.readUInt8(5),
        sourceId: buffer.readUInt8(6),
        flags: buffer.readUInt8(7),
        sequenceNumber: buffer.readUInt32BE(8),
        timestamp: buffer.readBigUInt64BE(12),
        totalSize: buffer.readUInt32BE(20),
        fragmentIndex: buffer.readUInt16BE(24),
        fragmentCount: buffer.readUInt16BE(26),
        payloadSize: buffer.readUInt16BE(28),
        // Audio-specific fields (v2 only)
        sampleRate: version >= 2 ? buffer.readUInt32BE(30) : 0,
        channels: version >= 2 ? buffer.readUInt8(34) : 0,
        // Computed
        headerSize,
        isKeyframe: (buffer.readUInt8(7) & 0x01) === 1
    };
}

/**
 * Extract payload from packet
 * @param {Buffer} buffer - Raw UDP packet
 * @param {Object} header - Parsed header
 * @returns {Buffer} Payload data
 */
function extractPayload(buffer, header) {
    return buffer.subarray(header.headerSize, header.headerSize + header.payloadSize);
}

/**
 * Convert protocol timestamp to seconds
 * @param {BigInt} timestamp - Protocol timestamp (10M ticks/sec)
 * @returns {number} Time in seconds
 */
function timestampToSeconds(timestamp) {
    return Number(timestamp) / TIMESTAMP_SCALE;
}

/**
 * Convert protocol timestamp to milliseconds
 * @param {BigInt} timestamp - Protocol timestamp (10M ticks/sec)
 * @returns {number} Time in milliseconds
 */
function timestampToMs(timestamp) {
    return Number(timestamp) / (TIMESTAMP_SCALE / 1000);
}

module.exports = {
    MAGIC,
    HEADER_SIZE,
    VERSION,
    MediaType,
    TIMESTAMP_SCALE,
    parseHeader,
    extractPayload,
    timestampToSeconds,
    timestampToMs
};
