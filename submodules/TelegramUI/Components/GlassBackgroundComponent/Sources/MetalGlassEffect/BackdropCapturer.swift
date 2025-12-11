import UIKit
import Metal

/// Optimized backdrop capturer with persistent buffers to avoid per-frame allocations
/// Change detection handled by CA transaction ID + RunLoop observer in GlassBackgroundComponent
@available(iOS 11.0, *)
final class BackdropCapturer {
    
    private weak var targetView: UIView?
    
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    
    // Downsample factor for performance (0.5 = 4x fewer pixels, 0.25 = 16x fewer)
    private let downsampleFactor: CGFloat
    
    // Persistent buffers - no realloc per frame
    private var persistentContext: CGContext?
    private var persistentTexture: MTLTexture?
    private var stagingBuffers: [MTLBuffer] = []  // Pool of staging buffers for triple buffering
    private var stagingIndex: Int = 0
    private var lastCaptureSize: CGSize = .zero
    
    // GPU synchronization - prevent command buffer accumulation
    private let inflightSemaphore = DispatchSemaphore(value: 3)  // Max 3 in-flight frames
    
    public init?(targetView: UIView, device: MTLDevice? = nil, commandQueue: MTLCommandQueue? = nil, downsampleFactor: CGFloat = 1.0) {
        guard let metalDevice = device ?? MTLCreateSystemDefaultDevice() else { return nil }
        self.device = metalDevice
        
        // Use provided queue (shared with renderer) or create new one
        if let queue = commandQueue {
            self.commandQueue = queue  // ✅ Shared queue - prevents GPU race condition
        } else {
            guard let queue = metalDevice.makeCommandQueue() else { return nil }
            self.commandQueue = queue
        }
        
        self.targetView = targetView
        self.downsampleFactor = max(0.1, min(1.0, downsampleFactor))  // Clamp to 0.1...1.0
    }
    
    /// Fast backdrop capture with persistent buffers (~0.6-1.2ms)
    /// No pixel hashing - change detection done at CA transaction level
    public func captureBackdrop() -> MTLTexture? {
        guard let view = targetView,
              let window = view.window else {
            return nil
        }
        
        let rect = view.convert(view.bounds, to: window)
        let scale = window.screen.scale * downsampleFactor  // Apply downsample
        let w = Int((rect.width * scale).rounded(.down))
        let h = Int((rect.height * scale).rounded(.down))
        guard w > 0 && h > 0 else {
            return nil
        }
        
        let captureSize = CGSize(width: w, height: h)
        
        // Recreate buffers only if size changed
        if captureSize != lastCaptureSize {
            setupPersistentBuffers(width: w, height: h)
            lastCaptureSize = captureSize
        }
        
        guard let ctx = persistentContext,
              let texture = persistentTexture else {
            return nil
        }
        
        // Clear previous contents
        ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
        
        // Setup coordinate transform: scale first, then translate in points
        ctx.saveGState()
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -rect.origin.x, y: -rect.origin.y)
        
        // Hide target layer temporarily (without animation)
        let originalOpacity = view.layer.opacity
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        view.layer.opacity = 0.01
        window.layer.render(in: ctx)
        view.layer.opacity = originalOpacity
        CATransaction.commit()

        ctx.restoreGState()
        
        // Async GPU upload via blit encoder (non-blocking)
        if let data = ctx.data {
            // Try to acquire staging buffer slot immediately - don't block ✅
            if inflightSemaphore.wait(timeout: .now()) == .timedOut {
                // All staging buffers busy - skip this frame (return cached texture)
                return texture  // Return existing texture instead of blocking
            }
            
            guard stagingBuffers.count > 0 else {
                inflightSemaphore.signal()
                return nil
            }
            
            // Round-robin through staging buffers (triple buffering)
            let staging = stagingBuffers[stagingIndex]
            stagingIndex = (stagingIndex + 1) % stagingBuffers.count
            
            let bufferSize = w * h * 4
            memcpy(staging.contents(), data, bufferSize)

            // Async blit to GPU texture
            if let commandBuffer = commandQueue.makeCommandBuffer() {
                // Signal semaphore when GPU completes this frame
                commandBuffer.addCompletedHandler { [weak self] _ in
                    self?.inflightSemaphore.signal()
                }
                
                if let blitEncoder = commandBuffer.makeBlitCommandEncoder() {
                    blitEncoder.copy(
                        from: staging,
                        sourceOffset: 0,
                        sourceBytesPerRow: w * 4,
                        sourceBytesPerImage: bufferSize,
                        sourceSize: MTLSize(width: w, height: h, depth: 1),
                        to: texture,
                        destinationSlice: 0,
                        destinationLevel: 0,
                        destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
                    )
                    blitEncoder.endEncoding()
                }
                commandBuffer.commit()
            } else {
                // Failed to create command buffer, release semaphore
                inflightSemaphore.signal()
            }
        }
        
        return texture
    }
    
    private func setupPersistentBuffers(width: Int, height: Int) {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue |
                         CGBitmapInfo.byteOrder32Little.rawValue
        
        // Create persistent CGContext
        persistentContext = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        )
        
        // Create persistent Metal texture
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        persistentTexture = device.makeTexture(descriptor: descriptor)
        
        // Create staging buffers pool (3 buffers for triple buffering)
        let bufferSize = width * height * 4
        stagingBuffers.removeAll()
        for _ in 0..<3 {
            if let buffer = device.makeBuffer(length: bufferSize, options: .storageModeShared) {
                stagingBuffers.append(buffer)
            }
        }
        stagingIndex = 0
    }
}
