# Revision history for haskan2

## 0.1.0.0 -- 2026-05-13

### M10: Scalable Lighting & Dynamic Atmosphere

* Multi-light SSBO with 256-light capacity (M10.1)
* Skybox background via fullscreen triangle cubemap sampling (M10.2)
* Dynamic day/night cycle with sun trajectory, sky tint, IBL modulation (M10.3)
* Volumetric clouds with ray marching, noise textures, HG phase (M10.4)
* Cloud shader modularization: separate pass with RGBA16F intermediate
* Quarter-resolution cloud rendering for performance
* Temporal accumulation with history buffer blending
* Blue-noise dithering, wind animation, dual-lobe HG, texture-sampled light march

### Infrastructure

* FIR optimization: spirv-opt integration, vectorized SelectionF/IfF
* FIR math extensions: clamp, mix, step, smoothstep, fract
* `Texture2D'` synonym for independent sampled/image format types
* Push constant layout fixes (std430 vec3 alignment)
* Compilation warning cleanup (partial functions, deprecations)
* Code formatting with ormolu

### Bug Fixes

* glTF UV flip fix (matches Vulkan top-left convention)
* BRDF LUT double-counting fix
* Skybox ray math fix (worldRot extraction, X-axis sign)
* Orbital camera: local right axis pitch, elevation clamping, slerp animation
* Y-down handling via negative viewport height
