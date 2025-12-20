import UIKit
import Metal

@available(iOS 11.0, *)
final class BackdropCapturer {
    
    private weak var targetView: UIView?
    
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let downsampleFactor: CGFloat
    
    private var persistentContext: CGContext?
    private var persistentTexture: MTLTexture?
    private var stagingBuffer: MTLBuffer?
    private var lastCaptureSize: CGSize = .zero
    
    public init?(targetView: UIView, device: MTLDevice? = nil, commandQueue: MTLCommandQueue? = nil, downsampleFactor: CGFloat = 1.0) {
        guard let metalDevice = device ?? MTLCreateSystemDefaultDevice() else { return nil }
        self.device = metalDevice
        
        if let queue = commandQueue {
            self.commandQueue = queue
        } else {
            guard let queue = metalDevice.makeCommandQueue() else { return nil }
            self.commandQueue = queue
        }
        
        self.targetView = targetView
        self.downsampleFactor = max(0.1, min(1.0, downsampleFactor))
    }
    
    public func captureBackdrop() -> MTLTexture? {
        // ⚠️ UIKit drawing APIs must run on main thread
        precondition(Thread.isMainThread, "BackdropCapturer.captureBackdrop() must be called on the main thread because it uses UIKit drawing APIs.")
        
        guard let view = targetView,
              let window = view.window else {
            return nil
        }
        
        let rect = view.convert(view.bounds, to: window)
        let scale = window.screen.scale * downsampleFactor
        let w = Int((rect.width * scale).rounded(.down))
        let h = Int((rect.height * scale).rounded(.down))
        
        guard w > 0 && h > 0 else {
            return nil
        }
        
        let captureSize = CGSize(width: w, height: h)
        
        if captureSize != lastCaptureSize {
            setupPersistentBuffers(width: w, height: h)
            lastCaptureSize = captureSize
        }
        
        guard let ctx = persistentContext,
              let texture = persistentTexture else {
            return nil
        }
        
        // Temporarily hide target view
        let originalOpacity = view.layer.opacity
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        view.layer.opacity = 0.01
        
        // Clear and setup context
        ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.saveGState()
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -rect.origin.x, y: -rect.origin.y)
        
        // Render the window layer
        window.layer.render(in: ctx)
        
        ctx.restoreGState()
        view.layer.opacity = originalOpacity
        CATransaction.commit()

        // Copy data to GPU
        if let data = ctx.data, let staging = stagingBuffer {
            let bufferSize = w * h * 4
            memcpy(staging.contents(), data, bufferSize)

            if let commandBuffer = commandQueue.makeCommandBuffer(),
               let blitEncoder = commandBuffer.makeBlitCommandEncoder() {
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
                commandBuffer.commit()
            }
        }
        
        return texture
    }
    
    private func setupPersistentBuffers(width: Int, height: Int) {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue |
                         CGBitmapInfo.byteOrder32Little.rawValue
        
        persistentContext = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        )
        
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        persistentTexture = device.makeTexture(descriptor: descriptor)
        
        let bufferSize = width * height * 4
        stagingBuffer = device.makeBuffer(length: bufferSize, options: .storageModeShared)
    }
}
