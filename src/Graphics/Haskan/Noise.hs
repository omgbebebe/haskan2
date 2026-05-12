module Graphics.Haskan.Noise
  ( generateCloudNoise
  , CloudNoiseParams(..)
  , defaultCloudParams
  ) where

import Data.Word (Word8)
import Data.Vector.Storable (Vector)
import Data.Vector.Storable qualified as V
import System.Random (RandomGen, randomR, mkStdGen)

-- | Parameters for cloud noise generation
data CloudNoiseParams = CloudNoiseParams
  { cnpSeed :: !Int
  , cnpOctaves :: !Int
  , cnpPersistence :: !Float
  , cnpScale :: !Float
  , cnpThreshold :: !Float
  }
  deriving (Show)

defaultCloudParams :: CloudNoiseParams
defaultCloudParams = CloudNoiseParams
  { cnpSeed = 42
  , cnpOctaves = 4
  , cnpPersistence = 0.5
  , cnpScale = 4.0
  , cnpThreshold = 0.45
  }

-- | Generate a 256x256 cloud noise texture (RGBA8)
-- Returns vector of Word8 pixels [R,G,B,A,...]
generateCloudNoise :: CloudNoiseParams -> Vector Word8
generateCloudNoise params =
  let size = 256
      gen = mkStdGen (cnpSeed params)
      -- Precompute random gradients for value noise
      gradients = V.fromList $ take (size * size) $ randomFloats gen
      
      pixelAt x y =
        let nx = fromIntegral x / fromIntegral size
            ny = fromIntegral y / fromIntegral size
            -- FBM noise
            noiseVal = fbm params gradients nx ny
            -- Cloud coverage: smoothstep threshold
            coverage = smoothstep (cnpThreshold params) (cnpThreshold params + 0.3) noiseVal
            -- Cloud color: white with soft edges
            alpha = round (coverage * 255) :: Word8
            brightness = round ((0.7 + 0.3 * coverage) * 255) :: Word8
        in [brightness, brightness, brightness, alpha]
      
      pixels = concat [pixelAt x y | y <- [0..size-1], x <- [0..size-1]]
  in V.fromList pixels

-- Simple value noise with FBM
fbm :: CloudNoiseParams -> Vector Float -> Float -> Float -> Float
fbm params grads nx ny =
  let octaves = cnpOctaves params
      persistence = cnpPersistence params
      scale = cnpScale params
      go :: Int -> Float -> Float -> Float -> Float
      go 0 _ _ acc = acc
      go n amp freq acc =
        let v = valueNoise grads (nx * freq * scale) (ny * freq * scale)
        in go (n-1) (amp * persistence) (freq * 2) (acc + amp * v)
  in go octaves 1.0 1.0 0.0

-- Value noise: bilinear interpolation of grid values
valueNoise :: Vector Float -> Float -> Float -> Float
valueNoise grads nx ny =
  let size = 256
      x = nx - fromIntegral (floor nx)
      y = ny - fromIntegral (floor ny)
      ix = floor (x * fromIntegral size) `mod` size
      iy = floor (y * fromIntegral size) `mod` size
      fx = x * fromIntegral size - fromIntegral ix
      fy = y * fromIntegral size - fromIntegral iy
      
      -- Bilinear interpolation of 4 corners
      i00 = (iy * size + ix) `mod` V.length grads
      i10 = (iy * size + ((ix + 1) `mod` size)) `mod` V.length grads
      i01 = (((iy + 1) `mod` size) * size + ix) `mod` V.length grads
      i11 = (((iy + 1) `mod` size) * size + ((ix + 1) `mod` size)) `mod` V.length grads
      
      v00 = grads V.! i00
      v10 = grads V.! i10
      v01 = grads V.! i01
      v11 = grads V.! i11
      
      v0 = lerp fx v00 v10
      v1 = lerp fx v01 v11
  in lerp fy v0 v1

lerp :: Float -> Float -> Float -> Float
lerp t a b = a + (b - a) * t

smoothstep :: Float -> Float -> Float -> Float
smoothstep edge0 edge1 x =
  let t = clamp ((x - edge0) / (edge1 - edge0)) 0.0 1.0
  in t * t * (3.0 - 2.0 * t)

clamp :: Float -> Float -> Float -> Float
clamp lo hi x = max lo (min hi x)

randomFloats :: RandomGen g => g -> [Float]
randomFloats g =
  let (v, g') = randomR (0.0, 1.0) g
  in v : randomFloats g'
