import Foundation
import UIKit
import Metal
import QuartzCore
import CoreFoundation
import HierarchyTrackingLayer

/// Custom liquid glass view (CABackdropLayer + Metal rendering)
/// Use if 1-2 layers of glass effect are on screen simultaneously.
/// Pros: low latency, good quality, access to direct backdrop texture

@available(iOS 13.0, *)
public final class CustomLiquidGlassView: UIView {
    
    public struct Configuration: Equatable {
        public var cornerRadius: CGFloat
        public var isDark: Bool
        
        public init(cornerRadius: CGFloat = 0, isDark: Bool = false) {
            self.cornerRadius = cornerRadius
            self.isDark = isDark
        }
    }

    private let backdropContainer: UIView
    private let glassContainer: UIView
    private var backdropLayer: CALayer?
    private var metalLayer: CAMetalLayer?
    
    private var renderer: MetalGlassRenderer?
    
    private var runLoopObserver: CFRunLoopObserver?
    private var hierarchyTracker: HierarchyTrackingLayer?
    private var configuration: Configuration
    
    private var lastRenderTime: CFTimeInterval = 0
    private static let throttleFPS: Double = 60.0
    private var isInHierarchy: Bool = false
    
    // Zero-copy texture pipeline (IOSurface backed)
    private var textureCache: CVMetalTextureCache?
    private var pixelBuffer: CVPixelBuffer?
    private var cachedTexture: CVMetalTexture?

    
    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        
        // Create separated containers
        self.backdropContainer = UIView()
        self.backdropContainer.layer.setValue(false, forKey: "layerUsesCoreImageFilters")
        
        self.glassContainer = UIView()
        
        super.init(frame: .zero)

        self.layer.setValue(false, forKey: "layerUsesCoreImageFilters")
        addSubview(backdropContainer)
        addSubview(glassContainer)
        
        setupMetalRendering()
        setupBackdropLayer()
        setupHierarchyTracking()
        setupRunLoopObserver()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    deinit {
        stopRunLoopObserver()
        
        // Clean up texture resources
        cachedTexture = nil
        pixelBuffer = nil
        if let cache = textureCache {
            CVMetalTextureCacheFlush(cache, 0)
        }
        textureCache = nil
    }

    private func setupMetalRendering() {
        guard let renderer = MetalGlassRenderer() else {
            return
        }
        self.renderer = renderer
        
        // Create CVMetalTextureCache for zero-copy texture access
        var cache: CVMetalTextureCache?
        let result = CVMetalTextureCacheCreate(
            kCFAllocatorDefault,
            nil,
            renderer.device,
            nil,
            &cache
        )
        
        guard result == kCVReturnSuccess, let cache = cache else {
            return
        }
        
        self.textureCache = cache
        
        // Create Metal layer
        let metalLayer = CAMetalLayer()
        renderer.configureLayer(metalLayer)
        metalLayer.contentsScale = UIScreen.main.scale
        self.metalLayer = metalLayer
        glassContainer.layer.addSublayer(metalLayer)
        
        // Update renderer configuration
        renderer.updateConfiguration(MetalGlassRenderer.Configuration(
            cornerRadius: configuration.cornerRadius,
            isDark: configuration.isDark
        ))
    }
    
    private func setupBackdropLayer() {
        guard let backdropLayerClass = NSClassFromString("CABackdropLayer") as? CALayer.Type else {
            return
        }
        
        let backdrop = backdropLayerClass.init()
        
        // Configure backdrop layer
        backdrop.setValue(true, forKey: "windowServerAware")
        backdrop.setValue("liquid_glass_\(UUID().uuidString)", forKey: "groupName")
        backdrop.setValue(1.0, forKey: "scale")
        backdrop.setValue(0.2, forKey: "bleedAmount")
        backdrop.name = "backdrop"
        
        self.backdropLayer = backdrop
        backdropContainer.layer.addSublayer(backdrop)
    }
    
    private func setupHierarchyTracking() {
        let tracker = HierarchyTrackingLayer()
        self.hierarchyTracker = tracker
        self.layer.addSublayer(tracker)
        
        tracker.didEnterHierarchy = { [weak self] in
            self?.isInHierarchy = true
        }
        
        tracker.didExitHierarchy = { [weak self] in
            self?.isInHierarchy = false
        }
    }

    private func setupRunLoopObserver() {
        let minRenderInterval = 1.0 / CustomLiquidGlassView.throttleFPS
        
        let observer = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault,
            CFRunLoopActivity.beforeWaiting.rawValue,
            true,
            0,
            { [weak self] _, _ in
                guard let self = self, self.isInHierarchy else { return }
                
                let currentTime = CACurrentMediaTime()
                if currentTime - self.lastRenderTime >= minRenderInterval {
                    self.renderFrame()
                    self.lastRenderTime = currentTime
                }
            }
        )
        
        if let observer = observer {
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
            self.runLoopObserver = observer
        }
    }
    
    private func stopRunLoopObserver() {
        if let observer = runLoopObserver {
            CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
            self.runLoopObserver = nil
        }
    }

    private func captureBackdropTexture() -> MTLTexture? {
        guard let cache = textureCache,
              let backdropLayer = backdropLayer else {
            return nil
        }
        
        let bounds = backdropLayer.bounds
        guard bounds.width > 0, bounds.height > 0 else {
            return nil
        }
        
        let width = Int(bounds.width)
        let height = Int(bounds.height)
        
        // Reuse or create IOSurface-backed CVPixelBuffer
        let needsNewBuffer: Bool
        if let existingBuffer = pixelBuffer {
            needsNewBuffer = CVPixelBufferGetWidth(existingBuffer) != width ||
                             CVPixelBufferGetHeight(existingBuffer) != height
        } else {
            needsNewBuffer = true
        }
        
        if needsNewBuffer {
            let options: [String: Any] = [
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferCGImageCompatibilityKey as String: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
            ]
            
            var buffer: CVPixelBuffer?
            let status = CVPixelBufferCreate(
                kCFAllocatorDefault,
                width,
                height,
                kCVPixelFormatType_32BGRA,
                options as CFDictionary,
                &buffer
            )
            
            guard status == kCVReturnSuccess, let buffer = buffer else {
                return nil
            }
            
            self.pixelBuffer = buffer
            self.cachedTexture = nil
        let lockStatus = CVPixelBufferLockBaseAddress(buffer, [])
        guard lockStatus == kCVReturnSuccess else {
            NSLog("CustomLiquidGlassView: CVPixelBufferLockBaseAddress failed with status \(lockStatus)")
            return nil
        }
        defer {
            let unlockStatus = CVPixelBufferUnlockBaseAddress(buffer, [])
            if unlockStatus != kCVReturnSuccess {
                NSLog("CustomLiquidGlassView: CVPixelBufferUnlockBaseAddress failed with status \(unlockStatus)")
            }
        }
            return nil
        }
        
        guard let buffer = pixelBuffer else { return nil }
        
        // Lock pixel buffer for drawing
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        
        guard let baseAddress = CVPixelBufferGetBaseAddress(buffer) else {
            return nil
        }
        
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        
        guard let context = CGContext(
            data: baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            return nil
        }
        
        // Render backdrop hierarchy into pixel buffer
        UIGraphicsPushContext(context)
        backdropContainer.drawHierarchy(in: CGRect(origin: .zero, size: bounds.size), afterScreenUpdates: false)
        UIGraphicsPopContext()
        
        // Create Metal texture from pixel buffer (zero-copy via IOSurface)
        var textureOut: CVMetalTexture?
        let result = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            cache,
            buffer,
            nil,
            .bgra8Unorm,
            width,
            height,
            0,
            &textureOut
        )
        
        guard result == kCVReturnSuccess,
              let cvTexture = textureOut,
              let mtlTexture = CVMetalTextureGetTexture(cvTexture) else {
            return nil
        }
        
        self.cachedTexture = cvTexture
        return mtlTexture
    }
    
    private func renderFrame() {
        guard let metalLayer = metalLayer,
              let renderer = renderer,
              self.bounds.width > 0,
              self.bounds.height > 0 else {
            return
        }
        
        guard let backdropTexture = captureBackdropTexture() else {
            return
        }

        renderer.render(in: metalLayer, backdropTexture: backdropTexture)
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        
        let bounds = self.bounds
        guard bounds.width > 0, bounds.height > 0 else { 
            return 
        }
        
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        
        backdropContainer.frame = bounds
        glassContainer.frame = bounds
        
        // Update backdrop layer
        if let backdropLayer = backdropLayer {
            backdropLayer.frame = bounds
            backdropLayer.cornerRadius = configuration.cornerRadius
            backdropLayer.masksToBounds = true
        }
        
        // Update metal layer
        if let metalLayer = metalLayer {
            metalLayer.frame = bounds
            metalLayer.drawableSize = CGSize(
                width: bounds.width * UIScreen.main.scale,
                height: bounds.height * UIScreen.main.scale
            )
            metalLayer.cornerRadius = configuration.cornerRadius
            metalLayer.masksToBounds = true
        }
        
        CATransaction.commit()
    }

    /// Update configuration and trigger re-render
    public func updateConfiguration(_ newConfiguration: Configuration) {
        guard configuration != newConfiguration else {
            return
        }
        
        self.configuration = newConfiguration
        
        // Update renderer configuration
        renderer?.updateConfiguration(MetalGlassRenderer.Configuration(
            cornerRadius: newConfiguration.cornerRadius,
            isDark: newConfiguration.isDark
        ))
        
        setNeedsLayout()
    }
}
