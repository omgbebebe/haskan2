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

module BindlessShader where

import FIR
import Math.Linear

type Defs
  =  '[ "textures" ':-> BindlessTexture2D '[ Binding 0, DescriptorSet 0 ] (RGBA8 UNorm)
      , "out_col"  ':-> Output     '[ Location 0 ] (V 4 Float)
      , "main"     ':-> EntryPoint '[ OriginLowerLeft ] Fragment
      ]

program :: Module Defs
program =
  Module $ entryPoint @"main" @Fragment do
    put @"out_col" (Vec4 1 0 0 1 :: Code (V 4 Float))
