# Data Flow Diagram

## Frame Lifecycle

```mermaid
sequenceDiagram
    participant App as Application Loop
    participant Input as Input System
    participant World as ECS World
    participant RS as Render System
    participant RG as Render Graph
    participant RC as Resource Cache
    participant Cmd as Command Buffer
    participant GPU as GPU

    loop Every Frame
        App->>Input: Poll SDL events
        Input->>World: Write action components

        App->>World: Run update systems
        Note over World: Physics, animation,<br/>transform hierarchy

        App->>RS: Extract visible entities
        RS->>World: Query Mesh + Transform + Material
        World-->>RS: [(EntityId, MeshHandle, Transform, MaterialHandle)]

        RS->>RC: Resolve handles → GPU resources
        RC-->>RS: [(VkBuffer, VkDescriptorSet, Pipeline)]

        RS->>RG: Build graph: visible entities + passes
        Note over RG: G-buffer? Lighting? Forward?<br/>Configured by active pipeline

        RG->>RG: Compile: barriers, layouts, ordering
        RG->>Cmd: Record primary + secondary CBs

        Cmd->>GPU: Submit (fence per frame)
        GPU-->>Cmd: Signal completion

        Cmd->>GPU: Present swapchain image
    end
```

## Resource Loading Flow

```mermaid
sequenceDiagram
    participant User as User / GLTF Loader
    participant RM as ResourceManager
    participant Parser as Mesh/Texture Parser
    participant Mem as Memory Allocator
    participant GPU as GPU

    User->>RM: loadMesh "player" "player.obj"
    RM->>Parser: Parse OBJ file
    Parser-->>RM: MeshData (vertices, indices)

    RM->>Mem: allocateBuffer (vertex data)
    Mem->>GPU: vkCreateBuffer + vkAllocateMemory
    Mem-->>RM: BufferHandle

    RM->>Mem: allocateBuffer (index data)
    Mem->>GPU: vkCreateBuffer + vkAllocateMemory
    Mem-->>RM: BufferHandle

    RM->>RM: Register MeshResource
    RM-->>User: MeshHandle

    User->>RM: loadTexture " diffuse" "diffuse.png"
    RM->>Parser: Parse PNG
    Parser-->>RM: ImageData (rgba, width, height)

    RM->>Mem: allocateImage + staging buffer
    Mem->>GPU: vkCreateImage + vkAllocateMemory
    Mem-->>RM: ImageHandle

    RM->>GPU: Copy staging → device-local (command buffer)
    RM->>RM: Register TextureResource
    RM-->>User: TextureHandle
```

## Resize / Swapchain Recreate Flow

```mermaid
sequenceDiagram
    participant App as Application
    participant RG as Render Graph
    participant RC as Resource Cache
    participant Cmd as Command Pool
    participant GPU as GPU

    App->>GPU: vkAcquireNextImageKHR
    GPU-->>App: VK_ERROR_OUT_OF_DATE_KHR

    App->>GPU: vkDeviceWaitIdle

    App->>RG: Recreate swapchain-dependent resources
    Note over RG: Old: swapchain, framebuffers,<br/>pipeline (extent changed)

    RG->>RC: Free transient attachments
    RG->>Cmd: Free command buffers

    RG->>RC: Create new swapchain
    RG->>RC: Create new framebuffers
    RG->>RC: Create new pipeline (new extent)

    Note over RG: Static resources unchanged:<br/>vertex buffers, textures, meshes

    RG-->>App: New PipelineContext
```

## Memory Flow

```mermaid
graph LR
    subgraph "CPU Memory"
        OBJ[OBJ/GLTF File]
        PNG[PNG Texture]
        MeshData[Parsed MeshData]
        ImageData[Parsed ImageData]
    end

    subgraph "Staging Memory"
        StagingBuf[Staging Buffer<br/>HOST_VISIBLE | HOST_COHERENT]
    end

    subgraph "GPU Memory"
        VertexBuf[Vertex Buffer<br/>DEVICE_LOCAL]
        IndexBuf[Index Buffer<br/>DEVICE_LOCAL]
        Texture[Texture Image<br/>DEVICE_LOCAL]
        UniformBuf[Uniform Buffer<br/>HOST_VISIBLE]
    end

    OBJ --> MeshData
    PNG --> ImageData

    MeshData --> StagingBuf
    ImageData --> StagingBuf

    StagingBuf --> VertexBuf
    StagingBuf --> IndexBuf
    StagingBuf --> Texture

    CPU[CPU Update] --> UniformBuf
```

**Key principle:** CPU data → staging buffer → GPU device-local memory. Only uniform buffers stay host-visible for per-frame updates.

## Synchronization Flow

```mermaid
graph LR
    subgraph "Frame N"
        A[Acquire Image<br/>imageAvailableSemaphore]
        B[Record CB<br/>renderFinishedFence]
        C[Submit Queue<br/>wait: imageAvailable<br/>signal: renderFinished]
        D[Present<br/>wait: renderFinished]
    end

    subgraph "Frame N+1"
        E[Acquire Image<br/>imageAvailableSemaphore2]
        F[Record CB<br/>renderFinishedFence2]
        G[Submit Queue<br/>wait: imageAvailable2<br/>signal: renderFinished2]
        H[Present<br/>wait: renderFinished2]
    end

    A --> C
    C --> D
    B -.->|wait| C

    E --> G
    G --> H
    F -.->|wait| G

    D -.->|frame pacing| E
```

**Per-frame resources (double/triple buffered):**
- `imageAvailableSemaphore[frameIndex]`
- `renderFinishedSemaphore[frameIndex]`
- `renderFinishedFence[frameIndex]`
- `commandBuffer[frameIndex]`
- `uniformBuffer[frameIndex]` (for per-frame data)

**Static resources (shared across frames):**
- Vertex/index buffers
- Textures
- Descriptor set layout
- Pipeline layout

## Component Data Flow (ECS)

```mermaid
graph TB
    subgraph "World State"
        Entities[EntityId: 0, 1, 2, ...]
        Transforms[Transform Component<br/>position, rotation, scale]
        Meshes[Mesh Component<br/>MeshHandle reference]
        Materials[Material Component<br/>MaterialHandle reference]
        Visibility[Visibility Component<br/>bool, frustum cull result]
    end

    subgraph "Systems"
        InputSys[Input System<br/>writes: Transform]
        PhysicsSys[Physics System<br/>reads/writes: Transform]
        CullSys[Frustum Cull System<br/>reads: Transform, Mesh<br/>writes: Visibility]
        RenderSys[Render System<br/>reads: Transform, Mesh, Material, Visibility]
    end

    subgraph "Output"
        DrawList[Draw List<br/>[(Mesh, Transform, Material)]]
    end

    InputSys --> Transforms
    PhysicsSys --> Transforms
    Transforms --> CullSys
    Meshes --> CullSys
    CullSys --> Visibility

    Transforms --> RenderSys
    Meshes --> RenderSys
    Materials --> RenderSys
    Visibility --> RenderSys
    RenderSys --> DrawList
```

Systems run in phases:
1. **Update phase** — Input, physics, animation (parallel where possible)
2. **Cull phase** — Frustum culling, occlusion culling
3. **Render phase** — Extract visible entities, build draw list, submit to render graph
