## Coherent noise generation — Perlin noise and fractal variants.
##
## Seed-based deterministic noise for procedural generation:
## terrain, textures, fog, animation, and more.
##
##   import std.noise as ns
##   var noise = ns.Noise.create(42)
##   let h = noise.fbm2d(x * 0.01, y * 0.01)


public struct Noise:
    perm: array[ubyte, 512]
    octaves: int
    lacunarity: float
    gain: float
    frequency: float


# ── fade / interpolation ──

function fade(t: float) -> float:
    return t * t * t * (t * (t * 6.0 - 15.0) + 10.0)


function lerp(a: float, b: float, t: float) -> float:
    return a + t * (b - a)


# ── gradient functions ──

function grad2d(hash: int, x: float, y: float) -> float:
    let h = hash & 3
    let u = if h == 0 or h == 1: x else: y
    let v = if h == 0 or h == 3: y else: x
    return (if (h & 1) == 0: u else: -u) + (if (h & 2) == 0: v else: -v)


function grad3d(hash: int, x: float, y: float, z: float) -> float:
    let h = hash & 15
    let u = if h < 8: x else: y
    let v = if h < 4: y else: if h == 12 or h == 14: x else: z
    let mu = if (h & 1) == 0: u else: -u
    let mv = if (h & 2) == 0: v else: -v
    return mu + mv


# ── internal noise functions ──

function perlin2d_impl(perm: array[ubyte, 512], x: float, y: float) -> float:
    let ix = int<-x
    let iy = int<-y
    let X = ix & 255
    let Y = iy & 255
    let xf = x - float<-(ix - (ix & ~255))
    let yf = y - float<-(iy - (iy & ~255))

    let u = fade(if xf < 0.0: xf + 1.0 else: xf)
    let v = fade(if yf < 0.0: yf + 1.0 else: yf)

    let A = int<-perm[X] + Y
    let B = int<-perm[X + 1] + Y
    let aa = int<-perm[A]
    let ab = int<-perm[A + 1]
    let ba = int<-perm[B]
    let bb = int<-perm[B + 1]

    let x1 = lerp(grad2d(aa, xf, yf), grad2d(ba, xf - 1.0, yf), u)
    let x2 = lerp(grad2d(ab, xf, yf - 1.0), grad2d(bb, xf - 1.0, yf - 1.0), u)

    return lerp(x1, x2, v)


function perlin3d_impl(perm: array[ubyte, 512], x: float, y: float, z: float) -> float:
    let ix = int<-x
    let iy = int<-y
    let iz = int<-z
    let X = ix & 255
    let Y = iy & 255
    let Z = iz & 255
    let xf = x - float<-(ix - (ix & ~255))
    let yf = y - float<-(iy - (iy & ~255))
    let zf = z - float<-(iz - (iz & ~255))

    let u = fade(if xf < 0.0: xf + 1.0 else: xf)
    let v = fade(if yf < 0.0: yf + 1.0 else: yf)
    let w = fade(if zf < 0.0: zf + 1.0 else: zf)

    let A = int<-perm[X] + Y
    let AA = int<-perm[A] + Z
    let AB = int<-perm[A + 1] + Z
    let B = int<-perm[X + 1] + Y
    let BA = int<-perm[B] + Z
    let BB = int<-perm[B + 1] + Z

    let x1 = lerp(grad3d(int<-perm[AA], xf, yf, zf), grad3d(int<-perm[BA], xf - 1.0, yf, zf), u)
    let x2 = lerp(grad3d(int<-perm[AB], xf, yf - 1.0, zf), grad3d(int<-perm[BB], xf - 1.0, yf - 1.0, zf), u)
    let y1 = lerp(x1, x2, v)

    let x3 = lerp(grad3d(int<-perm[AA + 1], xf, yf, zf - 1.0), grad3d(int<-perm[BA + 1], xf - 1.0, yf, zf - 1.0), u)
    let x4 = lerp(grad3d(int<-perm[AB + 1], xf, yf - 1.0, zf - 1.0), grad3d(int<-perm[BB + 1], xf - 1.0, yf - 1.0, zf - 1.0), u)
    let y2 = lerp(x3, x4, v)

    return lerp(y1, y2, w)


# ── float floor for negative numbers ──

function floor_f(x: float) -> int:
    let i = int<-x
    if x < 0.0 and float<-i != x:
        return i - 1
    return i


# ── public API ──

extending Noise:
    public static function create(seed: ulong) -> Noise:
        var n = Noise(
            perm = zero[array[ubyte, 512]],
            octaves = 6,
            lacunarity = 2.0,
            gain = 0.5,
            frequency = 1.0
        )

        var i: int = 0
        while i < 256:
            n.perm[i] = ubyte<-i
            i += 1

        var state: ulong = seed
        var j: int = 255
        while j > 0:
            state = state * 6364136223846793005 + 1442695040888963407
            let r = int<-(state % ulong<-(j + 1))
            let tmp = n.perm[j]
            n.perm[j] = n.perm[r]
            n.perm[r] = tmp
            j -= 1

        i = 0
        while i < 256:
            n.perm[i + 256] = n.perm[i]
            i += 1

        return n


    public function perlin2d(x: float, y: float) -> float:
        return perlin2d_impl(this.perm, x, y)


    public function perlin3d(x: float, y: float, z: float) -> float:
        return perlin3d_impl(this.perm, x, y, z)


    public function fbm2d(x: float, y: float) -> float:
        var value: float = 0.0
        var freq: float = this.frequency
        var amp: float = 1.0
        var max_val: float = 0.0
        var i: int = 0
        while i < this.octaves:
            value = value + amp * perlin2d_impl(this.perm, x * freq, y * freq)
            max_val = max_val + amp
            amp = amp * this.gain
            freq = freq * this.lacunarity
            i += 1
        return value / max_val


    public function fbm3d(x: float, y: float, z: float) -> float:
        var value: float = 0.0
        var freq: float = this.frequency
        var amp: float = 1.0
        var max_val: float = 0.0
        var i: int = 0
        while i < this.octaves:
            value = value + amp * perlin3d_impl(this.perm, x * freq, y * freq, z * freq)
            max_val = max_val + amp
            amp = amp * this.gain
            freq = freq * this.lacunarity
            i += 1
        return value / max_val


    public editable function set_octaves(n: int) -> void:
        this.octaves = n


    public editable function set_lacunarity(v: float) -> void:
        this.lacunarity = v


    public editable function set_gain(v: float) -> void:
        this.gain = v


    public editable function set_frequency(v: float) -> void:
        this.frequency = v