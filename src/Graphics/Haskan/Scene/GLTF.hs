{-# LANGUAGE RecordWildCards #-}

module Graphics.Haskan.Scene.GLTF
  ( importGLTF
  , GLTFImportResult (..)
  ) where

import Control.Monad (when)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Managed (MonadManaged)
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson qualified as JSON
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BSL
import Data.Char qualified as Char
import Data.Foldable (for_)
import Data.List (foldl')
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
import Graphics.Haskan.Assets.Cache (AssetCache)
import Graphics.Haskan.Assets.TexturePreprocessor (TextureConfig, defaultTextureConfig)
import Graphics.Haskan.Vertex (Vertex (..))

import Graphics.Haskan.Vulkan.Buffer qualified as Buffer
import Graphics.Haskan.Vulkan.Resources (ResourceManager, MeshHandle, TextureHandle)
import Graphics.Haskan.Vulkan.Texture qualified as Texture
import Linear (V2 (..), V3 (..), V4 (..), Quaternion (..))
import Linear qualified
import Graphics.Vulkan qualified as Vulkan
import System.Directory (withCurrentDirectory)
import System.FilePath (takeDirectory)
import Text.GLTF.Loader qualified as GLTF
import Text.GLTF.Loader.Gltf qualified as GLTFTypes
  ( Gltf (..)
  , Mesh (..)
  , MeshPrimitive (..)
  , Node (..)
  , Image (..)
  , Texture (..)
  , Material (..)
  , PbrMetallicRoughness (..)
  , TextureInfo (..)
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
  , meshPrimitiveMaterial
  , gltfMeshes
  , gltfNodes
  , gltfImages
  , gltfMaterials
  , gltfTextures
  , pbrBaseColorTexture
  , textureSourceId
  )
import Text.GLTF.Loader.Errors (Errors)

-- | Pre-process glTF JSON to add missing image mime types.
fixImageMimeTypes :: ByteString -> ByteString
fixImageMimeTypes bs =
  case JSON.decodeStrict' bs of
    Nothing -> bs  -- Not valid JSON, return as-is
    Just (obj :: JSON.Object) ->
      case KeyMap.lookup "images" obj of
        Just (JSON.Array images) ->
          let fixedImages = Vector.map fixImageMimeType images
              fixedObj = KeyMap.insert "images" (JSON.Array fixedImages) obj
           in BSL.toStrict (JSON.encode fixedObj)
        _ -> bs
  where
    fixImageMimeType (JSON.Object img) =
      case KeyMap.lookup "mimeType" img of
        Just _ -> JSON.Object img  -- Already has mime type
        Nothing ->
          case KeyMap.lookup "uri" img of
            Just (JSON.String uri) -> let mime = inferMimeType (Text.unpack uri)
              in JSON.Object (KeyMap.insert "mimeType" (JSON.String mime) img)
            _ -> JSON.Object img
    fixImageMimeType other = other

    inferMimeType uri
      | ".png" `Text.isSuffixOf` Text.pack (map Char.toLower uri) = "image/png"
      | ".jpg" `Text.isSuffixOf` Text.pack (map Char.toLower uri) = "image/jpeg"
      | ".jpeg" `Text.isSuffixOf` Text.pack (map Char.toLower uri) = "image/jpeg"
      | otherwise = "image/png"  -- Default fallback

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
  Vulkan.VkQueue ->
  Vulkan.VkCommandBuffer ->
  AssetCache ->
  FilePath ->
  m GLTFImportResult
importGLTF rm pdev dev queue cmdBuf cache path = do
  logInfo LogGeneral $ "loading glTF: " <> Text.pack path

  -- Load glTF file using gltf-loader
  -- Pre-process JSON to fix missing image mime types, then load from the file's directory
  jsonBytes <- liftIO $ BS.readFile path
  let fixedBytes = fixImageMimeTypes jsonBytes
  gltfResult <- liftIO $ withCurrentDirectory (takeDirectory path) $
    GLTF.fromJsonByteString fixedBytes
  gltf <- case gltfResult of
    Left err -> fail $ "failed to load glTF: " <> show err
    Right g -> pure g

  logInfo LogGeneral $ "glTF loaded: " <> showT (Vector.length (gltfMeshes gltf)) <> " meshes, "
    <> showT (Vector.length (gltfNodes gltf)) <> " nodes, "
    <> showT (Vector.length (gltfImages gltf)) <> " images"

  -- Create ECS world
  world <- ECS.createWorld

  -- Load textures from images
  textures <- loadTextures rm pdev dev queue cmdBuf cache gltf
  logInfo LogGeneral $ "loaded " <> showT (length textures) <> " textures"

  -- Build material -> texture mapping
  let materialTextures = buildMaterialTextures gltf textures

  -- Load meshes and create mesh resources
  meshes <- loadMeshes rm pdev dev gltf

  -- Build scene graph from nodes
  rootEntity <- buildSceneGraph world gltf meshes materialTextures

  pure GLTFImportResult
    { girWorld = world
    , girMeshes = meshes
    , girTextures = textures
    , girRootEntity = rootEntity
    }

-- | Load all images from glTF as Vulkan textures.
loadTextures ::
  (MonadFail m, MonadIO m, MonadManaged m) =>
  ResourceManager ->
  Vulkan.VkPhysicalDevice ->
  Vulkan.VkDevice ->
  Vulkan.VkQueue ->
  Vulkan.VkCommandBuffer ->
  AssetCache ->
  GLTFTypes.Gltf ->
  m [TextureHandle]
loadTextures rm pdev dev queue cmdBuf cache gltf = do
  let images = gltfImages gltf
  mapM (loadImage rm pdev dev queue cmdBuf cache) (Vector.toList images)

-- | Load a single glTF image as a Vulkan texture.
loadImage ::
  (MonadFail m, MonadIO m, MonadManaged m) =>
  ResourceManager ->
  Vulkan.VkPhysicalDevice ->
  Vulkan.VkDevice ->
  Vulkan.VkQueue ->
  Vulkan.VkCommandBuffer ->
  AssetCache ->
  GLTFTypes.Image ->
  m TextureHandle
loadImage rm pdev dev queue cmdBuf cache img = do
  case GLTFTypes.imageData img of
    Just bs -> do
      Texture.createTextureFromBytesCached rm pdev dev cache bs queue cmdBuf
    Nothing -> do
      -- No image data - create a white fallback texture
      let whitePixels = Texture.generateGridTexture 2 2 1
      Texture.createTextureFromData rm pdev dev 2 2 whitePixels queue cmdBuf

-- | Build a mapping from material index to its base color texture handle.
-- Returns a list where index = material index, value = Maybe TextureHandle.
buildMaterialTextures :: GLTFTypes.Gltf -> [TextureHandle] -> [Maybe TextureHandle]
buildMaterialTextures gltf textures =
  let materials = Vector.toList (gltfMaterials gltf)
      texturesList = Vector.toList (GLTFTypes.gltfTextures gltf)
      -- For each material, resolve baseColorTexture -> texture -> image -> TextureHandle
      resolveMaterial mat = do
        pbr <- GLTFTypes.materialPbrMetallicRoughness mat
        texInfo <- pbrBaseColorTexture pbr
        let texIdx = GLTFTypes.textureId texInfo
        gltfTex <- if texIdx >= 0 && texIdx < length texturesList
                     then Just (texturesList !! texIdx)
                     else Nothing
        imgIdx <- textureSourceId gltfTex
        if imgIdx >= 0 && imgIdx < length textures
          then Just (textures !! imgIdx)
          else Nothing
   in map resolveMaterial materials

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
      accumulatePrimitives = foldl' accumulatePrimitive ([], [])
      accumulatePrimitive (verts, idxs) prim =
        let primVerts = primitiveToVertices prim
            primIdxs = primitiveToIndices prim
            offset = length verts
            offsetIdxs = map (+ fromIntegral offset) primIdxs
        in (verts ++ primVerts, idxs ++ offsetIdxs)
      (allVertices, allIndices) = accumulatePrimitives (Vector.toList primitives)
  logInfo LogGeneral $ "glTF mesh: " <> showT (length allVertices) <> " vertices, " <> showT (length allIndices) <> " indices"
  let uvs = map vTexUV allVertices
      (uvals, vvals) = unzip [(realToFrac u, realToFrac v) | V2 u v <- uvs]
      umin = minimum uvals; umax = maximum uvals
      vmin = minimum vvals; vmax = maximum vvals
  logInfo LogGeneral $ "UV range: U[" <> showT umin <> ", " <> showT umax <> "], V[" <> showT vmin <> ", " <> showT vmax <> "]"
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
      -- Flip V coordinate to match Vulkan convention (glTF V=0 is bottom-left, Vulkan V=0 is top-left)
      flipV (V2 u v) = V2 u v
   in zipWith3
        (\pos norm uv ->
          Vertex
            { vPos = v3ToCFloat pos
            , vNorm = if nCount > 0 then v3ToCFloat norm else v3ToCFloat defaultNormal
            , vTexUV = if uvCount > 0 then v2ToCFloat (flipV uv) else v2ToCFloat defaultUV
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
      result = map fromIntegral (Vector.toList idxs)
   in result

-- | Build ECS scene graph from glTF nodes.
buildSceneGraph ::
  (MonadIO m, MonadFail m) =>
  World ->
  GLTFTypes.Gltf ->
  [MeshHandle] ->
  [Maybe TextureHandle] -> -- material index -> texture handle
  m EntityId
buildSceneGraph world gltf meshes materialTextures = do
  let nodes = gltfNodes gltf
      -- Find root nodes (nodes that are not children of any other node)
      allChildren = concatMap (Vector.toList . nodeChildren) (Vector.toList nodes)
      rootIndices = filter (\i -> i `notElem` allChildren) [0 .. Vector.length nodes - 1]

  -- Create a root entity for the scene
  sceneRoot <- ECS.spawnEntity world
  ECS.setTransform world sceneRoot defaultTransform

  -- Process each root node
  for_ rootIndices $ \nodeIdx -> do
    _ <- processNode world gltf meshes materialTextures nodeIdx sceneRoot
    pure ()

  pure sceneRoot

-- | Recursively process a glTF node and its children.
processNode ::
  (MonadIO m, MonadFail m) =>
  World ->
  GLTFTypes.Gltf ->
  [MeshHandle] ->
  [Maybe TextureHandle] -> -- material index -> texture handle
  Int -> -- node index
  EntityId -> -- parent entity
  m EntityId
processNode world gltf meshes materialTextures nodeIdx parentEntity = do
  let nodes = gltfNodes gltf
      node = nodes Vector.! nodeIdx

  -- Create entity for this node
  entity <- ECS.spawnEntity world

  -- Set transform
  let transform = nodeToTransform node
  ECS.setTransform world entity transform

  -- Set parent
  ECS.setParent world entity parentEntity

  -- Set mesh and material if present
  case nodeMeshId node of
    Just meshIdx -> do
      when (meshIdx >= 0 && meshIdx < length meshes) $ do
        ECS.setMesh world entity (meshes !! meshIdx)
        -- Look up material from first primitive
        let gltfMeshesList = Vector.toList (gltfMeshes gltf)
        when (meshIdx < length gltfMeshesList) $ do
          let gltfMesh = gltfMeshesList !! meshIdx
              primitives = Vector.toList (meshPrimitives gltfMesh)
          case primitives of
            (prim:_) -> do
              case meshPrimitiveMaterial prim of
                Just matIdx -> do
                  when (matIdx >= 0 && matIdx < length materialTextures) $ do
                    case materialTextures !! matIdx of
                      Just texHandle -> do
                        logInfo LogGeneral $ "entity " <> showT entity <> " material " <> showT matIdx <> " -> texture assigned"
                        ECS.setMaterial world entity texHandle
                      Nothing -> do
                        logInfo LogGeneral $ "entity " <> showT entity <> " material " <> showT matIdx <> " -> NO texture (using fallback)"
                Nothing -> do
                  logInfo LogGeneral $ "entity " <> showT entity <> " -> no material"
            [] -> pure ()
    Nothing -> pure ()

  -- Process children
  for_ (Vector.toList (nodeChildren node)) $ \childIdx -> do
    _ <- processNode world gltf meshes materialTextures childIdx entity
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