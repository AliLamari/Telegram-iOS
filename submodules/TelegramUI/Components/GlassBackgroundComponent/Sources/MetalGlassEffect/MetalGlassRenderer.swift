import Foundation
import UIKit
import Metal
import QuartzCore

/// Metal-based renderer for custom glass effect
/// Renders specular highlights and edge glow on top of blur layer
@available(iOS 13.0, *)
public final class MetalGlassRenderer {
    
    // MARK: - Metal Core Objects
    
    private let _device: MTLDevice
    private let _commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private let samplerState: MTLSamplerState
    
    /// The Metal device used by this renderer
    public var device: MTLDevice {
        return self._device
    }
    
    /// The Metal command queue (shared with BackdropCapturer to prevent GPU race)
    public var commandQueue: MTLCommandQueue {
        return self._commandQueue
    }
    
    // MARK: - Uniform Buffer
    
    private struct GlassUniforms {
        var viewSize: SIMD2<Float>
        var cornerRadius: Float
        var isDark: Float
    }
    
    private var uniformBuffer: MTLBuffer?
    
    // MARK: - Configuration
    
    public struct Configuration {
        public var cornerRadius: CGFloat
        public var isDark: Bool
        
        public init(cornerRadius: CGFloat = 0, isDark: Bool = false) {
            self.cornerRadius = cornerRadius
            self.isDark = isDark
        }
    }
    
    private var configuration: Configuration = Configuration()
    
    // MARK: - Initialization
    
    public init?() {
        // Get default Metal device
        guard let device = MTLCreateSystemDefaultDevice() else {
            return nil
        }
        self._device = device
        
        // Create command queue
        guard let commandQueue = device.makeCommandQueue() else {
            return nil
        }
        self._commandQueue = commandQueue
        
        // Create uniform buffer
        self.uniformBuffer = device.makeBuffer(length: MemoryLayout<GlassUniforms>.size, options: .storageModeShared)
        
        // Create texture sampler
        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        guard let samplerState = device.makeSamplerState(descriptor: samplerDescriptor) else {
            return nil
        }
        self.samplerState = samplerState
        
        // Load shader library
        guard let library = Self.loadShaderLibrary(device: device) else {
            return nil
        }
        
        // Get shader functions
        guard let vertexFunction = library.makeFunction(name: "glassVertexShader"),
              let fragmentFunction = library.makeFunction(name: "glassFragmentShader") else {
            return nil
        }
        
        // Create render pipeline
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        
        // Enable alpha blending for overlay effect
        pipelineDescriptor.colorAttachments[0].isBlendingEnabled = true
        pipelineDescriptor.colorAttachments[0].rgbBlendOperation = .add
        pipelineDescriptor.colorAttachments[0].alphaBlendOperation = .add
        pipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        pipelineDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        pipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        pipelineDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        
        do {
            self.pipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        } catch {
            return nil
        }
    }
    
    // MARK: - Shader Loading
    
    private static func loadShaderLibrary(device: MTLDevice) -> MTLLibrary? {
        // Compile shader from embedded source
        // Note: Bazel doesn't compile .metal files, so we use runtime compilation
        let shaderSource = Self.embeddedShaderSource()
        do {
            let library = try device.makeLibrary(source: shaderSource, options: nil)
            return library
        } catch {
            print("[MetalGlassRenderer] Failed to compile shader: \(error)")
            return nil
        }
    }
    
    /// Metal shader source (compiled at runtime since Bazel doesn't process .metal files)
    private static func embeddedShaderSource() -> String {
        return """
        #include <metal_stdlib>
        using namespace metal;
        
        // Uniforms passed from Swift
        struct GlassUniforms {
            float2 viewSize;       // Size in pixels
            float cornerRadius;    // Corner radius in pixels
            float isDark;          // 1.0 for dark mode, 0.0 for light mode
        };
        
        struct VertexOut {
            float4 position [[position]];
            float2 texCoord;
        };
        
        // Signed distance function for rounded rectangle
        float sdRoundedRect(float2 pos, float2 halfSize, float radius) {
            radius = min(radius, min(halfSize.x, halfSize.y));
            float2 q = abs(pos) - halfSize + radius;
            return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - radius;
        }
        
        vertex VertexOut glassVertexShader(uint vertexID [[vertex_id]]) {
            float2 positions[4] = {
                float2(-1.0, -1.0),
                float2( 1.0, -1.0),
                float2(-1.0,  1.0),
                float2( 1.0,  1.0)
            };
            
            // CGContext captures with Y-down (UIKit coordinate system)
            // So texture coordinates should match: (0,0) = top-left
            float2 texCoords[4] = {
                float2(0.0, 0.0),  // top-left
                float2(1.0, 0.0),  // top-right
                float2(0.0, 1.0),  // bottom-left
                float2(1.0, 1.0)   // bottom-right
            };
            
            VertexOut out;
            out.position = float4(positions[vertexID], 0.0, 1.0);
            out.texCoord = texCoords[vertexID];
            return out;
        }
        
        fragment float4 glassFragmentShader(VertexOut in [[stage_in]],
                                            constant GlassUniforms& uniforms [[buffer(0)]],
                                            texture2d<float> backdropTexture [[texture(0)]],
                                            sampler textureSampler [[sampler(0)]]) {
            
            float2 size = uniforms.viewSize;
            float radius = uniforms.cornerRadius;
            
            // Convert UV (0-1) to pixel coordinates centered at origin
            float2 halfSize = size * 0.5;
            float2 pos = in.texCoord * size - halfSize;
            
            // Signed distance to rounded rectangle edge (negative = inside)
            float dist = sdRoundedRect(pos, halfSize, radius);
            
            // Skip pixels outside the shape
            if (dist > 0.0) {
                discard_fragment();
            }
            
            // // DEBUG: Check if backdrop texture is available
            float4 backdropColor = backdropTexture.sample(textureSampler, in.texCoord);
            // Return backdrop directly (no tint) to see if it works
            return backdropColor;
        }
        """
    }
    
    // MARK: - Configuration
    
    public func updateConfiguration(_ configuration: Configuration) {
        self.configuration = configuration
    }
    
    // MARK: - Rendering
    
    /// Render glass effect into the given CAMetalLayer
    /// - Parameters:
    ///   - layer: The Metal layer to render into
    ///   - backdropTexture: Optional backdrop texture to display behind glass effect
    public func render(in layer: CAMetalLayer, backdropTexture: MTLTexture? = nil) {
        // CRITICAL: Shader requires backdropTexture, so skip rendering if nil
        guard let backdropTexture = backdropTexture else {
            return
        }
        
        guard let drawable = layer.nextDrawable() else {
            return
        }
        
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            return
        }
        
        // Update uniforms
        if let uniformBuffer = self.uniformBuffer {
            var uniforms = GlassUniforms(
                viewSize: SIMD2<Float>(Float(layer.drawableSize.width), Float(layer.drawableSize.height)),
                cornerRadius: Float(configuration.cornerRadius * layer.contentsScale),
                isDark: configuration.isDark ? 1.0 : 0.0
            )
            memcpy(uniformBuffer.contents(), &uniforms, MemoryLayout<GlassUniforms>.size)
        }
        
        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = drawable.texture
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].storeAction = .store
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        
        guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return
        }
        
        renderEncoder.setRenderPipelineState(pipelineState)
        
        // Set uniform buffer
        if let uniformBuffer = self.uniformBuffer {
            renderEncoder.setFragmentBuffer(uniformBuffer, offset: 0, index: 0)
        }
        
        // Set backdrop texture (guaranteed to be non-nil here)
        renderEncoder.setFragmentTexture(backdropTexture, index: 0)
        renderEncoder.setFragmentSamplerState(samplerState, index: 0)
        
        // Draw full-screen quad (triangle strip with 4 vertices)
        renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        
        renderEncoder.endEncoding()
        
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
    
    // MARK: - Layer Setup
    
    /// Configure a CAMetalLayer for rendering
    public func configureLayer(_ layer: CAMetalLayer) {
        layer.device = _device
        layer.pixelFormat = .bgra8Unorm
        layer.isOpaque = false
        layer.framebufferOnly = true
        
        // Triple buffering для плавного рендеринга без разрывов
        layer.maximumDrawableCount = 3
        
        // Отображать как можно скорее без ожидания VSync
        layer.presentsWithTransaction = false
    }
}
