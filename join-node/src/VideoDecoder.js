/**
 * VideoDecoder - H.264 decoding via FFmpeg subprocess
 * Input: H.264 Annex-B stream
 * Output: Raw video frames (UYVY for NDI)
 */

const { spawn } = require('child_process');
const EventEmitter = require('events');

class VideoDecoder extends EventEmitter {
    constructor(options = {}) {
        super();
        this.width = options.width || 1920;
        this.height = options.height || 1080;
        this.ffmpeg = null;
        this.frameSize = this.width * this.height * 2; // UYVY = 2 bytes/pixel
        this.buffer = Buffer.alloc(0);
        this.frameCount = 0;
        this.initialized = false;
    }

    /**
     * Start FFmpeg decoder process
     */
    start() {
        // FFmpeg command:
        // - Input: raw H.264 Annex-B from stdin
        // - Output: raw UYVY frames to stdout
        const args = [
            '-hide_banner',
            '-loglevel', 'warning',
            // Input
            '-f', 'h264',
            '-i', 'pipe:0',
            // Output
            '-f', 'rawvideo',
            '-pix_fmt', 'uyvy422',
            '-s', `${this.width}x${this.height}`,
            'pipe:1'
        ];

        console.log(`[VideoDecoder] Starting FFmpeg: ffmpeg ${args.join(' ')}`);

        this.ffmpeg = spawn('ffmpeg', args, {
            stdio: ['pipe', 'pipe', 'pipe']
        });

        this.ffmpeg.stdout.on('data', (data) => {
            this.processOutput(data);
        });

        this.ffmpeg.stderr.on('data', (data) => {
            const msg = data.toString().trim();
            if (msg) {
                // Parse resolution from FFmpeg output
                const resMatch = msg.match(/(\d+)x(\d+)/);
                if (resMatch && !this.initialized) {
                    const detectedWidth = parseInt(resMatch[1]);
                    const detectedHeight = parseInt(resMatch[2]);
                    if (detectedWidth !== this.width || detectedHeight !== this.height) {
                        console.log(`[VideoDecoder] Detected resolution: ${detectedWidth}x${detectedHeight}`);
                        this.width = detectedWidth;
                        this.height = detectedHeight;
                        this.frameSize = this.width * this.height * 2;
                    }
                    this.initialized = true;
                    this.emit('initialized', { width: this.width, height: this.height });
                }
                // Only log warnings/errors, not info
                if (msg.includes('Warning') || msg.includes('Error')) {
                    console.warn(`[FFmpeg] ${msg}`);
                }
            }
        });

        this.ffmpeg.on('close', (code) => {
            console.log(`[VideoDecoder] FFmpeg exited with code ${code}`);
            this.emit('close', code);
        });

        this.ffmpeg.on('error', (err) => {
            console.error('[VideoDecoder] FFmpeg error:', err);
            this.emit('error', err);
        });

        console.log('[VideoDecoder] Started');
    }

    /**
     * Decode H.264 frame
     * @param {Buffer} h264Data - H.264 Annex-B encoded frame
     */
    decode(h264Data) {
        if (!this.ffmpeg || !this.ffmpeg.stdin.writable) {
            return;
        }

        try {
            this.ffmpeg.stdin.write(h264Data);
        } catch (err) {
            console.error('[VideoDecoder] Write error:', err);
        }
    }

    /**
     * Process FFmpeg output - extract complete frames
     */
    processOutput(data) {
        // Accumulate data
        this.buffer = Buffer.concat([this.buffer, data]);

        // Extract complete frames
        while (this.buffer.length >= this.frameSize) {
            const frame = this.buffer.subarray(0, this.frameSize);
            this.buffer = this.buffer.subarray(this.frameSize);

            this.frameCount++;
            this.emit('frame', {
                data: frame,
                width: this.width,
                height: this.height,
                format: 'UYVY',
                frameNumber: this.frameCount
            });
        }
    }

    /**
     * Stop the decoder
     */
    stop() {
        if (this.ffmpeg) {
            this.ffmpeg.stdin.end();
            this.ffmpeg.kill('SIGTERM');
            this.ffmpeg = null;
        }
        console.log('[VideoDecoder] Stopped');
    }
}

module.exports = VideoDecoder;
