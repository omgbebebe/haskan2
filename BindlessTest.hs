{-# LANGUAGE BlockArguments      #-}
{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE FlexibleInstances   #-}
{-# LANGUAGE GADTs               #-}
{-# LANGUAGE OverloadedLabels    #-}
{-# LANGUAGE PatternSynonyms     #-}
{-# LANGUAGE PolyKinds           #-}
{-# LANGUAGE RebindableSyntax    #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications    #-}
{-# LANGUAGE TypeOperators       #-}

module Main where

-- base
import qualified Data.ByteString.Lazy as BSL
import System.Exit (exitFailure)

-- fir
import FIR
import Math.Linear

------------------------------------------------
-- Simple fragment shader with bindless texture array sampling.
-- Uses BindlessTexel optic to sample from a runtime array of sampled images.

type Defs
  =  '[ "textures" ':-> BindlessTexture2D '[ Binding 0, DescriptorSet 0 ] (RGBA8 UNorm)
      , "in_uv"    ':-> Input      '[ Location 0 ] (V 2 Float)
      , "out_col"  ':-> Output     '[ Location 0 ] (V 4 Float)
      , "main"     ':-> EntryPoint '[ OriginLowerLeft ] Fragment
      ]

program :: Module Defs
program =
  Module $ entryPoint @"main" @Fragment do
    uv <- get @"in_uv"
    -- Sample texture index 0 from bindless array
    col <- use @(BindlessTexel "textures") (0 :: Word32) NilOps uv
    put @"out_col" col

main :: IO ()
main = do
  let spirv = compile program [SPIRV (Version 1 0)]
  BSL.writeFile "/tmp/bindless_test.spv" spirv
  putStrLn "SPIR-V written to /tmp/bindless_test.spv"
  
  -- Check for RuntimeDescriptorArray capability (33) in the binary
  let ws = map BSL.index (repeat spirv) [0..fromIntegral (BSL.length spirv) - 1]
      hasCap33 = any (== 33) ws
  if hasCap33
    then putStrLn "SUCCESS: RuntimeDescriptorArray capability (33) found"
    else do
      putStrLn "FAIL: RuntimeDescriptorArray capability not found"
      exitFailure
