# Cloud Shader Analysis — v2 (post-fix, UBO era)

Date: 2026-05-15

## Symptoms
- No clouds visible at all
- Black band around entire horizon circle
- Sky is otherwise clear

## Changes Since v1
- Cloud data moved from Push Constants to UBO (Binding 4)
- `* 4.0` density multiplier removed
- Tone map + gamma added to Lighting.hs for cloud pixels
- Double-tinting removed (cloud shader no longer applies sky tint)
- noiseScale reduced from 0.003 to 0.0008
- Domain warping: separate frequencies per axis (0.0013/0.0017/0.0023), amplitude 60

## Findings

---

### 1. CRITICAL — UBO Layout: Missing Pad Float Before prevViewProj Matrix

**File**: `Render/Deferred.hs:200-247`

FIR Uniform uses **Extended** layout (not Base/std430). Key difference: all alignment rules same, but struct alignment rounds up to 16.

FIR Extended layout for CloudFrameData:

```
Offset  Member            Type        Align  Size
0       cameraX           Float       4      4
4       cameraY           Float       4      4
8       cameraZ           Float       4      4
16      ray0               V3 Float   16     12    ← pad 12→16
32      ray1               V3 Float   16     12    ← pad 28→32
48      ray2               V3 Float   16     12    ← pad 44→48
64      sunDir             V3 Float   16     12    ← pad 60→64
76      cloudHeight        Float      4      4
80      time               Float      4      4
84      blendFactor        Float      4      4
96      prevViewProj0      V4 Float   16     16    ← pad 88→96 (NEEDS 2 PAD FLOATS!)
112     prevViewProj1      V4 Float   16     16
128     prevViewProj2      V4 Float   16     16
144     prevViewProj3      V4 Float   16     16
160     windDirX           Float      4      4
164     windDirZ           Float      4      4
168     prevTime           Float      4      4
172     cloudCoverage      Float      4      4
176     cloudDetail        Float      4      4
180     cloudAbsorption    Float      4      4
```

Struct size: roundUp(184, 16) = **192 bytes**.

CPU data (48 floats = 192 bytes) has **only 1 pad float** between blendFactor and prevViewProj:

```haskell
, realToFrac dpdBlendFactor  -- byte 84
, 0,                         -- byte 88  ← 1 pad
, realToFrac m00             -- byte 92  ← WRONG! FIR expects byte 96
```

The gap from 88→96 is **8 bytes = 2 floats**. The CPU only provides 1 pad float. **All fields from offset 92 onward are shifted by 4 bytes.**

Consequences — what the shader ACTUALLY reads vs what was intended:

| FIR Member       | FIR Offset | CPU data at that byte | Intended Value |
|------------------|-----------|----------------------|----------------|
| prevViewProj0.x  | 96        | m10                  | m00            |
| prevViewProj0.y  | 100       | m20                  | m10            |
| prevViewProj0.z  | 104       | m30                  | m20            |
| prevViewProj0.w  | 108       | m01                  | m30            |
| ... (entire matrix shifted by 1 float) | | | |
| prevViewProj3.w  | 156       | windDirX             | m33            |
| windDirX         | 160       | windDirZ             | windDirX       |
| windDirZ         | 164       | prevTime             | windDirZ       |
| prevTime         | 168       | cloudCoverage (0.45) | prevTime       |
| cloudCoverage    | 172       | cloudDetail (0.35)   | 0.45           |
| cloudDetail      | 176       | cloudAbsorption (1.5)| 0.35           |
| cloudAbsorption  | 180       | **0 (pad zero!)**    | 1.5            |

**Key misread values:**
- `cloudDetail` = 1.5 (should be 0.35) → density formula: `nr * (1.0 - 1.5 * detail_term)` makes detail_term up to 0.7875, requiring `nr > 3.06` for any density — **impossible** since nr ∈ [0,1]
- `cloudAbsorption` = 0.0 (should be 1.5) → light always passes through (exp(0) = 1.0)
- `cloudCoverage` = 0.35 (should be 0.45) → slightly wrong threshold
- Entire prevViewProj matrix is shifted → temporal reprojection uses garbage

**This is the primary cause of "no clouds".** The density formula with detail=1.5 makes it impossible for any noise value to exceed the coverage threshold. The noise can produce density ONLY where detail channels (G/B/A) are all near zero (about 5% of volume), and even then only barely.

**Fix**: Add one more `0` pad after the existing pad at line 223:
```haskell
, 0, 0,                    -- bytes 88-95: TWO pads for 16-align to 96
, realToFrac m00            -- byte 96
```

---

### 2. CRITICAL — horizonSkip Creates Solid Black Band at Horizon

**File**: `Clouds.hs:259, 279`

```haskell
horizonSkip = 1.0 - step 0.05 absDirY   -- 1.0 when near horizontal
...
_ <- def @"transmittance" @RW @Float (1.0 - horizonSkip)  -- = 0.0 near horizon
```

For all rays within ~3° of horizontal (absDirY < 0.05):
- `horizonSkip = 1.0`
- `transmittance = 0.0`
- Ray march loop exits immediately (`when (t < 0.01) break`)
- Accumulated color = 0
- Output: `skyR * 0 + 0 = (0, 0, 0)` → **solid black**

After tone map + gamma in Lighting.hs: `sqrt(0/(0+1)) = 0`. After tint: `0 * tint = 0`.

This produces a thin black ring at the exact horizon level around the entire 360° view.

**Fix**: Instead of zeroing transmittance, either:
- Output sky color directly for skipped rays, or
- Set transmittance to 1.0 and just reduce step count for horizon rays, or
- Remove horizonSkip entirely (the adaptive step count already handles this)

---

### 3. Moderate — Descriptor Pool Undersized

**File**: `DescriptorPool.hs:111-114`

Cloud descriptor set has 5 bindings:
- Bindings 0-3: Combined Image Sampler (env, noise, history, blue_noise) = 4 per set
- Binding 4: Uniform Buffer (frame_data) = 1 per set

But the pool allocates:
```haskell
samplerPoolSize = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, count = numSets * 3
```

Only 3 image samplers per set (needs 4) and **zero** UBO descriptors (needs 1).

Works on NVIDIA (lenient pool enforcement) but will fail on conformant drivers and triggers validation errors.

**Fix**: Add UBO pool size and increase sampler count:
```haskell
samplerPoolSize = COMBINED_IMAGE_SAMPLER, count = numSets * 4
uboPoolSize = UNIFORM_BUFFER, count = numSets
poolSizes = [samplerPoolSize, uboPoolSize]
```

---

### 4. Minor — UBO Buffer Size Comment Wrong

**File**: `Render/Deferred.hs:246`

```haskell
0, 0, 0  -- 184-192 pad to 256
```

Comment says "pad to 256" but actual data is 48 floats = 192 bytes (matching FIR struct size). The buffer is allocated at 256 bytes, which is fine. The comment is misleading but not a bug.

---

## Root Cause Analysis

The "black band + no clouds" is caused by TWO independent bugs:

1. **horizonSkip** → black band (transmittance=0 for near-horizontal rays)
2. **UBO layout shift** → no clouds (cloudDetail reads 1.5, making density function produce zero for all noise values)

With both bugs:
- Near horizon (absDirY < 0.05): solid black from horizonSkip
- Rest of sky: clear sky (no clouds) because density ≈ 0 from wrong parameters

This matches Sergey's description exactly.

---

## Priority Fix Order
1. **Add missing pad float** before prevViewProj in Deferred.hs (1-line fix)
2. **Fix horizonSkip** to output sky color instead of black
3. **Fix descriptor pool** sizes for UBO + correct sampler count
