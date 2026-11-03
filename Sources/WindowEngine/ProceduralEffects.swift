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
    var style: SIMD4<Float> // preset in x; geometry mode in w (0 corner, 1 window interior)
    var clock: SIMD4<Float> // timestep, elapsed time, reset flag, acceleration energy
    var drawRect: SIMD4<Float>
    var smoke: SIMD4<Float> // progress, enabled, cursor radius, cursor enabled
    var cursor: SIMD4<Float> // swept cursor start XY, end XY in AppKit desktop points
    var windowRect: SIMD4<Float> // accepted window, independent of exterior simulation bounds
    var lifecycle: SIMD4<Float> // departure time and reserved components
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
    private let spritePipeline: MTLRenderPipelineState
    private var wind = WindField()
    private var electricity = ElectricalField()
    private var crystal = CrystalFrostField()
    private var spriteBuffer: MTLBuffer?
    private var spriteCount = 0
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
    private var departureTime: Float?
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
            descriptor.vertexFunction = library.makeFunction(name: "spriteVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "spriteFragment")
            spritePipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch { NSLog("Jimmy Tweaks: procedural effects unavailable: %@", String(describing: error)); return nil }
        self.device = device; self.queue = queue
    }

    /// A transition keeps its own heat textures, sharing already compiled GPU resources.
    private init(sharing other: ProceduralEffects) {
        device = other.device; queue = other.queue
        updatePipeline = other.updatePipeline; renderPipeline = other.renderPipeline; spritePipeline = other.spritePipeline
    }
    func makeSibling() -> ProceduralEffects { ProceduralEffects(sharing: self) }

    /// A neutral puff seeded from an opaque object instead of an existing heat
    /// trail. It shares the usual smoke advection, diffusion, and finite fade.
    func configureSmokePuff(rect: CGRect, object: CGRect, progress: Float, strength: Float = 1) -> Bool {
        guard configure(rect: rect, source: CGPoint(x: object.midX, y: object.midY), arms: .zero, mist: true,
                        motion: EffectMotion(), smoke: progress, effect: .blueMist, windowRect: object) else { return false }
        uniforms?.lifecycle.y = 1
        uniforms?.lifecycle.z = max(0, min(1, strength))
        return true
    }

    func restart() {
        reset = true; previousTime = nil; previousSource = nil; elapsed = 0; departureTime = nil
        wind = WindField(); electricity = ElectricalField(); crystal = CrystalFrostField()
        spriteBuffer = nil; spriteCount = 0
    }

    /// Returns false when resources cannot be allocated; caller uses the static fallback.
    func configure(rect: CGRect, source: CGPoint, arms: SIMD2<Float>, mist: Bool, motion: EffectMotion, smoke: Float? = nil, cursor: SmokeCursorStroke? = nil, effect: WindowEffect? = nil, windowRect: CGRect? = nil) -> Bool {
        let longest = max(rect.width, rect.height)
        // Fire retains heat throughout the desktop, at roughly one cell per three points.
        // Cap extreme multi-display arrangements while preserving a stationary world-space domain.
        let cellSize = max(3, longest / 4096)
        let selectedEffect = effect ?? (mist ? .blueMist : .iridescentEnergy)
        let sprites = selectedEffect == .cartoonWind || selectedEffect == .furiousLightning || selectedEffect == .crystalFrost
        let width = sprites ? 1 : mist ? max(64, Int(256 * rect.width / longest)) : max(1, Int(ceil(rect.width / cellSize)))
        let height = sprites ? 1 : mist ? max(64, Int(256 * rect.height / longest)) : max(1, Int(ceil(rect.height / cellSize)))
        if textures.first?.width != width || textures.first?.height != height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r16Float, width: width, height: height, mipmapped: false)
            descriptor.usage = [.shaderRead, .shaderWrite]; descriptor.storageMode = .private
            textures = (0..<2).compactMap { _ in device.makeTexture(descriptor: descriptor) }
            guard textures.count == 2 else { textures = []; return false }
            output = 0; reset = true
        }
        let next = Self.vector(rect)
        if smoke != nil { if departureTime == nil { departureTime = elapsed } } else { departureTime = nil }
        uniforms = EffectUniforms(rect: next, previousRect: Self.vector(previousRect),
            source: SIMD4(Float(source.x), Float(source.y), arms.x, arms.y),
            previousSource: previousSource ?? SIMD4(Float(source.x), Float(source.y), arms.x, arms.y),
            motion: SIMD4(motion.velocity.x, motion.velocity.y, motion.acceleration.x, motion.acceleration.y),
            style: SIMD4((effect ?? (mist ? .blueMist : .iridescentEnergy)).shaderStyle, 0, 0, mist ? 1 : 0),
            clock: SIMD4(1 / 60, elapsed, reset ? 1 : 0, min(0.4, simd_length(motion.acceleration) / 20000)), drawRect: next,
            smoke: SIMD4(smoke ?? 0, smoke == nil ? 0 : 1, cursor?.radius ?? 0, smoke != nil && cursor != nil ? 1 : 0),
            cursor: SIMD4(Float(cursor?.start.x ?? 0), Float(cursor?.start.y ?? 0), Float(cursor?.end.x ?? 0), Float(cursor?.end.y ?? 0)),
            windowRect: Self.vector(windowRect ?? rect),
            lifecycle: SIMD4(departureTime ?? elapsed, 0, 0, 0))
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
        let isWind = params.style.x > 5.5 && params.style.x < 6.5
        let isLightning = params.style.x > 0.5 && params.style.x < 1.5
        let isFrost = params.style.x > 7.5 && params.style.x < 8.5
        if isWind || isLightning || isFrost {
            let window = CGRect(x: CGFloat(params.windowRect.x), y: CGFloat(params.windowRect.y), width: CGFloat(params.windowRect.z), height: CGFloat(params.windowRect.w))
            let velocity = SIMD2(params.motion.x, params.motion.y)
            let departure: Float? = params.smoke.y > 0.5 ? params.smoke.x : nil
            let sprites: [EffectSprite]
            if isWind {
                wind.advance(dt: dt, window: window, velocity: velocity, emitting: departure == nil)
                sprites = wind.sprites(departure: departure)
            } else if isLightning {
                electricity.advance(dt: dt, window: window, corner: SIMD2(params.source.x, params.source.y),
                    arms: SIMD2(params.source.z, params.source.w), speed: simd_length(velocity), emitting: departure == nil)
                sprites = electricity.sprites(departure: departure)
            } else {
                crystal.advance(dt: dt, corner: SIMD2(params.source.x, params.source.y),
                    arms: SIMD2(params.source.z, params.source.w), emitting: departure == nil)
                sprites = crystal.sprites(departure: departure)
            }
            spriteCount = sprites.count
            spriteBuffer = sprites.isEmpty ? nil : sprites.withUnsafeBytes { bytes in
                device.makeBuffer(bytes: bytes.baseAddress!, length: bytes.count, options: .storageModeShared)
            }
            if spriteCount > 0 && spriteBuffer == nil { inFlight.signal(); return false }
        }
        let startSource = reset ? params.source : (previousSource ?? params.source)
        // Analytically sweep the emitter in one compute pass. A fast drag must not
        // multiply the cost of updating the entire stationary desktop heat field.
        params.previousSource = startSource
        params.previousRect = reset ? params.rect : Self.vector(previousRect)
        params.clock.x = dt; params.clock.y = elapsed; params.clock.z = reset ? 1 : 0
        if !isWind && !isLightning && !isFrost {
            guard let encoder = command.makeComputeCommandEncoder() else { inFlight.signal(); return false }
            encoder.setComputePipelineState(updatePipeline)
            encoder.setTexture(textures[output], index: 0); encoder.setTexture(textures[1 - output], index: 1)
            encoder.setBytes(&params, length: MemoryLayout<EffectUniforms>.stride, index: 0)
            let groupWidth = updatePipeline.threadExecutionWidth
            encoder.dispatchThreads(MTLSize(width: textures[0].width, height: textures[0].height, depth: 1),
                threadsPerThreadgroup: MTLSize(width: groupWidth, height: max(1, updatePipeline.maxTotalThreadsPerThreadgroup / groupWidth), depth: 1))
            encoder.endEncoding(); output = 1 - output
        }
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
        let spritesOnly = (params.style.x > 5.5 && params.style.x < 6.5) || (params.style.x > 0.5 && params.style.x < 1.5)
        let frost = params.style.x > 7.5 && params.style.x < 8.5
        if !spritesOnly {
            encoder.setRenderPipelineState(renderPipeline)
            encoder.setFragmentTexture(textures[output], index: 0)
            encoder.setFragmentBytes(&params, length: MemoryLayout<EffectUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        if spritesOnly || frost {
            encoder.setRenderPipelineState(spritePipeline)
            if let spriteBuffer, spriteCount > 0 {
                encoder.setVertexBuffer(spriteBuffer, offset: 0, index: 0)
                encoder.setVertexBytes(&params, length: MemoryLayout<EffectUniforms>.stride, index: 1)
                encoder.setFragmentBytes(&params, length: MemoryLayout<EffectUniforms>.stride, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: spriteCount)
            }
        }
        encoder.endEncoding()
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
    struct Params { float4 rect, previousRect, source, previousSource, motion, style, clock, drawRect, smoke, cursor, windowRect, lifecycle; };
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
    float segment(float2 p, float2 a, float2 b) { float2 v=b-a; return length(p-a-v*clamp(dot(p-a,v)/max(dot(v,v),0.0001),0.0,1.0)); }
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
            if (p.lifecycle.y>0.5 && p.clock.z>0.5) {
                float2 delta=abs(world-(p.windowRect.xy+p.windowRect.zw*0.5))-p.windowRect.zw*0.5;
                float distance=length(max(delta,0.0))+min(max(delta.x,delta.y),0.0);
                float mask=1.0-smoothstep(-8.0,20.0,distance);
                float puff=mask*(0.55+0.65*turbulence(world*0.045))*p.lifecycle.z;
                next.write(half4(half(puff),0,0,1),gid); return;
            }
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
            if (p.style.x>1.5 && p.style.x<2.5) {
                flow=float2(curl.y*160.0,80.0+n*85.0)+outward*28.0;
                source*=0.65+0.5*noise(local*0.1+float2(t*4.0,-t*6.0));
            }
        }
        if (mist && p.style.x>3.5 && p.style.x<4.5) {
            flow+=float2(sin(q.y*2.0+t)*90.0,cos(q.x*2.0-t)*55.0);
            source*=0.5+0.9*pow(0.5+0.5*sin(q.x*4.0+q.y*2.0+n*5.0-t*1.7),3.0);
        }
        if (mist && p.style.x>4.5) {
            flow+=float2(-q.y,q.x)*min(p.rect.z,p.rect.w)*0.16;
            source*=0.7;
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
    struct Sprite { float4 geometry, direction, appearance, colour; };
    struct SpriteVertex {
        float4 position [[position]];
        float2 local, world;
        float4 geometry, direction, appearance, colour;
    };
    vertex SpriteVertex spriteVertex(uint vertexID [[vertex_id]], uint instance [[instance_id]],
                                    const device Sprite *sprites [[buffer(0)]], constant Params &p [[buffer(1)]]) {
        const float2 corners[6]={float2(-1,-1),float2(1,-1),float2(-1,1),float2(-1,1),float2(1,-1),float2(1,1)};
        Sprite s=sprites[instance]; float2 uv=corners[vertexID];
        float2 axis=s.direction.xy, normal=float2(-axis.y,axis.x);
        float2 world=s.geometry.xy+axis*uv.x*s.geometry.z*0.5+normal*uv.y*s.geometry.w*0.5;
        return {float4((world-p.drawRect.xy)/p.drawRect.zw*2.0-1.0,0,1),uv,world,s.geometry,s.direction,s.appearance,s.colour};
    }
    fragment float4 spriteFragment(SpriteVertex in [[stage_in]], constant Params &p [[buffer(0)]]) {
        float2 q=in.local; float kind=in.appearance.y, a=0; float3 rgb=in.colour.rgb;
        if (kind>6.5 && kind<7.5) {
            // A few small star glints interrupt the varied six-arm crystals.
            float radius=in.geometry.z*0.43;
            float2 point=q*in.geometry.z*0.5;
            if (length(point)>radius+3.0) return float4(0);
            float distance=length(point);
            if (in.appearance.w>0.76) {
                distance=min(distance,segment(point,float2(-radius,0),float2(radius,0)));
                distance=min(distance,segment(point,float2(0,-radius),float2(0,radius)));
            } else {
                for (int arm=0;arm<6;arm++) {
                    float angle=float(arm)*1.04719755;
                    float2 axis=float2(cos(angle),sin(angle));
                    float2 side=float2(-axis.y,axis.x);
                    distance=min(distance,segment(point,float2(0),axis*radius));
                    for (int fork=0;fork<2;fork++) {
                        float reach=(fork==0?0.33:0.61)+in.appearance.w*0.09;
                        float2 root=axis*radius*reach;
                        for (int sign=-1;sign<=1;sign+=2) {
                            float2 tip=root+axis*radius*0.15+side*float(sign)*radius*(fork==0?0.21:0.16);
                            distance=min(distance,segment(point,root,tip));
                        }
                    }
                }
            }
            float width=0.58+in.geometry.z*0.01;
            float crystal=1.0-smoothstep(width,width+1.0,distance);
            float aura=exp(-distance*distance*0.17)*0.22;
            float twinkle=pow(0.5+0.5*sin(p.clock.y*11.0+in.direction.z*7.0+in.direction.w),14.0);
            a=clamp((crystal*(0.78+0.22*twinkle)+aura)*in.appearance.x,0.0,0.95);
            rgb=mix(rgb,float3(1.0,0.99,1.0),crystal*(0.45+0.45*twinkle));
        } else if (kind>3.5 && kind<4.5) {
            // An overexposed white channel with a fine violet streamer sheath.
            float2 point=q*in.geometry.zw*0.5;
            float d=length(float2(max(0.0,abs(point.x)-in.direction.z*0.5),point.y));
            float aa=max(0.45,fwidth(d)), width=in.appearance.w;
            float core=1.0-smoothstep(width*0.25,width+aa,d);
            float sheath=exp(-d*d*0.18)*0.25+exp(-d*0.42)*0.07;
            a=clamp((core*0.96+sheath)*in.appearance.x,0.0,0.98);
            rgb=mix(float3(0.48,0.22,1.0),float3(0.97,0.95,1.0),core);
        } else if (kind>5.5) {
            float r=dot(q,q);
            a=(exp(-r*10.0)*0.55+exp(-r*2.5)*0.14)*in.appearance.x;
            rgb=mix(rgb,float3(1.0,0.96,1.0),exp(-r*16.0));
        } else if (kind>4.5) {
            a=exp(-dot(q,q)*3.0)*in.appearance.x;
            rgb=mix(rgb,float3(1),exp(-dot(q,q)*12.0));
        } else {
            float2 halfSize=p.windowRect.zw*0.5, centre=p.windowRect.xy+halfSize;
            float2 relative=abs(in.world-centre)/max(halfSize,float2(1));
            float centreMask=smoothstep(0.30,0.58,max(relative.x,relative.y));
            if (centreMask<0.001) return float4(0);
            if (kind<1.5) {
                float curve=sin(q.x*2.8+in.direction.z)*0.26+sin(q.x*5.0+in.direction.w)*0.08;
                float d=abs(q.y-curve);
                float taper=pow(max(0.0,1.0-q.x*q.x),0.75);
                if (kind<0.5) {
                    float wisps=0.68+0.32*noise(float2(q.x*8.0+in.direction.w,q.y*4.0+in.direction.z));
                    a=exp(-d*d*5.0)*taper*wisps*0.38;
                } else {
                    a=(1.0-smoothstep(0.18,0.50,d))*taper*0.62;
                }
            } else if (kind<2.5) {
                a=exp(-dot(q,q)*3.5)*0.50;
            } else {
                float outline=sqrt(max(0.001,1.0-q.x*q.x))*(0.72+0.10*sin(q.x*17.0));
                float body=1.0-smoothstep(outline-0.12,outline+0.06,abs(q.y));
                float vein=(1.0-smoothstep(0.025,0.09,abs(q.y+q.x*0.10)))*(1.0-abs(q.x));
                rgb=mix(rgb,rgb*1.3+float3(0.08),vein*0.6); a=body*0.90;
            }
            a*=in.appearance.x*centreMask;
        }
        return float4(rgb*a,a);
    }
    fragment float4 effectFragment(Vertex in [[stage_in]], texture2d<half> field [[texture(0)]], constant Params &p [[buffer(0)]]) {
        float2 world=p.drawRect.xy+in.uv*p.drawRect.zw;
        if (p.style.x>7.5 && p.style.x<8.5) {
            float2 source=p.source.xy;
            if (any(abs(world-source)>180.0)) return float4(0);
            float progress=smoothstep(0.0,0.34,p.clock.y);
            float horizontal=min(145.0,p.windowRect.z)*progress;
            float vertical=min(145.0,p.windowRect.w)*progress;
            float2 endX=source+float2(p.source.z*horizontal,0);
            float2 endY=source+float2(0,p.source.w*vertical);
            float distance=min(segment(world,source,endX),segment(world,source,endY));
            if (distance>26.0) return float4(0);
            float crystal=turbulence(world*0.085+float2(7.0,-4.0));
            float width=2.0+crystal*5.0;
            float rim=1.0-smoothstep(width-1.5,width+1.5,distance);
            float haze=exp(-distance*0.24)*0.09;
            float complete=smoothstep(0.24,0.38,p.clock.y);
            float2 cell=floor(world/23.0), delta=abs(world-(cell+0.5)*23.0);
            float seed=hash21(cell+17.0);
            float glint=exp(-min(delta.x,delta.y)*1.6-max(delta.x,delta.y)*0.22)
                *step(0.73,seed)*pow(0.5+0.5*sin(p.clock.y*8.0+seed*18.0),12.0)*complete;
            float fade=p.smoke.y>0.5?1.0-smoothstep(0.64,1.0,p.smoke.x):1.0;
            float entrance=smoothstep(0.0,0.14,p.clock.y);
            float alpha=clamp((rim*(0.40+0.42*crystal)+haze+glint*0.55)*entrance*fade,0.0,0.94);
            float3 colour=mix(float3(0.34,0.67,0.88),float3(0.94,0.99,1.0),clamp(crystal*0.7+glint,0.0,1.0));
            return float4(colour*alpha,alpha);
        }
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
        if (p.lifecycle.y>0.5) {
            float cloud=turbulence(world*0.035+float2(p.clock.y*0.9,-p.clock.y*0.8));
            float envelope=smoothstep(0.0,0.08,p.smoke.x)*(1.0-smoothstep(smokeMorphEnd,1.0,p.smoke.x));
            alpha=smoothstep(0.015,0.9,h)*(0.38+0.28*cloud)*envelope;
            rgb=float3(0.52+0.22*cloud);
            return float4(rgb*alpha,alpha);
        }
        if (p.style.w>0.5) {
            float2 q=(uv-0.5)*2;
            float edge=min(min(uv.x,1-uv.x),min(uv.y,1-uv.y));
            float mask=smoothstep(0.0,0.18,edge)*(1.0-smoothstep(0.30,1.15,length(q)));
            float detail=0.7+0.3*turbulence(q*6+float2(p.clock.y*0.42,-p.clock.y*0.36));
            alpha=min(0.65,h*0.9*detail)*mask;
            rgb=mix(float3(0.08,0.38,0.95),float3(0.52,0.81,1.0),clamp(h,0.0,1.0));
            if (p.style.x>3.5 && p.style.x<4.5) {
                float ribbon=0.5+0.5*sin(q.x*12.0+q.y*5.0+detail*16.0-p.clock.y*1.8);
                float curtains=pow(ribbon,5.0);
                alpha=min(0.62,h*(0.14+curtains*0.85))*mask;
                rgb=mix(float3(0.12,0.90,0.48),float3(0.65,0.28,1.0),0.5+0.5*sin(q.x*3.0+p.clock.y*0.6));
            } else if (p.style.x>4.5) {
                float angle=p.clock.y*0.2, c=cos(angle), s=sin(angle);
                float2 rotated=float2(c*local.x-s*local.y,s*local.x+c*local.y);
                float2 grid=rotated/27.0, cell=floor(grid), f=fract(grid);
                float2 centre=float2(hash21(cell),hash21(cell+41.0))*0.6+0.2;
                float2 delta=abs(f-centre)*27.0;
                float twinkle=0.45+0.55*pow(0.5+0.5*sin(p.clock.y*3.5+hash21(cell+17.0)*6.28),3.0);
                float star=exp(-dot(delta,delta)*1.5)+0.45*exp(-min(delta.x,delta.y)*4.0-max(delta.x,delta.y)*0.8);
                star*=step(0.62,hash21(cell+7.0))*twinkle;
                alpha=clamp(h*0.13*mask+star*mask*min(1.0,h*4.0),0.0,0.85);
                rgb=mix(float3(0.35,0.22,0.72),float3(0.91,0.95,1.0),clamp(star*5.0,0.0,1.0));
            }
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
            if (p.style.x>1.5 && p.style.x<2.5) {
                float flicker=noise(local*0.09+float2(p.clock.y*3.0,-p.clock.y*7.0));
                float tongues=smoothstep(0.03,0.7,h)*(0.25+0.6*flicker);
                alpha=clamp(core*0.95+tongues+bloom*0.12,0.0,0.95);
                rgb=mix(float3(0.80,0.06,0.01),float3(1.0,0.45,0.04),clamp(h+flicker*0.4,0.0,1.0));
                rgb=mix(rgb,float3(1.0,0.92,0.48),clamp(core+ridge*0.5,0.0,1.0));
            }
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
