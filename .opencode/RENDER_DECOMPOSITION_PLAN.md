# Render Loop Decomposition Plan

## Current State

`renderFrameLoop'` (lines 219-571) is a 352-line monolithic function with:
- 34-field `RenderEnv` destructuring (lines 220-253)
- 4 levels of case/if nesting
- ~10 distinct responsibilities mixed together

## Nesting Structure (current)

```
renderFrameLoop' = do
  destructure RenderEnv
  case maybeControlMessage of
    Nothing -> do                              -- LEVEL 1: main frame path
      prepareDebugInfo                         -- 50 lines of debug entity computation
      computeEntityData                        -- 35 lines of AABB/normal matrix computation
      computeCullData                          -- 15 lines of frustum/cull data
      uploadBuffers                            -- 4 lines
      case drawList of                         -- LEVEL 2
        [] -> pure (False, False)
        _  -> do
          computeSkyboxRays                    -- 5 lines
          readTVarState                        -- 7 lines
          let recordAction = do                -- LEVEL 3: IO callback (100 lines)
                buildPassContexts              -- 20 lines
                buildDeferredGraph             -- 30 lines
                computeCullDispatch            -- 15 lines
                recordPasses                   -- 10 lines
          res <- drawFrameGraphics
          case res of                          -- LEVEL 4: frame result
            FrameOk imageIndex -> do
              presentResult <- presentFrameGraphics
              case presentResult of            -- LEVEL 5: present result
                VK_SUCCESS -> do
                  handleInspector              -- 10 lines
                  handleScreenshots            -- 25 lines
                VK_SUBOPTIMAL -> ...
                VK_ERROR_OUT_OF_DATE -> ...
            FrameSuboptimal -> ...
            FrameOutOfDate -> ...
            FrameTimeout -> ...
            FrameFailed -> ...
    Just Terminate -> do                       -- LEVEL 1: termination
      ...

  -- tail: timing + loop
  if needRestart then ... else ...
```

## Proposed Decomposition

### New Module: `Engine.Render.Internal.FramePrepare`

Pure computation helpers. No `MonadIO`, no capabilities.

```haskell
module Engine.Render.Internal.FramePrepare where

-- Lines 264-313: debug entity info computation
computeEntityDebugInfos ::
  [DrawCall] -> M44 Float -> M44 Float -> [EntityDebugInfo]

-- Lines 307-313: render debug info assembly
buildRenderDebugInfo ::
  Int -> V3 Float -> V3 Float -> M44 Float -> [EntityDebugInfo] -> RenderDebugInfo

-- Lines 315-347: compute entity data for GPU
buildComputeEntityData :: DrawCall -> ComputeEntityData
-- Or: buildAllEntityData :: [DrawCall] -> [ComputeEntityData]

-- Lines 348-361: frustum cull data
buildCullData ::
  Float -> Float -> AnyCamera -> [DrawCall] -> ComputeCullData

-- Lines 375-379: skybox ray computation (already a top-level function)
-- computeSkyboxRays already exists, keep it

-- Lines 390-397: sun state + sky params
computeSkyParams ::
  Bool -> Float -> (DayNight.SunState, V3 Float, Float, Float, V3 Float)
```

### New Module: `Engine.Render.Internal.PassRecording`

The `recordAction` IO callback extracted as a top-level builder.

```haskell
module Engine.Render.Internal.PassRecording where

-- Lines 399-497: the entire recordAction callback
-- Takes pre-computed values, returns the IO action
data RecordContext = RecordContext
  { rcDeferred :: DeferredResources
  , rcSurfaceExtent :: VkExtent2D
  , rcGraphicsCommandBuffers :: [VkCommandBuffer]
  , rcFrameDescriptorSets :: [VkDescriptorSet]
  , rcCullResources :: ComputeCullResources
  , rcDrawList :: [DrawCall]
  , rcDevice :: VkDevice
  , rcLightSsboBuffer :: VkBuffer
  , rcTextureSampler :: VkSampler
  , rcPassData :: DeferredPassData  -- all the pre-read TVar values packed
  }

buildRecordAction :: RecordContext -> Word32 -> Int -> IO ()
```

This is the biggest win — moves 100 lines of IO callback out of the main loop.

### Refactored `renderFrameLoop'` (target ~80 lines)

```haskell
renderFrameLoop' frameNumber = do
  env@RenderEnv{..} <- ask
  frameStartTime <- getMonotonicTime
  maybeControlMessage <- readControl

  (needRestart, terminating) <- case maybeControlMessage of
    Just Terminate -> terminateFrame
    Nothing        -> runFrame env frameNumber

  handleFrameTiming frameStartTime needRestart terminating targetFPS frameNumber

-- Top-level helpers (in Render.hs or Internal module):

terminateFrame :: MonadLog m => m (Bool, Bool)
terminateFrame = do
  logInfo LogGeneral "terminating render loop by signal"
  pure (True, True)

runFrame :: (...constraints...) => RenderEnv -> Int -> m (Bool, Bool)
runFrame env frameNumber = do
  -- Phase 1: read state + compute
  camera <- readCamera
  drawList <- extractDrawList ...
  entityData <- buildComputeEntityData drawList     -- pure
  cullData <- buildCullData camera drawList          -- pure
  uploadBuffers entityData cullData

  case drawList of
    [] -> pure (False, False)
    _  -> renderAndPresent env frameNumber camera drawList

renderAndPresent :: (...constraints...) => RenderEnv -> Int -> AnyCamera -> [DrawCall] -> m (Bool, Bool)
renderAndPresent env frameNumber camera drawList = do
  -- Pre-read all TVar state
  frameState <- readFrameState            -- collects 7 TVar reads into one record
  let skyParams = computeSkyParams frameState
  let recordCtx = buildRecordContext env frameState skyParams camera drawList
  res <- drawFrameGraphics ... (buildRecordAction recordCtx)
  handleFrameResult env frameNumber res camera drawList

handleFrameResult :: (...constraints...) => RenderEnv -> Int -> Render.FrameResult -> ...
handleFrameResult env frameNumber (Render.FrameOk imageIndex) = do
  res <- presentFrameGraphics imageIndex ...
  handlePresentResult env imageIndex res
handleFrameResult _ _ Render.FrameOutOfDate = logInfo ... >> pure (True, False)
handleFrameResult _ _ Render.FrameTimeout = delayMicros 16000 >> pure (False, False)
...

handlePresentResult :: (...constraints...) => RenderEnv -> Word32 -> VkResult -> m (Bool, Bool)
handlePresentResult env imageIndex Vulkan.VK_SUCCESS = do
  handleInspector env imageIndex
  handleScreenshots env imageIndex
  pure (False, False)
handlePresentResult _ _ Vulkan.VK_SUBOPTIMAL_KHR = pure (True, False)
handlePresentResult _ _ Vulkan.VK_ERROR_OUT_OF_DATE_KHR = pure (True, False)
handlePresentResult _ _ _ = fail "presentFrame failed"

handleFrameTiming :: (...constraints...) => Integer -> Bool -> Bool -> Integer -> Int -> m Bool
handleFrameTiming frameStartTime needRestart terminating targetFPS frameNumber
  | needRestart = do
      deviceWaitIdle
      logInfo LogGeneral "waiting IDLE state for device"
      logInfo LogGeneral "terminating renderFrameLoop"
      pure terminating
  | otherwise = do
      frameEndTime <- getMonotonicTime
      let renderTime = toNanoSecs frameEndTime - toNanoSecs frameStartTime
          delay = ((1000000000 `div` targetFPS) - renderTime) `div` 1000
      recordFrameTime renderTime
      mMsg <- getTelemetryMessage
      for_ mMsg $ logInfo LogRender
      delayMicros (fromIntegral delay)
      renderFrameLoop' ((frameNumber + 1) `mod` Render.maxFramesInFlight)
```

### New Data Types

```haskell
-- Collected TVar state (read once per frame, passed as value)
data FrameState = FrameState
  { fsWireframe :: !Bool
  , fsDebugMode :: !Word32
  , fsAxisOverlay :: !Float
  , fsGroundPlane :: !Float
  , fsTimeOfDay :: !Float
  , fsDayNightEnabled :: !Bool
  , fsCloudHeight :: !Float
  }

-- Read all at once
readFrameState :: MonadStateReader m => m FrameState
readFrameState = FrameState
  <$> readWireframe
  <*> readDebugMode
  <*> readAxisOverlay
  <*> readGroundPlane
  <*> readTimeOfDay
  <*> readDayNightEnabled
  <*> readCloudHeight
```

This replaces the 7 individual `readX` calls with one `readFrameState`.

### Screenshot Helpers

```haskell
-- In Engine.Render.Internal.Screenshot or inline
handleScreenshots :: (...constraints...) => RenderEnv -> Word32 -> m ()
handleScreenshots env imageIndex = do
  shouldScreenshot <- consumeScreenshotFlag
  shouldAllStages <- consumeAllStagesFlag
  shouldSwapchain <- consumeSwapchainScreenshotFlag
  when shouldScreenshot $ captureSingleStage env imageIndex
  when shouldAllStages $ captureAllStages env imageIndex
  when shouldSwapchain $ captureSwapchain env imageIndex
```

## Implementation Phases

### Phase A: Extract pure computations (low risk)
- Create `Engine.Render.Internal.FramePrepare`
- Move `buildComputeEntityData`, `buildCullData`, `computeSkyParams`
- These are pure functions, zero behavior change
- **Effort**: 1 hr

### Phase B: Extract `recordAction` callback (medium risk)
- Create `Engine.Render.Internal.PassRecording`
- Move the 100-line IO callback into `buildRecordAction`
- Pass `RecordContext` record instead of individual closures
- **Effort**: 1.5 hrs

### Phase C: Extract case branches (structural refactor)
- Create `runFrame`, `renderAndPresent`, `handleFrameResult`, `handlePresentResult`
- Create `FrameState` record + `readFrameState`
- Create `handleFrameTiming` for the tail section
- Main loop becomes ~30 lines of orchestration
- **Effort**: 2 hrs

### Phase D: Extract screenshot/inspector handlers
- Create `handleScreenshots`, `handleInspector` as top-level
- Move debug entity computation to `FramePrepare`
- **Effort**: 1 hr

## File Structure (after)

```
src/Graphics/Haskan/Engine/
  Render.hs                          -- main loop orchestration (~100 lines)
  Render/
    Internal/
      FramePrepare.hs                -- pure computation helpers
      PassRecording.hs               -- recordAction IO callback builder
      FrameState.hs                  -- FrameState record + reader
```

## Risk Assessment

| Phase | Risk | Mitigation |
|-------|------|-----------|
| A | None — pure extractions | Compile after each move |
| B | Low — IO callback signature unchanged | Test render after move |
| C | Medium — changes control flow shape | Small commits, one branch at a time |
| D | Low — isolated handlers | Straightforward extraction |

Recommended order: A → D → B → C (easiest first, build confidence)
