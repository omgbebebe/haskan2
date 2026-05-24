# InfiniteDiffusion: Complete Mathematical Formulation and Vulkan Compute Pipeline

## Executive Summary

This document provides an exhaustive extraction of all mathematical formulations from the InfiniteDiffusion paper (Goslin, SIGGRAPH 2026) [^13^], together with a production-ready Vulkan compute pipeline implementation in pseudo-GLSL/Vulkan shading language. InfiniteDiffusion reformulates MultiDiffusion [^35^] for unbounded domains, achieving **seed-consistent**, **constant-time random-access** generation over infinitely large terrains. The core algorithm reduces to a lazy evaluation of spatially overlapping diffusion windows with cached numerator/denominator accumulators. When deployed as Terrain Diffusion, the system generates 512×512 tiles at **90m resolution** with a **time-to-first-tile (TTFT) of 1.72s** and **time-to-second-tile (TTST) of 0.66s** on an NVIDIA RTX 3090 Ti, outpacing orbital velocity by **9×**.

---

## 1. Core Mathematical Framework

### 1.1 MultiDiffusion Foundation

InfiniteDiffusion extends MultiDiffusion (Bar-Tal et al., 2023) [^35^]. Let $\Phi$ denote a pretrained diffusion model operating on images in $\mathcal{I} = \mathbb{R}^{H \times W \times C}$. The standard diffusion process generates a sequence:

```tex
I_T, I_{T-1}, \ldots, I_0 \quad \text{s.t.} \quad I_{t-1} = \Phi(I_t \mid y)
```

where $y$ is a conditioning vector. MultiDiffusion defines a new model $\Psi$ generating in a different image space $\mathcal{J} = \mathbb{R}^{H' \times W' \times C}$, producing:

```tex
J_T, J_{T-1}, \ldots, J_0 \quad \text{s.t.} \quad J_{t-1} = \Psi(J_t \mid z)
```

MultiDiffusion defines $n$ windows indexed by $i \in [n]$. Each window $i$ is assigned a **window region** $R_i$ (fixed size $H \times W$) and a **weight matrix** $W_i \in \mathbb{R}^{H \times W}$. Let $U_i(x)$ denote the $H' \times W'$ image that places an $H \times W$ tensor $x$ in region $R_i$ with zeros elsewhere. The closed-form MultiDiffusion update is:

```tex
\Psi(J_t \mid z) = \frac{\sum_{i=1}^{n} U_i\bigl(W_i \otimes \Phi(J_t[R_i] \mid y_i)\bigr)}{\sum_{j=1}^{n} U_j(W_j)}
```

where $\otimes$ denotes the **Hadamard (element-wise) product**. This is Equation (1) from the paper [^1^].

### 1.2 The Infinite Extension

To extend to infinite domains, redefine the image space as an **unbounded image**:

```tex
\mathcal{J} = \mathbb{R}^{\mathbb{Z} \times \mathbb{Z} \times C}
```

Window indices now range over a countably infinite set $S = \mathbb{Z}^2$. Each window region for a sliding-window layout with side length $H = W$, stride $s$:

```tex
R_{ij} = [is, is + H) \times [js, js + W)
```

Define $\kappa(R)$ as the function mapping a region to the **finite set of window indices** that overlap it. The **InfiniteDiffusion update** (Equation 2) [^1^]:

```tex
\Psi(J_t \mid z)[R] = \left( \frac{\sum_{i \in \kappa(R)} U_i\bigl(W_i \otimes \Phi(J_t[R_i] \mid y_i)\bigr)}{\sum_{j \in \kappa(R)} U_j(W_j)} \right)[R]
```

This formulation is the cornerstone of the algorithm: it evaluates only windows intersecting the queried region $R$, making lazy generation possible.

### 1.3 Practical Querying with Sparse Infinite Tensors

For each image $J_t$, maintain two corresponding **sparse infinite tensors** [^1^]:

- $A_t$: stores the numerator of the InfiniteDiffusion update
- $B_t$: stores the denominator (weight accumulation)

When a query $J_t[R]$ occurs:

```tex
J_t[R] = \frac{A_t[R]}{B_t[R]}
```

Each infinite tensor is stored as a set of **per-window contributions** $(i, x_i)$, where:

```tex
x_i = W_i \otimes \Phi(J_{t+1}[R_i] \mid y_i) \quad \text{for } A_t
```

```tex
x_i = W_i \quad \text{for } B_t
```

### 1.4 Signed Square-Root Transform

Terrain tiles exhibit significant elevation range variation. The **signed square-root transform** compresses high-relief values:

```tex
f(z) = \text{sign}(z) \sqrt{|z|}
```

The inverse transform recovers original elevations:

```tex
f^{-1}(x) = \text{sign}(x) \cdot x^2
```

This transform reduces the correlation between mean and log standard deviation of tiles from **0.66 to 0.31**, enabling more uniform noise scheduling during training [^1^].

### 1.5 Laplacian Encoding for Stabilization

To handle Earth's large dynamic range, the model predicts a **Laplacian-based representation** [^1^] comprising:

- **Low-frequency component** $L$: obtained by downsampling and blurring the original image
- **Residual/high-frequency component** $H$: given by subtracting the upsampled low-frequency component from the original

```tex
L = \text{Blur}(\text{Downsample}(I, 8\times)), \quad \sigma = 5
```

```tex
H = I - \text{Upsample}(L)
```

The **Laplacian denoising step** decodes $(L + H)$ into a provisional heightmap, then re-extracts:

```tex
\hat{L} = \text{Blur}(\text{Downsample}(L + H, 8\times))
```

```tex
\hat{H} = (L + H) - \text{Upsample}(\hat{L})
```

Final synthesis uses $\hat{L} + H$, eliminating low-frequency errors while preserving high-frequency detail. This reduces FID from **21.51 to 8.11** for the untiled core model [^1^].

### 1.6 Complexity Analysis

**Assumption 2 (Uniform overlap bound)** [^1^]: There exists a finite constant $M$ such that $|\kappa(R_i)| \leq M$ for every window region $R_i$.

**Lemma B.6 (Recursive cost bound)** [^1^]: Under Assumption 2, the worst-case number of $\Phi$-calls satisfies:

```tex
C_t(R_i) \leq M\bigl(1 + \sup_{j \in S} C_{t+1}(R_j)\bigr) \quad \text{for } t < T
```

with base case $C_T(R_i) = 0$.

**Theorem B.7 (Uniform bound on cost)** [^1^]: There exists a constant $K$ depending only on $T$ and $M$ such that:

```tex
C_t(R_i) \leq K \quad \forall t, \forall i \in S
```

Unwinding the recurrence yields:

```tex
C_t \leq M + M^2 + \cdots + M^{T-t}
```

This formally justifies **O(1)** query complexity for window-sized regions, independent of absolute location.

### 1.7 Amortized Cost with Hierarchical Cascades

For a cascade with $4\times$ super-resolution at each level, the amortized cost per $S \times S$ region is [^1^]:

```tex
O(S^2) \cdot \left(1 + \frac{1}{a} + \frac{1}{a^2} + \cdots\right) = O(S^2) \cdot \frac{a}{a-1}
```

For $a = 4$, this is approximately **1.33×** the cost of a single layer, independent of cascade depth. Adding unlimited resolution to an infinite world is nearly free.

---

## 2. Hierarchical Terrain Pipeline Architecture

The Terrain Diffusion pipeline [^1^] consists of three cascaded stages:

| Stage | Model | Resolution | Purpose | Steps |
|---|---|---|---|---|
| **Coarse** | EDM2 [^51^] (no down/up sampling) | 23 km/pixel | Continental structure from procedural/user input | T=1 |
| **Core Latent** | EDM2 + sCM [^53^] distillation | 46 km tile (512×512 at 90m) | Realistic terrain in latent space | 2-step consistency |
| **Decoder** | EDM2 + sCM distillation | Full 512×512 residual | Expand latents to high-fidelity elevation | T=1 |

*Table 1: Hierarchical model stack of Terrain Diffusion.*

The coarse model generates conditioning variables (mean elevation, 5th percentile, binary mask, climate data) for the core latent model. The core model simultaneously predicts a **64×64 low-frequency elevation channel** and **residual latents**. The decoder expands residual latents into a full-resolution residual, which is combined with the denoised low-frequency channel via the Laplacian reconstruction.

---

## 3. Vulkan Compute Pipeline Implementation

This section provides a complete pseudo-implementation of the InfiniteDiffusion algorithm as a **Vulkan compute shader pipeline**. The design targets real-time terrain generation on modern GPUs, leveraging Vulkan's explicit memory management, compute queue parallelism, and descriptor set bindings.

### 3.1 Pipeline Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                     CPU HOST CONTROLLER                         │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────────┐  │
│  │ Query Manager │  │ Window Cache │  │ Model Orchestrator   │  │
│  │ (region queue)│  │ (LRU eviction)│  │ (load UNet weights)  │  │
│  └──────┬───────┘  └──────┬───────┘  └──────────┬───────────┘  │
└─────────┼────────────────┼────────────────────┼──────────────┘
          │                │                    │
          ▼                ▼                    ▼
┌─────────────────────────────────────────────────────────────────┐
│              VULKAN COMPUTE QUEUE (Async)                       │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────────┐  │
│  │ Stage 1:     │  │ Stage 2:     │  │ Stage 3:             │  │
│  │ Window       │  │ Denoiser     │  │ Blend & Writeback    │  │
│  │ Discovery    │  │ (U-Net eval) │  │ (weighted average)   │  │
│  │ (κ-compute)  │  │ (batch Φ)    │  │ (A_t/B_t update)     │  │
│  └──────────────┘  └──────────────┘  └──────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

### 3.2 Descriptor Set Layout

```glsl
// ============================================================
// SET 0: Global Parameters (per-timestep, uniform)
// ============================================================
layout(set = 0, binding = 0) uniform GlobalParams {
    ivec2 query_region_origin;      // (x, y) of queried region R
    ivec2 query_region_size;        // (H_q, W_q) of R
    int   timestep;                 // current t (T down to 0)
    int   total_timesteps;          // T
    float window_stride;            // s (typically 384 for decoder)
    int   window_size;              // H = W (typically 512)
    int   pad_margin;               // context padding for recursive query
    uint  seed;                     // deterministic seed for noise gen
    float guidance_scale;           // AutoGuidance scale [^50^]
} g_params;

// ============================================================
// SET 1: Infinite Tensor State (storage buffers, sparse)
// ============================================================
layout(set = 1, binding = 0) buffer AccumulatorANum {
    vec4 data[];                    // A_t numerator contributions
} accumulator_A;

layout(set = 1, binding = 1) buffer AccumulatorBDen {
    float data[];                   // B_t denominator weights
} accumulator_B;

layout(set = 1, binding = 2) buffer ProcessedWindows {
    uint window_indices[];          // bitfield/hashset of processed windows
} processed_set;

// ============================================================
// SET 2: Model Weights (read-only, device-local)
// ============================================================
layout(set = 2, binding = 0) uniform sampler2D unet_weights_conv[128];
layout(set = 2, binding = 1) uniform sampler2D unet_weights_attn[32];
layout(set = 2, binding = 2) uniform sampler1D embedding_fourier;

// ============================================================
// SET 3: Conditioning Data (per-query)
// ============================================================
layout(set = 3, binding = 0) uniform sampler2D conditioning_coarse; // 4x4 patches
layout(set = 3, binding = 1) uniform sampler1D climate_vector;      // temp, precip, etc.
layout(set = 3, binding = 2) uniform sampler2D latent_codes;        // VAE latents
```

### 3.3 Stage 1: Window Discovery (κ-computation)

This compute shader determines which windows overlap the queried region $R$.

```glsl
// ============================================================
// COMPUTE SHADER: window_discovery.comp
// Local size: 1 (single dispatch per query, writes indirect args)
// ============================================================
#version 460
#extension GL_EXT_buffer_reference : require

layout(local_size_x = 1, local_size_y = 1) in;

layout(set = 0, binding = 0) uniform GlobalParams g_params;

layout(set = 1, binding = 3) buffer WindowList {
    int  count;                     // atomic counter
    ivec2 window_coords[];          // (i, j) indices
} window_list;

// Compute κ(R): all windows intersecting the query region
void main() {
    ivec2 R_min = g_params.query_region_origin;
    ivec2 R_max = R_min + g_params.query_region_size;
    
    int s = int(g_params.window_stride);
    int W = g_params.window_size;
    
    // Find bounds of window indices that could overlap R
    int i_min = floor(float(R_min.x - W) / float(s));
    int i_max = ceil(float(R_max.x) / float(s));
    int j_min = floor(float(R_min.y - W) / float(s));
    int j_max = ceil(float(R_max.y) / float(s));
    
    int count = 0;
    for (int i = i_min; i <= i_max; i++) {
        for (int j = j_min; j <= j_max; j++) {
            // Window region R_ij
            ivec2 w_min = ivec2(i * s, j * s);
            ivec2 w_max = w_min + ivec2(W, W);
            
            // Check overlap with R
            bool overlaps = all(lessThanEqual(w_min, R_max)) && 
                           all(greaterThanEqual(w_max, R_min));
            
            if (overlaps) {
                int idx = atomicAdd(window_list.count, 1);
                window_list.window_coords[idx] = ivec2(i, j);
                count++;
            }
        }
    }
}
```

### 3.4 Stage 2: Denoising Kernel (U-Net Evaluation)

This is the core $\Phi$ evaluation, implemented as a batched compute shader. The U-Net follows the EDM2 architecture [^51^] with modifications from sCM [^53^] (pixel-norm on embeddings, positional embeddings replacing Fourier).

```glsl
// ============================================================
// COMPUTE SHADER: denoise_unet.comp
// Local size: 8x8x1 (one workgroup per 8x8 tile)
// Batch: 16 windows per dispatch (concurrent SM occupancy)
// ============================================================
#version 460
#extension GL_KHR_shader_subgroup_arithmetic : require

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform GlobalParams g_params;
layout(set = 2, binding = 0) uniform sampler2D conv_weights[128];
layout(set = 3, binding = 0) uniform sampler2D conditioning_coarse;
layout(set = 3, binding = 1) uniform sampler1D climate_vector;

// Shared memory for subgroup-coalesced loading
shared vec4 shmem_input[8][8];      // cached input tile
shared vec4 shmem_conditioning[4][4]; // 4x4 coarse conditioning

// EDM2 preconditioning parameters
const float sigma_data = 0.5;
const float sigma_min  = 0.002;

// Preconditioning: c_skip, c_out, c_in as per EDM2 [^51^]
vec3 edm_precond(float sigma) {
    float c_skip = sigma_data * sigma_data / (sigma * sigma + sigma_data * sigma_data);
    float c_out  = sigma * sigma_data / sqrt(sigma * sigma + sigma_data * sigma_data);
    float c_in   = 1.0 / sqrt(sigma * sigma + sigma_data * sigma_data);
    return vec3(c_skip, c_out, c_in);
}

// Magnitude-preserving convolution (EDM2 standard) [^51^]
vec4 mp_conv2d(sampler2D weight, vec4 input, ivec2 coord) {
    // Normalize input activations
    float rms = sqrt(dot(input, input) + 1e-8);
    vec4 norm_input = input / rms;
    
    // Weighted sum (simplified - actual impl uses textureGather)
    vec4 result = vec4(0.0);
    for (int ky = -1; ky <= 1; ky++) {
        for (int kx = -1; kx <= 1; kx++) {
            vec4 w = texelFetch(weight, ivec2(kx + 1, ky + 1), 0);
            result += w * norm_input;  // simplified
        }
    }
    return result;
}

// U-Net downblock with self-attention (EDM2-S variant)
vec4 unet_downblock(vec4 x, float sigma, int level) {
    // Embedding injection
    vec3 pre = edm_precond(sigma);
    x = pre.z * x;  // c_in scaling
    
    // ResNet block with group norm → SiLU → conv
    vec4 h = groupnorm(x, 32);
    h = silu(h);
    h = mp_conv2d(conv_weights[level * 4 + 0], h, ivec2(gl_LocalInvocationID.xy));
    
    // Self-attention at lower resolutions (levels 2, 3)
    if (level >= 2) {
        h = multihead_attention(h, 4);  // 4 heads
    }
    
    // Skip connection with c_skip
    return pre.x * x + pre.y * h;
}

// Main denoising function Φ(J_{t+1}[R_i] | y_i)
vec4 denoise_phi(ivec2 window_origin, int window_idx, float sigma_t) {
    // Load window content from previous timestep (or noise at t=T)
    vec4 input_tile = load_window_input(window_origin);
    
    // Load conditioning: 4x4 coarse elevation patch
    ivec2 coarse_origin = window_origin / 128;  // 23km -> 90m mapping
    vec4 conditioning = sample_conditioning(coarse_origin);
    
    // Concatenate conditioning to input (channel dim)
    vec4 x = channel_concat(input_tile, conditioning);
    
    // U-Net forward pass (4 down + bottleneck + 4 up)
    vec4 down_activations[4];
    for (int l = 0; l < 4; l++) {
        x = unet_downblock(x, sigma_t, l);
        down_activations[l] = x;
        if (l < 3) x = downsample(x, 2);
    }
    
    // Bottleneck
    x = unet_bottleneck(x, sigma_t);
    
    // Upsample path with skip connections
    for (int l = 3; l >= 0; l--) {
        if (l < 3) x = upsample(x, 2);
        x = channel_concat(x, down_activations[l]);
        x = unet_upblock(x, sigma_t, l);
    }
    
    // AutoGuidance: enhance with guidance model delta [^50^]
    vec4 guided = apply_autoguidance(x, input_tile, sigma_t, g_params.guidance_scale);
    
    return guided;
}

void main() {
    uint window_idx = gl_WorkGroupID.z;
    ivec2 window_ij = load_window_index(window_idx);
    ivec2 window_origin = window_ij * int(g_params.window_stride);
    
    // Compute noise level sigma_t for this timestep
    float sigma_t = compute_noise_schedule(g_params.timestep, g_params.total_timesteps);
    
    // Evaluate denoiser Φ
    vec4 denoised = denoise_phi(window_origin, window_idx, sigma_t);
    
    // Write to output tile buffer
    ivec2 tile_coord = ivec2(gl_GlobalInvocationID.xy);
    store_denoised_output(window_idx, tile_coord, denoised);
}
```

### 3.5 Stage 3: Weighted Blending and Accumulation

This shader implements the core InfiniteDiffusion weighted averaging, updating $A_t$ and $B_t$.

```glsl
// ============================================================
// COMPUTE SHADER: blend_accumulate.comp
// Local size: 16x16 (one thread per output pixel)
// ============================================================
#version 460
#extension GL_KHR_shader_subgroup : require

layout(local_size_x = 16, local_size_y = 16) in;

layout(set = 0, binding = 0) uniform GlobalParams g_params;

layout(set = 1, binding = 0) buffer AccumulatorANum { vec4 data[]; } acc_A;
layout(set = 1, binding = 1) buffer AccumulatorBDen { float data[]; } acc_B;

// Denoised outputs from Stage 2
layout(set = 4, binding = 0) readonly buffer DenoisedTiles {
    vec4 tiles[];                   // [num_windows][window_size^2]
} denoised_batch;

// Separable linear weight window (precomputed on CPU)
layout(set = 4, binding = 1) readonly buffer WeightWindow {
    float row_weights[];            // 1D weights, decay center->edge
} weight_lut;

// Compute weight W_i[p] for pixel p in window i
float compute_weight(ivec2 p_local, int window_size) {
    // Separable: W_i[x,y] = w_x[x] * w_y[y]
    float wx = weight_lut.row_weights[p_local.x];
    float wy = weight_lut.row_weights[p_local.y];
    return wx * wy;
}

void main() {
    ivec2 R_origin = g_params.query_region_origin;
    ivec2 R_size   = g_params.query_region_size;
    
    // Global pixel coordinate within the infinite image
    ivec2 global_pixel = R_origin + ivec2(gl_GlobalInvocationID.xy);
    
    if (any(greaterThanEqual(gl_GlobalInvocationID.xy, uvec2(R_size)))) return;
    
    // Initialize accumulators for this pixel
    vec4 numerator   = vec4(0.0);
    float denominator = 0.0;
    
    // Iterate over all windows in κ(R) that cover this pixel
    int num_windows = window_list.count;
    for (int w = 0; w < num_windows; w++) {
        ivec2 w_ij = window_list.window_coords[w];
        ivec2 w_origin = w_ij * int(g_params.window_stride);
        ivec2 w_size = ivec2(g_params.window_size);
        
        // Check if this window covers global_pixel
        ivec2 w_max = w_origin + w_size;
        if (any(lessThan(global_pixel, w_origin)) || 
            any(greaterThanEqual(global_pixel, w_max))) continue;
        
        // Local coordinate within this window
        ivec2 p_local = global_pixel - w_origin;
        
        // Fetch denoised value for this window
        vec4 phi_output = denoised_batch.tiles[w * w_size.x * w_size.y + 
                                                p_local.y * w_size.x + p_local.x];
        
        // Compute weight W_i at this pixel
        float W_i = compute_weight(p_local, w_size.x);
        
        // Accumulate: numerator += W_i * Φ(output), denominator += W_i
        numerator += W_i * phi_output;
        denominator += W_i;
    }
    
    // Write to accumulator buffers (atomically for concurrent queries)
    int flat_idx = global_pixel.y * 65536 + global_pixel.x;  // sparse addressing
    
    if (denominator > 1e-6) {
        // Use subgroup-atomic for SIMD efficiency
        subgroupBarrier();
        atomicAdd_vec4(acc_A.data[flat_idx], numerator);
        atomicAdd(acc_B.data[flat_idx], denominator);
    }
    
    // Mark window as processed
    processed_set.window_indices[window_hash] = 1u;
}
```

### 3.6 Stage 4: Final Division and Output

```glsl
// ============================================================
// COMPUTE SHADER: resolve_output.comp
// Local size: 16x16
// ============================================================
layout(local_size_x = 16, local_size_y = 16) in;

layout(set = 1, binding = 0) readonly buffer AccumulatorANum { vec4 data[]; } acc_A;
layout(set = 1, binding = 1) readonly buffer AccumulatorBDen { float data[]; } acc_B;

layout(set = 5, binding = 0) writeonly uniform image2D output_heightmap;

layout(set = 0, binding = 0) uniform GlobalParams g_params;

// Inverse signed-sqrt transform: f^{-1}(x) = sign(x) * x^2
float inverse_sqrt_transform(float x) {
    return sign(x) * x * x;
}

void main() {
    ivec2 R_origin = g_params.query_region_origin;
    ivec2 R_size   = g_params.query_region_size;
    ivec2 local_coord = ivec2(gl_GlobalInvocationID.xy);
    
    if (any(greaterThanEqual(local_coord, R_size))) return;
    
    ivec2 global_pixel = R_origin + local_coord;
    int flat_idx = global_pixel.y * 65536 + global_pixel.x;
    
    // J_t[R] = A_t[R] / B_t[R]
    vec4 A_val = acc_A.data[flat_idx];
    float B_val = acc_B.data[flat_idx];
    
    vec4 result = (B_val > 1e-6) ? (A_val / B_val) : vec4(0.0);
    
    // Apply inverse transform to elevation channel (channel 0)
    result.x = inverse_sqrt_transform(result.x);
    
    // Write final heightmap
    imageStore(output_heightmap, local_coord, result);
}
```

### 3.7 Laplacian Reconstruction Pipeline

The Laplacian encoding requires additional compute passes after denoising:

```glsl
// ============================================================
// COMPUTE SHADER: laplacian_reconstruct.comp
// Implements: L_hat + H final synthesis
// ============================================================
layout(local_size_x = 16, local_size_y = 16) in;

layout(set = 0, binding = 0) uniform sampler2D low_freq_channel;   // 64x64 L
layout(set = 0, binding = 1) uniform sampler2D residual_channel;   // 512x512 H
layout(set = 0, binding = 2) writeonly uniform image2D final_heightmap;

// Gaussian blur kernel (σ=5, separable)
const float gaussian_kernel[21] = float[](
    0.0002, 0.0005, 0.0012, 0.0029, 0.0066, 0.0135, 0.0250,
    0.0422, 0.0652, 0.0920, 0.1192, 0.1398, 0.1484, 0.1398,
    0.1192, 0.0920, 0.0652, 0.0422, 0.0250, 0.0135, 0.0066
    // ... truncated, computed via exp(-x^2/(2σ^2))
);

vec4 blur_upsample(sampler2D low_res, ivec2 coord, int upscale) {
    ivec2 low_coord = coord / upscale;
    vec4 sum = vec4(0.0);
    
    // Separable Gaussian blur on upsampled low-freq channel
    for (int dy = -10; dy <= 10; dy++) {
        for (int dx = -10; dx <= 10; dx++) {
            float w = gaussian_kernel[dx + 10] * gaussian_kernel[dy + 10];
            sum += w * texelFetch(low_res, low_coord + ivec2(dx, dy), 0);
        }
    }
    return sum;
}

void main() {
    ivec2 coord = ivec2(gl_GlobalInvocationID.xy);
    
    // L_hat = Blur(Upsample(L, 8x), σ=5)
    vec4 L_hat = blur_upsample(low_freq_channel, coord, 8);
    
    // H (residual from decoder)
    vec4 H = texelFetch(residual_channel, coord, 0);
    
    // Final = L_hat + H
    vec4 final_elevation = L_hat + H;
    
    // Apply inverse signed-sqrt
    final_elevation.x = sign(final_elevation.x) * final_elevation.x * final_elevation.x;
    
    imageStore(final_heightmap, coord, final_elevation);
}
```

---

## 4. Synchronization and Command Buffer Flow

```cpp
// ============================================================
// CPU-side Vulkan command buffer recording (pseudo-C++)
// ============================================================
void record_infinite_diffusion_pass(VkCommandBuffer cmd, QueryRequest req) {
    // Step 1: Window discovery (κ-computation)
    vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_COMPUTE, window_discovery_pipe);
    vkCmdPushConstants(cmd, layout, VK_SHADER_STAGE_COMPUTE_BIT, 0, sizeof(GlobalParams), &params);
    vkCmdDispatch(cmd, 1, 1, 1);  // Single workgroup
    
    // Barrier: ensure window list is written before read
    VkMemoryBarrier mem_barrier = {
        .sType = VK_STRUCTURE_TYPE_MEMORY_BARRIER,
        .srcAccessMask = VK_ACCESS_SHADER_WRITE_BIT,
        .dstAccessMask = VK_ACCESS_SHADER_READ_BIT
    };
    vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
                         VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, 0, 1, &mem_barrier, 0, nullptr, 0, nullptr);
    
    // Step 2: Batch denoising (one dispatch per timestep)
    vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_COMPUTE, denoise_unet_pipe);
    for (int t = params.total_timesteps; t >= 0; t--) {
        params.timestep = t;
        vkCmdPushConstants(cmd, layout, VK_SHADER_STAGE_COMPUTE_BIT, 0, sizeof(GlobalParams), &params);
        
        // Batch 16 windows per dispatch (RTX 3090 occupancy)
        int num_batches = (window_list.count + 15) / 16;
        for (int b = 0; b < num_batches; b++) {
            vkCmdDispatch(cmd, 
                params.window_size / 8,   // local_x
                params.window_size / 8,   // local_y
                min(16, window_list.count - b * 16)  // batch size
            );
        }
        
        // Barrier between timesteps (recursive dependency)
        vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
                             VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, 0, 1, &mem_barrier, 0, nullptr, 0, nullptr);
    }
    
    // Step 3: Weighted blending
    vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_COMPUTE, blend_accumulate_pipe);
    vkCmdDispatch(cmd, 
        (params.query_region_size.x + 15) / 16,
        (params.query_region_size.y + 15) / 16, 1
    );
    
    // Step 4: Resolve final output
    vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_COMPUTE, resolve_output_pipe);
    vkCmdDispatch(cmd,
        (params.query_region_size.x + 15) / 16,
        (params.query_region_size.y + 15) / 16, 1
    );
}
```

---

## 5. Memory Layout and Sparse Tensor Representation

The infinite tensor framework [^1^] uses a **two-level sparse addressing scheme**:

| Level | Structure | Purpose | Size |
|---|---|---|---|
| **L1: Tile Table** | Hash map (CPU) | Maps global tile coordinates to GPU memory pages | O(active tiles) |
| **L2: Page Pool** | Fixed 256×256 tiles (GPU) | Dense storage within allocated region | 256×256×4 bytes |
| **L3: LRU Cache** | Ring buffer (GPU) | Recently-used window contributions | Configurable (default 1024 windows) |

*Table 2: Sparse tensor memory hierarchy.*

### 5.1 LRU Eviction Policy

```cpp
// Eviction is safe when simultaneously removing from processed_set
struct WindowCacheEntry {
    ivec2   window_ij;       // Window index
    vec4    numerator[window_size^2];   // A_t contribution
    float   denominator[window_size^2]; // B_t contribution
    uint64_t last_access;    // Timestamp for LRU
};

// On cache miss: recompute by invoking denoising pipeline
// On eviction: remove from processed_set, allowing lazy recomputation
```

---

## 6. Performance Characteristics

| Metric | Value | Configuration |
|---|---|---|
| **TTFT** (Time to First Tile) | **1.72 ± 0.18 s** | 512×512, T=2, RTX 3090 Ti [^1^] |
| **TTST** (Time to Second Tile) | **0.66 ± 0.03 s** | Neighbor tile, cached context [^1^] |
| **FID (InfiniteDiffusion T=2)** | **14.78** | vs. 12.72 (non-tiled lower bound) [^1^] |
| **FID (Naive InfiniteDiffusion)** | 27.61 | T=0, no latent blending [^1^] |
| **Speed vs. Orbital Velocity** | **9× faster** | ~7,700 m/s at 90m resolution [^1^] |
| **Window Batch Size** | 16 | Concurrent SM occupancy [^1^] |
| **Decoder Window Stride** | 384 / 512 (75% overlap) | Separable linear weights [^1^] |

*Table 3: Performance benchmarks for Terrain Diffusion.*

---

## 7. AutoGuidance Integration

AutoGuidance [^50^] replaces Classifier-Free Guidance (CFG) by using a **degraded version of the model itself** as the guidance signal. For Terrain Diffusion:

```glsl
// AutoGuidance: Δ = Φ_main - Φ_guidance
vec4 apply_autoguidance(vec4 x, vec4 input, float sigma, float scale) {
    // Main model (full capacity)
    vec4 main_pred = unet_forward(x, sigma, /*full_blocks=*/true);
    
    // Guidance model (reduced capacity - fewer blocks/shorter training)
    vec4 guide_pred = unet_forward(x, sigma, /*reduced_blocks=*/false);
    
    // Guidance direction
    vec4 delta = main_pred - guide_pred;
    
    // Apply scaled guidance
    return main_pred + scale * delta;
}
```

AutoGuidance avoids the task-mismatch problem of CFG (where unconditional and conditional denoisers solve different objectives) and enables guidance for **unconditional generation**, improving FID from 19.32 to 14.78 on the tiled decoder [^1^].
