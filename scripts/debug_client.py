#!/usr/bin/env python3
"""Haskan2 Debug CLI Client

Connects to the haskan2 Unix socket and sends debug commands.

Usage:
    python3 debug_client.py get-state
    python3 debug_client.py get-render-state
    python3 debug_client.py set-distance 50.0
    python3 debug_client.py set-target 0.0 5.0 0.0
    python3 debug_client.py set-angles 0.5 0.2
    python3 debug_client.py inspect
    python3 debug_client.py key f12 true
    python3 debug_client.py key w true
"""

import json
import socket
import sys

SOCKET_PATH = "/tmp/haskan2.sock"

def send_message(msg):
    """Send a JSON message to the debug server and return the response."""
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        s.connect(SOCKET_PATH)
        # Use file-like interface for line-based I/O
        f = s.makefile("r")
        
        # Read connection ack
        ack = f.readline().strip()
        print(f"Server: {ack}")
        
        # Send command
        line = json.dumps(msg)
        s.send(f"{line}\n".encode())
        
        # Read response
        resp = f.readline().strip()
        return resp
    except FileNotFoundError:
        print(f"Error: Socket not found at {SOCKET_PATH}")
        print("Is haskan2 running?")
        sys.exit(1)
    except ConnectionRefusedError:
        print(f"Error: Connection refused at {SOCKET_PATH}")
        print("Is haskan2 running?")
        sys.exit(1)
    finally:
        s.close()

def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    
    cmd = sys.argv[1]
    
    if cmd == "get-state":
        msg = {"command": {"get_state": []}}
        print(f"Request: {json.dumps(msg)}")
        resp = send_message(msg)
        print(f"Response: {resp}")
        # Pretty print if it's JSON
        try:
            data = json.loads(resp)
            print(json.dumps(data, indent=2))
        except:
            pass
    
    elif cmd == "get-render-state":
        msg = {"command": {"get_render_state": []}}
        print(f"Request: {json.dumps(msg)}")
        resp = send_message(msg)
        print(f"Response: {resp}")
        try:
            data = json.loads(resp)
            print(json.dumps(data, indent=2))
            if "render_state" in data:
                render_data = data["render_state"]
                print("\n=== Render Debug State ===")
                print(f"Frame: {render_data.get('frame_number', 'N/A')}")
                print(f"Camera Pos: {render_data.get('camera_pos', 'N/A')}")
                print(f"Camera Target: {render_data.get('camera_target', 'N/A')}")
                print("\nEntities:")
                for entity in render_data.get('entities', []):
                    print(f"\n  Entity {entity.get('entity_id')}:")
                    print(f"    Position: {entity.get('position', 'N/A')}")
                    print(f"    Sample Vertices (NDC):")
                    for i, vert in enumerate(entity.get('sample_vertices_ndc', [])):
                        print(f"      v{i}: {vert}")
            else:
                print("No render_state in response")
        except Exception as e:
            print(f"Error parsing response: {e}")
    
    elif cmd == "set-distance":
        if len(sys.argv) < 3:
            print("Usage: debug_client.py set-distance <float>")
            sys.exit(1)
        distance = float(sys.argv[2])
        msg = {"command": {"set_camera_distance": distance}}
        print(f"Request: {json.dumps(msg)}")
        resp = send_message(msg)
        print(f"Response: {resp}")
    
    elif cmd == "set-target":
        if len(sys.argv) < 5:
            print("Usage: debug_client.py set-target <x> <y> <z>")
            sys.exit(1)
        x, y, z = float(sys.argv[2]), float(sys.argv[3]), float(sys.argv[4])
        msg = {"command": {"set_camera_target": [x, y, z]}}
        print(f"Request: {json.dumps(msg)}")
        resp = send_message(msg)
        print(f"Response: {resp}")
    
    elif cmd == "set-angles":
        if len(sys.argv) < 4:
            print("Usage: debug_client.py set-angles <azimuth> <elevation>")
            sys.exit(1)
        az, el = float(sys.argv[2]), float(sys.argv[3])
        msg = {"command": {"set_camera_angles": [az, el]}}
        print(f"Request: {json.dumps(msg)}")
        resp = send_message(msg)
        print(f"Response: {resp}")
    
    elif cmd == "inspect":
        msg = {"command": {"trigger_frame_inspect": []}}
        print(f"Request: {json.dumps(msg)}")
        resp = send_message(msg)
        print(f"Response: {resp}")
    
    elif cmd == "key":
        if len(sys.argv) < 4:
            print("Usage: debug_client.py key <keyname> <true|false>")
            sys.exit(1)
        key = sys.argv[2]
        pressed = sys.argv[3].lower() == "true"
        msg = {"inject_event": {"key_press": [key, pressed]}}
        print(f"Request: {json.dumps(msg)}")
        resp = send_message(msg)
        print(f"Response: {resp}")
    
    else:
        print(f"Unknown command: {cmd}")
        print(__doc__)
        sys.exit(1)

if __name__ == "__main__":
    main()