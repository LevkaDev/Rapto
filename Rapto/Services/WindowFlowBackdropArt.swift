//
//  WindowFlowBackdropArt.swift
//  Rapto
//
//  Renders native-Retina GPU atmospheric sky backdrops (Metal) plus the smoked
//  frosted glass desktop backdrop for Window Flow.
//

import CoreGraphics
import CoreImage
import Foundation
import Metal
import QuartzCore

// MARK: - Native Retina GPU Atmospheric Sky Renderer

struct WindowFlowSkyUniforms {
    var resolution: SIMD2<Float>
    var time: Float
    var mode: Int32          // 0 = Crisp Azure Sky, 1 = Twilight Dusk Sky, 2 = Moonlit Night Sky
    var lean: SIMD2<Float>   // Smoothed pointer offset (-1...1)
    var pad: SIMD2<Float> = .zero
}

@MainActor
final class WindowFlowMetalSkyLayer: CAMetalLayer {
    private static let srgbSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    private let commandQueue: MTLCommandQueue?
    private let pipeline: MTLRenderPipelineState?

    init?(pipelineBundle: WindowFlowMetalPipeline?) {
        guard let bundle = pipelineBundle else { return nil }
        self.commandQueue = bundle.queue
        self.pipeline = bundle.pipeline
        super.init()
        self.device = bundle.device
        // MARK: - Workaround: SDR sRGB Metal drawable to prevent EDR close flash
        // Cause: Wide-gamut monitors briefly promote .rgba16Float CAMetalLayers to EDR and flash
        //        back to SDR when the panel orders out.
        // Context: Pure SDR .bgra8Unorm_srgb keeps compositing in standard range and halves VRAM.
        self.pixelFormat = .bgra8Unorm_srgb
        self.colorspace = Self.srgbSpace
        self.framebufferOnly = true
        self.isOpaque = true
    }

    override init(layer: Any) {
        if let other = layer as? WindowFlowMetalSkyLayer {
            self.commandQueue = other.commandQueue
            self.pipeline = other.pipeline
        } else {
            self.commandQueue = nil
            self.pipeline = nil
        }
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) { nil }

    func configureSize(bounds: CGRect, backingScale: CGFloat) {
        self.frame = bounds
        self.contentsScale = backingScale
        // Cap longest horizontal edge at 4480 px so 5K+ displays stay comfortably within 120 Hz budget.
        let rawW = bounds.width * backingScale
        let rawH = bounds.height * backingScale
        let capFactor = min(1.0, 4480.0 / max(rawW, 1.0))
        self.drawableSize = CGSize(
            width: max(1, (rawW * capFactor).rounded()),
            height: max(1, (rawH * capFactor).rounded())
        )
    }

    func drawSky(mode: Int32, time: Double, lean: CGPoint) {
        guard let commandQueue, let pipeline,
              drawableSize.width >= 1, drawableSize.height >= 1,
              let drawable = nextDrawable(),
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        var uniforms = WindowFlowSkyUniforms(
            resolution: SIMD2<Float>(Float(drawableSize.width), Float(drawableSize.height)),
            time: Float(time),
            mode: mode,
            lean: SIMD2<Float>(Float(lean.x), Float(lean.y))
        )
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<WindowFlowSkyUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}

nonisolated final class WindowFlowMetalPipeline: @unchecked Sendable {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState

    init(device: MTLDevice, queue: MTLCommandQueue, pipeline: MTLRenderPipelineState) {
        self.device = device
        self.queue = queue
        self.pipeline = pipeline
    }

    static func build() -> WindowFlowMetalPipeline? {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: shaderSource, options: nil),
              let vs = library.makeFunction(name: "windowFlowSkyVertex"),
              let fs = library.makeFunction(name: "windowFlowSkyFragment") else {
            return nil
        }
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vs
        desc.fragmentFunction = fs
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: desc) else { return nil }
        return WindowFlowMetalPipeline(device: device, queue: queue, pipeline: pipeline)
    }

    static let shaderSource = #"""
    #include <metal_stdlib>
    using namespace metal;

    struct SkyUniforms {
        float2 resolution;
        float  time;
        int    mode;
        float2 lean;
        float2 pad;
    };

    struct Varyings {
        float4 position [[position]];
        float2 uv; // (0,0) bottom-left, (1,1) top-right
    };

    vertex Varyings windowFlowSkyVertex(uint vid [[vertex_id]]) {
        float2 pos = float2((vid == 1) ? 3.0 : -1.0, (vid == 2) ? 3.0 : -1.0);
        Varyings out;
        out.position = float4(pos, 0.0, 1.0);
        out.uv = pos * 0.5 + 0.5;
        return out;
    }

    inline float hash21(float2 p) {
        float3 p3 = fract(float3(p.xyx) * float3(0.1031, 0.1030, 0.0973));
        p3 += dot(p3, p3.yzx + 33.33);
        return fract((p3.x + p3.y) * p3.z);
    }

    inline float2 hash22(float2 p) {
        float3 p3 = fract(float3(p.xyx) * float3(0.1031, 0.1030, 0.0973));
        p3 += dot(p3, p3.yzx + 33.33);
        return fract((p3.xx + p3.yz) * p3.zy);
    }

    inline float vnoise(float2 p) {
        float2 i = floor(p);
        float2 f = fract(p);
        float2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
        float a = hash21(i);
        float b = hash21(i + float2(1.0, 0.0));
        float c = hash21(i + float2(0.0, 1.0));
        float d = hash21(i + float2(1.0, 1.0));
        return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
    }

    inline float2 cloudWarp(float2 q) {
        const float2x2 rot = float2x2(0.80, -0.60, 0.60, 0.80);
        float2 w = float2(0.0);
        float amp = 0.58;
        float2 p = q * 0.52;
        for (int i = 0; i < 2; ++i) {
            w.x += amp * (vnoise(p + float2(4.2, 1.7)) - 0.5);
            w.y += amp * (vnoise(p + float2(8.9, 6.3)) - 0.5);
            p = (rot * p) * 2.08 + float2(13.1, 7.7);
            amp *= 0.48;
        }
        return q + w * 0.88;
    }

    inline float cloudDensityFine(float2 warped) {
        const float2x2 rot = float2x2(0.80, -0.60, 0.60, 0.80);
        float sum = 0.0;
        float amp = 0.52;
        float2 p = warped * 1.32;
        for (int i = 0; i < 7; ++i) {
            sum += amp * vnoise(p);
            p = (rot * p) * 2.07 + float2(17.1, 31.7);
            amp *= 0.505;
        }
        return sum / 1.01;
    }

    inline float cloudDensitySoft(float2 warped) {
        const float2x2 rot = float2x2(0.80, -0.60, 0.60, 0.80);
        float sum = 0.0;
        float amp = 0.54;
        float2 p = warped * 1.32;
        for (int i = 0; i < 4; ++i) {
            sum += amp * vnoise(p);
            p = (rot * p) * 2.06 + float2(17.1, 31.7);
            amp *= 0.5;
        }
        return sum / 0.98;
    }

    inline float cirrusField(float2 uv, float aspect, float t) {
        float2 p = float2((uv.x - 0.5) * aspect * 2.3, uv.y * 5.6);
        p += float2(t * 0.010, 0.0);
        float curl = vnoise(p * 0.55 + float2(2.1, 7.4)) - 0.5;
        p.y += curl * 1.15;
        p.x += curl * 0.35;
        const float2x2 rot = float2x2(0.94, -0.34, 0.34, 0.94);
        float sum = 0.0;
        float amp = 0.53;
        float2 q = p;
        for (int i = 0; i < 5; ++i) {
            sum += amp * vnoise(q * float2(1.0, 2.5));
            q = (rot * q) * 2.12 + float2(13.7, 5.3);
            amp *= 0.5;
        }
        return sum;
    }

    inline float3 starField(float2 fragPx, float scale, float densityKeep) {
        float2 p = fragPx / scale;
        float2 cell = floor(p);
        float2 local = fract(p) - 0.5;
        float rnd = hash21(cell + 91.7);
        if (rnd < densityKeep) return float3(0.0);
        float2 jitter = (hash22(cell + 17.3) - 0.5) * 0.72;
        float2 d = (local - jitter) * scale;
        float r2 = dot(d, d);
        float mag = fract(rnd * 37.3);
        float core = exp(-r2 * 0.58) * (0.40 + 0.65 * mag * mag);
        float halo = exp(-sqrt(r2) * 0.34) * 0.16 * mag * mag;
        float3 tint = (mag > 0.78)
            ? float3(1.00, 0.90, 0.78)
            : (mag < 0.32 ? float3(0.74, 0.86, 1.00) : float3(0.95, 0.97, 1.00));
        return tint * (core + halo);
    }

    fragment half4 windowFlowSkyFragment(Varyings in [[stage_in]], constant SkyUniforms &U [[buffer(0)]]) {
        float aspect = U.resolution.x / max(U.resolution.y, 1.0);
        float2 uv = in.uv;
        float2 fragPx = in.uv * U.resolution;
        float t = U.time;

        float3 zenithCol, midSkyCol, horizonCol, groundMistCol;
        float3 sunGlowCol, cloudShadowCol, cloudLitCol, cirrusCol;
        float2 glowCenter;
        float2 rayOrigin;
        float covLow, covHigh, rayStrength;

        if (U.mode == 0) {
            zenithCol      = float3(0.038, 0.095, 0.195);
            midSkyCol      = float3(0.115, 0.242, 0.420);
            horizonCol     = float3(0.320, 0.475, 0.655);
            groundMistCol  = float3(0.038, 0.068, 0.122);
            sunGlowCol     = float3(0.82,  0.90,  1.00);
            cloudShadowCol = float3(0.072, 0.132, 0.232);
            cloudLitCol    = float3(0.82,  0.89,  0.98);
            cirrusCol      = float3(0.80,  0.88,  0.98);
            glowCenter     = float2(0.34,  0.10);
            rayOrigin      = float2(0.34, -0.26);
            covLow         = 0.53;
            covHigh        = 0.84;
            rayStrength    = 0.085;
        } else if (U.mode == 1) {
            zenithCol      = float3(0.028, 0.065, 0.152);
            midSkyCol      = float3(0.082, 0.175, 0.330);
            horizonCol     = float3(0.285, 0.355, 0.495);
            groundMistCol  = float3(0.032, 0.050, 0.096);
            sunGlowCol     = float3(0.98,  0.58,  0.36);
            cloudShadowCol = float3(0.056, 0.096, 0.178);
            cloudLitCol    = float3(0.68,  0.74,  0.86);
            cirrusCol      = float3(0.90,  0.72,  0.66);
            glowCenter     = float2(0.66,  0.08);
            rayOrigin      = float2(0.66, -0.26);
            covLow         = 0.52;
            covHigh        = 0.83;
            rayStrength    = 0.105;
        } else {
            zenithCol      = float3(0.012, 0.025, 0.062);
            midSkyCol      = float3(0.032, 0.072, 0.155);
            horizonCol     = float3(0.088, 0.162, 0.285);
            groundMistCol  = float3(0.014, 0.024, 0.048);
            sunGlowCol     = float3(0.56,  0.74,  1.00);
            cloudShadowCol = float3(0.016, 0.030, 0.066);
            cloudLitCol    = float3(0.40,  0.54,  0.76);
            cirrusCol      = float3(0.36,  0.48,  0.70);
            glowCenter     = float2(0.72,  0.70);
            rayOrigin      = float2(0.72, -0.40);
            covLow         = 0.54;
            covHigh        = 0.85;
            rayStrength    = 0.0;
        }

        float horizonY = 0.10;
        float elev = max(uv.y - horizonY, 0.0);
        float upperMix = pow(clamp(elev / (1.0 - horizonY), 0.0, 1.0), 0.66);
        float3 sky = mix(midSkyCol, zenithCol, upperMix);
        float airMass = exp(-elev * 5.4);
        sky = mix(sky, horizonCol, airMass * 0.84);

        float2 toGlow = float2((uv.x - glowCenter.x) * aspect, uv.y - glowCenter.y);
        float glowDist = length(toGlow);
        float aureoleBroad = exp(-glowDist * 2.0);
        float aureoleCore  = exp(-glowDist * 5.8);
        sky += sunGlowCol * (aureoleBroad * 0.25 + aureoleCore * 0.16) * smoothstep(-0.05, 0.26, uv.y);
        if (U.mode == 1) {
            float duskBand = exp(-pow((uv.y - 0.24) * 4.5, 2.0)) * exp(-abs(uv.x - glowCenter.x) * 1.3);
            sky += float3(0.28, 0.11, 0.24) * duskBand * 0.34;
        }

        if (U.mode == 2) {
            float starVis = smoothstep(0.12, 0.52, uv.y);
            float3 s1 = starField(fragPx, 36.0, 0.942);
            float3 s2 = starField(fragPx + 413.0, 66.0, 0.910);
            float twinkle = 0.86 + 0.14 * sin(t * 1.6 + fragPx.x * 0.13 + fragPx.y * 0.09);
            sky += (s1 * 0.78 + s2 * 1.20) * starVis * twinkle;
        }

        float cirRaw = cirrusField(uv, aspect, t);
        float cirMask = smoothstep(0.54, 0.85, cirRaw) * smoothstep(0.20, 0.62, uv.y);
        float3 cirLight = mix(cirrusCol * 0.68, sunGlowCol * 0.82 + cirrusCol * 0.35, aureoleBroad);
        sky = mix(sky, sky + cirLight * 0.32, cirMask * 0.75);

        float domeY = abs(uv.y - horizonY) + 0.18;
        float zDepth = 1.0 / domeY;
        float2 cloudP = float2((uv.x - 0.5) * aspect * zDepth * 0.56, zDepth * 0.50);
        float2 q = cloudP + float2(t * 0.016, t * 0.005);
        float2 warped = cloudWarp(q);

        float d = cloudDensityFine(warped);
        float2 sunDir2D = normalize(glowCenter - uv + float2(0.0001));
        float dSun = cloudDensitySoft(warped + sunDir2D * 0.095);

        float horizonFade = smoothstep(0.05, 0.28, uv.y) * (1.0 - smoothstep(0.84, 1.02, uv.y) * 0.35);
        float thick = smoothstep(covLow, covHigh, d) * horizonFade;

        float opticalDepth = max(dSun - covLow, 0.0) * 5.4;
        float transmittance = exp(-opticalDepth);
        float thinEdge = thick * (1.0 - thick * 0.80) * 3.3;
        float forwardGlare = pow(clamp(aureoleBroad * 1.18, 0.0, 1.0), 1.25);

        float3 bodyCol = mix(cloudShadowCol, cloudLitCol, transmittance * 0.82);
        bodyCol += (sunGlowCol * 0.78 + cloudLitCol * 0.38) * thinEdge * (0.20 + 0.90 * forwardGlare) * (0.35 + 0.65 * transmittance);

        sky = mix(sky, bodyCol, thick * 0.90);

        if (rayStrength > 0.001) {
            float2 rayVec = float2((uv.x - rayOrigin.x) * aspect, uv.y - rayOrigin.y);
            float2 rayDir = normalize(rayVec);
            float rayDist = length(rayVec);
            float shafts = vnoise(rayDir * 14.0 + float2(t * 0.025, 0.0)) * 0.65
                         + vnoise(rayDir * 29.0 - float2(t * 0.018, 0.0)) * 0.35;
            float rays = smoothstep(0.47, 0.82, shafts)
                       * exp(-max(rayDist - 0.26, 0.0) * 1.75)
                       * (1.0 - thick * 0.82)
                       * smoothstep(0.06, 0.28, uv.y);
            sky += sunGlowCol * rays * rayStrength;
        }

        float bottomCalm = 1.0 - smoothstep(0.0, 0.20, uv.y);
        sky = mix(sky, groundMistCol, bottomCalm * 0.80);

        float2 vigUV = (in.uv - float2(0.5, 0.53)) * float2(1.0, 1.08);
        float vig = 1.0 - smoothstep(0.34, 0.94, length(vigUV)) * 0.46;
        sky *= vig;

        sky = 1.0 - exp(-sky * 1.06);

        float g1 = hash21(fragPx);
        float g2 = hash21(fragPx * 1.7 + 53.1);
        float grain = (g1 + g2 - 1.0) * 0.010;
        sky = max(sky + grain, 0.0);

        return half4(half3(sky), 1.0h);
    }
    """#
}

// MARK: - Smoked Frosted Glass Art

nonisolated enum WindowFlowBackdropArt {
    static let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB) as Any])

    static func bitmap(_ size: CGSize) -> CGContext? {
        CGContext(
            data: nil, width: max(1, Int(size.width)), height: max(1, Int(size.height)),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }

    static func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: r, green: g, blue: b, alpha: a)
    }

    /// Smoked, vibrant frosted glass over the desktop with fine high-resolution frost grain.
    static func glass(size: CGSize, blurred: CGImage) -> CGImage? {
        let extent = CGRect(origin: .zero, size: size)
        var behind = CIImage(cgImage: blurred)
            .transformed(by: CGAffineTransform(
                scaleX: size.width / CGFloat(max(blurred.width, 1)),
                y: size.height / CGFloat(max(blurred.height, 1))
            ))
            .applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 1.42,
                kCIInputContrastKey: 0.94
            ])
            .applyingFilter("CIGammaAdjust", parameters: ["inputPower": 1.45])
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0.17, y: 0.015, z: 0.015, w: 0),
                "inputGVector": CIVector(x: 0.015, y: 0.17, z: 0.02, w: 0),
                "inputBVector": CIVector(x: 0.015, y: 0.025, z: 0.20, w: 0),
                "inputBiasVector": CIVector(x: 0.056, y: 0.062, z: 0.080, w: 0),
            ])
            .cropped(to: extent)

        if let noise = CIFilter(name: "CIRandomGenerator")?.outputImage {
            let monochromeNoise = noise
                .applyingFilter("CIColorControls", parameters: [
                    kCIInputSaturationKey: 0,
                    kCIInputBrightnessKey: -0.5,
                    kCIInputContrastKey: 0.045
                ])
                .cropped(to: extent)
            behind = monochromeNoise
                .applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: behind])
                .applyingFilter("CIColorClamp", parameters: [:])
                .cropped(to: extent)
        }
        return context.createCGImage(behind, from: extent)
    }

    static func glassSurface(size: CGSize) -> CGImage? {
        guard let drawing = bitmap(size), let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let w = size.width, h = size.height
        let topSheen = [
            color(0.88, 0.93, 1.0, 0.09),
            color(0.85, 0.90, 1.0, 0.025),
            color(0.85, 0.90, 1.0, 0.0)
        ]
        if let gradient = CGGradient(colorsSpace: space, colors: topSheen as CFArray, locations: [0, 0.40, 1]) {
            drawing.drawLinearGradient(
                gradient,
                start: CGPoint(x: w * 0.5, y: h),
                end: CGPoint(x: w * 0.5, y: h * 0.18),
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            )
        }
        return drawing.makeImage()
    }
}
