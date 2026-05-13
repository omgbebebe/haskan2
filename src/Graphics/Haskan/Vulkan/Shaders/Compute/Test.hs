{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE RebindableSyntax #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}

module Graphics.Haskan.Vulkan.Shaders.Compute.Test
  ( program,
  )
where

import FIR
import Math.Linear

-- Minimal compute shader: increments a counter in a storage buffer.
-- Used to validate compute pipeline infrastructure.

type CounterStruct = Struct '["value" ':-> Word32]

type Defs =
  '[ "counter" ':-> StorageBuffer '[DescriptorSet 0, Binding 0] CounterStruct,
     "main" ':-> EntryPoint '[LocalSize 1 1 1] Compute
   ]

program :: Module Defs
program = Module $ entryPoint @"main" @Compute do
  -- Read current counter value
  count <- use @(Name "counter" :.: Name "value")
  -- Increment by 1
  assign @(Name "counter" :.: Name "value") (count + 1)
