# Logging Subsystem

Multi-backend structured logging via the `effectful` effects library.

## Overview

The logging subsystem was migrated from an IORef-based global logger to `effectful`'s extensible effects system. This provides:

- **Type-safe effect tracking** — `Logger :> es` constraint on functions that log
- **Multiple backends** — stdout, stderr, file, each with independent configuration
- **Per-backend filtering** — minimum log level per backend
- **Pluggable formatters** — human-readable or JSON output
- **Gradual migration** — `logInfoIO`/`logDebugIO` variants for unconverted `MonadIO` code

## Usage

### In Eff code (preferred)

```haskell
import Effectful
import Graphics.Haskan.Logger

myFunction :: (IOE :> es, Logger :> es) => Eff es ()
myFunction = do
  logInfo LogGeneral "Application started"
  logDebug LogRender $ "Drawing " <> showT entityCount <> " entities"
```

### In IO/MonadIO code (bridge)

```haskell
import Graphics.Haskan.Logger

legacyFunction :: MonadIO m => m ()
legacyFunction = do
  logInfoIO LogGeneral "Legacy function called"
```

### Running with backends

```haskell
import Effectful
import Graphics.Haskan.Logger

main :: IO ()
main = do
  let backends = [ stdoutBackend Info
                 , stderrBackend Warning
                 ]
  fileBackendMb <- optional (fileBackend Debug "/tmp/debug.log")
  let allBackends = backends ++ maybeToList fileBackendMb
  runEff $ runLogger allBackends $ do
    logInfo LogGeneral "Hello from effectful logging"
```

## Backends

| Backend | Constructor | Purpose |
|---------|-------------|---------|
| stdout | `stdoutBackend minLevel` | Console output |
| stderr | `stderrBackend minLevel` | Error output |
| file | `fileBackend minLevel path` | Persistent log file |

## Formatters

- `defaultFormatter` — `timestamp [LEVEL] [CATEGORY] message`
- `jsonFormatter` — `{"timestamp":"...","level":"...","category":"...","message":"..."}`

Custom formatters: `type LogFormatter = LogEntry -> Text`

## Log Levels

`Debug < Info < Warning < Error < Fatal`

Messages below a backend's `lbMinLevel` are silently dropped.

## Architecture

```
┌─────────────────────────────────────┐
│         Application Code            │
│    logInfo LogGeneral "hello"       │
└─────────────┬───────────────────────┘
              │ Logger :> es
┌─────────────▼───────────────────────┐
│      runLogger [backends]           │
│         Effect Handler              │
└─────────────┬───────────────────────┘
              │ IO ()
┌─────────────▼───────────────────────┐
│      stdoutBackend Info             │
│      fileBackend Debug "/tmp/..."   │
│      stderrBackend Warning          │
└─────────────────────────────────────┘
```

## Global Backends (Bridge)

During gradual migration, unconverted modules use `logInfoIO` which writes to a global `IORef [LogBackend]`:

```haskell
setGlobalBackends [stdoutBackend Info]     -- configure at startup
getGlobalBackends                           -- read current backends
```

The `Main.hs` entry point configures global backends from CLI flags before spawning threads.

## Migration Status

| Module | Status |
|--------|--------|
| `Logger.hs` | Full `Eff` (effect definition + handler) |
| `Engine.hs` | Bridge (`logInfoIO`/`logDebugIO`) — `Managed`/`MonadIO` retained |
| `Graphics.Haskan.hs` | Bridge (`logInfoIO`) |
| `Main.hs` | Plain `IO`, configures global backends |
| Vulkan wrappers | Bridge (`logInfoIO`) |
| glTF loader | Bridge (`logInfoIO`) |
| Asset preprocessor | Bridge (`logDebugIO`) |
| Debug server | Bridge (`logInfoIO`) |

**Rationale:** `Managed` (CPS-based resource brackets) is incompatible with `Eff`'s evaluation model. Converting `Engine.hs` would require replacing all Vulkan resource acquisition (~40 functions) with `resourcet-effectful` or explicit handle passing. The bridge pattern provides structured logging without restructuring the render loop.

Future work: target ECS game logic, input systems, or UI layers for `Eff` conversion — not the Vulkan command layer.

## Files

- `src/Graphics/Haskan/Logger.hs` — Effect definition, handlers, backends, formatters
- `app/Main.hs` — Backend initialization from CLI, plain `IO` entry point
