import Foundation
import UIKit
import Metal
import MetalPerformanceShaders
import QuartzCore

@available(iOS 13.0, *)
public final class MetalKnobGlassRenderer {

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
    }
    
    public struct Configuration {
        public var cornerRadius: CGFloat
        public var isDark: Bool
        public var edgeWidth: Float
        public var distortionStrength: Float
        public var blurRadius: Float

        public init(
            cornerRadius: CGFloat = 0,
            isDark: Bool = false,
            edgeWidth: Float = 20.0,
            distortionStrength: Float = 160.0,
            blurRadius: Float = 0.0,
        ) {
            self.cornerRadius = cornerRadius
            self.isDark = isDark
            self.edgeWidth = edgeWidth
            self.distortionStrength = distortionStrength
            self.blurRadius = blurRadius
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
        samplerDesc.minFilter = .nearest
        samplerDesc.magFilter = .nearest
        samplerDesc.sAddressMode = .clampToEdge
        samplerDesc.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: samplerDesc) else { return nil }
        self.samplerState = sampler
        
        // Shader
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: Self.shaderSource, options: nil)
        } catch {
            print("[MetalKnobGlassRenderer] Shader compilation failed: \(error)")
            return nil
        }
        
        guard let vertexFunc = library.makeFunction(name: "glassVertex"),
              let fragmentFunc = library.makeFunction(name: "glassFragment") else {
            print("[MetalKnobGlassRenderer] Failed to load shader functions")
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
            print("[MetalKnobGlassRenderer] Pipeline creation failed: \(error)")
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
            blurRadius: configuration.blurRadius
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
        
        // Sample background first
        float4 color = tex.sample(s, in.uv);
        
        // Shadow - render outside glass but within shadow radius
        float shadowOffset = 2.0;
        float shadowBlur = 6.0;
        float2 shadowCenter = float2(shadowOffset, shadowOffset);
        float shadowDist = sdfRoundRect(p - shadowCenter, hs, u.cornerRadius);
        float shadowRadius = shadowBlur;
        
        bool insideGlass = (dist <= 0.0);
        bool insideShadow = (shadowDist < shadowRadius && shadowDist > 0.0);
        
        if (!insideGlass && insideShadow) {
            float shadowFalloff = shadowDist / shadowBlur;
            float shadowStrength = smoothstep(1.0, 0.0, shadowFalloff);
            float shadowDarkness = u.isDark > 0.5 ? 0.15 : 0.10;
            color.rgb = mix(color.rgb, float3(0.0), shadowStrength * shadowDarkness);
        }
        
        // Outside shape (including shadow area)
        if (dist > shadowRadius) discard_fragment();
                
        // Skip glass rendering in shadow-only area
        if (!insideGlass) {
            return color;
        }
        
        // Hybrid distortion - center scale + edge distortion
        if (u.distortionStrength > 0.01) {
            // Step 1: Center scaling (makes content appear smaller through glass)
            float2 center = float2(0.5, 0.5);
            float2 toCenter = in.uv - center;
            float centerDist = length(toCenter);
            
            float centerScale = 1.0 + 0.04 * smoothstep(0.0, 0.5, centerDist);
            float2 baseUV = center + toCenter * centerScale;
            
            // Step 2: Edge distortion + chromatic aberration
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
            
            // Apply distortion first
            float2 distortedUV = baseUV - offset;
            
            // Chromatic aberration - TEST: constant strength to verify it works
            float2 toEdge = distortedUV - float2(0.5);
            float2 chromaticDir = normalize(toEdge);
            // Simple formula: stronger as we get closer to edge
            float edgeFactor = (1.0 - norm) * (1.0 - norm);  // Quadratic falloff from edge
            float chromaticStrength = edgeFactor * 3.0 / u.viewSize.x;  // 3 pixels max
            
            float2 redUV = clamp(distortedUV + chromaticDir * chromaticStrength, 0.0, 1.0);
            float2 greenUV = clamp(distortedUV, 0.0, 1.0);
            float2 blueUV = clamp(distortedUV - chromaticDir * chromaticStrength, 0.0, 1.0);
            
            // Sample each channel separately for chromatic aberration
            float4 redSample = tex.sample(s, redUV);
            float4 greenSample = tex.sample(s, greenUV);
            float4 blueSample = tex.sample(s, blueUV);
            
            color.r = redSample.r;
            color.g = greenSample.g;
            color.b = blueSample.b;
            color.a = greenSample.a;
        } else {
            color = tex.sample(s, in.uv);
        }

        // Light mode: subtle glass veil
        if (u.isDark < 0.5) {
            float luma = dot(color.rgb, float3(0.299, 0.587, 0.114));
            float veilMask = smoothstep(0.05, 0.6, luma);
            color.rgb += 0.03 * veilMask;  // Subtle 5% veil on bright areas
        }
        
        // Inner shadow from bottom (glass darkening effect)
        float normalizedY = in.uv.y;  // 0 at top, 1 at bottom
        float shadowHeight = 0.5;  // Shadow extends to half of height
        if (normalizedY > (1.0 - shadowHeight)) {
            // Gradient from bottom to half height
            float shadowFactor = (normalizedY - (1.0 - shadowHeight)) / shadowHeight;
            shadowFactor = pow(shadowFactor, 1.5);  // Smooth falloff
            
            // Darker for light mode, subtle for dark mode
            float shadowStrength = u.isDark > 0.5 ? 0.08 : 0.15;
            color.rgb *= (1.0 - shadowFactor * shadowStrength);
        }
        
        // Directional edge glow (iOS 26 style) - rim lighting based on view direction
        float edgeDist = -dist;
        float edgeGlow = smoothstep(12.0, 0.0, edgeDist);  // Wider rim for blue
        
        if (edgeGlow > 0.01) {
            // Calculate surface normal from SDF gradient
            float2 e = float2(1.0, 0.0);
            float2 grad = float2(
                sdfRoundRect(p + e.xy, hs, u.cornerRadius) - sdfRoundRect(p - e.xy, hs, u.cornerRadius),
                sdfRoundRect(p + e.yx, hs, u.cornerRadius) - sdfRoundRect(p - e.yx, hs, u.cornerRadius)
            );
            float2 normal = normalize(grad);
            
            // Light direction from top-left
            float2 lightDir = normalize(float2(-1.0, 1.0));
            float NdotL = dot(normal, lightDir);
            
            // Rim light effect - concentrated at edges
            float rimPower = 2.5;
            float rimStrength = pow(edgeGlow, rimPower);

            // Directional color mixing based on light angle
            float lightFacing = smoothstep(-0.1, 0.3, NdotL);  // Even wider blue coverage

            // Colors - darker more saturated blue
            float3 blueRim = float3(30.0/255.0, 70.0/255.0, 110.0/255.0);  // Darker blue
            float3 whiteRim = float3(0.6, 0.6, 0.6);   // Soft white
            
            // Mix based on light direction
            float3 rimColor = mix(whiteRim, blueRim, lightFacing);
            
            // Apply rim lighting with stronger intensity for blue areas
            float baseStrength = u.isDark > 0.5 ? 0.30 : 0.45;
            float blueBoost = lightFacing * 0.15;  // Extra boost for blue areas
            float finalStrength = rimStrength * (baseStrength + blueBoost);
            color.rgb = mix(color.rgb, rimColor, finalStrength);
        }
        
        return clamp(color, 0.0, 1.0);
    }
    """
}
