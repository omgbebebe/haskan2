

# Adding Bindless Descriptor Array Support to FIR: A Technical Roadmap

## 1. Current State Assessment and Gap Analysis

### 1.1 FIR Project Architecture Review

#### 1.1.1 EDSL Design Philosophy and Type-Level Safety Guarantees

The **FIR (Functional IR)** project embodies a rigorous approach to GPU shader development by embedding a complete shader authoring system within Haskell's type system. At its core, FIR leverages **GADTs (Generalized Algebraic Data Types)**, **type families**, **promoted datatypes**, and **type-level natural numbers** to enforce compile-time guarantees about shader correctness, resource binding consistency, and SPIR-V generation validity. This design philosophy prioritizes **static verification over runtime flexibility**, ensuring that shader programs cannot express invalid resource access patterns or inconsistent binding configurations. The project's commitment to type-level safety manifests in its interface specification, where developers must explicitly provide binding numbers for uniforms, inputs, and outputs through a type-level interface that encodes these constraints directly into Haskell's type system.

The practical consequence of this philosophy is that FIR users experience a **tight feedback loop**: shader programming errors manifest as Haskell type errors with location information, rather than as cryptic Vulkan validation layer messages or silent rendering corruption. However, this same rigidity that provides safety for traditional shader patterns becomes a **structural barrier when attempting to incorporate bindless descriptor techniques**, which fundamentally rely on runtime-determined resource selection that cannot be fully characterized at compile time. The challenge lies in relaxing these constraints for bindless contexts while preserving them for traditional fixed-binding scenarios—a design tension that permeates every aspect of potential FIR bindless integration.

#### 1.1.2 Fixed Binding Model Implementation Details

FIR's current resource binding implementation adheres to the **traditional "bindful" model** that predates modern bindless rendering techniques. In this model, every shader resource receives a **predetermined binding number at compile time**, with explicit set and binding decorations emitted in the generated SPIR-V. This approach mirrors conventional Vulkan descriptor set layout usage, where applications create `VkDescriptorSetLayout` objects with explicit `VkDescriptorSetLayoutBinding` entries specifying binding slot, descriptor type, descriptor count, shader stage flags, and immutable sampler information. In FIR's EDSL, this manifests as **type-level parameters on resource declarations**—users write something conceptually equivalent to `Uniform @0 @0 Float` to declare a float uniform at descriptor set 0, binding 0, with the type system tracking these assignments throughout the shader program.

The fixed binding model offers several compelling advantages that FIR leverages effectively. **First**, it enables complete static verification that no two resources collide on the same binding slot within a descriptor set, eliminating a common source of Vulkan runtime errors. **Second**, it allows the SPIR-V code generator to emit `OpDecorate` instructions with literal binding numbers at module generation time, avoiding any runtime overhead for binding resolution. **Third**, it simplifies the mental model for shader authors, who can directly correlate their Haskell code with Vulkan API calls for descriptor set updates. However, this model **fundamentally prevents the expression of true bindless patterns** where the number of active descriptors varies per-frame or where individual draw calls reference arbitrary subsets of a potentially unbounded resource pool. The fixed binding model's rigidity becomes particularly apparent when attempting to implement **GPU-driven rendering pipelines**, **texture streaming systems**, or **large-scale scene management** where resource counts exceed practical static allocation limits.

#### 1.1.3 SPIR-V Code Generation Pipeline Overview

FIR's code generation pipeline transforms high-level EDSL expressions into valid SPIR-V modules through a **multi-stage compilation process**. The pipeline begins with the embedding of EDSL constructs in Haskell source code, where overloaded operators and monadic combinators build an abstract representation of shader logic. This representation undergoes **type-directed translation**, where FIR's type class instances determine the appropriate SPIR-V instructions for each operation. The code generator produces SPIR-V modules containing global variable declarations for shader inputs/outputs and resources, function definitions for shader entry points, and executable instructions implementing the shader's computational logic. The generated SPIR-V targets **Vulkan execution environments**, with decorations and capabilities selected to match Vulkan's validation requirements.

The current code generation pipeline demonstrates **mature handling of standard Vulkan shader features**, including uniform buffers, storage buffers, combined image samplers, storage images, and input/output interfaces. However, the pipeline **lacks support for several capabilities and instructions essential to bindless descriptor indexing**. Notably absent are **`OpTypeRuntimeArray`** for unsized descriptor arrays, the **`NonUniform` decoration** for divergence annotation, and the **`SPV_EXT_descriptor_indexing` extension declarations**. The pipeline's architecture follows a pattern where new capabilities require extending the set of recognized SPIR-V opcodes, adding corresponding AST node types, and implementing the translation rules from high-level EDSL constructs to these low-level representations. Understanding this pipeline's structure is essential for planning bindless integration, as the modifications must preserve existing code generation quality while adding new paths for bindless-specific constructs.

### 1.2 Identified Capability Gaps

#### 1.2.1 Absence of VK_EXT_descriptor_indexing in Validated Features

The most fundamental capability gap preventing bindless support in FIR is the **explicit absence of `VK_EXT_descriptor_indexing`** from the project's validated feature set. This Vulkan extension, **promoted to core in Vulkan 1.2**, provides the foundational capabilities for bindless resource access, including runtime-sized descriptor arrays, non-uniform indexing, update-after-bind semantics, and partial binding support. Without explicit support for this extension, FIR's generated SPIR-V cannot declare the required capabilities such as **`RuntimeDescriptorArray`**, **`SampledImageArrayNonUniformIndexing`**, **`StorageBufferArrayNonUniformIndexing`**, and their counterparts for other descriptor types. Each of these capabilities corresponds to a specific bindless indexing scenario, and their absence from FIR's capability system means that even manually crafted SPIR-V would fail Vulkan validation for bindless shaders.

The validation gap extends beyond simple capability declarations to encompass the **full semantic requirements of the Vulkan SPIR-V environment specification**. The Vulkan specification imposes precise rules about where `NonUniform` decorations must appear, which indices require dynamic uniformity guarantees, and how descriptor binding flags interact with shader code patterns. FIR's current validation infrastructure, designed around fixed binding assumptions, would need substantial enhancement to verify these bindless-specific constraints. For instance, the specification requires that non-uniform indexing of sampled images must have both the `SampledImageArrayNonUniformIndexing` capability and the `NonUniform` decoration on the **actual sampled image operand consumed by texture sampling instructions**—not merely on the index variable or intermediate access chain results.

#### 1.2.2 Strictly Sized Array Constraint vs. Runtime-Sized Array Requirement

A critical architectural tension exists between **FIR's commitment to compile-time sized arrays** and **bindless techniques' requirement for runtime-sized or unsized arrays**. In GLSL, bindless descriptor arrays are declared with empty brackets (`texture2D textures[]`) to indicate runtime-determined sizes, which map to SPIR-V's **`OpTypeRuntimeArray`** instruction. FIR's type system currently encodes array sizes at the type level, enabling static bounds checking and memory layout computation, but **preventing the expression of arrays whose sizes are unknown at Haskell compile time**. This constraint is deeply embedded in FIR's design philosophy, as runtime-sized arrays fundamentally cannot provide the same compile-time safety guarantees that motivate FIR's type-level approach.

The practical implications of this constraint are substantial for bindless adoption. Modern rendering engines frequently employ descriptor arrays with sizes determined by frame configuration, scene complexity, or platform capabilities rather than shader source code. A texture array for material shading might contain **thousands of entries**, with the active subset varying per frame as textures stream in and out of memory. Similarly, buffer arrays for GPU-driven rendering might need to accommodate **arbitrary numbers of mesh sections or instance data blocks**. FIR's current architecture would require either **pre-allocating arrays to maximum possible sizes** (wasting descriptor resources and potentially exceeding implementation limits) or **generating shader variants for different size configurations** (increasing compilation overhead and code complexity). Resolving this tension requires careful design of new type system constructs that can express runtime-sized arrays while preserving as much static safety as possible.

#### 1.2.3 Missing Non-Uniform Index Annotation Mechanism

Bindless descriptor indexing introduces a **critical distinction between uniform and non-uniform dynamic indexing** that FIR's EDSL currently cannot express. In Vulkan's execution model, **dynamically uniform indexing** means that all invocations within an invocation group (typically a draw call or compute workgroup) use the same index value, enabling hardware optimizations that assume coherent access patterns. **Non-uniform indexing**, where different invocations may use different indices, requires explicit annotation so that implementations can generate appropriate code sequences, potentially including waterfall loops or other divergence-handling mechanisms on hardware that lacks native non-uniform descriptor access. The GLSL extension **`GL_EXT_nonuniform_qualifier`** provides the **`nonuniformEXT()`** function for this annotation, while HLSL offers **`NonUniformResourceIndex()`**, but **FIR's EDSL lacks any equivalent mechanism**.

The absence of non-uniform annotation capability has **both functional and performance implications**. Functionally, shaders that perform non-uniform indexing without proper annotation may produce **undefined behavior or validation errors** on strict Vulkan implementations. The Vulkan SPIR-V environment specification explicitly requires `NonUniform` decorations on specific operands for non-uniform access patterns, with validation rules such as **VUID-RuntimeSpirv-None-10148** mandating decoration on "the operand corresponding to that resource (e.g. the pointer or sampled image operand)". Performance-wise, missing non-uniform annotations may cause implementations to assume uniform access when the actual access pattern is divergent, leading to **incorrect results or severe performance degradation**. Implementing non-uniform annotation in FIR requires not only adding a syntactic mechanism but also ensuring that the annotation **propagates correctly through the EDSL's operator hierarchy** to generate properly decorated SPIR-V, with the decoration appearing on the **final resource operand rather than intermediate computation results**.

### 1.3 Fork and Alternative Investigation Results

#### 1.3.1 Official Repository and Branch Analysis

Investigation of the **official FIR repository at `https://gitlab.com/sheaf/fir`** reveals **no explicit bindless descriptor indexing support** in the main development branch or documented feature roadmap. The project's focus remains on solidifying the core EDSL infrastructure, type system, and SPIR-V generation for standard Vulkan shader features. This finding indicates that bindless support would need to be **implemented as a new feature contribution** rather than activated from existing code. The absence of bindless in official branches suggests that the maintainers have prioritized foundational EDSL completeness over advanced Vulkan feature coverage, a reasonable decision given the complexity of type-safe shader embedding but one that leaves a gap for users requiring modern bindless rendering capabilities.

The repository structure and commit history, as inferred from project documentation and community discussions, shows active development in areas such as **improved type inference**, **expanded primitive type support**, and **enhanced SPIR-V optimization**. However, no branches or merge requests specifically address descriptor indexing. This situation presents both an opportunity and a challenge for bindless implementation: the **opportunity to design integration from first principles** without conflicting with existing partial implementations, and the **challenge of ensuring that new bindless constructs align with the project's architectural vision** and coding standards.

#### 1.3.2 Community Fork Search Outcomes

Comprehensive search of community forks and related projects has **not identified any existing implementation of bindless descriptor indexing specifically for FIR**. The Haskell GPU programming ecosystem includes several related projects, but none appear to have extended FIR with VK_EXT_descriptor_indexing support. This negative finding is significant because it indicates that **bindless FIR integration represents greenfield development** rather than adaptation of proven solutions. The search encompassed GitHub mirrors of the GitLab repository, Hackage package dependencies, and community forums where Haskell graphics programming is discussed.

The absence of community forks with bindless support may reflect several factors: the **relatively specialized nature of FIR's approach** compared to alternatives, the **complexity of implementing bindless within a type-safe EDSL framework**, and the **smaller user base of Haskell GPU programming** compared to C++ or Rust ecosystems. However, this situation also suggests that a well-implemented bindless extension for FIR could **fill a unique niche**, providing type-safe bindless shader programming that combines Haskell's strong static guarantees with modern Vulkan performance characteristics.

#### 1.3.3 Alternative Haskell GPU EDSL Evaluation (luminance, Accelerate, hspirv, wgpu-hs)

Evaluation of alternative Haskell GPU programming approaches reveals different trade-offs that may inform FIR's bindless integration design:

| Alternative | Abstraction Level | Bindless Support | Type Safety Approach | Vulkan Integration |
|-------------|-------------------|------------------|----------------------|-------------------|
| **FIR (current)** | EDSL for shaders | **None** | Type-level, compile-time | Direct SPIR-V generation |
| **luminance** | Graphics framework | Limited (backend-dependent) | Type-safe, runtime-checked | Via vulkan-api bindings |
| **Accelerate** | Data-parallel arrays | None | Type-level, shape polymorphism | CUDA/OpenCL primarily |
| **hspirv** | SPIR-V assembler | Manual capability | Low-level, manual validation | Direct SPIR-V output |
| **wgpu-hs** | WebGPU bindings | **None (WebGPU limitation)** | Runtime validation | Via wgpu-native |

The **luminance** ecosystem provides a type-safe graphics framework with Vulkan backend support, though its shader programming model differs from FIR's embedded approach, using an external shading language rather than Haskell EDSL. **Accelerate** focuses on data-parallel array computations with GPU code generation, targeting a higher level of abstraction than low-level shader programming and lacking direct Vulkan bindless support. **hspirv** offers direct SPIR-V manipulation capabilities in Haskell, which could serve as a foundation for bindless code generation but lacks FIR's high-level EDSL conveniences. **wgpu-hs** bindings to the WebGPU implementation provide a more modern graphics API abstraction, though **WebGPU itself does not support bindless descriptor indexing**, reflecting the extension's complexity and hardware dependency .

The most relevant precedent comes from **hspirv**, which demonstrates that Haskell can effectively represent low-level SPIR-V constructs including runtime arrays and decorations. However, FIR's challenge is not merely emitting correct SPIR-V but doing so through a **type-safe, user-friendly EDSL that preserves the project's safety guarantees while enabling bindless flexibility**.

## 2. Vulkan/SPIR-V Bindless Foundation Requirements

### 2.1 Extension and Capability Prerequisites

#### 2.1.1 VK_EXT_descriptor_indexing Feature Set (Promoted to Vulkan 1.2 Core)

The **`VK_EXT_descriptor_indexing` extension**, promoted to Vulkan 1.2 core, establishes the foundational capabilities for bindless descriptor arrays in Vulkan. This extension represents a **significant evolution in Vulkan's resource binding model**, introducing capabilities that enable shaders to access descriptor arrays with dynamic indices, tolerate unbound or partially bound descriptor sets, and update descriptors after they have been bound to command buffers. The extension's feature set is organized into several categories: **dynamic indexing capabilities** that relax compile-time index requirements, **non-uniform indexing capabilities** that allow divergence across shader invocations, and **binding flag behaviors** that control descriptor set update semantics and validation strictness .

For FIR integration, the most relevant extension features include **`runtimeDescriptorArray`**, which enables arrays of descriptors with sizes determined at descriptor set allocation time rather than shader compile time, and the various **`shader*ArrayNonUniformIndexing`** features that permit non-uniform access patterns for different descriptor types. The extension also introduces descriptor binding flags such as **`VK_DESCRIPTOR_BINDING_UPDATE_AFTER_BIND_BIT`**, which allows descriptor updates without command buffer invalidation, and **`VK_DESCRIPTOR_BINDING_PARTIALLY_BOUND_BIT`**, which permits descriptor sets to contain invalid descriptors as long as they are not accessed by shader execution . These features collectively enable the **bindless programming model** where a single, large descriptor set can contain all resources needed for a frame, with shaders selecting specific resources through dynamic indices passed via push constants or other mechanisms.

The Vulkan 1.2 promotion of this extension means that modern Vulkan applications can rely on core functionality rather than explicit extension enabling, though **hardware support remains optional** and must be queried through `VkPhysicalDeviceVulkan12Features` or the `VkPhysicalDeviceDescriptorIndexingFeatures` structure. For FIR's target audience, this promotion simplifies the runtime interface by reducing the number of extensions that must be explicitly managed, but the shader-side SPIR-V generation must still declare appropriate capabilities and use correct decoration patterns regardless of whether the functionality is accessed through core or extension interfaces.

#### 2.1.2 Required Physical Device Features: runtimeDescriptorArray, descriptorBindingVariableDescriptorCount

Among the descriptor indexing features, **`runtimeDescriptorArray`** and **`descriptorBindingVariableDescriptorCount`** are particularly critical for FIR's bindless integration. The `runtimeDescriptorArray` feature enables the declaration of **runtime-sized arrays in shaders**, corresponding to SPIR-V's `OpTypeRuntimeArray`. Without this feature, shader compilers must reject arrays with unspecified sizes, preventing the fundamental bindless pattern of declaring a large, potentially unbounded array of descriptors. This feature's availability varies across hardware generations, with **full support typically found in desktop GPUs from the Vulkan 1.2 era onward** and more limited support on mobile devices .

The `descriptorBindingVariableDescriptorCount` feature complements `runtimeDescriptorArray` by allowing **descriptor set layouts to specify variable descriptor counts for the last binding in a descriptor set layout**. This enables efficient allocation where the actual number of descriptors can vary per descriptor set rather than being fixed at layout creation time. For FIR applications, this feature is essential for scenarios like **texture streaming** where the number of active textures changes frame-to-frame, or for **GPU-driven rendering** where the number of visible mesh sections varies with view frustum and occlusion results. The combination of runtime descriptor arrays and variable descriptor counts allows a **single pipeline layout to accommodate arbitrary resource quantities**, eliminating the need for shader variants or pipeline state changes when resource counts vary.

| Feature | SPIR-V Capability | GLSL Extension | Use Case | Hardware Support |
|---------|-------------------|--------------|----------|----------------|
| `runtimeDescriptorArray` | `RuntimeDescriptorArray` | `GL_EXT_descriptor_indexing` | Unsized descriptor arrays | Vulkan 1.2+ desktop, limited mobile |
| `descriptorBindingVariableDescriptorCount` | (runtime only) | N/A | Variable array sizes per descriptor set | Same as `runtimeDescriptorArray` |
| `shaderSampledImageArrayNonUniformIndexing` | `SampledImageArrayNonUniformIndexing` | `GL_EXT_nonuniform_qualifier` | Non-uniform texture sampling | Widely supported on desktop |
| `shaderStorageBufferArrayNonUniformIndexing` | `StorageBufferArrayNonUniformIndexing` | `GL_EXT_nonuniform_qualifier` | Non-uniform SSBO access | Widely supported on desktop |
| `descriptorBindingUpdateAfterBind` | (runtime behavior) | N/A | Descriptor updates without rebind | Vulkan 1.2+ |

#### 2.1.3 Non-Uniform Indexing Capabilities: shaderSampledImageArrayNonUniformIndexing, shaderStorageBufferArrayNonUniformIndexing, etc.

Non-uniform indexing capabilities define **which descriptor types can be accessed with indices that vary across shader invocations** within an invocation group. The Vulkan specification provides **separate capability bits for each descriptor type**, allowing implementations to expose non-uniform indexing for some resource types while requiring uniform indexing for others. For FIR's comprehensive bindless support, the relevant capabilities include:

- **`shaderSampledImageArrayNonUniformIndexing`** for texture and image sampling
- **`shaderStorageImageArrayNonUniformIndexing`** for storage image read/write operations
- **`shaderUniformBufferArrayNonUniformIndexing`** and **`shaderStorageBufferArrayNonUniformIndexing`** for buffer access
- **`shaderInputAttachmentArrayNonUniformIndexing`** for input attachments in render subpasses
- **`uniformTexelBufferArrayNonUniformIndexing`** and **`storageTexelBufferArrayNonUniformIndexing`** for texel buffer views 

The granularity of these capabilities reflects **hardware implementation realities**, as different resource types may have different access paths and caching behaviors that affect non-uniform indexing feasibility. Sampled images, which typically involve texture sampling units with dedicated caches, often have the most mature non-uniform indexing support, while storage buffers may have more restrictions due to memory coherency considerations. FIR's type system could potentially **track non-uniform indexing capability requirements at the type level**, ensuring that shaders only use non-uniform indexing for resource types where the corresponding Vulkan feature is available. This would maintain FIR's safety-oriented design philosophy while accommodating hardware variation.

The practical importance of non-uniform indexing capabilities is evident in **modern rendering techniques**. GPU-driven rendering pipelines frequently use draw data indices that vary per-instance to select materials, meshes, and animation data from large descriptor arrays. Deferred shading and clustered lighting may access different light data structures per pixel based on screen-space tile assignments. Without non-uniform indexing, these techniques would require **expensive sorting or binning** to ensure uniform access patterns, negating much of the performance benefit of GPU-driven approaches. FIR's support for non-uniform indexing would enable these techniques within its type-safe framework.

#### 2.1.4 Descriptor Binding Flags: VK_DESCRIPTOR_BINDING_UPDATE_AFTER_BIND_BIT, VK_DESCRIPTOR_BINDING_PARTIALLY_BOUND_BIT

Descriptor binding flags control the **runtime behavior of descriptor sets** and are essential for practical bindless implementations. The **`VK_DESCRIPTOR_BINDING_UPDATE_AFTER_BIND_BIT`** flag allows applications to update descriptors in a set after it has been bound to a command buffer, with the update taking effect for subsequent command submissions without requiring command buffer re-recording. This capability is **fundamental to bindless texture streaming**, where new mip levels or newly loaded textures must be integrated into the global descriptor set without disrupting in-flight rendering . The **`VK_DESCRIPTOR_BINDING_PARTIALLY_BOUND_BIT`** flag permits descriptor set bindings to contain invalid or null descriptors, as long as shader execution does not access these invalid entries. This enables **safe allocation of large descriptor arrays with sparse usage patterns**, where only a subset of potential entries are populated at any given time.

Additional binding flags include **`VK_DESCRIPTOR_BINDING_UPDATE_UNUSED_WHILE_PENDING_BIT`**, which allows updating descriptors that are not referenced by currently executing shaders, and **`VK_DESCRIPTOR_BINDING_VARIABLE_DESCRIPTOR_COUNT_BIT`**, which enables variable-sized descriptor arrays as discussed previously. These flags are specified per-binding in the `VkDescriptorSetLayoutBinding` structure and affect both descriptor set allocation and shader validation behavior. For FIR integration, the **Haskell Vulkan bindings** (such as the `vulkan` package on Hackage) must support these flag specifications, and FIR's runtime interface layer must provide convenient mechanisms for setting appropriate flags based on shader requirements.

The interaction between binding flags and shader code patterns requires careful attention. For example, using `PARTIALLY_BOUND` without proper shader-side validation can lead to **undefined behavior if shader logic computes invalid indices**. FIR's type system could potentially track which descriptor arrays are declared as partially bound, enabling compile-time warnings or runtime validation for index bounds checking. Similarly, `UPDATE_AFTER_BIND` requires synchronization considerations to ensure that descriptor updates are visible to shader execution at appropriate pipeline stages.

### 2.2 SPIR-V Representation Essentials

#### 2.2.1 OpTypeRuntimeArray for Unsized Descriptor Arrays

At the SPIR-V instruction level, **runtime-sized descriptor arrays are represented through the `OpTypeRuntimeArray` instruction**, which declares an array type with unspecified element count. This instruction takes a single operand specifying the element type and is used in global variable declarations for resources that will be accessed through descriptor indexing. In the context of bindless rendering, `OpTypeRuntimeArray` typically appears in `OpTypeStruct` definitions for uniform or storage blocks, or directly in `OpVariable` declarations for descriptor arrays. The runtime array **must be the final member of a struct** when used in buffer contexts, reflecting the memory layout flexibility needed for variable-sized data .

For FIR's code generation, supporting `OpTypeRuntimeArray` requires **extending the type representation to include runtime-sized array constructs** and modifying the global variable emission logic to use this instruction type. The current generation pipeline likely uses `OpTypeArray` with constant size operands for all array types, and this must be generalized to **select between fixed-size and runtime-size array representations** based on type-level information. Additionally, the `OpArrayLength` instruction can query the runtime length of runtime arrays in buffer contexts, which may be useful for bounds checking or iteration patterns in shader code. FIR's EDSL could expose this operation through a dedicated combinator, enabling shaders to adapt their behavior based on actual array sizes.

The Vulkan validation rules for `OpTypeRuntimeArray` impose specific constraints: runtime arrays can only appear in certain storage classes (primarily `Uniform` and `StorageBuffer`), must be the last member of a struct when used in buffer contexts, and require the **`RuntimeDescriptorArray` capability** to be declared in the SPIR-V module. These constraints must be enforced by FIR's type checker and code generator to produce valid SPIR-V.

#### 2.2.2 NonUniform Decoration Semantics and Placement Rules

The **`NonUniform` decoration** (also known as `NonUniformEXT` in extension contexts) is SPIR-V's mechanism for indicating that a value or instruction result **may vary across invocations** within an invocation group, requiring implementation-specific handling for correct execution. This decoration is critical for bindless descriptor indexing because **hardware implementations often optimize for uniform access patterns**, and incorrect uniformity assumptions can lead to undefined behavior or severe performance degradation. The SPIR-V specification defines `NonUniform` as applicable to object `<id>`s, asserting that "the value backing the decorated `<id>` is not dynamically uniform" .

The placement rules for `NonUniform` decorations are specified in detail by the Vulkan SPIR-V environment specification and have been refined through implementation experience. **Critical validation rule VUID-RuntimeSpirv-None-10148** states that for non-uniform resource access, "the operand corresponding to that resource (e.g. the pointer or sampled image operand) must be decorated with `NonUniform`" . This rule has important implications for where decorations must appear in the instruction chain. For sampled image access, the decoration must appear on the **final `OpSampledImage` result or the loaded image variable**, not merely on the index variable or intermediate `OpAccessChain` results. For storage buffer access, the decoration must appear on the **pointer operand to the load or store instruction**.

Recent bug reports from the **Slang compiler project** illustrate the consequences of incorrect decoration placement. Slang's SPIR-V backend was found to place `NonUniform` on earlier values in the access chain while missing it on critical final resource operands, causing **rendering glitches on RADV drivers** that strictly enforce validation requirements . The correct SPIR-V pattern requires decorating the index variable, the access chain result, and crucially the **final loaded resource operand**:

```spvasm
; Correct NonUniform placement for sampled image access
%29 = OpCompositeExtract %uint %28 0                ; NonUniform
%35 = OpAccessChain %_ptr_UniformConstant_30 %bindless_storage_buffers_1 %29    ; NonUniform
%47 = OpLoad %21 %26                                ; NonUniform
%sampledImage = OpSampledImage %59 %58 %55          ; NonUniform
%sampled_0 = OpImageSampleExplicitLod %v4float %sampledImage %float_0 Lod %float_0
```

This pattern demonstrates that **multiple instructions in the chain may carry `NonUniform` decorations**, but the critical decoration on the final resource operand must not be omitted.

#### 2.2.3 Required SPIR-V Capabilities and Extensions: SPV_EXT_descriptor_indexing

Bindless descriptor indexing in SPIR-V requires **declaration of specific capabilities and extensions** in the generated module header. The `SPV_EXT_descriptor_indexing` extension (or `SPV_KHR_descriptor_indexing` for Khronos ratification) provides the SPIR-V-side specification of bindless capabilities, while individual capabilities such as `RuntimeDescriptorArray`, `SampledImageArrayNonUniformIndexing`, and their counterparts for other descriptor types enable specific functionality. The SPIR-V module must declare **`OpExtension "SPV_EXT_descriptor_indexing"`** or the KHR variant, followed by **`OpCapability`** instructions for each capability used by the module's instructions .

The capability declaration requirements are precise: a module using `OpTypeRuntimeArray` must declare `RuntimeDescriptorArray`, while modules using `NonUniform` decorations on specific resource types must declare the corresponding non-uniform indexing capability. **Using capabilities without declaring them, or declaring capabilities without using them, may result in validation warnings or errors** depending on the validation layer configuration. FIR's code generator must track which bindless features are used by a shader and emit appropriate capability declarations, potentially through a **capability analysis pass** that inspects the generated instruction stream.

The extension and capability system also interacts with Vulkan's feature querying mechanism. Even if SPIR-V declares a capability, **the Vulkan device must support the corresponding feature** for shader execution to be valid. This two-level validation (SPIR-V capability validation and Vulkan feature validation) means that FIR's runtime interface must ensure **feature-capability consistency**, either by checking device features at shader load time or by providing compile-time configuration that restricts generated capabilities to known-supported features.

#### 2.2.4 Critical Decoration Placement: Resource Operand vs. Index Operand (VUID-RuntimeSpirv-None-10148)

The distinction between decorating **index operands versus resource operands** represents one of the most subtle and error-prone aspects of bindless SPIR-V generation. Vulkan validation rule **VUID-RuntimeSpirv-None-10148** explicitly requires decoration on the **resource operand consumed by memory-accessing instructions**, not merely on the index used to compute that operand . This requirement stems from **hardware implementation details** where the critical divergence point is the resource access itself, not the index computation leading to it.

For different instruction types, the "resource operand" is defined differently:

| Instruction Type | Resource Operand | NonUniform Placement |
|-----------------|------------------|----------------------|
| `OpImageSample*` | Sampled image operand (result of `OpSampledImage`) | Decorate `OpSampledImage` result or loaded image |
| `OpImageFetch` | Image operand | Decorate loaded image variable |
| `OpImageRead`/`OpImageWrite` | Image operand | Decorate loaded image variable |
| `OpLoad`/`OpStore` (buffers) | Pointer operand | Decorate `OpAccessChain` result or loaded pointer |
| `OpAtomic*` | Pointer operand | Decorate `OpAccessChain` result |

The Slang compiler's experience demonstrates that **decorating only the index variable and intermediate access chain results is insufficient**. In the problematic pattern, `NonUniform` appeared on `%29` (the index extraction) and `%35` (the access chain), but was missing on `%47` (the loaded buffer variable), `%sampledImage` (the sampled image construction), and `%68` (another loaded variable) . This incomplete decoration caused RADV drivers to miss the non-uniform indication for actual resource access points, leading to **incorrect code generation and visible rendering artifacts**.

For FIR's EDSL integration, this decoration semantics implies that the `nonUniform` annotation **must propagate through the entire access chain** to ensure correct placement. If FIR provides a combinator like `nonUniform :: Expr Word32 -> Expr Word32` that marks an index as potentially divergent, the code generator must **track this non-uniformity through subsequent array access operations** and apply decorations to both intermediate results and final resource operands. This **propagation analysis** is essential for correct bindless SPIR-V generation and represents a significant engineering challenge in maintaining FIR's high-level abstraction while producing low-level-correct code.

### 2.3 Shader Language Precedents

#### 2.3.1 GLSL: GL_EXT_nonuniform_qualifier and nonuniformEXT() Syntax

GLSL's approach to non-uniform indexing through the **`GL_EXT_nonuniform_qualifier` extension** provides the most direct precedent for FIR's EDSL design. This extension introduces the **`nonuniformEXT()` function** that can be applied to index expressions or resource expressions to indicate non-uniform access. The syntax is flexible: `nonuniformEXT` can appear on the array index (`texture(mySampler[nonuniformEXT(index)], uv)`), on the entire sampled image expression (`texture(nonuniformEXT(sampler2D(Tex[index], Sampler)), UV)`), or on the resource array variable itself in certain contexts  .

The GLSL extension also provides the **`nonuniform` qualifier** that can be applied to variables, indicating that all uses of that variable should be treated as non-uniform. This is particularly useful for indices computed through complex expressions or passed between shader stages. For example, when `gl_DrawID` is used to compute a texture index, the resulting value may need non-uniform qualification even though `gl_DrawID` itself is dynamically uniform:

```glsl
#extension GL_EXT_nonuniform_qualifier : require
#extension GL_ARB_shader_draw_parameters : require

layout(set = 2, binding = 0) uniform ShaderOptions {
    uint albedo_texture_indices[];
} shader_options;

void main() {
    uint albedo_texture_index = shader_options.albedo_texture_indices[gl_DrawID];
    float4 albedo = texture(global_textures[nonuniformEXT(albedo_texture_index)], uv);
}
```

This pattern from the Vulkan guide demonstrates the **common case where a dynamically uniform expression (`gl_DrawID`) is used to index into an array, producing a value that is then used for non-uniform resource access** . The `nonuniformEXT` annotation on `albedo_texture_index` ensures correct handling even though the original draw ID was uniform.

For FIR's EDSL, GLSL's syntax suggests several design options: a **function-like combinator** applied to index expressions, a **type qualifier** that propagates non-uniformity, or a **wrapper type** that must be explicitly unwrapped for resource access. The function-like approach (`nonUniform index`) aligns well with FIR's existing combinator style and provides **clear syntactic indication of non-uniform intent at the point of use**.

#### 2.3.2 HLSL: NonUniformResourceIndex() Equivalent

HLSL provides the **`NonUniformResourceIndex()` intrinsic function** for non-uniform indexing in bindless scenarios, particularly with DirectX 12's ResourceDescriptorHeap and SamplerDescriptorHeap features introduced in Shader Model 6.6. The syntax places `NonUniformResourceIndex` around the index expression used to access descriptor heaps:

```hlsl
Texture2D<float4> Textures[] : register(t0, space0);
SamplerState Samp : register(s0, space0);
float4 color = Textures[NonUniformResourceIndex(index)].Sample(Samp, UV);
```

HLSL's approach differs from GLSL in that `NonUniformResourceIndex` is **specifically an index modifier** rather than a general non-uniform qualifier, and it integrates with DirectX's descriptor heap abstraction rather than Vulkan's descriptor set model. However, the **underlying semantic requirement is identical**: informing the compiler that the index may vary across invocations, enabling appropriate code generation for divergence handling .

The **Shader Model 6.6 `ResourceDescriptorHeap` and `SamplerDescriptorHeap` features** provide an even more direct bindless model, where all descriptors reside in a single heap and are accessed by integer indices without explicit binding declarations. This model simplifies descriptor management but requires the `D3D12_ROOT_SIGNATURE_FLAG_CBV_SRV_UAV_HEAP_DIRECTLY_INDEXED` and `D3D12_ROOT_SIGNATURE_FLAG_SAMPLER_HEAP_DIRECTLY_INDEXED` flags in the root signature . While FIR targets Vulkan rather than DirectX, HLSL's evolution toward increasingly direct descriptor access **informs the design space** for FIR's bindless support, suggesting that future extensions might consider even more streamlined access patterns as Vulkan capabilities evolve.

#### 2.3.3 Slang: Bindless<T> Type Wrapper Approach

The **Slang shading language** explores a **type-system-oriented approach to bindless** through generic type wrappers and interface-based resource access. Slang's design allows generic functions to operate over any resource type satisfying a capability interface, with bindless arrays represented as generic `Bindless<T>` or similar constructs. This approach provides **type safety through parametric polymorphism** while enabling the flexibility of runtime resource selection. Slang's SPIR-V backend implementation, including the decoration placement issues discussed previously, demonstrates **both the feasibility and the pitfalls of generating correct bindless SPIR-V from a high-level type-safe language** .

Slang's experience is particularly relevant to FIR because **both languages prioritize type safety and generic programming**. Slang's approach of using type wrappers to distinguish bindless from bound resources could translate to FIR as a type constructor `Bindless :: DescriptorType -> DescriptorType`, allowing the type system to track which resources require bindless code generation paths. The challenges Slang encountered with `NonUniform` decoration placement also highlight the **importance of careful code generator design**, where high-level type information must correctly propagate to low-level decoration attachment points.

## 3. EDSL Integration Design for FIR

### 3.1 Type System Extensions

#### 3.1.1 Bindless Kind or Type Constructor Introduction

Extending FIR's type system for bindless support requires introducing **new type-level constructs that distinguish bindless resources from traditionally bound resources**. A promising approach is the introduction of a **`Bindless` type constructor** that wraps existing descriptor types, creating a kind-preserving transformation that maintains FIR's type safety guarantees while enabling bindless access patterns. This constructor would appear in type signatures as `Bindless (SampledImage2D a)` or `Bindless (StorageBuffer b)`, indicating that the underlying resource type is accessed through bindless descriptor indexing rather than fixed binding.

The `Bindless` constructor serves **multiple purposes in the type system**. **First**, it enables distinct type class instances for bindless resource operations, ensuring that bindless arrays use different code generation paths than fixed-size arrays. **Second**, it carries type-level information about the binding configuration, such as which descriptor set contains the bindless array and which binding index identifies it. **Third**, it can participate in type-level constraints that ensure bindless resources are only used with appropriate Vulkan features enabled. For example, a type family could map `Bindless (SampledImage2D a)` to a constraint requiring `SampledImageArrayNonUniformIndexing` capability support.

An alternative or complementary approach introduces a **`RuntimeSized` type constructor** specifically for array dimensions, distinguishing `Array RuntimeSized (SampledImage2D a)` from `Array (Static n) (SampledImage2D a)`. This finer-grained distinction allows mixed scenarios where some array dimensions are statically known while others are runtime-determined, though in practice most bindless arrays are uniformly runtime-sized. The choice between these approaches involves **trade-offs in type system complexity, error message clarity, and implementation effort**.

#### 3.1.2 Runtime-Sized Array Type Representation

Representing runtime-sized arrays in FIR's type system requires **balancing expressiveness against the compile-time safety guarantees** that motivate the project's design. A practical approach introduces a **`RuntimeArray` type distinct from the existing fixed-size `Array` type**, with `RuntimeArray a` representing an array of elements of type `a` with size determined at descriptor set allocation time. This type would appear in shader interface declarations and propagate through the type system to constrain valid operations.

The `RuntimeArray` type supports several **key operations**: element access via dynamic indexing (producing `Expr a` from `Expr RuntimeArray a` and `Expr Word32` index), length query via `OpArrayLength` (producing `Expr Word32`), and potentially bounded iteration combinators. However, it **excludes operations that require static size knowledge**, such as compile-time bounds checking or fixed-size vector conversions. This restriction maintains type safety by preventing operations that cannot be correctly implemented for unknown-sized arrays.

**Type-level programming techniques** can enhance the runtime array representation with additional safety properties. For example, a phantom type parameter could track the descriptor set and binding of a runtime array, preventing accidental cross-binding access:

```haskell
data RuntimeArray (set :: Nat) (binding :: Nat) a

-- Access requires matching set/binding context
access :: KnownNat set => KnownNat binding 
       => Expr (RuntimeArray set binding a) 
       -> Expr Word32 
       -> Expr a
```

This encoding ensures that **runtime array variables can only be used in the descriptor context where they were declared**, catching a class of binding errors at compile time.

#### 3.1.3 Preservation of Compile-Time Safety for Uniform Access Patterns

A critical design challenge is **preserving FIR's compile-time safety guarantees for scenarios where bindless arrays are accessed with uniform indices**. When all invocations use the same index, the access pattern is dynamically uniform and does not require `NonUniform` decoration, enabling hardware optimizations that assume coherent access. FIR's type system could potentially **track index uniformity through the type of index expressions**, distinguishing `Uniform (Expr Word32)` from potentially non-uniform `Expr Word32`.

Tracking uniformity at the type level involves **significant complexity**, as uniformity depends on control flow and data dependencies that may be difficult to analyze statically. A pragmatic compromise introduces **explicit uniformity annotations** that developers apply to index expressions they know to be uniform, with the type system verifying that these annotations are only used in appropriate contexts. For example:

```haskell
-- Explicit uniformity annotation
uniformIndex :: Expr Word32 -> Expr (Uniform Word32)

-- Runtime array access with uniform index (no NonUniform decoration)
accessUniform :: Expr (RuntimeArray a) -> Expr (Uniform Word32) -> Expr a

-- Runtime array access with potentially non-uniform index (requires NonUniform)
accessDynamic :: Expr (RuntimeArray a) -> Expr Word32 -> Expr a
```

This design **preserves safety by requiring explicit developer choice** between uniform and dynamic access paths, with the code generator producing appropriate SPIR-V for each path. The explicit annotation approach aligns with FIR's philosophy of **making important properties visible in types**, though it adds syntactic overhead compared to automatic uniformity inference.

#### 3.1.4 Type-Level Distinction Between Uniform and Non-Uniform Indices

Building on uniformity tracking, the type system can **distinguish index expressions that are known uniform, potentially non-uniform, or explicitly marked non-uniform**. This distinction enables targeted code generation and validation: uniform indices generate simple array access without `NonUniform` decoration, potentially non-uniform indices generate conservative code with decoration, and explicitly marked non-uniform indices generate decoration with validation that the corresponding Vulkan feature is available.

A **type family approach** can implement this distinction:

```haskell
type family IndexUniformity (u :: Uniformity) :: Constraint where
  IndexUniformity 'Uniform = ()
  IndexUniformity 'NonUniform = HasNonUniformIndexing a  -- capability constraint

data Expr (u :: Uniformity) a where
  UniformExpr :: a -> Expr 'Uniform a
  NonUniformExpr :: a -> Expr 'NonUniform a
  UnknownExpr :: a -> Expr 'Unknown a
```

This encoding allows operations to **specify uniformity requirements in their types**, with the type checker ensuring that non-uniform access only occurs where supported. The `Unknown` uniformity level represents expressions where static analysis cannot determine uniformity, **defaulting to conservative non-uniform code generation**.

### 3.2 New EDSL Combinators and Operators

#### 3.2.1 nonUniform Index Annotation Function

The **central new combinator for bindless support is `nonUniform`**, which annotates an index expression as potentially non-uniform across invocations. This combinator serves as FIR's equivalent to GLSL's `nonuniformEXT()` and HLSL's `NonUniformResourceIndex()`, providing **explicit syntactic indication of non-uniform intent**. The combinator's type signature reflects its uniformity-transforming behavior:

```haskell
nonUniform :: Expr a -> Expr (NonUniform a)
```

Or, integrating with the uniformity-indexed expression type:

```haskell
nonUniform :: Expr 'Unknown a -> Expr 'NonUniform a
nonUniform :: Expr 'Uniform a -> Expr 'NonUniform a  -- explicit override
```

The `nonUniform` combinator's implementation in the code generator must ensure that **the resulting expression and all dependent resource access operations receive appropriate `NonUniform` decorations**. This propagation requires the code generator to track non-uniformity through the expression graph, applying decorations to index extractions, access chain computations, and crucially the **final resource operands consumed by memory operations**. The Slang compiler's experience with incorrect decoration placement  underscores the importance of thorough propagation analysis.

Beyond simple index annotation, `nonUniform` could support **pattern matching or conditional application**:

```haskell
-- Conditional non-uniform based on runtime flag
nonUniformIf :: Expr Bool -> Expr a -> Expr a -> Expr (NonUniform a)

-- Non-uniform with explicit capability evidence
nonUniformWithEvidence :: NonUniformIndexingEvidence t -> Expr a -> Expr (NonUniform a)
```

These variants provide **additional flexibility for complex scenarios** while maintaining type safety through explicit evidence passing.

#### 3.2.2 Bindless Array Declaration Syntax

Declaring bindless arrays in FIR's EDSL requires syntax that **integrates with existing resource declaration patterns** while indicating the bindless nature of the array. A natural approach extends the current uniform/input/output declaration syntax with a `bindless` keyword or modifier:

```haskell
-- Bindless sampled image array declaration
myTextures :: BindlessArray (SampledImage2D RGBA8) 
myTextures = bindlessArray @Set0 @Binding0

-- Bindless storage buffer array declaration  
myBuffers :: BindlessArray (StorageBuffer MyBufferType)
myBuffers = bindlessArray @Set0 @Binding1
```

The **`BindlessArray` type constructor** combines the runtime-sized array aspect with bindless binding configuration, while `bindlessArray` creates the declaration with explicit set and binding type-level parameters. This syntax **mirrors FIR's existing fixed-binding declarations** but with clear indication of bindless semantics.

Alternative syntax options include using the `Bindless` type constructor directly on array types:

```haskell
myTextures :: Bindless (RuntimeArray (SampledImage2D RGBA8))
```

Or integrating bindless into the binding specification:

```haskell
myTextures :: SampledImage2D RGBA8 `At` Set0 `Binding` Bindless
```

The choice between these options involves **readability, consistency with existing syntax, and extensibility** for future binding models.

#### 3.2.3 Array Access Operator Overloads for Bindless Contexts

Array access for bindless arrays requires **operator definitions that generate appropriate SPIR-V based on index uniformity**. FIR's existing array indexing operators (likely `!` or similar) must be overloaded or extended for bindless array types, with the uniformity of the index expression determining the generated code pattern.

```haskell
-- Uniform index access (no NonUniform decoration)
(!) :: Expr (BindlessArray a) -> Expr (Uniform Word32) -> Expr a

-- Dynamic index access (conservative NonUniform decoration)
(!) :: Expr (BindlessArray a) -> Expr Word32 -> Expr a

-- Explicit non-uniform index access (NonUniform decoration with validation)
(!) :: Expr (BindlessArray a) -> Expr (NonUniform Word32) -> Expr a
```

The **multiple type class instances for `!`** enable type-directed code generation, with the most specific instance matching the actual index type. This approach leverages Haskell's type class resolution to **select appropriate SPIR-V generation strategies** without explicit syntax beyond the index expression's type.

For **combined image sampler access**, additional combinators may be needed to construct sampled images from separate texture and sampler arrays before sampling:

```haskell
-- Construct sampled image from bindless texture and sampler
sampledImage :: Expr (BindlessArray (Image2D a)) -> Expr Sampler -> Expr (SampledImage2D a)

-- Sample with non-uniform texture selection
sample :: Expr (SampledImage2D a) -> Expr Vec2 -> Expr a
```

These combinators must ensure that **non-uniformity annotations propagate correctly** to the final sampled image construction.

#### 3.2.4 Integration with Existing FIR Field and Texture Operations

The bindless extension must **integrate seamlessly with FIR's existing operations for field access, texture sampling, and buffer loading**. When a bindless array access produces a texture reference, that reference should be usable with all existing texture sampling operations without requiring separate bindless-specific variants. Similarly, bindless buffer access should compose with FIR's field optics for structured buffer data access.

This integration can be achieved through **type class polymorphism** in the existing operations. For example, the `sample` operation could be generalized to accept any expression of sampled image type, whether produced by direct binding reference or by bindless array access:

```haskell
class Sampleable img where
  sample :: img -> Expr Vec2 -> Expr a

instance Sampleable (Expr (SampledImage2D a)) where
  -- existing implementation

instance Sampleable (Expr (BindlessArray (SampledImage2D a), Expr Word32)) where
  -- bindless array element sampling
```

Alternatively, **bindless array access could produce values of the same types as direct binding references**, with the bindless nature tracked only through the expression's provenance metadata rather than its result type. This approach **minimizes API surface changes** but may complicate code generation that needs to distinguish bindless from bound access patterns.

### 3.3 SPIR-V Code Generation Modifications

#### 3.3.1 Runtime Array Type Emission (OpTypeRuntimeArray)

The SPIR-V backend requires **new instruction selection patterns to emit `OpTypeRuntimeArray`** for bindless descriptor types. The emission logic must:

1. **Detect `Bindless` or `RuntimeArray` types** in the shader interface declaration
2. **Emit `OpCapability RuntimeDescriptorArray`** in the module header
3. **Emit `OpTypeRuntimeArray %elementType`** for the array type
4. **Wrap in appropriate pointer and struct types** for the binding context
5. **Attach `ArrayStride` decorations** where required for buffer-backed arrays

For **descriptor-backed runtime arrays** (textures, samplers, etc.), the `OpVariable` declaration uses the runtime array type directly with a `UniformConstant` storage class. For **buffer-backed runtime arrays**, the runtime array is the final member of a struct with `BufferBlock` or `Block` decoration.

The type emission must also handle **nested struct types** that may contain runtime arrays as their final member, ensuring that `ArrayStride` and `Offset` decorations are correctly computed even when the total struct size is unknown at compile time. This may require **deferred stride computation** or conservative alignment assumptions based on the element type's properties.

#### 3.3.2 NonUniform Decoration Emission Logic

Non-uniform decoration emission requires **tracking non-uniformity from the EDSL through intermediate representation to final SPIR-V**. A dedicated compiler pass should:

1. **Identify all values marked as `NonUniform`** in the EDSL
2. **Propagate non-uniformity through dependent instructions** (arithmetic, composite operations)
3. **Attach `NonUniform` decorations to the correct final instruction operands**:
   - The index operand of `OpAccessChain` for array indexing
   - The pointer operand of `OpLoad`/`OpStore` for buffer access
   - The image or sampled image operand of texture operations

The propagation logic must handle **complex expression patterns** where non-uniformity flows through function calls, control flow, and composite construction/deconstruction. **Conservative propagation** (marking all potentially affected values as non-uniform) is safer but may reduce optimization opportunities; **precise propagation** requires more sophisticated analysis but yields better performance.

The implementation should draw on the **detailed examples from the Slang project's bug fixes** , which demonstrate correct decoration placement for multiple resource access patterns. A **verification step**, enabled in debug builds, could cross-check decoration placement against the Vulkan specification's requirements by inspecting generated SPIR-V and validating that all resource operands of memory-accessing instructions are properly decorated when their access indices originate from `nonUniform` annotations.

#### 3.3.3 Capability Declaration in Generated SPIR-V Modules

Capability computation for bindless shaders must **aggregate requirements across all bindless operations in the module**. A capability mapping:

| EDSL Operation | Required SPIR-V Capability |
|----------------|---------------------------|
| `RuntimeArray` of any descriptor type | `RuntimeDescriptorArray` |
| Non-uniform sampled image indexing | `SampledImageArrayNonUniformIndexing` |
| Non-uniform storage image indexing | `StorageImageArrayNonUniformIndexing` |
| Non-uniform uniform buffer indexing | `UniformBufferArrayNonUniformIndexing` |
| Non-uniform storage buffer indexing | `StorageBufferArrayNonUniformIndexing` |
| Non-uniform input attachment indexing | `InputAttachmentArrayNonUniformIndexing` |

The backend should implement **capability collection as a fold over the intermediate representation**, emitting the minimal required capability set. **Over-declaration of capabilities unnecessarily restricts hardware compatibility**, while under-declaration produces invalid SPIR-V. The capability analysis should also track **which Vulkan extension or core version** provides each capability, ensuring correct `OpExtension` declarations for pre-Vulkan 1.2 targets.

#### 3.3.4 Validation Against Vulkan Environment Specification

Generated SPIR-V must pass validation against the **Vulkan environment specification**, which imposes additional constraints beyond core SPIR-V validity. Key validation rules for bindless include:

- **VUID-RuntimeSpirv-OpTypeRuntimeArray-06273**: Runtime arrays of descriptors require `RuntimeDescriptorArray` capability
- **VUID-RuntimeSpirv-NonUniform-06274**: Correct placement of `NonUniform` decorations
- **VUID-RuntimeSpirv-None-10148**: Resource operand decoration requirements

FIR's test suite should incorporate **`spirv-val` with `--target-env vulkan1.2`** (or appropriate version) to verify generated modules. Integration with the **Vulkan Validation Layers** through Haskell's `vulkan` package would provide additional runtime verification, catching issues such as capability-feature mismatches or incorrect descriptor set layout configurations.

## 4. Implementation Architecture and Component Changes

### 4.1 Compiler Frontend Modifications

#### 4.1.1 AST Extensions for Bindless Constructs

The frontend abstract syntax tree requires extensions to **represent bindless array declarations, bindless array access operations, and non-uniform index annotations**. New AST node types would include:

```haskell
-- Runtime-sized array type
data Type a where
  -- existing constructors...
  RuntimeArrayType :: Type a -> Type (RuntimeArray a)
  BindlessType :: Type a -> Type (Bindless a)
  NonUniformType :: Type a -> Type (NonUniform a)

-- Non-uniform expression annotation
data Expr a where
  -- existing constructors...
  NonUniform :: Expr a -> Expr (NonUniform a)
  RuntimeArrayAccess :: Expr (RuntimeArray a) -> Expr i -> Expr a
```

These extensions **integrate with existing AST traversal and pretty-printing infrastructure**, with pattern synonyms preserving backward compatibility for code not using bindless features. The `NonUniform` node carries metadata linking it to the source `nonUniform` combinator application, enabling **accurate error reporting** that references user code locations.

The AST extensions should also support **bindless array declarations as global variables**, with nodes that capture the binding configuration, element type, and optional maximum size. These declaration nodes participate in the existing global variable analysis that computes shader interface requirements and validates binding consistency across shader stages.

#### 4.1.2 Type Checker Enhancements for Runtime-Sized Arrays

The type checker must **validate that runtime-sized arrays are used correctly**: only as the final element of buffer structs, only with appropriate binding flags, and with non-uniform indices where required. New typing rules:

- **`RuntimeArray a` is a valid shader interface type only with `Bindless` wrapper or in `StorageBuffer`/`UniformBuffer` contexts**
- **`RuntimeArrayAccess` requires the index type to match the array's index type**, with `NonUniform` wrapper for non-uniform access
- **`NonUniform` annotation is required (or strongly recommended via warning) for `RuntimeArray` accesses in certain descriptor contexts**

The type checker should also enforce **structural constraints on runtime array placement**: within buffer block structs, the runtime array must be the final member, and no other members may follow it. This validation prevents generation of invalid SPIR-V that would fail Vulkan environment validation.

**Capability constraint generation** is another critical type checker responsibility. When type checking encounters non-uniform indexing of a specific descriptor type, the type checker should generate a **capability constraint** that is later solved against the target device's feature set. Unsatisfied constraints produce **clear error messages** indicating which Vulkan feature is required and how to enable it or restructure the code to avoid the requirement.

#### 4.1.3 Error Reporting for Invalid Non-Uniform Usage

Clear **error messages are essential for usability**. The type checker should produce specific diagnostics for common bindless usage errors:

| Error Scenario | Message Pattern | Suggested Fix |
|---------------|---------------|-------------|
| Missing `nonUniform` on non-uniform index | "Non-uniform index required for bindless texture access" | Wrap index with `nonUniform` |
| `RuntimeArray` not in final struct position | "Runtime-sized array must be the last member of buffer struct" | Reorder struct fields |
| Capability not supported on target | "Non-uniform storage buffer indexing requires `shaderStorageBufferArrayNonUniformIndexing`" | Use uniform indexing or select different hardware |
| `Bindless` on invalid resource type | "Bindless arrays not supported for resource type `X`" | Use fixed binding or different resource type |

Error messages should **reference relevant Vulkan specification sections** and provide **concrete code examples** showing correct usage patterns. The error reporting infrastructure should leverage FIR's existing source location tracking to **pinpoint errors in user code**, and should provide **suggestions for fixes** based on the specific error pattern.

### 4.2 Compiler Backend Modifications

#### 4.2.1 SPIR-V Instruction Selection for Bindless Operations

The instruction selection pass must **recognize bindless-specific AST and IR constructs** and generate corresponding SPIR-V instruction sequences. For bindless array declarations, this involves emitting `OpTypeRuntimeArray` and associated decorations rather than `OpTypeArray`. For bindless array access, the instruction selection depends on the resource type: for images and samplers, the access typically produces an `<id>` that is used directly as an operand to subsequent operations, without the `OpAccessChain` indirection used for buffer arrays.

The instruction selection must also handle the **interaction between bindless access and FIR's existing optimization passes**, ensuring that common subexpression elimination, dead code elimination, and other transforms correctly preserve bindless semantics. For example, eliminating a seemingly redundant `OpCopyObject` of a bindless-accessed image could **incorrectly remove a necessary attachment point for `NonUniform` decoration**. The instruction selection should be **validated against reference SPIR-V generated by established compilers** (GLSLANG, DXC) for equivalent bindless patterns, ensuring semantically equivalent output.

#### 4.2.2 Decoration Attachment Strategy (Index Chain vs. Final Resource Operand)

The backend's decoration attachment strategy must **implement the correct placement of `NonUniform` decorations** as specified by the Vulkan SPIR-V environment. This requires a **dedicated compiler pass** that runs after initial SPIR-V generation but before final module assembly, identifying instructions that produce resource operands consumed by memory access operations and attaching `NonUniform` decorations where the corresponding index was marked as non-uniform.

The pass must understand the **instruction patterns for different resource types**:

| Resource Type | Access Pattern | Decoration Target |
|-------------|--------------|-----------------|
| Sampled image | `OpSampledImage` → `OpImageSample*` | `OpSampledImage` result |
| Storage image | `OpLoad` → `OpImageRead`/`OpImageWrite` | Loaded image variable |
| Uniform buffer | `OpAccessChain` → `OpLoad` | Access chain result |
| Storage buffer | `OpAccessChain` → `OpLoad`/`OpStore` | Access chain result |

The implementation should draw on the **detailed examples from the Slang project's bug fixes** , which demonstrate correct decoration placement for multiple resource access patterns. A **verification step**, enabled in debug builds, could cross-check decoration placement against the Vulkan specification's requirements.

#### 4.2.3 Capability and Extension Header Generation

The module header generation must be extended to **emit `OpCapability` and `OpExtension` declarations for bindless features**. This requires collecting capability requirements during code generation and emitting them in the correct order. For **Vulkan 1.2+ targets**, many bindless capabilities are available without explicit extensions, but the `RuntimeDescriptorArray` capability and non-uniform indexing capabilities must still be declared.

The capability tracking should be **precise, declaring only capabilities that are actually used by the shader**. This improves portability across Vulkan implementations with different feature support levels. The tracking must also account for **interactions between capabilities**: some capabilities may implicitly require others, and the declaration order may matter for certain validators. FIR's existing capability tracking infrastructure for other Vulkan features can be extended with **bindless-specific capability cases**.

### 4.3 Runtime Interface and Validation

#### 4.3.1 Haskell Vulkan Bindings Integration (vulkan package on Hackage)

FIR's runtime interface to Vulkan relies on Haskell bindings, with the **`vulkan` package on Hackage** being the most prominent option. This package provides **comprehensive bindings to Vulkan's API**, including the structures and functions for `VK_EXT_descriptor_indexing`. Key structures include `PhysicalDeviceDescriptorIndexingFeatures` for querying capabilities, `DescriptorSetLayoutBindingFlagsCreateInfo` for specifying binding flags, and `DescriptorSetVariableDescriptorCountAllocateInfo` for variable descriptor counts.

The runtime interface must use these bindings to **create bindless-compatible descriptor set layouts**, **allocate descriptor sets with appropriate counts**, and **update descriptors in bindless arrays**. The integration should handle **version differences gracefully**, using the `EXT`-suffixed structures for pre-1.2 Vulkan and core structures for 1.2+. Error handling should **convert Vulkan error codes to informative Haskell exceptions**.

#### 4.3.2 Descriptor Set Layout Creation with Variable Descriptor Counts

Creating descriptor set layouts for bindless bindings requires using **`DescriptorSetLayoutBindingFlagsCreateInfo`** to specify binding flags for each binding. The last binding in a layout can use **`VARIABLE_DESCRIPTOR_COUNT_BIT`** to enable runtime-sized arrays, with the actual count specified at allocation time through **`DescriptorSetVariableDescriptorCountAllocateInfo`**.

The runtime interface should provide **higher-level combinators** that abstract these details:

```haskell
-- Create a bindless descriptor set layout with specified maximum sizes
createBindlessLayout :: Device -> [(DescriptorType, Word32)] -> IO DescriptorSetLayout

-- Allocate a descriptor set with variable counts
allocateBindlessSet :: Device -> DescriptorPool -> DescriptorSetLayout -> [Word32] -> IO DescriptorSet
```

These combinators handle the **structure chaining and flag setting** required by the Vulkan API, presenting a simpler interface that aligns with FIR's EDSL abstractions.

#### 4.3.3 Physical Device Feature Query and Enablement

The runtime interface must **query and enable physical device features** required by bindless shaders. This involves:

1. **Checking `PhysicalDeviceDescriptorIndexingFeatures`** for required capabilities
2. **Enabling features in `DeviceCreateInfo`** during device creation
3. **Validating shader capabilities against device features** at pipeline creation time

Feature query results should be **cached and made available to the shader compilation pipeline**, enabling conditional code generation or clear error messages when required features are unavailable. The integration with FIR's compilation pipeline could support **feature-based code generation**, where the same EDSL source produces different SPIR-V variants optimized for different hardware capabilities.

## 5. Validation and Correctness Assurance

### 5.1 SPIR-V Validation Requirements

#### 5.1.1 NonUniform Decoration Placement Verification

The most critical validation requirement for bindless SPIR-V is **correct `NonUniform` decoration placement**. Automated validation should:

- **Parse generated SPIR-V** and identify all memory-accessing instructions
- **Trace dataflow from `nonUniform` annotations** to resource operands
- **Verify that `NonUniform` decorations appear on final resource operands**, not just intermediate indices
- **Cross-check against Vulkan specification rules** (VUID-RuntimeSpirv-None-10148 and related)

This validation can be implemented as a **standalone tool** using SPIR-V parsing libraries, or integrated into FIR's test suite using `spirv-val` with custom validation rules. The Slang project's test cases for decoration placement  provide **valuable reference inputs** for this validation.

#### 5.1.2 Capability Consistency Checks

Capability validation ensures that **generated SPIR-V only declares capabilities supported by the target device**. Checks include:

- **Capability declaration presence**: All used capabilities are declared
- **Capability declaration minimality**: No unused capabilities are declared
- **Feature-capability correspondence**: Declared capabilities match enabled device features
- **Extension consistency**: `OpExtension` declarations match capability requirements

These checks prevent **portability issues** where shaders fail on devices lacking advertised capabilities, and **validation failures** where undeclared capabilities are used.

#### 5.1.3 Vulkan Validation Layer Compatibility

Integration with the **Vulkan Validation Layers** provides runtime verification of bindless usage patterns. Key validation scenarios include:

- **Descriptor set layout compatibility** with shader declarations
- **Descriptor update correctness** for update-after-bind bindings
- **Index bounds validation** where possible (partially-bound bindings relax this)
- **Non-uniform access validation** on hardware that requires it

FIR's test infrastructure should include **integration tests that run shaders through actual Vulkan drivers** with validation layers enabled, catching issues that static SPIR-V validation cannot detect.

### 5.2 Testing Strategy

#### 5.2.1 Uniform Dynamic Indexing Test Cases

**Uniform dynamic indexing tests** verify correct behavior when all invocations use the same index:

| Test Case | Description | Expected Result |
|-----------|-------------|---------------|
| Single texture access | All invocations sample texture at index 0 | Correct texture displayed, no `NonUniform` decoration |
| Constant index propagation | Compile-time constant index into bindless array | Optimized to direct binding reference |
| Push constant index | Uniform push constant used as array index | Correct resource accessed, uniform code path |
| Loop-uniform index | Index uniform within loop iteration | Per-iteration correct access, no divergence handling |

These tests establish **baseline correctness** for bindless array access and verify that uniform access patterns **do not incur unnecessary overhead** from non-uniform handling.

#### 5.2.2 Non-Uniform Dynamic Indexing Test Cases

**Non-uniform dynamic indexing tests** exercise the full bindless capability:

| Test Case | Description | Validation Focus |
|-----------|-------------|----------------|
| Per-instance texture | `gl_InstanceIndex`-derived texture selection | `NonUniform` decoration on sampled image operand |
| Material ID sampling | Material index from vertex attribute | Decoration propagation through attribute load |
| Random index selection | Pseudorandom index per pixel | Stress test for divergence handling |
| Nested non-uniformity | Index computed from non-uniformly sampled value | Multi-level propagation correctness |

These tests should be **run on multiple hardware vendors** to verify correct divergence handling across different implementations.

#### 5.2.3 Cross-Vendor Driver Validation (AMD, NVIDIA, Intel)

**Cross-vendor validation is essential** because non-uniform indexing behavior varies significantly:

| Vendor | Architecture | Non-Uniform Support | Known Issues |
|--------|-----------|---------------------|--------------|
| **NVIDIA** | Turing+ | Native for all descriptor types | Minimal issues |
| **AMD** | RDNA | Native, waterfall on older GCN | Strict decoration placement requirements |
| **Intel** | Xe | Improving, limited on older gen | Capability availability varies |

Testing should cover **minimum advertised capabilities** on each vendor, with graceful degradation or clear errors when capabilities are unavailable. The **RADV driver's strict validation** of decoration placement makes it particularly valuable for catching specification compliance issues .

### 5.3 Performance Considerations

#### 5.3.1 Divergence Handling and Subgroup Uniformity

**Non-uniform indexing introduces shader divergence** that impacts performance differently across hardware:

- **NVIDIA**: Hardware texture cache handles non-uniform access efficiently, minimal overhead for typical divergence patterns
- **AMD RDNA**: Native non-uniform indexing, but subgroup-level uniformity still beneficial
- **AMD GCN/Intel**: May insert **waterfall loops** (serial per-lane execution) for non-uniform access, significant performance impact

FIR's EDSL could potentially expose **subgroup uniformity hints** or **wave-level synchronization operations** to help users optimize divergence patterns, though this extends beyond basic bindless support.

#### 5.3.2 Waterfall Loop Emulation Fallbacks for Legacy Hardware

On hardware without native non-uniform indexing, **drivers may emulate the feature using waterfall loops**—serializing execution across divergent lanes. This emulation:

- **Guarantees correctness** but with **severe performance penalties**
- Is **transparent to the application** but observable through performance profiling
- Can be **avoided by restructuring shaders** to use uniform indexing where possible

FIR's documentation should **warn users about waterfall loop risks** and provide guidance for **identifying and mitigating divergence** in performance-critical code paths.

#### 5.3.3 Descriptor Cache Efficiency in Bindless Designs

Bindless descriptor arrays interact with **hardware descriptor caches** in complex ways:

- **Large arrays** may exceed cache capacity, causing **cache thrashing** with random access patterns
- **Spatial locality** in index selection (nearby pixels accessing nearby descriptors) improves cache efficiency
- **Update-after-bind** may require cache invalidation, with **performance costs proportional to array size**

Optimization strategies include:

| Strategy | Implementation | Benefit |
|----------|---------------|---------|
| **Texture atlas fallback** | Combine small textures into larger arrays | Reduce active descriptor count |
| **LOD-based array segmentation** | Separate arrays per mip level | Improve spatial locality |
| **Material sorting** | Sort draws by material to cluster access | Reduce cache working set |
| **Partial binding** | Only populate active descriptor ranges | Reduce cache pressure |

These optimizations are **application-level concerns** beyond FIR's scope, but the EDSL design should **not preclude them** through unnecessary constraints on array organization or access patterns.

## 6. Migration Path and User-Facing Documentation

### 6.1 Backward Compatibility Strategy

#### 6.1.1 Opt-In Bindless Feature Flag Design

Bindless support should be **opt-in through explicit feature flags** to preserve backward compatibility:

```haskell
-- Enable bindless features at module or compilation unit level
{-# LANGUAGE FIRBindless #-}

-- Or via compiler option
-- -XBindless
```

This design ensures that **existing FIR code continues to compile unchanged**, with bindless features only available in modules that explicitly request them. The feature flag enables:

- **`BindlessArray` and `RuntimeArray` type constructors**
- **`nonUniform` combinator**
- **Bindless-specific validation rules**
- **Updated SPIR-V capability tracking**

#### 6.1.2 Gradual Migration from Fixed Binding Model

Migration from fixed binding to bindless should support **incremental adoption**:

| Migration Stage | Approach | Effort |
|---------------|----------|--------|
| **Stage 1: Texture arrays** | Convert large texture arrays to bindless | Low: direct replacement |
| **Stage 2: Material systems** | Use bindless for per-material resource selection | Medium: restructure material data |
| **Stage 3: GPU-driven rendering** | Full bindless with indirect draw buffers | High: architectural changes |
| **Stage 4: Dynamic streaming** | Update-after-bind for runtime resource loading | High: synchronization complexity |

Documentation should provide **migration guides for each stage**, with before/after code examples and performance expectations.

#### 6.1.3 Deprecation Timeline for Legacy Patterns

No immediate deprecation of fixed binding is proposed. **Fixed binding remains preferred** for:

- **Small, stable resource sets** (global uniforms, post-processing inputs)
- **Scenarios requiring maximum portability** (mobile, older hardware)
- **Simple shaders where bindless complexity is unjustified**

Bindless and fixed binding **can coexist in the same shader**, with bindless used for variable resources and fixed binding for stable globals. This **hybrid approach** provides flexibility without forcing architectural decisions.

### 6.2 Documentation and Examples

#### 6.2.1 Bindless Array Declaration Examples

Documentation should include **complete, compilable examples**:

```haskell
{-# LANGUAGE FIRBindless #-}
{-# LANGUAGE DataKinds #-}

module BindlessExample where

import FIR

-- Declare a bindless array of 2D textures at set 0, binding 0
myTextures :: BindlessArray (SampledImage2D RGBA8)
myTextures = bindlessArray @0 @0

-- Declare a bindless array of storage buffers at set 0, binding 1
myMeshes :: BindlessArray (StorageBuffer MeshData)
myMeshes = bindlessArray @0 @1
```

#### 6.2.2 Non-Uniform Index Usage Patterns

**Common non-uniform indexing patterns** with explanations:

```haskell
-- Pattern 1: Per-instance material selection
fragmentShader :: Expr (NonUniform Word32) -> Expr Vec4
fragmentShader materialId = 
  sample (myTextures ! nonUniform materialId) uvCoords defaultSampler

-- Pattern 2: Material ID from vertex attribute
vertexShader :: VertexInput -> Expr (NonUniform Word32)
vertexShader input = nonUniform (materialId attribute)

-- Pattern 3: Computed index with non-uniform intermediate
complexIndex :: Expr Vec3 -> Expr (NonUniform Word32)
complexIndex normal = nonUniform (hashNormal normal `mod` arrayLength myTextures)
```

Each pattern should include **SPIR-V output highlights** showing correct decoration placement.

#### 6.2.3 Common Pitfalls and Validation Error Explanations

| Pitfall | Symptom | Solution |
|---------|---------|----------|
| **Missing `nonUniform`** | Corruption on AMD/Intel | Add `nonUniform` to divergent indices |
| **Decoration on wrong operand** | Validation error VUID-RuntimeSpirv-None-10148 | Check compiler version, report bug if persistent |
| **Capability mismatch** | `VK_ERROR_INVALID_SHADER_NV` | Query device features, conditionally use bindless |
| **Partial binding without flag** | Validation error on access to unpopulated descriptor | Enable `PARTIALLY_BOUND` in descriptor set layout |
| **Update-after-bind without pool flag** | `VK_ERROR_POOL_OUT_OF_MEMORY` or validation error | Create descriptor pool with `UPDATE_AFTER_BIND` |

### 6.3 Community Engagement

#### 6.3.1 Contribution Guidelines for Extension Authors

The bindless extension should be **developed as a collaborative contribution** with:

- **Design RFC** posted to FIR's issue tracker for community review
- **Incremental merge requests** with test coverage for each component
- **Performance benchmarks** comparing bindless vs. fixed binding scenarios
- **Documentation updates** accompanying code changes

#### 6.3.2 Issue Tracking and Feature Request Process

A dedicated **issue label `bindless`** should track:

- **Bug reports** for incorrect SPIR-V generation
- **Feature requests** for additional bindless capabilities (update-after-bind, etc.)
- **Hardware compatibility** reports with vendor/driver versions
- **Performance regressions** compared to fixed binding

#### 6.3.3 Collaboration with Vulkan Haskell Ecosystem Maintainers

Coordination with **maintainers of related packages** is essential:

| Package | Coordination Topic |
|---------|-----------------|
| `vulkan` | Feature structure updates, capability query helpers |
| `vulkan-api` | Alternative binding compatibility |
| `VulkanMemoryAllocator` | Bindless descriptor pool allocation strategies |
| `gfx-hal` (if applicable) | Cross-abstraction bindless patterns |

Regular **ecosystem sync meetings** or **shared RFC process** could prevent fragmentation and ensure consistent bindless support across the Haskell Vulkan ecosystem.


