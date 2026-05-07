{-# LANGUAGE RecordWildCards #-}

module Graphics.Haskan.Scene.GLTF
  ( importGLTF
  , GLTFImportResult (..)
  ) where

import Control.Monad (when)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Managed (MonadManaged)
import Data.Foldable (for_)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Vector qualified as Vector
import Data.Word (Word32)
import Foreign.C qualified
import Graphics.Haskan.Logger (logDebug, logInfo, showT, LogCategory (..))
import Graphics.Haskan.Mesh (Mesh (..))
import Graphics.Haskan.Scene.ECS (World, EntityId)
import Graphics.Haskan.Scene.ECS qualified as ECS
import Graphics.Haskan.Scene.Transform (Transform (..), defaultTransform)
import Graphics.Haskan.Vertex (Vertex (..))
import Graphics.Haskan.Vulkan.Buffer qualified as Buffer
import Graphics.Haskan.Vulkan.Resources (ResourceManager, MeshHandle, TextureHandle)
import Graphics.Haskan.Vulkan.Texture qualified as Texture
import Linear (V2 (..), V3 (..), V4 (..), Quaternion (..))
import Linear qualified
import Graphics.Vulkan qualified as Vulkan
import Text.GLTF.Loader qualified as GLTF
import Text.GLTF.Loader.Gltf qualified as GLTFTypes
  ( Gltf (..)
  , Mesh (..)
  , MeshPrimitive (..)
  , Node (..)
  , Image (..)
  , Texture (..)
  )
import Text.GLTF.Loader.Gltf
  ( nodeTranslation
  , nodeRotation
  , nodeScale
  , nodeChildren
  , nodeMeshId
  , meshPrimitives
  , meshPrimitivePositions
  , meshPrimitiveNormals
  , meshPrimitiveTexCoords
  , meshPrimitiveIndices
  , gltfMeshes
  , gltfNodes
  )

-- | Result of importing a glTF scene
data GLTFImportResult = GLTFImportResult
  { girWorld :: !World
  , girMeshes :: ![MeshHandle]
  , girTextures :: ![TextureHandle]
  , girRootEntity :: !EntityId
  }

-- | Import a glTF file into the engine's ECS + ResourceManager.
importGLTF ::
  (MonadFail m, MonadIO m, MonadManaged m) =>
  ResourceManager ->
  Vulkan.VkPhysicalDevice ->
  Vulkan.VkDevice ->
  FilePath ->
  m GLTFImportResult
importGLTF rm pdev dev path = do
  logInfo LogGeneral $ "loading glTF: " <> Text.pack path

  -- Load glTF file using gltf-loader
  gltfResult <- liftIO $ GLTF.fromJsonFile path
  gltf <- case gltfResult of
    Left err -> fail $ "failed to load glTF: " <> show err
    Right g -> pure g

  logInfo LogGeneral $ "glTF loaded: " <> showT (Vector.length (gltfMeshes gltf)) <> " meshes, "
    <> showT (Vector.length (gltfNodes gltf)) <> " nodes"

  -- Create ECS world
  world <- ECS.createWorld

  -- Load textures (for now, skip texture loading until mesh loading works)
  -- textures <- loadTextures rm gltf
  let textures = []

  -- Load meshes and create mesh resources
  meshes <- loadMeshes rm pdev dev gltf

  -- Build scene graph from nodes
  rootEntity <- buildSceneGraph world gltf meshes

  pure GLTFImportResult
    { girWorld = world
    , girMeshes = meshes
    , girTextures = textures
    , girRootEntity = rootEntity
    }

-- | Load all meshes from glTF into engine Mesh resources.
loadMeshes ::
  (MonadFail m, MonadIO m) =>
  ResourceManager ->
  Vulkan.VkPhysicalDevice ->
  Vulkan.VkDevice ->
  GLTFTypes.Gltf ->
  m [MeshHandle]
loadMeshes rm pdev dev gltf = do
  let meshes = gltfMeshes gltf
  mapM (loadMesh rm pdev dev) (Vector.toList meshes)

-- | Load a single glTF mesh (all primitives merged into one engine Mesh).
loadMesh ::
  (MonadFail m, MonadIO m) =>
  ResourceManager ->
  Vulkan.VkPhysicalDevice ->
  Vulkan.VkDevice ->
  GLTFTypes.Mesh ->
  m MeshHandle
loadMesh rm pdev dev gltfMesh = do
  -- For simplicity, merge all primitives into one mesh
  let primitives = meshPrimitives gltfMesh
      allVertices = concatMap primitiveToVertices (Vector.toList primitives)
      allIndices = concatMap primitiveToIndices (Vector.toList primitives)
  Buffer.createMeshResource rm pdev dev allVertices allIndices

-- | Convert a glTF primitive to engine vertices.
primitiveToVertices :: GLTFTypes.MeshPrimitive -> [Vertex]
primitiveToVertices prim =
  let positions = Vector.toList (meshPrimitivePositions prim)
      normals = Vector.toList (meshPrimitiveNormals prim)
      texCoords = Vector.toList (meshPrimitiveTexCoords prim)
      -- Default values if attributes are missing
      defaultNormal = V3 0 0 1
      defaultUV = V2 0 0
      defaultColor = V3 1 1 1
      -- Zip them together
      nCount = length normals
      uvCount = length texCoords
   in zipWith3
        (\pos norm uv ->
          Vertex
            { vPos = v3ToCFloat pos
            , vNorm = if nCount > 0 then v3ToCFloat norm else v3ToCFloat defaultNormal
            , vTexUV = if uvCount > 0 then v2ToCFloat uv else v2ToCFloat defaultUV
            , vCol = v3ToCFloat defaultColor
            }
        )
        positions
        (normals ++ repeat defaultNormal)
        (texCoords ++ repeat defaultUV)

-- | Convert a glTF primitive to engine indices.
primitiveToIndices :: GLTFTypes.MeshPrimitive -> [Word32]
primitiveToIndices prim =
  let idxs = meshPrimitiveIndices prim
   in map fromIntegral (Vector.toList idxs)

-- | Build ECS scene graph from glTF nodes.
buildSceneGraph ::
  (MonadIO m, MonadFail m) =>
  World ->
  GLTFTypes.Gltf ->
  [MeshHandle] ->
  m EntityId
buildSceneGraph world gltf meshes = do
  let nodes = gltfNodes gltf
      -- Find root nodes (nodes that are not children of any other node)
      allChildren = concatMap (Vector.toList . nodeChildren) (Vector.toList nodes)
      rootIndices = filter (\i -> i `notElem` allChildren) [0 .. Vector.length nodes - 1]

  -- Create a root entity for the scene
  sceneRoot <- ECS.spawnEntity world
  ECS.setTransform world sceneRoot defaultTransform

  -- Process each root node
  for_ rootIndices $ \nodeIdx -> do
    _ <- processNode world gltf meshes nodeIdx sceneRoot
    pure ()

  pure sceneRoot

-- | Recursively process a glTF node and its children.
processNode ::
  (MonadIO m, MonadFail m) =>
  World ->
  GLTFTypes.Gltf ->
  [MeshHandle] ->
  Int -> -- node index
  EntityId -> -- parent entity
  m EntityId
processNode world gltf meshes nodeIdx parentEntity = do
  let nodes = gltfNodes gltf
      node = nodes Vector.! nodeIdx

  -- Create entity for this node
  entity <- ECS.spawnEntity world

  -- Set transform
  let transform = nodeToTransform node
  ECS.setTransform world entity transform

  -- Set parent
  ECS.setParent world entity parentEntity

  -- Set mesh if present
  case nodeMeshId node of
    Just meshIdx -> do
      when (meshIdx >= 0 && meshIdx < length meshes) $ do
        ECS.setMesh world entity (meshes !! meshIdx)
    Nothing -> pure ()

  -- Process children
  for_ (Vector.toList (nodeChildren node)) $ \childIdx -> do
    _ <- processNode world gltf meshes childIdx entity
    pure ()

  pure entity

-- | Convert glTF node TRS to engine Transform.
nodeToTransform :: GLTFTypes.Node -> Transform
nodeToTransform node =
  let translation = fromMaybe (V3 0 0 0) (nodeTranslation node)
      rotation = fromMaybe (V4 0 0 0 1) (nodeRotation node)
      scale = fromMaybe (V3 1 1 1) (nodeScale node)
      -- glTF rotation is quaternion (x, y, z, w)
      -- Linear.Quaternion expects (w, x, y, z)
      V4 rx ry rz rw = rotation
      quat = Quaternion rw (V3 rx ry rz)
   in Transform
        { tPosition = translation
        , tRotation = quat
        , tScale = scale
        }

v3ToCFloat :: V3 Float -> V3 Foreign.C.CFloat
v3ToCFloat (V3 x y z) = V3 (realToFrac x) (realToFrac y) (realToFrac z)

v2ToCFloat :: V2 Float -> V2 Foreign.C.CFloat
v2ToCFloat (V2 x y) = V2 (realToFrac x) (realToFrac y)