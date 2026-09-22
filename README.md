# roblox-tycoon-framework

A modular, server-authoritative restaurant and tycoon backend written in strict Luau.

Designed to handle real-time NPC customer queues, worker state machines, and high-frequency currency transactions without relying on server-side physics replication or table-heavy network remotes.

---

## Architecture & Core Systems

### 1. Zero-Physics NPC Pathing & Binary Replication
* **Server-side Waypoint Generation:** Server calculates raw pathfinding waypoints, strips collinear nodes, and smooths the path using Chaikin's algorithm.
* **Buffer Serialization:** Trajectories, start timestamps, speed, and look-ahead targets are packed into raw binary payloads via the Luau `buffer` library rather than serializing Luau tables over `RemoteEvent` instances.
* **Client-side Spline Interpolation:** Clients unpack the trajectory and evaluate positions on `RenderStepped` using precomputed arc-length distances and binary search segment lookups. Server keeps NPC root parts anchored, eliminating server physics pipeline overhead.

### 2. Transaction Ledger & Idempotency
* **Ledger Safety:** In-memory wallet operations with double-precision bounds, integer safety checks, and NaN detection.
* **Idempotency Ring Buffer:** A 32-entry circular buffer caches recent transaction keys to prevent replay attacks and duplicate spending on network retries.
* **Binary State Sync:** Client balance updates are dispatched via naturally aligned 22-byte buffers.
* **Session Locking:** ProfileService-backed distributed locking with periodic lease renewal heartbeats and a graceful persistence drain procedure during `game:BindToClose`.

### 3. Pathfinding Semaphore & Rate Limiting
* **Compute Throttling:** `PathfindingService:ComputeAsync` calls are managed through a coroutine-based semaphore queue limited to 6 concurrent threads with a timeout fallback.
* **Direct Raycast Short-Circuit:** Unobstructed paths under 25 studs bypass path computation via spherical raycasting to reduce engine pressure.
* **Path Pooling:** Reusable `Path` instances are pooled to minimize garbage collection allocations.

### 4. Server-Authoritative Plot Validation
* **Anti-Cheat Validation:** Server verifies physical distance from character to placement target, sanitizes CFrame orientation (zeroing out exploited pitch/roll), and clamps height to expected plot floor levels.
* **Spatial Collision Testing:** Uses `workspace:GetPartBoundsInBox` with `OverlapParams` to prevent overlapping placed assets.
* **Token Bucket Rate Limiting:** Placement and removal requests are throttled per-player using token buckets to mitigate remote spam.

### 5. Finite State Machines (FSM)
* Modular state machines drive worker roles (Cook, Cashier) and customer lifecycles (Spawning, Queueing, Ordering, Leaving) with decoupled state transitions and cleanup handling via Maids.

---

## Project Structure (Rojo)

```text
roblox-tycoon-framework/
├── default.project.json       # Rojo project configuration
├── README.md
└── src/
    ├── shared/                # Network service, shared types, configs, and math/spline utils
    ├── server/                # Server bootstrapper, core services, components, and rate limiters
    └── client/                # Client controllers (Plot, NPC, Economy) and UI builders
