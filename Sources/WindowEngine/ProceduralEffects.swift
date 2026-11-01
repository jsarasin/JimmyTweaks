import AppKit
import MetalKit
import simd

/// Motion is measured from accepted window geometry, never the pointer's requested frame.
struct EffectMotion {
    private var point: SIMD2<Float>?
    private var sampleTime: TimeInterval = 0
    private(set) var velocity = SIMD2<Float>.zero
    private(set) var acceleration = SIMD2<Float>.zero

    mutating func sample(_ position: CGPoint, at time: TimeInterval) {
        let next = SIMD2<Float>(Float(position.x), Float(position.y))
        defer { point = next; sampleTime = time }
        guard let point, time > sampleTime else { return }
        let dt = Float(time - sampleTime)
        guard dt < 0.25, simd_length(next - point) < 600 else {
            velocity = .zero; acceleration = .zero; return
        }
        let old = velocity
        let response = 1 - exp(-dt * 18)
        velocity += (Self.limited((next - point) / max(dt, 0.004), to: 2200) - velocity) * response
        acceleration += (Self.limited((velocity - old) / max(dt, 0.004), to: 8000) - acceleration) * response
    }
    mutating func settle(at time: TimeInterval, dt: Float) {
        if time - sampleTime > 0.045 {
            velocity *= exp(-dt * 12); acceleration *= exp(-dt * 18)
        }
    }
    private static func limited(_ value: SIMD2<Float>, to limit: Float) -> SIMD2<Float> {
        value * min(1, limit / max(simd_length(value), 0.001))
    }
}

private struct EffectUniforms {
    var rect: SIMD4<Float>
    var previousRect: SIMD4<Float>
    var source: SIMD4<Float> // source world position, directions of the two inward arms
    var previousSource: SIMD4<Float>
    var motion: SIMD4<Float>
    var style: SIMD4<Float> // mode in w (0 supernatural corner, 1 mist)
    var clock: SIMD4<Float> // timestep, elapsed time, reset flag, acceleration energy
    var drawRect: SIMD4<Float>
    var smoke: SIMD4<Float> // progress, enabled, cursor radius, cursor enabled
    var cursor: SIMD4<Float> // swept cursor start XY, end XY in AppKit desktop points
}

struct SmokeCursorStroke {
    let start: CGPoint
    let end: CGPoint
    var radius: Float = 36
}

/// A stationary desktop heat field feeds full-display surfaces. Mist retains its window-edge mask.
final class ProceduralEffects {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let updatePipeline: MTLComputePipelineState
    private let renderPipeline: MTLRenderPipelineState
    private var textures: [MTLTexture] = []
    private var output = 0
    private var uniforms: EffectUniforms?
    private var previousRect = CGRect.zero
    private var previousSource: SIMD4<Float>?
    private var reset = true
    private let inFlight = DispatchSemaphore(value: 2)
    private var currentCommand: MTLCommandBuffer?
    private var currentUnderlays: [ProceduralEffects] = []
    private var previousTime: TimeInterval?
    private var elapsed: Float = 0
    private(set) var frameCount = 0
    private(set) var presentedFrames = 0
    private(set) var failed = false
    private(set) var gpuSeconds: Double = 0
    private(set) var completedFrames = 0

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        do {
            let library = try device.makeLibrary(source: Self.shader, options: nil)
            guard let update = library.makeFunction(name: "advanceHeat"),
                  let vertex = library.makeFunction(name: "effectVertex"), let fragment = library.makeFunction(name: "effectFragment") else { return nil }
            updatePipeline = try device.makeComputePipelineState(function: update)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertex; descriptor.fragmentFunction = fragment
            let attachment = descriptor.colorAttachments[0]!
            attachment.pixelFormat = .bgra8Unorm
            attachment.isBlendingEnabled = true
            attachment.sourceRGBBlendFactor = .one; attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
            attachment.sourceAlphaBlendFactor = .one; attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            renderPipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch { NSLog("Jimmy Tweaks: procedural effects unavailable: %@", String(describing: error)); return nil }
        self.device = device; self.queue = queue
    }

    /// A transition keeps its own heat textures, sharing already compiled GPU resources.
    private init(sharing other: ProceduralEffects) {
        device = other.device; queue = other.queue
        updatePipeline = other.updatePipeline; renderPipeline = other.renderPipeline
    }
    func makeSibling() -> ProceduralEffects { ProceduralEffects(sharing: self) }

    func restart() { reset = true; previousTime = nil; previousSource = nil; elapsed = 0 }

    /// Returns false when resources cannot be allocated; caller uses the static fallback.
    func configure(rect: CGRect, source: CGPoint, arms: SIMD2<Float>, mist: Bool, motion: EffectMotion, smoke: Float? = nil, cursor: SmokeCursorStroke? = nil) -> Bool {
        let longest = max(rect.width, rect.height)
        // Fire retains heat throughout the desktop, at roughly one cell per three points.
        // Cap extreme multi-display arrangements while preserving a stationary world-space domain.
        let cellSize = max(3, longest / 4096)
        let width = mist ? max(64, Int(256 * rect.width / longest)) : max(1, Int(ceil(rect.width / cellSize)))
        let height = mist ? max(64, Int(256 * rect.height / longest)) : max(1, Int(ceil(rect.height / cellSize)))
        if textures.first?.width != width || textures.first?.height != height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r16Float, width: width, height: height, mipmapped: false)
            descriptor.usage = [.shaderRead, .shaderWrite]; descriptor.storageMode = .private
            textures = (0..<2).compactMap { _ in device.makeTexture(descriptor: descriptor) }
            guard textures.count == 2 else { textures = []; return false }
            output = 0; reset = true
        }
        let next = Self.vector(rect)
        uniforms = EffectUniforms(rect: next, previousRect: Self.vector(previousRect),
            source: SIMD4(Float(source.x), Float(source.y), arms.x, arms.y),
            previousSource: previousSource ?? SIMD4(Float(source.x), Float(source.y), arms.x, arms.y),
            motion: SIMD4(motion.velocity.x, motion.velocity.y, motion.acceleration.x, motion.acceleration.y),
            style: SIMD4(0, 0, 0, mist ? 1 : 0),
            clock: SIMD4(1 / 60, elapsed, reset ? 1 : 0, min(0.4, simd_length(motion.acceleration) / 20000)), drawRect: next,
            smoke: SIMD4(smoke ?? 0, smoke == nil ? 0 : 1, cursor?.radius ?? 0, smoke != nil && cursor != nil ? 1 : 0),
            cursor: SIMD4(Float(cursor?.start.x ?? 0), Float(cursor?.start.y ?? 0), Float(cursor?.end.x ?? 0), Float(cursor?.end.y ?? 0)))
        return true
    }

    func render(surfaces: [EffectSurface], at time: TimeInterval, underlays: [ProceduralEffects] = []) -> Bool {
        guard !failed, var params = uniforms, textures.count == 2 else { return false }
        guard inFlight.wait(timeout: .now()) == .success else { return true }
        guard let command = queue.makeCommandBuffer() else {
            inFlight.signal(); return false
        }
        let dt = Float(min(1 / 30.0, max(1 / 240.0, time - (previousTime ?? time - 1 / 60))))
        previousTime = time; elapsed += dt
        let startSource = reset ? params.source : (previousSource ?? params.source)
        // Analytically sweep the emitter in one compute pass. A fast drag must not
        // multiply the cost of updating the entire stationary desktop heat field.
        params.previousSource = startSource
        params.previousRect = reset ? params.rect : Self.vector(previousRect)
        params.clock.x = dt; params.clock.y = elapsed; params.clock.z = reset ? 1 : 0
        guard let encoder = command.makeComputeCommandEncoder() else { inFlight.signal(); return false }
        encoder.setComputePipelineState(updatePipeline)
        encoder.setTexture(textures[output], index: 0); encoder.setTexture(textures[1 - output], index: 1)
        encoder.setBytes(&params, length: MemoryLayout<EffectUniforms>.stride, index: 0)
        let groupWidth = updatePipeline.threadExecutionWidth
        encoder.dispatchThreads(MTLSize(width: textures[0].width, height: textures[0].height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: groupWidth, height: max(1, updatePipeline.maxTotalThreadsPerThreadgroup / groupWidth), depth: 1))
        encoder.endEncoding(); output = 1 - output
        uniforms = params; previousSource = params.source
        previousRect = CGRect(x: CGFloat(params.rect.x), y: CGFloat(params.rect.y), width: CGFloat(params.rect.z), height: CGFloat(params.rect.w)); reset = false
        // MTKView.draw() acquires/releases each drawable normally. All fragments are encoded
        // after the one compute pass, into the same command buffer, at the same simulation time.
        currentCommand = command; currentUnderlays = underlays
        for surface in surfaces { surface.draw() }
        currentCommand = nil; currentUnderlays = []
        let semaphore = inFlight
        command.addCompletedHandler { [weak self] completed in
            semaphore.signal()
            let duration = max(0, completed.gpuEndTime - completed.gpuStartTime)
            let failed = completed.status == .error
            DispatchQueue.main.async { [weak self] in
                if failed { self?.failed = true }
                self?.gpuSeconds += duration; self?.completedFrames += 1
            }
        }
        command.commit(); frameCount += 1
        return true
    }

    fileprivate func encode(_ surface: EffectSurface) {
        guard let command = currentCommand, let pass = surface.currentRenderPassDescriptor,
              let drawable = surface.currentDrawable else { return }
        pass.colorAttachments[0].storeAction = .store
        for underlay in currentUnderlays {
            underlay.encodeDraw(command: command, pass: pass, rect: surface.worldRect)
            pass.colorAttachments[0].loadAction = .load
        }
        encodeDraw(command: command, pass: pass, rect: surface.worldRect)
        command.present(drawable)
        presentedFrames += 1
    }
    private func encodeDraw(command: MTLCommandBuffer, pass: MTLRenderPassDescriptor, rect: CGRect) {
        guard var params = uniforms, let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return }
        params.drawRect = Self.vector(rect)
        encoder.setRenderPipelineState(renderPipeline)
        encoder.setFragmentTexture(textures[output], index: 0)
        encoder.setFragmentBytes(&params, length: MemoryLayout<EffectUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3); encoder.endEncoding()
    }
    private static func vector(_ rect: CGRect) -> SIMD4<Float> { SIMD4(Float(rect.minX), Float(rect.minY), Float(rect.width), Float(rect.height)) }

    #if TESTING
    func waitForGPUForTesting() {
        let fence = queue.makeCommandBuffer()!; fence.commit(); fence.waitUntilCompleted()
    }
    func snapshot(rect: CGRect, width: Int, height: Int, underlays: [ProceduralEffects] = []) -> [UInt8]? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared; descriptor.usage = [.renderTarget]
        guard let texture = device.makeTexture(descriptor: descriptor), let command = queue.makeCommandBuffer() else { return nil }
        let pass = MTLRenderPassDescriptor(); pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        for underlay in underlays {
            underlay.encodeDraw(command: command, pass: pass, rect: rect)
            pass.colorAttachments[0].loadAction = .load
        }
        encodeDraw(command: command, pass: pass, rect: rect)
        command.commit(); command.waitUntilCompleted()
        guard command.status == .completed else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { texture.getBytes($0.baseAddress!, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0) }
        return pixels
    }
    #endif

    private static let shader = #"""
    #include <metal_stdlib>
    using namespace metal;
    struct Params { float4 rect, previousRect, source, previousSource, motion, style, clock, drawRect, smoke, cursor; };
    constant float fireArm = 96.0;
    // The colour change occupies 1/4 of the full transition: 1/3 s, followed by a 1 s fade.
    constant float smokeMorphEnd = 0.25;
    constexpr sampler linearSampler(coord::normalized, address::clamp_to_zero, filter::linear);
    float hash21(float2 p) { return fract(sin(dot(p, float2(127.1,311.7))) * 43758.5453); }
    float noise(float2 p) {
        float2 i=floor(p), f=fract(p); f=f*f*(3.0-2.0*f);
        return mix(mix(hash21(i),hash21(i+float2(1,0)),f.x),mix(hash21(i+float2(0,1)),hash21(i+1),f.x),f.y);
    }
    float turbulence(float2 p) { return noise(p)*0.57 + noise(p*2.07+13.2)*0.28 + noise(p*4.13-7.1)*0.15; }
    float segment(float2 p, float2 a, float2 b) { float2 v=b-a; return length(p-a-v*clamp(dot(p-a,v)/dot(v,v),0.0,1.0)); }
    float cross2(float2 a, float2 b) { return a.x*b.y-a.y*b.x; }
    float sweptArm(float2 world, float2 start, float2 end, float2 arm) {
        float2 movement=end-start, local=world-start;
        float determinant=cross2(movement,arm);
        if (abs(determinant)>0.001) {
            float u=cross2(local,arm)/determinant, v=cross2(movement,local)/determinant;
            if (u>=0 && u<=1 && v>=0 && v<=1) return 0;
        }
        float d=min(segment(world,start,start+arm),segment(world,end,end+arm));
        if (dot(movement,movement)>0.001) {
            d=min(d,min(segment(world,start,end),segment(world,start+arm,end+arm)));
        }
        return d;
    }
    float heat(texture2d<half> field, float2 world, constant Params &p) {
        if (p.clock.z > 0.5) return 0;
        float2 uv=(world-p.previousRect.xy)/p.previousRect.zw;
        if (any(uv<0.0) || any(uv>1.0)) return 0;
        return float(field.sample(linearSampler,uv).r);
    }
    kernel void advanceHeat(texture2d<half> previous [[texture(0)]], texture2d<half,access::write> next [[texture(1)]],
                            constant Params &p [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
        float2 resolution=float2(next.get_width(),next.get_height());
        if (any(gid>=uint2(resolution))) return;
        float2 uv=(float2(gid)+0.5)/resolution, world=p.rect.xy+uv*p.rect.zw;
        float dt=p.clock.x, t=p.clock.y; bool mist=p.style.w>0.5;
        float2 local=world-p.source.xy;
        float2 cell=p.rect.zw/resolution;
        if (p.smoke.y>0.5) {
            // The old field puffs outward and rises; it stops emitting immediately.
            float2 outward=local/max(length(local),1.0);
            float2 drift=outward*65.0+float2(sin(world.y*0.035+t*5.0)*30.0,75.0+cos(world.x*0.025+t)*18.0);
            float2 origin=world-drift*dt;
            float centre=heat(previous,origin,p);
            float blurred=(heat(previous,origin+float2(cell.x*2,0),p)+heat(previous,origin-float2(cell.x*2,0),p)
                          +heat(previous,origin+float2(0,cell.y*2),p)+heat(previous,origin-float2(0,cell.y*2),p))*0.25;
            float h=mix(centre,blurred,1.0-exp(-dt*12.0))*exp(-dt*0.85);
            if (p.smoke.w>0.5) {
                // Clear the entire cursor stroke between frames, with a feathered edge.
                // Erasing density here keeps the wake thin on subsequent frames too.
                float2 movement=p.cursor.zw-p.cursor.xy;
                float along=clamp(dot(world-p.cursor.xy,movement)/max(dot(movement,movement),0.0001),0.0,1.0);
                float distance=length(world-(p.cursor.xy+movement*along));
                float brush=1.0-smoothstep(p.smoke.z*0.25,p.smoke.z,distance);
                h*=1.0-0.94*brush;
            }
            next.write(half4(half(h),0,0,1),gid); return;
        }
        float2 q=mist ? (uv-0.5)*4.0 : local*0.035;
        float n=turbulence(q+float2(t*0.7,-t*0.95));
        float2 curl=float2(turbulence(q+float2(0.13,0)+t*0.24)-turbulence(q-float2(0.13,0)+t*0.24),
                          turbulence(q+float2(0,0.13)-t*0.3)-turbulence(q-float2(0,0.13)-t*0.3));
        float2 flow;
        float source;
        if (mist) {
            float scale=min(p.rect.z,p.rect.w);
            flow=float2(-curl.y,curl.x)*scale*1.6 + float2(-q.y,q.x)*scale*0.028;
            float cloud=exp(-dot(q,q)*0.95)*(0.4+n*0.9);
            source=cloud*(dt*(9.0+p.clock.w*4.0)+(p.clock.z>0.5?0.45:0.0));
        } else {
            float horizontal=segment(local,float2(0),float2(p.source.z*fireArm,0));
            float vertical=segment(local,float2(0),float2(0,p.source.w*fireArm));
            float2 outward = horizontal < vertical ? float2(0,-p.source.w) : float2(-p.source.z,0);
            // Sideways folds and opposing curls read as an unfamiliar energy field.
            flow=outward*(35.0+n*45.0)+float2(-curl.y,curl.x)*430.0
                +float2(sin(local.y*0.013+t*0.8),cos(local.x*0.015-t*0.6))*38.0;
            float swept=min(sweptArm(world,p.previousSource.xy,p.source.xy,float2(p.source.z*fireArm,0)),
                            sweptArm(world,p.previousSource.xy,p.source.xy,float2(0,p.source.w*fireArm)));
            source=exp(-swept*swept*0.10)*(0.65+n*0.65+p.clock.w);
        }
        // World-space reprojection keeps old heat behind when its moving source accelerates.
        float2 inertia=-p.motion.xy*0.12-p.motion.zw*0.007;
        inertia*=min(1.0,(mist?300.0:160.0)/max(length(inertia),0.001));
        float2 origin=world-(flow+inertia)*dt;
        float centre=heat(previous,origin,p);
        float neighbours=(heat(previous,origin+float2(cell.x,0),p)+heat(previous,origin-float2(cell.x,0),p)
                         +heat(previous,origin+float2(0,cell.y),p)+heat(previous,origin-float2(0,cell.y),p))*0.25;
        // Diffusion follows elapsed time, independently of frame rate.
        float diffusion=1.0-exp(-dt*(mist?13.4:9.0));
        float h=mix(centre,neighbours,diffusion)*exp(-dt*(mist?0.9:2.0+n*1.8));
        h=mist ? min(1.6,h+source) : max(h,source);
        float edge=min(min(uv.x,1.0-uv.x),min(uv.y,1.0-uv.y));
        if (mist) h*=smoothstep(0.0,0.065,edge);
        next.write(half4(half(h),0,0,1),gid);
    }
    struct Vertex { float4 position [[position]]; float2 uv; };
    vertex Vertex effectVertex(uint id [[vertex_id]]) {
        float2 pos=float2(id==1?3.0:-1.0,id==2?3.0:-1.0);
        return {float4(pos,0,1),(pos+1.0)*0.5};
    }
    fragment float4 effectFragment(Vertex in [[stage_in]], texture2d<half> field [[texture(0)]], constant Params &p [[buffer(0)]]) {
        float2 world=p.drawRect.xy+in.uv*p.drawRect.zw;
        float2 uv=(world-p.rect.xy)/p.rect.zw;
        if (any(uv<0.0)||any(uv>1.0)) return float4(0);
        float h=float(field.sample(linearSampler,uv).r);
        // Most full-screen pixels contain no heat. Avoid bloom/noise work there,
        // without clipping any live trail to a rectangle around the current corner.
        float2 local=world-p.source.xy;
        float2 armEnd=p.source.zw*fireArm;
        bool outsideCore=any(local<min(float2(0),armEnd)-4.0)||any(local>max(float2(0),armEnd)+4.0);
        if (h<0.001 && (p.style.w>0.5 || outsideCore || p.smoke.y>0.5)) return float4(0);
        float2 texel=1.0/float2(field.get_width(),field.get_height());
        float alpha; float3 rgb;
        if (p.style.w>0.5) {
            float2 q=(uv-0.5)*2;
            float edge=min(min(uv.x,1-uv.x),min(uv.y,1-uv.y));
            float mask=smoothstep(0.0,0.18,edge)*(1.0-smoothstep(0.30,1.15,length(q)));
            float detail=0.7+0.3*turbulence(q*6+float2(p.clock.y*0.42,-p.clock.y*0.36));
            alpha=min(0.65,h*0.9*detail)*mask;
            rgb=mix(float3(0.08,0.38,0.95),float3(0.52,0.81,1.0),clamp(h,0.0,1.0));
        } else {
            float bloom=0;
            for (int i=0;i<8;i++) {
                float a=float(i)*0.785398;
                float2 direction=float2(cos(a),sin(a));
                bloom+=float(field.sample(linearSampler,uv+direction*texel*3.0).r)*0.075;
                bloom+=float(field.sample(linearSampler,uv+direction*texel*8.0).r)*0.05;
            }
            float2 local=world-p.source.xy;
            float d=min(segment(local,float2(0),float2(p.source.z*fireArm,0)),segment(local,float2(0),float2(0,p.source.w*fireArm)));
            float core=exp(-d*d*0.45)*(p.smoke.y>0.5?1.0-smoothstep(0.0,smokeMorphEnd,p.smoke.x):1.0);
            float2 warp=float2(sin(local.y*0.025+p.clock.y*0.7),cos(local.x*0.021-p.clock.y*0.6))*12.0;
            float vapor=turbulence((local+warp)*0.03+float2(p.clock.y*0.25,-p.clock.y*0.35));
            float interference=0.5+0.5*sin(local.x*0.11+local.y*0.07+vapor*8.0-p.clock.y*2.5);
            float filament=pow(interference,8.0);
            float2 gradient=float2(float(field.sample(linearSampler,uv+float2(texel.x,0)).r)-float(field.sample(linearSampler,uv-float2(texel.x,0)).r),
                                   float(field.sample(linearSampler,uv+float2(0,texel.y)).r)-float(field.sample(linearSampler,uv-float2(0,texel.y)).r));
            float ridge=smoothstep(0.04,0.35,length(gradient));
            float veil=smoothstep(0.015,0.8,h)*(0.22+0.30*vapor);
            alpha=clamp(veil*(0.4+0.6*filament)+bloom*0.18+ridge*0.18+core*0.96,0.0,0.98);
            float iridescence=0.5+0.5*sin(p.clock.y*0.8+local.x*0.013-local.y*0.019+vapor*4.0+h*5.0);
            float3 violet=float3(0.29,0.23,0.46), cyan=float3(0.38,0.73,0.70), pearl=float3(0.90,0.94,1.0);
            float3 palette=mix(violet,cyan,iridescence);
            rgb=mix(palette,pearl,clamp(core*0.95+filament*0.45+ridge*0.6,0.0,1.0));
        }
        if (p.smoke.y>0.5) {
            float cloud=turbulence(world*0.035+float2(p.clock.y*0.9,-p.clock.y*0.8));
            float change=smoothstep(0.0,smokeMorphEnd,p.smoke.x);
            float puff=smoothstep(0.015,0.8,h)*(0.25+0.35*cloud);
            alpha=mix(alpha,max(alpha*0.7,puff),change)*(1.0-smoothstep(smokeMorphEnd,1.0,p.smoke.x));
            rgb=mix(rgb,float3(0.52+0.22*cloud),change);
        }
        return float4(rgb*alpha,alpha); // Premultiplied alpha for the transparent compositor.
    }
    """#
}

/// Paused MTKViews are advanced only by the shared effect clock, including across displays.
final class EffectSurface: MTKView, MTKViewDelegate {
    weak var renderer: ProceduralEffects?
    var worldRect = CGRect.zero
    init(renderer: ProceduralEffects) {
        self.renderer = renderer
        super.init(frame: .zero, device: renderer.device)
        colorPixelFormat = .bgra8Unorm; framebufferOnly = true
        clearColor = MTLClearColorMake(0, 0, 0, 0)
        isPaused = true; enableSetNeedsDisplay = false; autoResizeDrawable = false
        wantsLayer = true; layer?.isOpaque = false
        delegate = self
    }
    required init(coder: NSCoder) { fatalError("Programmatic interface") }
    override var isOpaque: Bool { false }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
    func draw(in view: MTKView) { renderer?.encode(self) }
}
