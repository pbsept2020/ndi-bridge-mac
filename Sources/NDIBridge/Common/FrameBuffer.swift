import Foundation
import CoreVideo
import QuartzCore

/// Frame vidéo avec timestamp pour synchronisation
struct BufferedVideoFrame {
    let pixelBuffer: CVPixelBuffer
    let timestamp: UInt64
    let presentationTime: CFTimeInterval  // Quand émettre cette frame
}

/// Frame audio avec timestamp
struct BufferedAudioFrame {
    let data: Data
    let timestamp: UInt64
    let sampleRate: Int32
    let channels: Int32
    let presentationTime: CFTimeInterval
}

/// Ring buffer thread-safe pour frames vidéo et audio
/// Utilisé pour ajouter un délai configurable à la sortie NDI
final class FrameBuffer {
    private var videoFrames: [BufferedVideoFrame] = []
    private var audioFrames: [BufferedAudioFrame] = []
    private let lock = NSLock()
    private let bufferDuration: CFTimeInterval  // en secondes
    private var startTime: CFTimeInterval = 0
    private var isStarted = false

    /// Nombre de frames vidéo actuellement dans le buffer
    var videoCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return videoFrames.count
    }

    /// Nombre de frames audio actuellement dans le buffer
    var audioCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return audioFrames.count
    }

    /// Initialise le buffer avec un délai en millisecondes
    /// - Parameter bufferMs: Délai en millisecondes (0 = pas de buffer)
    init(bufferMs: Int) {
        self.bufferDuration = CFTimeInterval(bufferMs) / 1000.0
    }

    // MARK: - Private Helpers

    /// Copier un CVPixelBuffer pour le stocker indépendamment du pool source
    /// Le décodeur VideoToolbox recycle ses buffers, donc on doit faire une copie
    /// pour que les frames bufferisées restent valides pendant la durée du buffer
    private func copyPixelBuffer(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        let pixelFormat = CVPixelBufferGetPixelFormatType(source)

        var destPixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            pixelFormat,
            nil,
            &destPixelBuffer
        )

        guard status == kCVReturnSuccess, let dest = destPixelBuffer else {
            return nil
        }

        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(dest, [])
        defer {
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
            CVPixelBufferUnlockBaseAddress(dest, [])
        }

        // Copier chaque plan (Y et UV pour NV12, ou unique pour BGRA)
        let planeCount = CVPixelBufferGetPlaneCount(source)

        if planeCount > 0 {
            // Format planaire (NV12, etc.)
            for plane in 0..<planeCount {
                let srcBase = CVPixelBufferGetBaseAddressOfPlane(source, plane)
                let destBase = CVPixelBufferGetBaseAddressOfPlane(dest, plane)
                let srcBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(source, plane)
                let destBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(dest, plane)
                let planeHeight = CVPixelBufferGetHeightOfPlane(source, plane)

                if let src = srcBase, let dst = destBase {
                    for row in 0..<planeHeight {
                        let srcRow = src.advanced(by: row * srcBytesPerRow)
                        let dstRow = dst.advanced(by: row * destBytesPerRow)
                        memcpy(dstRow, srcRow, min(srcBytesPerRow, destBytesPerRow))
                    }
                }
            }
        } else {
            // Format non-planaire (BGRA, etc.)
            let srcBase = CVPixelBufferGetBaseAddress(source)
            let destBase = CVPixelBufferGetBaseAddress(dest)
            let srcBytesPerRow = CVPixelBufferGetBytesPerRow(source)
            let destBytesPerRow = CVPixelBufferGetBytesPerRow(dest)

            if let src = srcBase, let dst = destBase {
                for row in 0..<height {
                    let srcRow = src.advanced(by: row * srcBytesPerRow)
                    let dstRow = dst.advanced(by: row * destBytesPerRow)
                    memcpy(dstRow, srcRow, min(srcBytesPerRow, destBytesPerRow))
                }
            }
        }

        return dest
    }

    // MARK: - Public API

    /// Ajouter une frame vidéo au buffer
    /// Une copie profonde du pixelBuffer est faite pour éviter que le décodeur
    /// ne recycle le buffer avant l'émission
    /// - Parameters:
    ///   - pixelBuffer: Le CVPixelBuffer décodé
    ///   - timestamp: Timestamp original de la frame
    func enqueueVideo(_ pixelBuffer: CVPixelBuffer, timestamp: UInt64) {
        // Deep copy pour éviter que le décodeur recycle le buffer
        guard let copiedBuffer = copyPixelBuffer(pixelBuffer) else {
            // Silently skip if copy fails - don't crash
            return
        }

        lock.lock()
        defer { lock.unlock() }

        if !isStarted {
            startTime = CACurrentMediaTime()
            isStarted = true
        }

        let presentationTime = CACurrentMediaTime() + bufferDuration
        let frame = BufferedVideoFrame(
            pixelBuffer: copiedBuffer,  // Buffer copié, indépendant du pool décodeur
            timestamp: timestamp,
            presentationTime: presentationTime
        )
        videoFrames.append(frame)
    }

    /// Ajouter une frame audio au buffer
    /// - Parameters:
    ///   - data: Les données audio PCM
    ///   - timestamp: Timestamp original
    ///   - sampleRate: Taux d'échantillonnage (ex: 48000)
    ///   - channels: Nombre de canaux (ex: 2)
    func enqueueAudio(_ data: Data, timestamp: UInt64, sampleRate: Int32, channels: Int32) {
        lock.lock()
        defer { lock.unlock() }

        if !isStarted {
            startTime = CACurrentMediaTime()
            isStarted = true
        }

        let presentationTime = CACurrentMediaTime() + bufferDuration
        let frame = BufferedAudioFrame(
            data: data,
            timestamp: timestamp,
            sampleRate: sampleRate,
            channels: channels,
            presentationTime: presentationTime
        )
        audioFrames.append(frame)
    }

    /// Récupérer les frames vidéo prêtes à être émises
    /// - Returns: Array de frames dont le presentationTime est passé
    func dequeueReadyVideo() -> [BufferedVideoFrame] {
        lock.lock()
        defer { lock.unlock() }

        let now = CACurrentMediaTime()
        var ready: [BufferedVideoFrame] = []

        while let first = videoFrames.first, first.presentationTime <= now {
            ready.append(videoFrames.removeFirst())
        }

        return ready
    }

    /// Récupérer les frames audio prêtes à être émises
    /// - Returns: Array de frames dont le presentationTime est passé
    func dequeueReadyAudio() -> [BufferedAudioFrame] {
        lock.lock()
        defer { lock.unlock() }

        let now = CACurrentMediaTime()
        var ready: [BufferedAudioFrame] = []

        while let first = audioFrames.first, first.presentationTime <= now {
            ready.append(audioFrames.removeFirst())
        }

        return ready
    }

    /// Vider le buffer complètement
    func flush() {
        lock.lock()
        defer { lock.unlock() }
        videoFrames.removeAll()
        audioFrames.removeAll()
        isStarted = false
    }

    /// Durée du buffer en millisecondes
    var bufferMs: Int {
        return Int(bufferDuration * 1000)
    }
}
