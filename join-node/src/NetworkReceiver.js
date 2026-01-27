/**
 * NetworkReceiver - UDP listener with frame reassembly
 * Compatible with Swift NetworkSender
 */

const dgram = require('dgram');
const EventEmitter = require('events');
const { parseHeader, extractPayload, MediaType, timestampToMs } = require('./protocol');

/**
 * Frame reassembler - collects fragments and emits complete frames
 */
class FrameReassembler {
    constructor(name) {
        this.name = name;
        this.fragments = new Map();
        this.currentSequence = null;
        this.expectedCount = 0;
    }

    /**
     * Add a fragment to the reassembly buffer
     * @param {Object} header - Parsed packet header
     * @param {Buffer} payload - Fragment payload
     * @returns {Buffer|null} Complete frame if all fragments received, null otherwise
     */
    addFragment(header, payload) {
        const { sequenceNumber, fragmentIndex, fragmentCount, totalSize } = header;

        // New sequence - reset state
        if (this.currentSequence !== sequenceNumber) {
            if (this.currentSequence !== null && this.fragments.size > 0) {
                console.warn(`[${this.name}] Incomplete frame dropped: seq=${this.currentSequence}, got ${this.fragments.size}/${this.expectedCount} fragments`);
            }
            this.fragments.clear();
            this.currentSequence = sequenceNumber;
            this.expectedCount = fragmentCount;
        }

        // Store fragment
        this.fragments.set(fragmentIndex, payload);

        // Check if complete
        if (this.fragments.size === fragmentCount) {
            // Reassemble in order
            const buffers = [];
            for (let i = 0; i < fragmentCount; i++) {
                const frag = this.fragments.get(i);
                if (!frag) {
                    console.error(`[${this.name}] Missing fragment ${i} in sequence ${sequenceNumber}`);
                    this.fragments.clear();
                    return null;
                }
                buffers.push(frag);
            }

            const completeFrame = Buffer.concat(buffers);
            this.fragments.clear();
            this.currentSequence = null;

            // Validate size
            if (completeFrame.length !== totalSize) {
                console.warn(`[${this.name}] Size mismatch: expected ${totalSize}, got ${completeFrame.length}`);
            }

            return completeFrame;
        }

        return null;
    }
}

/**
 * NetworkReceiver - Main UDP receiver class
 */
class NetworkReceiver extends EventEmitter {
    constructor(options = {}) {
        super();
        this.port = options.port || 5990;
        this.socket = null;
        this.videoReassembler = new FrameReassembler('video');
        this.audioReassembler = new FrameReassembler('audio');

        // Stats
        this.stats = {
            packetsReceived: 0,
            bytesReceived: 0,
            videoFrames: 0,
            audioFrames: 0,
            lastStatsTime: Date.now()
        };
    }

    /**
     * Start listening for UDP packets
     */
    start() {
        return new Promise((resolve, reject) => {
            this.socket = dgram.createSocket({ type: 'udp4', reuseAddr: true });

            this.socket.on('error', (err) => {
                console.error('[NetworkReceiver] Socket error:', err);
                this.emit('error', err);
                reject(err);
            });

            this.socket.on('message', (msg, rinfo) => {
                this.processPacket(msg, rinfo);
            });

            this.socket.on('listening', () => {
                const addr = this.socket.address();
                console.log(`[NetworkReceiver] Socket bound successfully on ${addr.address}:${addr.port}`);
                this.emit('listening', addr);
                resolve(addr);
            });

            console.log(`[NetworkReceiver] Binding to port ${this.port}...`);
            this.socket.bind(this.port, '0.0.0.0');

            // Stats logging every second
            this.statsInterval = setInterval(() => this.logStats(), 1000);
        });
    }

    /**
     * Stop the receiver
     */
    stop() {
        if (this.statsInterval) {
            clearInterval(this.statsInterval);
        }
        if (this.socket) {
            this.socket.close();
            this.socket = null;
        }
        console.log('[NetworkReceiver] Stopped');
    }

    /**
     * Process incoming UDP packet
     */
    processPacket(buffer, rinfo) {
        // Parse header
        const header = parseHeader(buffer);
        if (!header) {
            return; // Invalid packet, ignore
        }

        // Update stats
        this.stats.packetsReceived++;
        this.stats.bytesReceived += buffer.length;

        // Extract payload
        const payload = extractPayload(buffer, header);

        // Route to appropriate reassembler
        let completeFrame = null;
        if (header.mediaType === MediaType.VIDEO) {
            completeFrame = this.videoReassembler.addFragment(header, payload);
            if (completeFrame) {
                this.stats.videoFrames++;
                this.emit('videoFrame', {
                    data: completeFrame,
                    timestamp: header.timestamp,
                    timestampMs: timestampToMs(header.timestamp),
                    isKeyframe: header.isKeyframe,
                    sequenceNumber: header.sequenceNumber
                });
            }
        } else if (header.mediaType === MediaType.AUDIO) {
            completeFrame = this.audioReassembler.addFragment(header, payload);
            if (completeFrame) {
                this.stats.audioFrames++;
                this.emit('audioFrame', {
                    data: completeFrame,
                    timestamp: header.timestamp,
                    timestampMs: timestampToMs(header.timestamp),
                    sampleRate: header.sampleRate,
                    channels: header.channels,
                    sequenceNumber: header.sequenceNumber
                });
            }
        }
    }

    /**
     * Log stats every second
     */
    logStats() {
        const now = Date.now();
        const elapsed = (now - this.stats.lastStatsTime) / 1000;

        if (elapsed > 0 && this.stats.packetsReceived > 0) {
            const mbps = (this.stats.bytesReceived * 8 / elapsed / 1_000_000).toFixed(2);
            console.log(`[Stats] ${mbps} Mbps | Video: ${this.stats.videoFrames} frames | Audio: ${this.stats.audioFrames} frames | Packets: ${this.stats.packetsReceived}`);
        }

        // Reset stats
        this.stats.packetsReceived = 0;
        this.stats.bytesReceived = 0;
        this.stats.videoFrames = 0;
        this.stats.audioFrames = 0;
        this.stats.lastStatsTime = now;
    }
}

module.exports = NetworkReceiver;
