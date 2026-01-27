#!/usr/bin/env node
/**
 * NDI Bridge Join (Node.js)
 * Receives H.264 stream over UDP and outputs as NDI
 *
 * Usage:
 *   node index.js --port 5990 --name "NDI Bridge"
 */

const NetworkReceiver = require('./src/NetworkReceiver');
const VideoDecoder = require('./src/VideoDecoder');
const NDISender = require('./src/NDISender');

// Parse command line arguments
function parseArgs() {
    const args = {
        port: 5990,
        name: 'NDI Bridge',
        width: 1920,
        height: 1080
    };

    const argv = process.argv.slice(2);
    for (let i = 0; i < argv.length; i++) {
        switch (argv[i]) {
            case '--port':
            case '-p':
                args.port = parseInt(argv[++i]) || 5990;
                break;
            case '--name':
            case '-n':
                args.name = argv[++i] || 'NDI Bridge';
                break;
            case '--width':
            case '-w':
                args.width = parseInt(argv[++i]) || 1920;
                break;
            case '--height':
            case '-h':
                if (argv[i] === '-h' && (argv[i + 1] === undefined || argv[i + 1].startsWith('-'))) {
                    showHelp();
                    process.exit(0);
                }
                args.height = parseInt(argv[++i]) || 1080;
                break;
            case '--help':
                showHelp();
                process.exit(0);
        }
    }

    return args;
}

function showHelp() {
    console.log(`
NDI Bridge Join (Node.js Receiver)

Usage: node index.js [options]

Options:
  --port, -p <port>     UDP port to listen on (default: 5990)
  --name, -n <name>     NDI source name (default: "NDI Bridge")
  --width, -w <pixels>  Video width hint (default: 1920)
  --height <pixels>     Video height hint (default: 1080)
  --help                Show this help

Examples:
  node index.js --port 5990 --name "Remote Camera"
  node index.js -p 5991 -n "Backup Feed"

Prerequisites:
  - FFmpeg in PATH
  - NDI Runtime installed
  - Node.js 18+
`);
}

async function main() {
    const args = parseArgs();

    console.log('='.repeat(50));
    console.log('NDI Bridge Join (Node.js)');
    console.log('='.repeat(50));
    console.log(`Port: ${args.port}`);
    console.log(`NDI Name: "${args.name}"`);
    console.log(`Resolution hint: ${args.width}x${args.height}`);
    console.log('='.repeat(50));

    // Create components
    const receiver = new NetworkReceiver({ port: args.port });
    const decoder = new VideoDecoder({ width: args.width, height: args.height });
    const sender = new NDISender({ name: args.name, width: args.width, height: args.height });

    // Wire up events: Receiver -> Decoder -> Sender

    // Video: receive H.264 -> decode -> send NDI
    receiver.on('videoFrame', (frame) => {
        decoder.decode(frame.data);
    });

    decoder.on('frame', (frame) => {
        sender.sendVideo(frame);
    });

    decoder.on('initialized', (info) => {
        console.log(`[Main] Video initialized: ${info.width}x${info.height}`);
        sender.setResolution(info.width, info.height);
    });

    // Audio: receive PCM -> send NDI directly (no decoding needed)
    receiver.on('audioFrame', (frame) => {
        sender.sendAudio({
            data: frame.data,
            sampleRate: frame.sampleRate,
            channels: frame.channels
        });
    });

    // Error handling
    receiver.on('error', (err) => {
        console.error('[Main] Receiver error:', err);
    });

    decoder.on('error', (err) => {
        console.error('[Main] Decoder error:', err);
    });

    // Graceful shutdown
    process.on('SIGINT', () => {
        console.log('\n[Main] Shutting down...');
        receiver.stop();
        decoder.stop();
        sender.stop();
        process.exit(0);
    });

    process.on('SIGTERM', () => {
        console.log('\n[Main] Shutting down...');
        receiver.stop();
        decoder.stop();
        sender.stop();
        process.exit(0);
    });

    // Start components
    try {
        await sender.start();
        decoder.start();
        await receiver.start();

        console.log('[Main] Ready - waiting for stream...');
        console.log('[Main] Press Ctrl+C to stop');

        // Keep process alive
        setInterval(() => {
            // Keep-alive tick
        }, 1000);
    } catch (err) {
        console.error('[Main] Failed to start:', err);
        process.exit(1);
    }
}

main().catch((err) => {
    console.error('Fatal error:', err);
    process.exit(1);
});
