# Debug Interface

Unix socket-based debug interface for remote control and introspection of the Haskan2 engine.

## Overview

The debug interface allows external tools to:
- **Inject input events** (key presses, mouse moves) into the event queue
- **Query game state** (camera position, running status)
- **Mutate state** (set camera distance, target, angles)
- **Trigger actions** (frame inspection)

## Architecture

```
┌─────────────┐     Unix Socket      ┌──────────────┐     STM Queues     ┌─────────────────┐
│ Debug CLI   │ ◀─────────────────▶  │ Debug Server │ ◀────────────────▶ │ stateUpdateLoop │
│ / Scripts   │    JSON Lines        │   (Haskell)  │                    │                 │
└─────────────┘                      └──────────────┘                    └─────────────────┘
                                                                              │
                                                                              ▼
                                                                        ┌─────────────┐
                                                                        │  GameState  │
                                                                        └─────────────┘
```

**Request flow:**
1. Client connects to `/tmp/haskan2.sock`
2. Server sends `{"status": "connected"}`
3. Client sends JSON command
4. Server routes to `actionQueue` (for input events) or `debugCmdQueue` (for commands)
5. `stateUpdateLoop` processes commands and sends responses back via `TMVar`
6. Server serializes response and sends to client

## Protocol

All messages are JSON Lines (one JSON object per line, newline-terminated).

### Message Types

#### Inject Event

Maps to the existing input system. Same as SDL events.

```json
{"inject_event": {"key_press": ["f12", true]}}
{"inject_event": {"key_press": ["w", true]}}
{"inject_event": {"key_press": ["w", false]}}
{"inject_event": {"mouse_move_event": [10, -5]}}
```

Supported keys: `w`, `a`, `s`, `d`, `f12`, `escape`

Response: `{"status": "ok"}`

#### Commands

Direct state mutations with acknowledgment or data response.

**Get State:**
```json
{"command": {"get_state": []}}
```

Response:
```json
{
  "state_response": {
    "gss_camera": {
      "cs_position": [0, 0, 20],
      "cs_target": [0, 0, 0],
      "cs_distance": 20,
      "cs_azimuth": 0,
      "cs_elevation": 0
    },
    "gss_running": true,
    "gss_frame_inspector_enabled": false
  }
}
```

**Set Camera Distance:**
```json
{"command": {"set_camera_distance": 50.0}}
```

Response: `{"ack_response": "camera_distance_set"}`

**Set Camera Target:**
```json
{"command": {"set_camera_target": [0.0, 5.0, 0.0]}}
```

Response: `{"ack_response": "camera_target_set"}`

**Set Camera Angles:**
```json
{"command": {"set_camera_angles": [0.5, 0.2]}}
```

Response: `{"ack_response": "camera_angles_set"}`

**Trigger Frame Inspect:**
```json
{"command": {"trigger_frame_inspect": []}}
```

Response: `{"ack_response": "frame_inspect_triggered"}`

### Response Types

| Response | Meaning |
|----------|---------|
| `{"status": "connected"}` | Initial connection handshake |
| `{"status": "ok"}` | Event injected successfully |
| `{"ack_response": "..."}` | Command executed |
| `{"state_response": {...}}` | State query result |
| `{"error": "..."}` | Parse or execution error |

## CLI Client

A Python client is provided at `scripts/debug_client.py`:

```bash
# Query current state
python3 scripts/debug_client.py get-state

# Set camera distance
python3 scripts/debug_client.py set-distance 50.0

# Set camera target
python3 scripts/debug_client.py set-target 0.0 5.0 0.0

# Set camera angles (azimuth, elevation)
python3 scripts/debug_client.py set-angles 0.5 0.2

# Trigger frame snapshot
python3 scripts/debug_client.py inspect

# Send key press (useful for automation)
python3 scripts/debug_client.py key f12 true
```

### Raw Socket Usage

Using `socat` or `nc`:

```bash
# Send a command
echo '{"command":{"get_state":[]}}' | socat - UNIX-CONNECT:/tmp/haskan2.sock

# Interactive session
socat READLINE UNIX-CONNECT:/tmp/haskan2.sock
```

Using Python directly:

```python
import socket, json

s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect("/tmp/haskan2.sock")
f = s.makefile("r")

print(f.readline())  # {"status": "connected"}

s.send(b'{"command":{"get_state":[]}}\n')
print(f.readline())  # {"state_response":{...}}

s.close()
```

## Configuration

The socket path is configured in `EngineConfig`:

```haskell
EngineConfig
  { -- ... other fields ...
  , debugSocketPath = Just "/tmp/haskan2.sock"  -- or Nothing to disable
  }
```

Default in `Graphics.Haskan`:
```haskell
debugSocketPath = Just "/tmp/haskan2.sock"
```

## Security

- Unix sockets use filesystem permissions
- Only processes with read/write access to the socket can connect
- No authentication layer (intended for local debugging only)
- To disable: set `debugSocketPath = Nothing`

## Implementation Details

### Modules

- **`Graphics.Haskan.Debug.Interface`** — JSON types, serialization, protocol parsing
- **`Graphics.Haskan.Debug.Server`** — Unix socket server, connection handling, response routing
- **`Graphics.Haskan.Engine`** — Integration: queue creation, command processing in `stateUpdateLoop`

### Threading Model

- **Main thread:** `mainLoop` creates queues, starts server, runs SDL input
- **Server thread:** Accepts connections, forks handler per client
- **Handler thread:** Reads lines, routes to queues, waits on `TMVar` for responses
- **State thread:** `stateUpdateLoop` flushes command queue each tick, fills response `TMVar`s

### Why STM Queues + TMVars

- **Async by default:** Commands don't block the render thread
- **Sync when needed:** `GetState` uses `TMVar` for request/response pattern
- **Thread-safe:** All state access goes through `stateUpdateLoop`
- **Composable:** Multiple clients can send commands; each gets its own response

## Future Extensions

- **Batch commands:** `{"commands": [...]}` for atomic multi-operation
- **Subscription:** `{"subscribe": "camera"}` for streaming updates
- **Replay:** Record command sequence to file, replay later
- **Validation:** Schema validation on incoming messages
- **Authentication:** Token-based for remote debugging scenarios

## Troubleshooting

**Connection refused:**
- Is haskan2 running?
- Check socket exists: `ls -la /tmp/haskan2.sock`

**Parse errors:**
- Commands must use `ObjectWithSingleField` encoding: `{"get_state": []}` not `"get_state"`
- All messages must be newline-terminated

**No response:**
- Is `debugSocketPath = Just path` in `EngineConfig`?
- Check logs for "starting debug server on ..."

**Stale socket:**
- Socket file persists after crash: `rm /tmp/haskan2.sock`
- Server auto-removes on startup