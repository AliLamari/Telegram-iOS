import Foundation
import UIKit
import Metal
import QuartzCore

@available(iOS 13.0, *)
public final class LiquidGlassKnob: UIView {
    
    public struct Configuration {
        public var size: CGFloat
        public var isDark: Bool
        
        public init(size: CGFloat, isDark: Bool = false) {
            self.size = size
            self.isDark = isDark
        }
    }
    
    private let configuration: Configuration
    
    private let backdropContainer: UIView
    private let glassContainer: UIView
    private var backdropLayer: CALayer?
    private var metalLayer: CAMetalLayer?
    private var renderer: MetalKnobGlassRenderer?
    
    private var displayLink: CADisplayLink?
    private var isRenderingActive: Bool = false
    
    private var textureCache: CVMetalTextureCache?
    private var pixelBuffer: CVPixelBuffer?
    private var cachedTexture: CVMetalTexture?
    
    public private(set) var isActive: Bool = false
    private var squeeze: CGFloat = 1.0
    
    private var inactiveWhiteLayer: CALayer?
    
    private var containerWidth: CGFloat { configuration.size * 2 }
    private var containerHeight: CGFloat { configuration.size * 1.25 }
    
    public init(configuration: Configuration) {
        self.configuration = configuration
        
        self.backdropContainer = UIView()
        self.backdropContainer.layer.setValue(false, forKey: "layerUsesCoreImageFilters")
        self.glassContainer = UIView()
        
        super.init(frame: CGRect(x: 0, y: 0, width: configuration.size * 2, height: configuration.size * 1.25))

        self.layer.setValue(false, forKey: "layerUsesCoreImageFilters")
        self.backgroundColor = .clear
        self.isUserInteractionEnabled = false
        
        addSubview(backdropContainer)
        addSubview(glassContainer)

        setupMetalRendering()
        setupBackdropLayer()
        setupInactiveLayer()
        setupDisplayLink()

        let scaleX = (configuration.size * 1.35) / (configuration.size * 2)
        let scaleY = (configuration.size * 0.9) / (configuration.size * 1.25)
        self.transform = CGAffineTransform(scaleX: scaleX, y: scaleY)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    deinit {
        stopDisplayLink()
        
        cachedTexture = nil
        pixelBuffer = nil
        if let cache = textureCache {
            CVMetalTextureCacheFlush(cache, 0)
        }
        textureCache = nil
    }
    
    private func setupMetalRendering() {
        guard let renderer = MetalKnobGlassRenderer() else {
            return
        }
        self.renderer = renderer
        
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
        
        let metalLayer = CAMetalLayer()
        renderer.configureLayer(metalLayer)
        metalLayer.contentsScale = UIScreen.main.scale
        self.metalLayer = metalLayer
        glassContainer.layer.addSublayer(metalLayer)
        
        renderer.updateConfiguration(MetalKnobGlassRenderer.Configuration(
            cornerRadius: containerHeight / 2.0,
            isDark: configuration.isDark,
            edgeWidth: 10.0,
            distortionStrength: 30.0,
            blurRadius: 0.0,
        ))
    }
    
    private func setupBackdropLayer() {
        guard let backdropLayerClass = NSClassFromString("CABackdropLayer") as? CALayer.Type else {
            return
        }
        
        let backdrop = backdropLayerClass.init()
        
        backdrop.setValue(true, forKey: "windowServerAware")
        backdrop.setValue("liquid_glass_knob_\(UUID().uuidString)", forKey: "groupName")
        backdrop.setValue(1.0, forKey: "scale")
        backdrop.setValue(0.2, forKey: "bleedAmount")
        backdrop.name = "backdrop"
        
        self.backdropLayer = backdrop
        backdropContainer.layer.addSublayer(backdrop)
    }
    
    private func setupInactiveLayer() {
        let whiteLayer = CALayer()
        whiteLayer.backgroundColor = UIColor.white.cgColor
        whiteLayer.shadowColor = UIColor.black.cgColor
        whiteLayer.shadowOpacity = 0.15
        whiteLayer.shadowOffset = CGSize(width: 0, height: 2)
        whiteLayer.shadowRadius = 4
        self.inactiveWhiteLayer = whiteLayer
        self.layer.insertSublayer(whiteLayer, above: glassContainer.layer)
    }
    
    private func animateOpacity() {
        let duration: TimeInterval = 0.08
        let curve: UIView.AnimationOptions = !isActive ? .curveEaseIn : .curveEaseOut
        
        UIView.animate(withDuration: duration, delay: 0, options: curve, animations: {
            self.inactiveWhiteLayer?.opacity = self.isActive ? 0.0 : 1.0
        })
    }
    
    private func animateTransforms() {
        UIView.animate(withDuration: 0.125, delay: 0, options: [.curveEaseOut, .beginFromCurrentState], animations: {
            if self.isActive {
                self.transform = .identity
            } else {
                let scaleX = (self.configuration.size * 1.35) / (self.configuration.size * 2)
                let scaleY = (self.configuration.size * 0.9) / (self.configuration.size * 1.25)
                self.transform = CGAffineTransform(scaleX: scaleX, y: scaleY)
            }
        })
    }
    
    private func setupDisplayLink() {
        let displayLink = CADisplayLink(target: self, selector: #selector(displayLinkFired))
        displayLink.add(to: .main, forMode: .common)
        displayLink.isPaused = true
        self.displayLink = displayLink
    }
    
    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }
    
    @objc private func displayLinkFired() {
        guard isRenderingActive else { return }
        renderFrame()
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
        }
        
        guard let buffer = pixelBuffer else { return nil }
        
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
        
        UIGraphicsPushContext(context)
        backdropContainer.drawHierarchy(in: CGRect(origin: .zero, size: bounds.size), afterScreenUpdates: false)
        UIGraphicsPopContext()
        
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
        
        if let whiteLayer = inactiveWhiteLayer {
            whiteLayer.frame = bounds
            whiteLayer.cornerRadius = bounds.height / 2.0
        }
        
        if let backdropLayer = backdropLayer {
            backdropLayer.bounds = CGRect(x: 0, y: 0, width: containerWidth, height: containerHeight)
            backdropLayer.position = CGPoint(x: containerWidth / 2.0, y: containerHeight / 2.0)
            backdropLayer.cornerRadius = containerHeight / 2.0
            backdropLayer.masksToBounds = true
        }
        
        if let metalLayer = metalLayer {
            metalLayer.bounds = CGRect(x: 0, y: 0, width: containerWidth, height: containerHeight)
            metalLayer.position = CGPoint(x: containerWidth / 2.0, y: containerHeight / 2.0)
            let scale = UIScreen.main.scale
            metalLayer.drawableSize = CGSize(
                width: containerWidth * scale,
                height: containerHeight * scale
            )
            metalLayer.cornerRadius = containerHeight / 2.0
            metalLayer.masksToBounds = true
        }
        
        CATransaction.commit()
    }
    
    public func startRendering() {
        guard let displayLink = displayLink else { return }
        isRenderingActive = true
        displayLink.isPaused = false
    }
    
    public func stopRendering() {
        guard let displayLink = displayLink else { return }
        isRenderingActive = false
        displayLink.isPaused = true
    }
    
    public func renderNow() {
        renderFrame()
    }
    
    public func setActive(_ active: Bool) {
        guard isActive != active else { return }
        isActive = active

        active ? startRendering() : stopRendering()

        animateOpacity()
        animateTransforms()
    }
    
    public func setSqueeze(_ squeeze: CGFloat) {
        guard self.squeeze != squeeze else { return }
        guard isActive else { return }
        
        self.squeeze = squeeze
        
        let squeezeScaleX = squeeze
        let squeezeScaleY = 1.0 + (1.0 - squeeze) * 0.75
        
        UIView.animate(
            withDuration: 1.0,
            delay: 0,
            usingSpringWithDamping: 0.5,
            initialSpringVelocity: 0.5,
            options: [.beginFromCurrentState],
            animations: {
                self.transform = CGAffineTransform(scaleX: squeezeScaleX, y: squeezeScaleY)
            }
        )
    }
}

