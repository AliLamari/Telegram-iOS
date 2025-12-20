import Foundation
import UIKit
import Metal
import MetalPerformanceShaders
import QuartzCore

/// Metal-based renderer for custom glass effect
@available(iOS 13.0, *)
public final class MetalGlassRenderer {

    private let _device: MTLDevice
    private let _commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private let samplerState: MTLSamplerState
    private var uniformBuffer: MTLBuffer?
    private var blurFilter: MPSImageGaussianBlur?
    private var blurTexture: MTLTexture?
    
    public var device: MTLDevice { _device }
    public var commandQueue: MTLCommandQueue { _commandQueue }
    
    private struct GlassUniforms {
        var viewSize: SIMD2<Float>
        var cornerRadius: Float
        var isDark: Float
        var edgeWidth: Float
        var distortionStrength: Float
        var blurRadius: Float
        var vars: SIMD4<Float>
    }
    
    public struct Configuration {
        public var cornerRadius: CGFloat
        public var isDark: Bool
        public var edgeWidth: Float
        public var distortionStrength: Float
        public var blurRadius: Float
        public var vars: SIMD4<Float>

        public init(
            cornerRadius: CGFloat = 0,
            isDark: Bool = false,
            edgeWidth: Float = 20.0,
            distortionStrength: Float = 160.0,
            // blurRadius: Float = 1.2, // Clear
            blurRadius: Float = 1.44, // Regular
            vars: SIMD4<Float> = SIMD4<Float>(0, 0, 0, 0)
        ) {
            self.cornerRadius = cornerRadius
            self.isDark = isDark
            self.edgeWidth = edgeWidth
            self.distortionStrength = distortionStrength
            self.blurRadius = blurRadius
            self.vars = vars
        }
    }
    
    public private(set) var configuration = Configuration()

    public init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            return nil
        }
        self._device = device
        self._commandQueue = commandQueue
        self.uniformBuffer = device.makeBuffer(length: MemoryLayout<GlassUniforms>.size, options: .storageModeShared)
        
        // Sampler
        let samplerDesc = MTLSamplerDescriptor()
        samplerDesc.minFilter = .linear
        samplerDesc.magFilter = .linear
        samplerDesc.sAddressMode = .clampToEdge
        samplerDesc.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: samplerDesc) else { return nil }
        self.samplerState = sampler
        
        // Shader
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: Self.shaderSource, options: nil)
        } catch {
            print("[MetalGlassRenderer] Shader compilation failed: \(error)")
            return nil
        }
        
        guard let vertexFunc = library.makeFunction(name: "glassVertex"),
              let fragmentFunc = library.makeFunction(name: "glassFragment") else {
            print("[MetalGlassRenderer] Failed to load shader functions")
            return nil
        }
        
        // Pipeline
        let pipelineDesc = MTLRenderPipelineDescriptor()
        pipelineDesc.vertexFunction = vertexFunc
        pipelineDesc.fragmentFunction = fragmentFunc
        pipelineDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipelineDesc.colorAttachments[0].isBlendingEnabled = true
        pipelineDesc.colorAttachments[0].rgbBlendOperation = .add
        pipelineDesc.colorAttachments[0].alphaBlendOperation = .add
        pipelineDesc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        pipelineDesc.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        pipelineDesc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        pipelineDesc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        
        do {
            self.pipelineState = try device.makeRenderPipelineState(descriptor: pipelineDesc)
        } catch {
            print("[MetalGlassRenderer] Pipeline creation failed: \(error)")
            return nil
        }
    }

    public func updateConfiguration(_ configuration: Configuration) {
        self.configuration = configuration
    }
    
    public func render(in layer: CAMetalLayer, backdropTexture: MTLTexture? = nil) {
        guard let backdropTexture = backdropTexture,
              let drawable = layer.nextDrawable(),
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let uniformBuffer = self.uniformBuffer else { return }

        var uniforms = GlassUniforms(
            viewSize: SIMD2<Float>(Float(layer.drawableSize.width), Float(layer.drawableSize.height)),
            cornerRadius: Float(configuration.cornerRadius * layer.contentsScale),
            isDark: configuration.isDark ? 1.0 : 0.0,
            edgeWidth: configuration.edgeWidth * Float(layer.contentsScale),
            distortionStrength: configuration.distortionStrength,
            blurRadius: configuration.blurRadius,
            vars: configuration.vars
        )
        memcpy(uniformBuffer.contents(), &uniforms, MemoryLayout<GlassUniforms>.size)
        
        // Apply MPS Gaussian blur if needed
        let textureToUse: MTLTexture
        if configuration.blurRadius > 0.01 {
            let blurSigma = Float(configuration.blurRadius)
            if blurFilter?.sigma != blurSigma {
                blurFilter = MPSImageGaussianBlur(device: _device, sigma: blurSigma)
                blurFilter?.edgeMode = .clamp
            }
            
            if blurTexture == nil || blurTexture!.width != backdropTexture.width || blurTexture!.height != backdropTexture.height {
                let descriptor = MTLTextureDescriptor()
                descriptor.textureType = .type2D
                descriptor.width = backdropTexture.width
                descriptor.height = backdropTexture.height
                descriptor.pixelFormat = backdropTexture.pixelFormat
                descriptor.storageMode = .private
                descriptor.usage = [.shaderRead, .shaderWrite]
                blurTexture = _device.makeTexture(descriptor: descriptor)
            }
            
            if let blur = blurFilter, let blurred = blurTexture {
                blur.encode(commandBuffer: commandBuffer, sourceTexture: backdropTexture, destinationTexture: blurred)
                textureToUse = blurred
            } else {
                textureToUse = backdropTexture
            }
        } else {
            textureToUse = backdropTexture
        }
        
        let renderPass = MTLRenderPassDescriptor()
        renderPass.colorAttachments[0].texture = drawable.texture
        renderPass.colorAttachments[0].loadAction = .clear
        renderPass.colorAttachments[0].storeAction = .store
        renderPass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPass) else { return }
        encoder.setRenderPipelineState(pipelineState)
        encoder.setFragmentBuffer(uniformBuffer, offset: 0, index: 0)
        encoder.setFragmentTexture(textureToUse, index: 0)
        encoder.setFragmentSamplerState(samplerState, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
    
    public func configureLayer(_ layer: CAMetalLayer) {
        layer.device = _device
        layer.pixelFormat = .bgra8Unorm
        layer.isOpaque = false
        layer.framebufferOnly = true
        layer.maximumDrawableCount = 3
        layer.presentsWithTransaction = false
    }
    
    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;
    
    struct Uniforms {
        float2 viewSize;
        float cornerRadius;
        float isDark;  // 0.0 = light, 1.0 = dark
        float edgeWidth;
        float distortionStrength;
        float blurRadius;
        float4 vars;
    };
    
    struct VertexOut {
        float4 position [[position]];
        float2 uv;
    };
    
    // SDF for rounded rectangle
    float sdfRoundRect(float2 p, float2 hs, float r) {
        r = min(r, min(hs.x, hs.y));
        float2 q = abs(p) - hs + r;
        return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r;
    }
        
    vertex VertexOut glassVertex(uint vid [[vertex_id]]) {
        float2 pos[4] = { {-1,-1}, {1,-1}, {-1,1}, {1,1} };
        float2 uv[4] = { {0,0}, {1,0}, {0,1}, {1,1} };
        return { float4(pos[vid], 0, 1), uv[vid] };
    }
    
    fragment float4 glassFragment(VertexOut in [[stage_in]],
                                   constant Uniforms& u [[buffer(0)]],
                                   texture2d<float> tex [[texture(0)]],
                                   sampler s [[sampler(0)]]) {
        float2 hs = u.viewSize * 0.5;
        float2 p = in.uv * u.viewSize - hs;
        float dist = sdfRoundRect(p, hs, u.cornerRadius);
        
        // Outside shape
        if (dist > 0.0) discard_fragment();
                
        // Sample texture (blur already applied via MPS)
        float4 color = tex.sample(s, in.uv);
                
        // Distortion
        if (u.distortionStrength > 0.01) {
            float edgeDist = -dist;
            float norm = clamp(edgeDist / u.edgeWidth, 0.0, 1.0);
            float lens = 1.0 - sqrt(max(0.0, 1.0 - pow(1.0 - norm, 2.0)));
            
            float2 e = float2(1.0, 0.0);
            float2 grad = float2(
                sdfRoundRect(p + e.xy, hs, u.cornerRadius) - sdfRoundRect(p - e.xy, hs, u.cornerRadius),
                sdfRoundRect(p + e.yx, hs, u.cornerRadius) - sdfRoundRect(p - e.yx, hs, u.cornerRadius)
            );
            float2 n = normalize(grad);
            float2 offset = n * lens * u.distortionStrength / u.viewSize;
            
            if (length(offset) > 0.001) {
                float2 distUV = clamp(in.uv - offset, 0.0, 1.0);
                color = tex.sample(s, distUV);
            }
        }

        // Native liquid glass effect: per-channel lifting/lowering
        // Working in linear RGB space for accurate color transformations
        float3 lin = pow(color.rgb, float3(2.2));
        
        float3 result;
        if (u.isDark > 0.5) {            
            // Prevent pure black (min gray ~0.0035 in linear RGB)
            float3 darkModeMinimumBrightness = max(0.0, 0.35 / 100.0);
            result = mix(lin, darkModeMinimumBrightness, 0.8);
        } else {
            // Light mode: lift colors while preserving hue differences
            // Reduce lift strength for already bright values to preserve visibility
            float3 liftFactor = 0.5 + lin * 1.75;
            
            // Dampen lift for very bright values (>0.85 in linear RGB ≈ sRGB 240+)
            float3 brightDampen = smoothstep(0, 1.0, lin);
            liftFactor = mix(liftFactor, liftFactor * 0.3, brightDampen);
            
            float3 lifted = lin + (1.0 - lin) * liftFactor;
            result = mix(lin, lifted, 0.8);
        }
        
        // Convert back to sRGB
        color.rgb = pow(clamp(result, 0.0, 1.0), float3(1.0/2.2));

        // Edge glow
        float edgeGlow = 1.0 - smoothstep(0.0, 2.5, -dist);
        color.rgb += edgeGlow * (u.isDark > 0.5 ? 0.3 : 0.1);
        
        // // // === CLEAR STYLE ===
        // // Use with others components later
        // float luma = dot(color.rgb, float3(0.299, 0.587, 0.114));

        // // Light mode: add veil
        // float veilMask = smoothstep(0.05, 0.6, luma);
        // color.rgb += 0.12 * veilMask;

        // // Dark mode: boost darks
        // float minC = min(color.r, min(color.g, color.b));
        // float darkMask = 1.0 - smoothstep(0.15, 0.45, minC);
        // float3 darkLift = float3(0.52);
        // color.rgb = mix(color.rgb, darkLift, darkMask * 0.18);

        // // Edge glow
        // float edgeGlow = 1.0 - smoothstep(0.0, 4.0, -dist);
        // color.rgb += edgeGlow * (u.isDark > 0.5 ? 0.06 : 0.03);
        
        return clamp(color, 0.0, 1.0);
    }
    """
}
