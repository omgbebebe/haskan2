# Related Work, Extensions, and Comprehensive Overview of InfiniteDiffusion

## Executive Summary

InfiniteDiffusion [^13^] represents a watershed moment in procedural content generation: it is the first method to achieve **learned fidelity** (diffusion-model quality) with **procedural utility** (infinite extent, seed consistency, O(1) random access). This document surveys the research landscape that preceded, enables, and extends this work. We cover **seven foundational papers** that directly improve upon or complement the InfiniteDiffusion approach, organized by their relationship to the core algorithm: (1) MultiDiffusion [^35^] as the direct predecessor, (2) DemoFusion [^16^] for high-resolution progressive generation, (3) BlockFusion [^34^] for autoregressive 3D scene extension, (4) MESA [^23^] for text-driven terrain with optical co-registration, (5) SynCity [^39^] for training-free 3D world generation, (6) WonderWorld [^42^] for interactive scene extrapolation, and (7) EDM2+/AutoGuidance [^51^][^50^] as architectural backbones. The overview section positions InfiniteDiffusion within the broader trajectory from Perlin noise (1985) to modern neural procedural generation, identifies current limitations, and projects future research directions.

---

## 1. Direct Predecessors and Foundations

### 1.1 MultiDiffusion: Fusing Diffusion Paths (Bar-Tal et al., 2023)

MultiDiffusion [^35^] is the immediate technical foundation of InfiniteDiffusion. It reformulates diffusion sampling as an optimization problem that binds multiple local diffusion processes with shared parameters:

```tex
\Psi(J_t \mid z) = \arg\min_{J \in \mathcal{J}} \sum_{i=1}^{n} \|W_i \otimes [F_i(J) - \Phi(I_t^i \mid y_i)]\|^2
```

The closed-form solution is a **weighted average** of all local denoising predictions, where each window contributes according to its weight map $W_i$. MultiDiffusion enabled panorama generation, aspect-ratio control, and spatial mask-guided synthesis without retraining [^29^].

| Property | MultiDiffusion | InfiniteDiffusion |
|---|---|---|
| **Domain** | Finite, bounded | Infinite, unbounded |
| **Window count** | Fixed $n$ | Countably infinite |
| **Evaluation** | Full canvas, all windows | Lazy, region-only |
| **Seed consistency** | Implicit | Formal guarantee |
| **Random access** | $O(n)$ | $O(1)$ per window |
| **Cache mechanism** | None | Sparse infinite tensors + LRU |

*Table 1: MultiDiffusion vs. InfiniteDiffusion comparison.*

MultiDiffusion's critical limitation—confinement to bounded domains—motivated InfiniteDiffusion's reformulation. The key insight of Goslin [^1^] was recognizing that the weighted average in Equation (1) could be evaluated **lazily** by maintaining sparse accumulators $A_t$ and $B_t$, and that the infinite sum reduces to a finite sum over $\kappa(R)$ for any bounded query region $R$.

### 1.2 EDM2: Analyzing and Improving Training Dynamics (Karras et al., 2024)

The EDM2 architecture [^51^] serves as the backbone for all models in the Terrain Diffusion pipeline. It standardizes magnitudes of network weights, activations, and gradients through a magnitude-preserving (MP) design paradigm. Key innovations include:

- **MP-Conv**: Convolutions with input activation normalization ($\text{RMS}(x) = \sqrt{\mathbb{E}[x^2] + \epsilon}$)
- **PixelNorm on embeddings**: Conditioning vectors are L2-normalized before injection
- **Positional embeddings**: Replace Fourier features for improved training stability

The Terrain Diffusion paper further modifies EDM2 following sCM (Lu and Song, 2025) [^53^] by implementing pixel-norm on embedding vectors and substituting Fourier embeddings with positional embeddings. These modifications are essential for the few-step consistency distillation that enables real-time performance.

### 1.3 AutoGuidance: Guiding with a Bad Version of Itself (Karras et al., 2024)

AutoGuidance [^50^] replaces Classifier-Free Guidance (CFG) with a **degraded copy of the model** as the guidance signal. Traditional CFG requires training both conditional and unconditional denoisers, which solve different objectives and can cause distribution overshoot. AutoGuidance avoids this by using a smaller, less-trained version of the same conditional model:

```tex
\hat{x} = \Phi_{\text{main}}(x_t, c) + s \cdot (\Phi_{\text{main}}(x_t, c) - \Phi_{\text{guide}}(x_t, c))
```

For Terrain Diffusion, AutoGuidance improves FID from **19.32 to 14.78** on the tiled decoder [^1^], a **24% relative improvement**. It also enables guidance for unconditional generation, which is critical since the terrain generation process has no text conditioning at the decoder stage.

---

## 2. Methods that Improve or Extend the Approach

### 2.1 DemoFusion: Democratising High-Resolution Generation (Du et al., 2024)

DemoFusion [^16^] addresses a key limitation shared by MultiDiffusion and InfiniteDiffusion: **repetitive content generation** when poorly conditioned. It introduces three complementary mechanisms for progressive high-resolution generation:

| Mechanism | Purpose | InfiniteDiffusion Relevance |
|---|---|---|
| **Progressive Upscaling** | Upsample-diffuse-denoise loop at increasing resolutions | Could enable deeper cascade levels |
| **Skip Residual** | Low-resolution noise inversion as global guidance | Applicable to coarse-to-fine hierarchy |
| **Dilated Sampling** | Global denoising paths with wider context | Improves long-range coherence at T=1 |

DemoFusion achieves **4×-16× resolution** beyond a model's native resolution without tuning [^20^]. For Terrain Diffusion, adopting DemoFusion's dilated sampling could reduce the required blending steps $T$ from 2 to 1 while maintaining quality, directly improving TTFT. The progressive upscaling mechanism could also replace the current fixed three-stage hierarchy with a more flexible depth-adaptive approach.

### 2.2 BlockFusion: Expandable 3D Scene Generation (Wu et al., 2024)

BlockFusion [^34^] generates 3D scenes as unit blocks and seamlessly incorporates new blocks via **latent tri-plane extrapolation**. It converts training blocks into hybrid neural fields (tri-plane + MLP for SDF), compresses tri-planes via VAE, and performs diffusion in the latent tri-plane space. New blocks are generated by conditioning on overlapping tri-plane features during denoising.

BlockFusion is an **auto-regressive** method: each block conditions on previously generated neighbors, producing continuous worlds but **without seed consistency**—outputs depend on sampling order [^1^]. This contrasts sharply with InfiniteDiffusion's order-invariant, seed-consistent generation. However, BlockFusion's tri-plane representation and extrapolation mechanism could inspire voxel-based extensions of InfiniteDiffusion for **3D terrain** (volumetric caves, overhangs) rather than 2.5D heightmaps.

### 2.3 MESA: Text-Driven Terrain with Co-Registered Output (Borne-Pons et al., 2025)

MESA [^23^] is the closest conceptual peer to Terrain Diffusion. It trains a latent diffusion model (based on Stable Diffusion 2.1) on global Copernicus data, generating **co-registered optical imagery and elevation maps** from text prompts:

```tex
\hat{x}_I = D(\hat{z}_I), \quad \hat{x}_D = D(\hat{z}_D)
```

| Feature | MESA | Terrain Diffusion |
|---|---|---|
| **Architecture** | Stable Diffusion 2.1 | EDM2 + sCM custom stack |
| **Conditioning** | Text (biome/country/season) | Climate + procedural noise |
| **Output** | RGB + DEM (bounded) | Elevation only (infinite) |
| **Scale** | Fixed tile size | Planetary, infinite |
| **Speed** | ~50 steps (minutes) | 2-step consistency (0.66s TTST) |
| **Dataset** | Major TOM Core-DEM (global) | MERIT DEM + ETOPO1 + WorldClim |

*Table 2: MESA vs. Terrain Diffusion comparison.*

The key differentiator is InfiniteDiffusion's algorithmic contribution: MESA generates fixed tiles, while Terrain Diffusion generates an **infinite, queryable domain**. A promising research direction is combining MESA's joint RGB+DEM generation with InfiniteDiffusion's unbounded sampling, producing photorealistic infinite worlds with aligned satellite-like textures.

### 2.4 SynCity: Training-Free Generation of 3D Worlds (Engstler et al., 2025)

SynCity [^39^] generates explorable 3D worlds from text without any training or optimization. It combines the **2D image generator Flux** (for artistic diversity) with the **3D generator TRELLIS** (for geometric precision) in a tile-by-tile construction:

1. Generate each tile as a 2D image with context from adjacent tiles
2. Convert the tile into a 3D model via TRELLIS
3. Blend adjacent tiles seamlessly using image inpainting

SynCity's training-free approach contrasts with Terrain Diffusion's extensive training pipeline (~2 weeks on RTX 3090 Ti) [^1^]. However, SynCity's tile generation is **sequential and order-dependent**, lacking InfiniteDiffusion's O(1) random-access guarantee. For applications requiring deterministic, seed-consistent worlds (e.g., multiplayer games), InfiniteDiffusion's formal properties are essential.

### 2.5 WonderWorld: Interactive 3D Scene Extrapolation (Yu et al., 2025)

WonderWorld [^42^] enables **interactive 3D scene generation** from a single image, producing connected scenes in **< 10 seconds** on a single A6000 GPU. Its core technical contributions are:

- **Fast Layered Gaussian Surfels (FLAGS)**: A surfel-based representation with geometry-based initialization reducing optimization to **< 1 second**
- **Guided depth diffusion**: Partial conditioning of depth estimation to ensure geometric alignment between scenes
- **Layer-wise generation**: Decomposing scenes into foreground/background/sky layers, inpainting each separately

WonderWorld targets **scene-level** generation (rooms, streets, landscapes) rather than terrain-scale worlds. Its FLAGS representation and guided diffusion could enhance Terrain Diffusion's decoder stage by providing principled geometry initialization for the elevation outputs. The guided depth diffusion mechanism is particularly relevant for maintaining geometric consistency across adjacent tiles in the infinite domain.

### 2.6 EDM2+: Efficient Diffusion Architecture (ICLR 2025)

EDM2+ [^51^] explores the design space of efficient U-Net based diffusion models, identifying key principles:

- **Decompose spatial/channel mixing**: Depthwise → Pointwise convolutions
- **Shift computation to channel dimension**: Reduces FLOPs without quality loss
- **Contract embedding network output dimension**: Concentrates conditioning information

These insights yield **2× compute reduction** without quality degradation. For Terrain Diffusion, adopting EDM2+ could halve the inference cost of the core latent model and decoder, potentially improving TTST from 0.66s to ~0.35s while maintaining the same perceptual quality.

---

## 3. Landscape of Related Terrain Generation Methods

### 3.1 GAN-Based Approaches

Prior to diffusion models, GANs dominated learned terrain generation [^3^][^4^]:

| Method | Year | Key Contribution | Limitation |
|---|---|---|---|
| Voulgaris et al. [^3^] | 2021 | GAN-based procedural terrain from POI data | Fixed crops, no tiling |
| Spick & Walker [^1^] | 2019 | Realistic textured terrain with spatial GAN | Bounded, region-specific |
| Beckham & Pal [^1^] | 2017 | First GAN terrain generation step | Low resolution, artifacts |
| Panagiotou & Charou [^4^] | 2020 | 3D point cloud + satellite image pairs | No infinite generation |

Terrain Diffusion surpasses all GAN-based approaches in both fidelity (FID **14.78** vs. 74.44 for naive tiling [^1^]) and functional properties (infinite extent vs. bounded crops).

### 3.2 Diffusion-Based Terrain Methods

| Method | Year | Approach | Infinite? | Seed-Consistent? |
|---|---|---|---|---|
| Hu et al. [^1^] | 2024 | Diffusion synthesis with erosion simulation | No | N/A |
| Borne-Pons et al. (MESA) [^23^] | 2025 | Text-conditioned latent diffusion | No | N/A |
| Jain et al. [^1^] | 2023 | Perlin-blended diffusion tiles | Yes (bounded context) | No |
| **Terrain Diffusion** [^1^] | **2026** | **InfiniteDiffusion + hierarchical stack** | **Yes** | **Yes** |

Jain et al.'s Perlin Blending [^1^] is the closest prior infinite terrain method, achieving FID of **186.70** compared to Terrain Diffusion's **14.78**—a **12.6× improvement**. Jain's approach generates tiles independently and blends with a Perlin-based kernel that has **no awareness of broader context**, so structure remains tied to Perlin noise rather than the learned model. Terrain Diffusion couples all tiles through shared global context and fuses via a fully learned, context-aware mechanism.

---

## 4. Comprehensive Summary and Positioning

### 4.1 What InfiniteDiffusion Achieves

InfiniteDiffusion occupies a unique position in the generative modeling landscape by achieving a **triple synthesis**:

1. **Fidelity of diffusion models**: Produces realistic terrain with FID 14.78, approaching the non-tiled lower bound of 12.72 [^1^]
2. **Utility of procedural noise**: Maintains seed-consistency, O(1) random access, and infinite extent—properties that made Perlin noise indispensable for 40 years
3. **Practical performance**: TTFT 1.72s, TTST 0.66s on consumer GPUs, outpacing orbital velocity by 9×

The formal properties proven in Appendix B [^1^]—**seed consistency** (order-invariant outputs), **constant-time access** (uniform $O(1)$ query complexity), and **parallelization** (independent window evaluations)—elevate the method from an engineering hack to a principled algorithmic contribution.

### 4.2 Technical Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    TERRAIN DIFFUSION PIPELINE                            │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  COARSE MODEL (23km/pixel)                                               │
│  ├── Input: Procedural noise / user sketch + climate data                │
│  ├── Model: EDM2 (no down/upsampling), T=1                               │
│  └── Output: 4×4 conditioning patches (mean elev, 5th percentile, mask)  │
│                              ↓                                           │
│  CORE LATENT MODEL (46km tile, 512² at 90m)                              │
│  ├── Input: Coarse conditioning + noise embedding                        │
│  ├── Model: EDM2 + sCM 2-step consistency + AutoGuidance                 │
│  ├── InfiniteDiffusion: T=2 blending steps, stride 32, batch 16          │
│  └── Output: 64×64 low-freq channel + residual latents                   │
│                              ↓                                           │
│  LAPLACIAN DENOISING                                                     │
│  ├── Decode (L+H) → provisional heightmap                                │
│  ├── Downsample 8× + blur (σ=5) → L̂                                     │
│  └── Redirect noise: Ĥ = (L+H) - Upsample(L̂)                            │
│                              ↓                                           │
│  DECODER (full 512² residual)                                            │
│  ├── Input: Residual latents (nearest-neighbor interpolated)             │
│  ├── Model: EDM2 + sCM 1-step, 512² windows, stride 384                  │
│  ├── InfiniteDiffusion: T=1 blending                                     │
│  └── Output: High-frequency residual H                                   │
│                              ↓                                           │
│  FINAL SYNTHESIS                                                         │
│  └── Output = L̂ + H (inverse signed-sqrt transform applied)             │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

### 4.3 Current Limitations and Open Problems

Despite its breakthroughs, several limitations remain [^1^]:

**Artifacts at low blending steps**: For ambiguous prompts/regions, T=2 can introduce visible artifacts. While T=5 typically resolves this, the additional overhead limits the use of few-step models and increases TTFT.

**Window-sized query granularity**: Unlike point-wise procedural noise, InfiniteDiffusion generates in windows, making queries for significantly smaller regions inefficient if uncached. This primarily impacts scattered point queries, leaving long-range biome searches unsupported.

**Coarsest-layer data acquisition**: Training data at the planetary scale (coarsest hierarchy layer) remains challenging. Synthetic data offers a promising avenue, effectively distilling any other model or simulation into an approximate procedural counterpart.

**3D structure limitation**: The current framework generates 2.5D heightmaps, unable to represent overhangs, caves, or vertical cliffs with true 3D structure. Extending InfiniteDiffusion to volumetric representations (voxels, tri-planes) is identified as future work.

### 4.4 Future Research Directions

Based on the surveyed literature, the highest-impact extensions include:

| Direction | Enabling Work | Expected Impact |
|---|---|---|
| **Volumetric InfiniteDiffusion** | BlockFusion [^34^] tri-planes | True 3D terrain (caves, overhangs) |
| **Joint RGB+DEM generation** | MESA [^23^] architecture | Aligned photorealistic textures |
| **Training-free world building** | SynCity [^39^] approach | Eliminate 2-week training cost |
| **Interactive scene + terrain fusion** | WonderWorld [^42^] FLAGS | User-driven world sculpting |
| **Efficient architecture** | EDM2+ [^51^] | 2× speedup, lower VRAM |
| **Reduced blending steps** | DemoFusion [^16^] dilated sampling | T=1 with T=2 quality |
| **3D Gaussian Splatting output** | WonderWorld surfels | Real-time rendering without meshing |

### 4.5 The Broader Significance

InfiniteDiffusion represents more than a terrain generation technique—it is a **general algorithm for unbounded diffusion sampling** applicable to any pixel or voxel-based diffusion model. The paper demonstrates this generality by first validating on standard text-to-image models (Stable Diffusion) before applying to terrain.

The method's amortized cost scaling—**O(S²) · a/(a-1) ≈ 1.33× per layer** for 4× super-resolution—independent of cascade depth, means that adding unlimited resolution to an infinite world is **nearly free**. This property is unique among ultra-high-resolution generation methods and positions diffusion models as a practical foundation for the next generation of infinite virtual worlds.

As Goslin notes in the paper's conclusion [^1^]: "Together, these components position diffusion models as a practical foundation for learned procedural worldbuilding and infinite generation in general." The method bridges four decades of procedural noise with the unprecedented fidelity of modern generative models, offering a path toward virtual worlds that are simultaneously infinite, deterministic, realistic, and interactive.
