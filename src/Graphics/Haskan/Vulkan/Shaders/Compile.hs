{-# LANGUAGE TemplateHaskell #-}

-- |
-- Module: Graphics.Haskan.Vulkan.Shaders.Compile
--
-- This module forces all FIR shaders to be compiled to SPIR-V at build time
-- via Template Haskell. If any shader has compilation errors, cabal build will
-- fail immediately rather than deferring the error to runtime.
--
-- Import this module anywhere that gets compiled (e.g. in Setup.hs) to ensure
-- shaders are validated during the build.
module Graphics.Haskan.Vulkan.Shaders.Compile () where

import FIR qualified
-- Import all shader modules
import Graphics.Haskan.Vulkan.Shaders.Compute.APVolume qualified as APVolume
import Graphics.Haskan.Vulkan.Shaders.Compute.CloudDetailNoiseGen qualified as CloudDetailNoiseGen
import Graphics.Haskan.Vulkan.Shaders.Compute.CloudNoiseGen qualified as CloudNoiseGen
import Graphics.Haskan.Vulkan.Shaders.Compute.CloudNoiseMipGen qualified as CloudNoiseMipGen
import Graphics.Haskan.Vulkan.Shaders.Compute.Cull qualified as Cull
import Graphics.Haskan.Vulkan.Shaders.Compute.IrradianceGen qualified as IrradianceGen
import Graphics.Haskan.Vulkan.Shaders.Compute.RadianceGen qualified as RadianceGen
import Graphics.Haskan.Vulkan.Shaders.Compute.WeatherMapGen qualified as WeatherMapGen
import Graphics.Haskan.Vulkan.Shaders.Deferred.Clouds qualified as Clouds
import Graphics.Haskan.Vulkan.Shaders.Deferred.GBuffer qualified as GBuffer
import Graphics.Haskan.Vulkan.Shaders.Deferred.GodRays qualified as GodRays
import Graphics.Haskan.Vulkan.Shaders.Deferred.Lighting qualified as Lighting
import Graphics.Haskan.Vulkan.Shaders.Deferred.LightingProcedural qualified as LightingProcedural
import Graphics.Haskan.Vulkan.Shaders.Forward.SimpleForward qualified as SimpleForward
import Graphics.Haskan.Vulkan.Shaders.TH (compileShader)
import Graphics.Haskan.Vulkan.Shaders.Texture qualified as TextureShader
import Graphics.Haskan.Vulkan.Shaders.Wireframe qualified as Wireframe

-- Compile all shaders at build time
$(compileShader "data/shaders/fir/vert.spv" [FIR.SPIRV (FIR.Version 1 5), FIR.Optimize] TextureShader.vertex)

$(compileShader "data/shaders/fir/frag.spv" [FIR.SPIRV (FIR.Version 1 5), FIR.Optimize] TextureShader.fragment)

$(compileShader "data/shaders/fir/gbuf_vert.spv" [FIR.SPIRV (FIR.Version 1 5), FIR.Optimize] GBuffer.vertex)

$(compileShader "data/shaders/fir/gbuf_frag.spv" [FIR.SPIRV (FIR.Version 1 5), FIR.Optimize] GBuffer.fragment)

$(compileShader "data/shaders/fir/light_vert.spv" [FIR.SPIRV (FIR.Version 1 5), FIR.Optimize] Lighting.vertex)

$(compileShader "data/shaders/fir/light_frag.spv" [FIR.SPIRV (FIR.Version 1 5), FIR.Optimize] Lighting.fragment)

$(compileShader "data/shaders/fir/light_procedural_frag.spv" [FIR.SPIRV (FIR.Version 1 5), FIR.Optimize] LightingProcedural.fragment)

$(compileShader "data/shaders/fir/wire_vert.spv" [FIR.SPIRV (FIR.Version 1 5), FIR.Optimize] Wireframe.vertex)

$(compileShader "data/shaders/fir/wire_geom.spv" [FIR.SPIRV (FIR.Version 1 5), FIR.Optimize] Wireframe.geometry)

$(compileShader "data/shaders/fir/wire_frag.spv" [FIR.SPIRV (FIR.Version 1 5), FIR.Optimize] Wireframe.fragment)

$(compileShader "data/shaders/fir/cull_comp.spv" [FIR.SPIRV (FIR.Version 1 5), FIR.Optimize] Cull.program)

$(compileShader "data/shaders/fir/cloud_noise_comp.spv" [FIR.SPIRV (FIR.Version 1 5), FIR.Optimize] CloudNoiseGen.program)

$(compileShader "data/shaders/fir/cloud_noise_mipgen_comp.spv" [FIR.SPIRV (FIR.Version 1 5), FIR.Optimize] CloudNoiseMipGen.program)

$(compileShader "data/shaders/fir/cloud_detail_noise_comp.spv" [FIR.SPIRV (FIR.Version 1 5), FIR.Optimize] CloudDetailNoiseGen.program)

$(compileShader "data/shaders/fir/weather_map_comp.spv" [FIR.SPIRV (FIR.Version 1 5), FIR.Optimize] WeatherMapGen.program)

$(compileShader "data/shaders/fir/radiance_comp.spv" [FIR.SPIRV (FIR.Version 1 5), FIR.Optimize] RadianceGen.program)

$(compileShader "data/shaders/fir/irradiance_comp.spv" [FIR.SPIRV (FIR.Version 1 5), FIR.Optimize] IrradianceGen.program)

$(compileShader "data/shaders/fir/cloud_vert.spv" [FIR.SPIRV (FIR.Version 1 5), FIR.Optimize] Clouds.cloudVertex)

$(compileShader "data/shaders/fir/cloud_frag.spv" [FIR.SPIRV (FIR.Version 1 5), FIR.Optimize] Clouds.cloudFragment)

$(compileShader "data/shaders/fir/godray_vert.spv" [FIR.SPIRV (FIR.Version 1 5), FIR.Optimize] GodRays.vertex)

$(compileShader "data/shaders/fir/godray_frag.spv" [FIR.SPIRV (FIR.Version 1 5), FIR.Optimize] GodRays.fragment)

$(compileShader "data/shaders/fir/ap_volume_comp.spv" [FIR.SPIRV (FIR.Version 1 5), FIR.Optimize] APVolume.program)

$(compileShader "data/shaders/fir/simple_forward_vert.spv" [FIR.SPIRV (FIR.Version 1 5), FIR.Optimize] SimpleForward.vertex)

$(compileShader "data/shaders/fir/simple_forward_frag.spv" [FIR.SPIRV (FIR.Version 1 5), FIR.Optimize] SimpleForward.fragment)
