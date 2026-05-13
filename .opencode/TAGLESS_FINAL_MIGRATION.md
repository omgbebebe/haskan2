# Tagless-Final Migration Plan for Render Loop

## Current Architecture

### Monad Stack
```
renderFrameLoop :: (MonadFail m, MonadIO m) => RenderEnv -> Int -> m Bool
  └─ renderFrameLoop' :: (MonadFail m, MonadIO m) => Int -> ReaderT RenderEnv m Bool
       └─ ~50 liftIO calls: Vulkan FFI, STM reads, threadDelay, IORef, logInfoIO
```

Everything runs in `ReaderT RenderEnv IO` at runtime. Zero typeclass abstractions.
`liftIO` is the only effect boundary. No test coverage for render path.

### Key Data Types
- `RenderEnv` (Render.hs:121-154): 33 fields, mix of Vulkan handles + 20+ TVars
- `RenderContext` (Vulkan/Types.hs:17-35): device, swapchain, queues, command buffers
- `DeferredResources` (Vulkan/DeferredResources.hs): pipelines, framebuffers, descriptors
- `GameState` (Engine/Types.hs:394-420): TVars duplicated into RenderEnv at startup

### liftIO Inventory in renderFrameLoop' (lines 167-534)

| Category | Count | Examples |
|----------|-------|---------|
| STM/TVar reads | ~18 | `STM.readTVarIO tvCamera`, `STM.atomically $ TChan.tryReadTChan` |
| Vulkan commands | ~12 | `vkCmdBindPipeline`, `Buffer.updateStorageBuffer`, `vkDeviceWaitIdle` |
| Logging | ~10 | `logInfoIO LogGeneral "..."` |
| Time/clock | ~5 | `getTime Monotonic`, `threadDelay` |
| Buffer uploads | ~4 | `updateStorageBuffer`, `updateUniformBufferRegion` |
| Telemetry | ~2 | `readIORef frameStatsRef`, `writeIORef` |
| Screenshot | ~4 | `saveGBufferStage`, `saveSwapchainScreenshot` |

### Existing Logger Abstraction
- `Logger :: Effect` (effectful): `logInfo`, `logDebug` for `Eff es` monads
- `logInfoIO :: MonadIO m => ...` (global IORef): used by render loop
- Render loop uses only the IO variants — effectful Logger not wired in

---

## Migration Strategy

**Approach**: Incremental, one capability at a time. Keep `ReaderT RenderEnv m` as base.
Don't change to `Eff` — too disruptive. Pure typeclass approach.

**Principle**: Each phase introduces one typeclass, replaces its `liftIO` calls,
keeps everything compiling. No big-bang rewrite.

---

## Phase 1: MonadLog

**Goal**: Replace `logInfoIO`/`logDebugIO` with typeclass method.

```haskell
class Monad m => MonadLog m where
  logMessage :: LogLevel -> LogCategory -> Text -> m ()

logInfo :: MonadLog m => LogCategory -> Text -> m ()
logInfo = logMessage Info

logDebug :: MonadLog m => LogCategory -> Text -> m ()
logDebug = logMessage Debug
```

**IO instance** (wraps existing global backends):
```haskell
instance MonadLog IO where
  logMessage = logMessageIO  -- existing function, already does the right thing
```

**Test instance**:
```haskell
newtype TestLogM a = TestLogM (State [Text] a)
  deriving (Functor, Applicative, Monad, MonadState [Text])
instance MonadLog TestLogM where
  logMessage _ _ msg = modify (msg :)
```

**Changes**:
- New file: `src/Graphics/Haskan/Engine/Capabilities/Log.hs`
- `Render.hs`: replace `logInfoIO cat msg` with `logInfo cat msg`
- Add `MonadLog m` constraint to `renderFrameLoop'`
- ~10 call sites

**Effort**: 30 min

---

## Phase 2: MonadClock

**Goal**: Abstract `getTime Monotonic` and `threadDelay`.

```haskell
class Monad m => MonadClock m where
  getMonotonicTime :: m Int64    -- nanoseconds
  delayMicros :: Int -> m ()
```

**IO instance**:
```haskell
instance MonadClock IO where
  getMonotonicTime = fmap toNanoSecs (getTime Monotonic)
  delayMicros = threadDelay
```

**Test instance**:
```haskell
data ClockState = ClockState { currentTime :: !Int64, totalDelay :: !Int }
instance MonadClock TestM where
  getMonotonicTime = gets currentTime
  delayMicros am = modify (\s -> s { totalDelay = totalDelay s + am })
```

**Changes**:
- New file: `src/Graphics/Haskan/Engine/Capabilities/Clock.hs`
- `Render.hs`: replace `liftIO $ toNanoSecs <$> getTime Monotonic` → `getMonotonicTime`
- Replace `liftIO $ threadDelay n` → `delayMicros n`
- ~5 call sites

**Effort**: 20 min

---

## Phase 3: MonadTelemetry

**Goal**: Abstract frame stats IORef.

```haskell
class Monad m => MonadTelemetry m where
  recordFrameTime :: Int64 -> m ()
  getTelemetryMessage :: m (Maybe Text)
```

**IO instance** (wraps existing IORef):
```haskell
instance MonadTelemetry IO where
  recordFrameTime rt = do
    stats <- readIORef frameStatsRef  -- needs access, see note
    let (newStats, _) = updateFrameStats stats rt
    writeIORef frameStatsRef newStats
  getTelemetryMessage = do
    stats <- readIORef frameStatsRef
    let (_, mMsg) = updateFrameStats stats 0
    pure mMsg
```

**Note**: The IORef `frameStatsRef` is created in `renderLoop` and passed via `RenderEnv`.
The IO instance will read it from a global or pass via Reader. Simplest: keep it in RenderEnv,
have the instance use `asks reFrameStatsRef`.

Actually, cleaner: make the instance use ReaderT:
```haskell
instance (MonadIO m, MonadReader RenderEnv m) => MonadTelemetry m where
  recordFrameTime rt = do
    ref <- asks reFrameStatsRef
    liftIO $ do
      stats <- readIORef ref
      let (newStats, _) = updateFrameStats stats rt
      writeIORef ref newStats
```

**Changes**:
- New file: `src/Graphics/Haskan/Engine/Capabilities/Telemetry.hs`
- `Render.hs`: replace `liftIO $ readIORef frameStatsRef` block
- ~2 call sites (but the biggest block of telemetry code)

**Effort**: 30 min

---

## Phase 4: MonadGraphics (the hard one)

**Goal**: Abstract all Vulkan FFI calls.

This is the largest category and hardest to abstract cleanly. Split into sub-capabilities:

```haskell
class Monad m => MonadGraphics m where
  -- Device synchronization
  waitDeviceIdle :: m ()

  -- Buffer uploads
  uploadEntityData :: Word32 -> [EntityData] -> m ()
  uploadCullData :: CullUniformData -> m ()
  uploadLightData :: [LightData] -> m ()
  uploadMVPData :: Int -> ViewMat -> ProjMat -> m ()

  -- Command buffer recording
  recordAndSubmit :: (PassContext -> IO ()) -> m ()

  -- Present
  drawAndPresent :: Int -> Word32 -> m ()

  -- Screenshots
  saveScreenshot :: ScreenshotType -> m ()
```

**IO instance**: delegates to existing Vulkan functions, reads handles from `MonadReader RenderEnv`.

**Test instance**: records what was called, no GPU:
```haskell
data GraphicsLog = GraphicsLog
  { uploadedEntities :: !Int
  , framesPresented :: !Int
  , deviceWaitCount :: !Int
  }
instance MonadGraphics TestM where
  waitDeviceIdle = modify (\s -> s { deviceWaitCount = deviceWaitCount s + 1 })
  drawAndPresent _ _ = modify (\s -> s { framesPresented = framesPresented s + 1 })
  ...
```

**Changes**:
- New file: `src/Graphics/Haskan/Engine/Capabilities/Graphics.hs`
- `Render.hs`: extract ~12 Vulkan `liftIO` blocks into typeclass methods
- This is the biggest refactor — each Vulkan call needs its parameters analyzed

**Effort**: 3-4 hrs

---

## Phase 5: MonadStateReader (STM abstraction)

**Goal**: Abstract all `STM.readTVarIO` / `STM.atomically` calls.

```haskell
class Monad m => MonadStateReader m where
  readCamera :: m AnyCamera
  readLights :: m [LightData]
  readDebugMode :: m Word32
  readWireframe :: m Bool
  readCloudHeight :: m Float
  readTimeOfDay :: m Float
  readDayNightEnabled :: m Bool
  readControl :: m (Maybe ControlMessage)
  consumeInspect :: m (Maybe FrameInspector)
  consumeScreenshot :: m (Maybe ScreenshotType)
  -- ... etc for all 20+ TVars
```

**IO instance**: `asks reTvX` + `liftIO . STM.readTVarIO`

**Test instance**: reads from pure state:
```haskell
instance MonadStateReader TestM where
  readCamera = gets testCamera
  readDebugMode = gets testDebugMode
  ...
```

**Alternative**: Instead of one method per TVar, use a Has-style pattern:
```haskell
class Has a env where
  hasLens :: Lens' env a

readState :: (MonadReader env m, MonadIO m, Has (TVar a) env) => m a
readState = do
  tvar <- view hasLens
  liftIO $ STM.readTVarIO tvar
```

This is more composable but harder to understand. Recommend method-per-field
for now, refactor to Has-style later if needed.

**Changes**:
- New file: `src/Graphics/Haskan/Engine/Capabilities/StateReader.hs`
- `Render.hs`: replace all `liftIO $ STM.readTVarIO tvX` with `readX`
- ~18 call sites

**Effort**: 2 hrs

---

## Phase 6: Test Infrastructure

**Goal**: Create test monad and write first render loop tests.

```haskell
data TestState = TestState
  { tsFrame :: !Int
  , tsCamera :: !AnyCamera
  , tsLogged :: ![Text]
  , tsDelays :: !Int
  , tsDeviceWaits :: !Int
  , tsFramesPresented :: !Int
  , tsDebugMode :: !Word32
  , tsCloudHeight :: !Float
  -- ... all state needed by MonadStateReader
  }

newtype TestM a = TestM (StateT TestState IO a)
  deriving (Functor, Applicative, Monad, MonadState TestState, MonadFail)

instance MonadLog TestM where ...
instance MonadClock TestM where ...
instance MonadTelemetry TestM where ...
instance MonadGraphics TestM where ...
instance MonadStateReader TestM where ...
```

**Tests**:
```haskell
describe "renderFrameLoop" $ do
  it "logs termination on Terminate signal" $ do
    let st = TestState { tsControl = Just Terminate, ... }
    result = evalStateT (runReaderT renderFrameLoop' 0 testEnv) st
    result `shouldSatisfy` (elem "terminating renderFrameLoop" . tsLogged)

  it "increments frame number" $ do
    ...

  it "delays to match target FPS" $ do
    ...
```

**Changes**:
- New file: `test/RenderLoopSpec.hs`
- New file: `test/TestM.hs`
- Update `test/Tests.hs` or cabal test suite

**Effort**: 3-4 hrs

---

## Updated Signature (Final)

```haskell
renderFrameLoop' ::
  ( MonadFail m
  , MonadReader RenderEnv m
  , MonadLog m
  , MonadClock m
  , MonadTelemetry m
  , MonadGraphics m
  , MonadStateReader m
  ) => Int -> m Bool
```

At runtime: `m ~ ReaderT RenderEnv IO` with orphan instances.
In tests: `m ~ StateT TestState IO` with mock instances.

No `MonadIO` constraint on the loop itself. All IO is behind typeclasses.

---

## Implementation Order

| Phase | Capability | Effort | liftIO calls removed |
|-------|-----------|--------|---------------------|
| 1 | MonadLog | 30 min | ~10 |
| 2 | MonadClock | 20 min | ~5 |
| 3 | MonadTelemetry | 30 min | ~2 |
| 4 | MonadGraphics | 3-4 hrs | ~12 |
| 5 | MonadStateReader | 2 hrs | ~18 |
| 6 | Test infrastructure | 3-4 hrs | (new code) |

**Recommended order**: 1 → 2 → 3 → 5 → 4 → 6

MonadGraphics is hardest — defer it. MonadStateReader is straightforward
pattern-matching. Tests come last when all capabilities are in place.

---

## File Structure

```
src/Graphics/Haskan/Engine/
  Capabilities/
    Log.hs           -- MonadLog
    Clock.hs         -- MonadClock
    Telemetry.hs     -- MonadTelemetry
    Graphics.hs      -- MonadGraphics
    StateReader.hs   -- MonadStateReader

test/
  TestM.hs           -- Test monad with mock instances
  RenderLoopSpec.hs  -- Render loop unit tests
```

---

## Risks and Mitigations

1. **Orphan instances**: IO instances for typeclasses defined in Capabilities/ modules.
   Mitigation: define instances in the same module as the class, or use newtype wrappers.

2. **MonadReader RenderEnv constraint**: some typeclasses need access to TVars in RenderEnv.
   Options: (a) add `MonadReader RenderEnv m` as superclass constraint, (b) pass refs explicitly.
   Recommend (a) — simpler, RenderEnv is already the reader context.

3. **Performance**: typeclass method calls are direct, no dictionary overhead in hot loops
   because GHC specializes. Same performance as hand-written `liftIO`.

4. **Gradual migration**: each phase is independent. Can stop at any point.
   Partial migration = some `liftIO` remaining, which is fine.

5. **renderFrameLoop' is 370 lines**: even after tagless-final, the function is still
   monolithic. Consider splitting it into sub-functions (phase selection, frame preparation,
   submit, present) as a separate refactoring pass after capabilities are in place.
