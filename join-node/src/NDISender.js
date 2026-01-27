/**
 * NDISender - NDI output via grandiose
 * Broadcasts decoded video/audio as NDI source
 */

const EventEmitter = require('events');

class NDISender extends EventEmitter {
    constructor(options = {}) {
        super();
        this.name = options.name || 'NDI Bridge';
        this.sender = null;
        this.grandiose = null;
        this.width = options.width || 1920;
        this.height = options.height || 1080;
        this.frameRate = options.frameRate || 30;
        this.videoFramesSent = 0;
        this.audioFramesSent = 0;
    }

    /**
     * Initialize NDI sender
     */
    async start() {
        try {
            // Dynamic import for grandiose (native module)
            this.grandiose = require('grandiose');

            this.sender = await this.grandiose.send({
                name: this.name,
                clockVideo: false,
                clockAudio: false
            });

            console.log(`[NDISender] Started: "${this.name}"`);
            this.emit('started', { name: this.name });
        } catch (err) {
            console.error('[NDISender] Failed to start:', err);
            throw err;
        }
    }

    /**
     * Send video frame
     * @param {Object} frame - { data: Buffer, width, height, format }
     */
    sendVideo(frame) {
        if (!this.sender) {
            return;
        }

        try {
            // Update dimensions if changed
            if (frame.width && frame.height) {
                this.width = frame.width;
                this.height = frame.height;
            }

            // Create NDI video frame
            const videoFrame = {
                // Resolution
                xres: this.width,
                yres: this.height,
                // Format: UYVY (4:2:2)
                fourCC: this.grandiose.FOURCC_UYVY,
                // Frame rate (30000/1001 for 29.97fps, 30000/1000 for 30fps)
                frameRateN: this.frameRate * 1000,
                frameRateD: 1000,
                // Picture aspect ratio (16:9)
                pictureAspectRatio: this.width / this.height,
                // Line stride (bytes per line) - UYVY = 2 bytes/pixel
                lineStrideBytes: this.width * 2,
                // Data
                data: frame.data
            };

            this.sender.video(videoFrame);
            this.videoFramesSent++;
        } catch (err) {
            console.error('[NDISender] Video send error:', err);
        }
    }

    /**
     * Send audio frame
     * @param {Object} audio - { data: Buffer, sampleRate, channels }
     */
    sendAudio(audio) {
        if (!this.sender) {
            return;
        }

        try {
            const { data, sampleRate, channels } = audio;

            // Calculate number of samples
            // PCM 32-bit float = 4 bytes per sample per channel
            const bytesPerSample = 4;
            const totalSamples = data.length / (bytesPerSample * channels);

            // Create NDI audio frame
            const audioFrame = {
                sampleRate: sampleRate || 48000,
                channels: channels || 2,
                samples: totalSamples,
                // Channel stride (bytes between channels in planar format)
                channelStrideBytes: totalSamples * bytesPerSample,
                // Data (PCM 32-bit float planar)
                data: data
            };

            this.sender.audio(audioFrame);
            this.audioFramesSent++;
        } catch (err) {
            console.error('[NDISender] Audio send error:', err);
        }
    }

    /**
     * Update video resolution
     */
    setResolution(width, height) {
        this.width = width;
        this.height = height;
        console.log(`[NDISender] Resolution set to ${width}x${height}`);
    }

    /**
     * Stop the sender
     */
    stop() {
        if (this.sender) {
            this.sender.destroy();
            this.sender = null;
        }
        console.log(`[NDISender] Stopped (sent ${this.videoFramesSent} video, ${this.audioFramesSent} audio frames)`);
    }
}

module.exports = NDISender;
