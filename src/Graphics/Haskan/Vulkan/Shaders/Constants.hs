{-# LANGUAGE OverloadedStrings #-}

-- | Centralized shader constants for cloud/weather rendering.
--
-- These values are used by both FIR shader EDSL code (via RebindableSyntax)
-- and host-side Haskell code. Since FIR shaders are compiled as Haskell,
-- regular top-level bindings work in shader modules too.
module Graphics.Haskan.Vulkan.Shaders.Constants
  ( -- * Cloud geometry
    cloudThickness,
    cloudBaseOffset,
    cloudTopOffset,

    -- * Ray marching
    maxRayLength,
    baseStepSize,
    stepCountF,
    growthRate,
    maxStepSize,
    detailFadeStart,
    detailFadeEnd,
    lodScale,
    maxNoiseLod,

    -- * Noise sampling
    noiseScale,
    noiseWindSpeed,
    warpAmpWorld1,
    warpAmpWorld2,

    -- * Weather map
    weatherMapSize,
    weatherMapScale,
    weatherMapMaxSampleDist,
    weatherWindAnimSpeed,

    -- * Lighting / scattering
    ambientStrength,
    phaseHGForward,
    phaseHGBack,
    phaseMixForward,
    phaseMixBack,
    powderStrength,
    internalScatterBoost,
    earthRadius,

    -- * Temporal reprojection
    reprojBlendBase,
    reprojBlendNear,
    reprojDistFadeStart,
    reprojDistFadeEnd,
    reprojBrightFadeStart,
    reprojBrightFadeEnd,
    reprojGhostThreshold,
    reprojGhostMaxDiff,

    -- * Sky scattering
    rayleighOD,
    mieOD,
    rayleighScatterR,
    rayleighScatterG,
    rayleighScatterB,
    mieScatterBase,
    sunDiscIntensity,
    gMie,

    -- * Debug
    debugModeWeather,
    debugModeHeightMask,
    debugModeRawNoise,
    debugModeCloudDensity,
  )
where

-- ---------------------------------------------------------------------------
-- Cloud geometry
-- ---------------------------------------------------------------------------

cloudThickness :: Float
cloudThickness = 800.0

cloudBaseOffset :: Float
cloudBaseOffset = 300.0

cloudTopOffset :: Float
cloudTopOffset = 300.0

-- ---------------------------------------------------------------------------
-- Ray marching
-- ---------------------------------------------------------------------------

maxRayLength :: Float
maxRayLength = 5000.0

baseStepSize :: Float
baseStepSize = 30.0

stepCountF :: Float
stepCountF = 96.0

growthRate :: Float
growthRate = 1.03

maxStepSize :: Float
maxStepSize = 300.0

detailFadeStart :: Float
detailFadeStart = 500.0

detailFadeEnd :: Float
detailFadeEnd = 2500.0

lodScale :: Float
lodScale = 400.0

maxNoiseLod :: Float
maxNoiseLod = 2.0

-- ---------------------------------------------------------------------------
-- Noise sampling
-- ---------------------------------------------------------------------------

noiseScale :: Float
noiseScale = 0.00015

noiseWindSpeed :: Float
noiseWindSpeed = 0.05

warpAmpWorld1 :: Float
warpAmpWorld1 = 500.0

warpAmpWorld2 :: Float
warpAmpWorld2 = 250.0

-- ---------------------------------------------------------------------------
-- Weather map
-- ---------------------------------------------------------------------------

weatherMapSize :: Int
weatherMapSize = 1024

weatherMapScale :: Float
weatherMapScale = 0.00002

weatherMapMaxSampleDist :: Float
weatherMapMaxSampleDist = 5000.0

weatherWindAnimSpeed :: Float
weatherWindAnimSpeed = 0.002

-- ---------------------------------------------------------------------------
-- Lighting / scattering
-- ---------------------------------------------------------------------------

ambientStrength :: Float
ambientStrength = 0.12

phaseHGForward :: Float
phaseHGForward = 0.6

phaseHGBack :: Float
phaseHGBack = (-0.3)

phaseMixForward :: Float
phaseMixForward = 0.7

phaseMixBack :: Float
phaseMixBack = 0.3

powderStrength :: Float
powderStrength = 2.0

internalScatterBoost :: Float
internalScatterBoost = 1.0

earthRadius :: Float
earthRadius = 6371000.0

-- ---------------------------------------------------------------------------
-- Temporal reprojection
-- ---------------------------------------------------------------------------

reprojBlendBase :: Float
reprojBlendBase = 0.3

reprojBlendNear :: Float
reprojBlendNear = 0.2

reprojDistFadeStart :: Float
reprojDistFadeStart = 200.0

reprojDistFadeEnd :: Float
reprojDistFadeEnd = 1500.0

reprojBrightFadeStart :: Float
reprojBrightFadeStart = 5.0

reprojBrightFadeEnd :: Float
reprojBrightFadeEnd = 30.0

reprojGhostThreshold :: Float
reprojGhostThreshold = 0.05

reprojGhostMaxDiff :: Float
reprojGhostMaxDiff = 0.3

-- ---------------------------------------------------------------------------
-- Sky scattering
-- ---------------------------------------------------------------------------

rayleighOD :: Float
rayleighOD = 0.3

mieOD :: Float
mieOD = 0.1

rayleighScatterR :: Float
rayleighScatterR = 0.0058

rayleighScatterG :: Float
rayleighScatterG = 0.0135

rayleighScatterB :: Float
rayleighScatterB = 0.0331

mieScatterBase :: Float
mieScatterBase = 0.021

sunDiscIntensity :: Float
sunDiscIntensity = 50.0

gMie :: Float
gMie = 0.76

-- ---------------------------------------------------------------------------
-- Debug modes
-- ---------------------------------------------------------------------------

debugModeWeather :: Float
debugModeWeather = 13.0

debugModeHeightMask :: Float
debugModeHeightMask = 14.0

debugModeRawNoise :: Float
debugModeRawNoise = 15.0

debugModeCloudDensity :: Float
debugModeCloudDensity = 16.0
