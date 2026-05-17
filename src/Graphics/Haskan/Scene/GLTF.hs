module Graphics.Haskan.Scene.GLTF
  ( importGLTF,
    GLTFImportResult (..),
  )
where

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, takeMVar)
import Control.Monad (forM, when)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Managed (MonadManaged)
import Data.Aeson qualified as JSON
import Data.Aeson.KeyMap qualified as KeyMap
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
import Data.Vector.Storable qualified as VectorStorable
import Data.Word (Word32, Word8)
import Foreign.C qualified
import Graphics.Haskan.Assets.Cache (AssetCache)
import Graphics.Haskan.Assets.TexturePreprocessor (TextureConfig, defaultTextureConfig)
import Graphics.Haskan.Engine.Types (PhysicsBodySpec (..))
import Graphics.Haskan.Logger (LogCategory (..), logDebugIO, logInfoIO, showT)
import Graphics.Haskan.Mesh (Mesh (..))
import Graphics.Haskan.Physics.Jolt.Types (BodyType (..))
import Graphics.Haskan.Scene.ECS (EntityId, World)
import Graphics.Haskan.Scene.ECS qualified as ECS
import Graphics.Haskan.Scene.Transform (Transform (..), defaultTransform)
import Graphics.Haskan.Utils.TangentSpace (computeTangents)
import Graphics.Haskan.Vertex (Vertex (..))
import Graphics.Haskan.Vulkan.Buffer qualified as Buffer
import Graphics.Haskan.Vulkan.Resources (MeshHandle, ResourceManager, TextureHandle (..), allocHandle, rmNextId)
import Graphics.Haskan.Vulkan.Texture qualified as Texture
import Graphics.Vulkan qualified as Vulkan
import Linear (Quaternion (..), V2 (..), V3 (..), V4 (..))
import Linear qualified
import System.Directory (withCurrentDirectory)
import System.FilePath (takeDirectory)
import Text.GLTF.Loader qualified as GLTF
import Text.GLTF.Loader.Errors (Errors)
import Text.GLTF.Loader.Gltf
  ( gltfImages,
    gltfMaterials,
    gltfMeshes,
    gltfNodes,
    gltfTextures,
    materialEmissiveTexture,
    materialOcclusionStrength,
    materialOcclusionTexture,
    meshPrimitiveIndices,
    meshPrimitiveMaterial,
    meshPrimitiveNormals,
    meshPrimitivePositions,
    meshPrimitiveTexCoords,
    meshPrimitives,
    nodeChildren,
    nodeMeshId,
    nodeName,
    nodeRotation,
    nodeScale,
    nodeTranslation,
    pbrBaseColorTexture,
    textureSourceId,
  )
import Text.GLTF.Loader.Gltf qualified as GLTFTypes
  ( Gltf (..),
    Image (..),
    Material (..),
    Mesh (..),
    MeshPrimitive (..),
    Node (..),
    PbrMetallicRoughness (..),
    Texture (..),
    TextureInfo (..),
  )

-- | Pre-process glTF JSON to add missing image mime types.
fixImageMimeTypes :: ByteString -> ByteString
fixImageMimeTypes bs =
  case JSON.decodeStrict' bs of
    Nothing -> bs -- Not valid JSON, return as-is
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
        Just _ -> JSON.Object img -- Already has mime type
        Nothing ->
          case KeyMap.lookup "uri" img of
            Just (JSON.String uri) ->
              let mime = inferMimeType (Text.unpack uri)
               in JSON.Object (KeyMap.insert "mimeType" (JSON.String mime) img)
            _ -> JSON.Object img
    fixImageMimeType other = other

    inferMimeType uri
      | ".png" `Text.isSuffixOf` Text.pack (map Char.toLower uri) = "image/png"
      | ".jpg" `Text.isSuffixOf` Text.pack (map Char.toLower uri) = "image/jpeg"
      | ".jpeg" `Text.isSuffixOf` Text.pack (map Char.toLower uri) = "image/jpeg"
      | otherwise = "image/png" -- Default fallback

-- | Result of importing a glTF scene
data GLTFImportResult = GLTFImportResult
  { girWorld :: !World,
    girMeshes :: ![MeshHandle],
    girTextures :: ![TextureHandle],
    -- | parallel to girTextures: (width, height, pixels)
    girTextureData :: ![(Int, Int, VectorStorable.Vector Word8)],
    girRootEntity :: !EntityId,
    girPhysicsSpecs :: ![PhysicsBodySpec]
  }

-- | Import a glTF file into the engine's ECS + ResourceManager.
importGLTF ::
  (MonadIO m, MonadManaged m) =>
  ResourceManager ->
  Vulkan.VkPhysicalDevice ->
  Vulkan.VkDevice ->
  Vulkan.VkQueue ->
  Vulkan.VkCommandBuffer ->
  AssetCache ->
  FilePath ->
  m GLTFImportResult
importGLTF rm pdev dev queue cmdBuf cache path = do
  logInfoIO LogGeneral $ "loading glTF: " <> Text.pack path

  -- Load glTF file using gltf-loader
  -- Pre-process JSON to fix missing image mime types, then load from the file's directory
  jsonBytes <- liftIO $ BS.readFile path
  let fixedBytes = fixImageMimeTypes jsonBytes
  gltfResult <-
    liftIO $
      withCurrentDirectory (takeDirectory path) $
        GLTF.fromJsonByteString fixedBytes
  gltf <- case gltfResult of
    Left err -> error $ "failed to load glTF: " <> show err
    Right g -> pure g

  logInfoIO LogGeneral $
    "glTF loaded: "
      <> showT (Vector.length (gltfMeshes gltf))
      <> " meshes, "
      <> showT (Vector.length (gltfNodes gltf))
      <> " nodes, "
      <> showT (Vector.length (gltfImages gltf))
      <> " images"

  -- Create ECS world
  world <- ECS.createWorld

  -- Load textures from images (decode only, no GPU upload)
  (textures, textureData) <- loadTextures rm pdev dev queue cmdBuf cache gltf
  logInfoIO LogGeneral $ "loaded " <> showT (length textures) <> " textures"

  -- Build material -> texture mappings
  let materialTextures = buildMaterialTextures gltf textures
      materialMRTextures = buildMaterialMetallicRoughnessTextures gltf textures
      materialNormalTextures = buildMaterialNormalTextures gltf textures
      materialOcclusionTextures = buildMaterialOcclusionTextures gltf textures
      materialEmissiveTextures = buildMaterialEmissiveTextures gltf textures

  -- Load meshes and create mesh resources
  meshes <- loadMeshes rm pdev dev gltf

  -- Build scene graph from nodes
  (rootEntity, physicsSpecs) <- buildSceneGraph world gltf meshes materialTextures materialMRTextures materialNormalTextures materialOcclusionTextures materialEmissiveTextures

  pure
    GLTFImportResult
      { girWorld = world,
        girMeshes = meshes,
        girTextures = textures,
        girTextureData = textureData,
        girRootEntity = rootEntity,
        girPhysicsSpecs = physicsSpecs
      }

-- | Load all images from glTF as placeholder texture handles.
-- Decodes all images concurrently. No GPU upload — pixel data is returned for batch array creation.
loadTextures ::
  (MonadIO m, MonadManaged m) =>
  ResourceManager ->
  Vulkan.VkPhysicalDevice ->
  Vulkan.VkDevice ->
  Vulkan.VkQueue ->
  Vulkan.VkCommandBuffer ->
  AssetCache ->
  GLTFTypes.Gltf ->
  m ([TextureHandle], [(Int, Int, VectorStorable.Vector Word8)])
loadTextures rm _pdev _dev _queue _cmdBuf cache gltf = do
  let images = Vector.toList (gltfImages gltf)
      numImages = length images

  logInfoIO LogGeneral $ "decoding " <> showT numImages <> " textures concurrently"

  -- Phase 1: Decode all images concurrently (CPU-bound)
  decoded <- liftIO $ do
    mvars <- mapM (const newEmptyMVar) images
    for_ (zip images mvars) $ \(img, mvar) -> forkIO $ do
      result <- decodeImage cache img
      putMVar mvar result
    mapM takeMVar mvars

  logInfoIO LogGeneral $ "all " <> showT numImages <> " textures decoded"

  -- Phase 2: Create placeholder handles (no GPU upload)
  handlesAndData <- forM decoded $ \result ->
    case result of
      Left err -> error $ "loadTextures: " <> err
      Right (w, h, pixels) -> do
        texH <- TextureHandle <$> allocHandle (rmNextId rm)
        pure (texH, (w, h, pixels))

  let handles = map fst handlesAndData
      pixelData = map snd handlesAndData

  pure (handles, pixelData)

-- | Decode a single glTF image to raw pixel data (CPU only).
decodeImage ::
  AssetCache ->
  GLTFTypes.Image ->
  IO (Either String (Int, Int, VectorStorable.Vector Word8))
decodeImage cache img =
  case GLTFTypes.imageData img of
    Just bs ->
      Texture.decodeTextureCached cache bs
    Nothing -> do
      -- No image data - return a white fallback
      let whitePixels = Texture.generateGridTexture 2 2 1
      pure (Right (2, 2, whitePixels))

-- | Build a mapping from material index to its metallic-roughness texture handle.
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
        gltfTex <-
          if texIdx >= 0 && texIdx < length texturesList
            then Just (texturesList !! texIdx)
            else Nothing
        imgIdx <- textureSourceId gltfTex
        if imgIdx >= 0 && imgIdx < length textures
          then Just (textures !! imgIdx)
          else Nothing
   in map resolveMaterial materials

-- | Build a mapping from material index to its metallic-roughness texture handle.
buildMaterialMetallicRoughnessTextures :: GLTFTypes.Gltf -> [TextureHandle] -> [Maybe TextureHandle]
buildMaterialMetallicRoughnessTextures gltf textures =
  let materials = Vector.toList (gltfMaterials gltf)
      texturesList = Vector.toList (GLTFTypes.gltfTextures gltf)
      resolveMaterial mat = do
        pbr <- GLTFTypes.materialPbrMetallicRoughness mat
        texInfo <- GLTFTypes.pbrMetallicRoughnessTexture pbr
        let texIdx = GLTFTypes.textureId texInfo
        gltfTex <-
          if texIdx >= 0 && texIdx < length texturesList
            then Just (texturesList !! texIdx)
            else Nothing
        imgIdx <- textureSourceId gltfTex
        if imgIdx >= 0 && imgIdx < length textures
          then Just (textures !! imgIdx)
          else Nothing
   in map resolveMaterial materials

-- | Build a mapping from material index to its normal texture handle.
buildMaterialNormalTextures :: GLTFTypes.Gltf -> [TextureHandle] -> [Maybe TextureHandle]
buildMaterialNormalTextures gltf textures =
  let materials = Vector.toList (gltfMaterials gltf)
      texturesList = Vector.toList (GLTFTypes.gltfTextures gltf)
      resolveMaterial mat = do
        texInfo <- GLTFTypes.materialNormalTexture mat
        let texIdx = GLTFTypes.textureId texInfo
        gltfTex <-
          if texIdx >= 0 && texIdx < length texturesList
            then Just (texturesList !! texIdx)
            else Nothing
        imgIdx <- textureSourceId gltfTex
        if imgIdx >= 0 && imgIdx < length textures
          then Just (textures !! imgIdx)
          else Nothing
   in map resolveMaterial materials

-- | Build a mapping from material index to its occlusion texture handle.
buildMaterialOcclusionTextures :: GLTFTypes.Gltf -> [TextureHandle] -> [Maybe TextureHandle]
buildMaterialOcclusionTextures gltf textures =
  let materials = Vector.toList (gltfMaterials gltf)
      texturesList = Vector.toList (GLTFTypes.gltfTextures gltf)
      resolveMaterial mat = do
        texInfo <- GLTFTypes.materialOcclusionTexture mat
        let texIdx = GLTFTypes.textureId texInfo
        gltfTex <-
          if texIdx >= 0 && texIdx < length texturesList
            then Just (texturesList !! texIdx)
            else Nothing
        imgIdx <- textureSourceId gltfTex
        if imgIdx >= 0 && imgIdx < length textures
          then Just (textures !! imgIdx)
          else Nothing
   in map resolveMaterial materials

-- | Build a mapping from material index to its emissive texture handle.
buildMaterialEmissiveTextures :: GLTFTypes.Gltf -> [TextureHandle] -> [Maybe TextureHandle]
buildMaterialEmissiveTextures gltf textures =
  let materials = Vector.toList (gltfMaterials gltf)
      texturesList = Vector.toList (GLTFTypes.gltfTextures gltf)
      resolveMaterial mat = do
        texInfo <- GLTFTypes.materialEmissiveTexture mat
        let texIdx = GLTFTypes.textureId texInfo
        gltfTex <-
          if texIdx >= 0 && texIdx < length texturesList
            then Just (texturesList !! texIdx)
            else Nothing
        imgIdx <- textureSourceId gltfTex
        if imgIdx >= 0 && imgIdx < length textures
          then Just (textures !! imgIdx)
          else Nothing
   in map resolveMaterial materials

-- | Load all meshes from glTF into engine Mesh resources.
-- Meshes are loaded concurrently to utilize multiple CPU cores.
loadMeshes ::
  (MonadIO m) =>
  ResourceManager ->
  Vulkan.VkPhysicalDevice ->
  Vulkan.VkDevice ->
  GLTFTypes.Gltf ->
  m [MeshHandle]
loadMeshes rm pdev dev gltf = do
  let meshes = Vector.toList (gltfMeshes gltf)
      numMeshes = length meshes
  logInfoIO LogGeneral $ "loading " <> showT numMeshes <> " meshes concurrently"

  liftIO $ do
    mvars <- mapM (const newEmptyMVar) meshes
    for_ (zip meshes mvars) $ \(mesh, mvar) -> forkIO $ do
      result <- loadMesh rm pdev dev mesh
      putMVar mvar result
    mapM takeMVar mvars

-- | Load a single glTF mesh (all primitives merged into one engine Mesh).
loadMesh ::
  (MonadIO m) =>
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
  logInfoIO LogGeneral $ "glTF mesh: " <> showT (length allVertices) <> " vertices, " <> showT (length allIndices) <> " indices"
  let uvs = map vTexUV allVertices
      (uvals, vvals) = unzip [(realToFrac u, realToFrac v) | V2 u v <- uvs]
      umin = minimum uvals
      umax = maximum uvals
      vmin = minimum vvals
      vmax = maximum vvals
  logInfoIO LogGeneral $ "UV range: U[" <> showT umin <> ", " <> showT umax <> "], V[" <> showT vmin <> ", " <> showT vmax <> "]"
  Buffer.createMeshResource rm pdev dev allVertices allIndices

-- | Convert a glTF primitive to engine vertices.
primitiveToVertices :: GLTFTypes.MeshPrimitive -> [Vertex]
primitiveToVertices prim =
  let positions = Vector.toList (meshPrimitivePositions prim)
      normals = Vector.toList (meshPrimitiveNormals prim)
      texCoords = Vector.toList (meshPrimitiveTexCoords prim)
      idxs = Vector.toList (meshPrimitiveIndices prim)
      -- Default values if attributes are missing
      defaultNormal = V3 0 0 1
      defaultUV = V2 0 0
      defaultColor = V3 1 1 1
      defaultTangent = V4 1 0 0 1

      -- Compute tangents from geometry
      n = length positions
      paddedNormals = take n (normals ++ repeat defaultNormal)
      paddedUVs = take n (texCoords ++ repeat defaultUV)
      tangents =
        if length idxs >= 3
          then
            Vector.toList $
              computeTangents
                (Vector.fromList positions)
                (Vector.fromList paddedNormals)
                (Vector.fromList paddedUVs)
                (Vector.fromList idxs)
          else replicate n defaultTangent

      -- Zip them together
      nCount = length normals
      uvCount = length texCoords
   in zipWith4
        ( \pos norm uv tangent ->
            Vertex
              { vPos = v3ToCFloat pos,
                vNorm = if nCount > 0 then v3ToCFloat norm else v3ToCFloat defaultNormal,
                vTexUV = if uvCount > 0 then v2ToCFloat uv else v2ToCFloat defaultUV,
                vTangent = v4ToCFloat tangent,
                vCol = v3ToCFloat defaultColor
              }
        )
        positions
        (normals ++ repeat defaultNormal)
        (texCoords ++ repeat defaultUV)
        tangents
  where
    zipWith4 f (a : as) (b : bs) (c : cs) (d : ds) = f a b c d : zipWith4 f as bs cs ds
    zipWith4 _ _ _ _ _ = []

-- | Convert a glTF primitive to engine indices.
primitiveToIndices :: GLTFTypes.MeshPrimitive -> [Word32]
primitiveToIndices prim =
  let idxs = meshPrimitiveIndices prim
      result = map fromIntegral (Vector.toList idxs)
   in result

-- | Build ECS scene graph from glTF nodes.
buildSceneGraph ::
  (MonadIO m) =>
  World ->
  GLTFTypes.Gltf ->
  [MeshHandle] ->
  [Maybe TextureHandle] -> -- material index -> base color texture handle
  [Maybe TextureHandle] -> -- material index -> metallic-roughness texture handle
  [Maybe TextureHandle] -> -- material index -> normal texture handle
  [Maybe TextureHandle] -> -- material index -> occlusion texture handle
  [Maybe TextureHandle] -> -- material index -> emissive texture handle
  m (EntityId, [PhysicsBodySpec])
buildSceneGraph world gltf meshes materialTextures materialMRTextures materialNormalTextures materialOcclusionTextures materialEmissiveTextures = do
  let nodes = gltfNodes gltf
      -- Find root nodes (nodes that are not children of any other node)
      allChildren = concatMap (Vector.toList . nodeChildren) (Vector.toList nodes)
      rootIndices = filter (`notElem` allChildren) [0 .. Vector.length nodes - 1]

  -- Create a root entity for the scene
  sceneRoot <- ECS.spawnEntity world
  ECS.setTransform world sceneRoot defaultTransform

  -- Process each root node
  specs <- fmap concat $ forM rootIndices $ \nodeIdx -> do
    (_, nodeSpecs) <- processNode world gltf meshes materialTextures materialMRTextures materialNormalTextures materialOcclusionTextures materialEmissiveTextures nodeIdx sceneRoot
    pure nodeSpecs

  pure (sceneRoot, specs)

-- | Recursively process a glTF node and its children.
processNode ::
  (MonadIO m) =>
  World ->
  GLTFTypes.Gltf ->
  [MeshHandle] ->
  [Maybe TextureHandle] -> -- material index -> base color texture handle
  [Maybe TextureHandle] -> -- material index -> metallic-roughness texture handle
  [Maybe TextureHandle] -> -- material index -> normal texture handle
  [Maybe TextureHandle] -> -- material index -> occlusion texture handle
  [Maybe TextureHandle] -> -- material index -> emissive texture handle
  Int -> -- node index
  EntityId -> -- parent entity
  m (EntityId, [PhysicsBodySpec])
processNode world gltf meshes materialTextures materialMRTextures materialNormalTextures materialOcclusionTextures materialEmissiveTextures nodeIdx parentEntity = do
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
            (prim : _) -> do
              case meshPrimitiveMaterial prim of
                Just matIdx -> do
                  when (matIdx >= 0 && matIdx < length materialTextures) $ do
                    case materialTextures !! matIdx of
                      Just texHandle -> do
                        logInfoIO LogGeneral $ "entity " <> showT entity <> " material " <> showT matIdx <> " -> texture assigned"
                        ECS.setMaterial world entity texHandle
                      Nothing -> do
                        logInfoIO LogGeneral $ "entity " <> showT entity <> " material " <> showT matIdx <> " -> NO texture (using fallback)"
                  -- Set PBR scalar factors from glTF material
                  let materialsList = Vector.toList (gltfMaterials gltf)
                  when (matIdx >= 0 && matIdx < length materialsList) $ do
                    let mat = materialsList !! matIdx
                    case GLTFTypes.materialPbrMetallicRoughness mat of
                      Just pbr -> do
                        let met = GLTFTypes.pbrMetallicFactor pbr
                            rou = GLTFTypes.pbrRoughnessFactor pbr
                        logInfoIO LogGeneral $ "entity " <> showT entity <> " PBR factors: metallic=" <> showT met <> " roughness=" <> showT rou
                        ECS.setMetallicFactor world entity met
                        ECS.setRoughnessFactor world entity rou
                      Nothing -> pure ()
                  -- Set metallic-roughness texture if present
                  when (matIdx >= 0 && matIdx < length materialMRTextures) $ do
                    case materialMRTextures !! matIdx of
                      Just texHandle -> do
                        logInfoIO LogGeneral $ "entity " <> showT entity <> " MR texture assigned"
                        ECS.setMetallicRoughnessTexture world entity texHandle
                      Nothing -> pure ()
                  -- Set normal texture if present
                  when (matIdx >= 0 && matIdx < length materialNormalTextures) $ do
                    case materialNormalTextures !! matIdx of
                      Just texHandle -> do
                        logInfoIO LogGeneral $ "entity " <> showT entity <> " normal texture assigned"
                        ECS.setNormalTexture world entity texHandle
                      Nothing -> pure ()
                  -- Set occlusion texture and strength if present
                  when (matIdx >= 0 && matIdx < length materialOcclusionTextures) $ do
                    case materialOcclusionTextures !! matIdx of
                      Just texHandle -> do
                        logInfoIO LogGeneral $ "entity " <> showT entity <> " occlusion texture assigned"
                        ECS.setOcclusionTexture world entity texHandle
                      Nothing -> pure ()
                  let materialsList = Vector.toList (gltfMaterials gltf)
                  when (matIdx >= 0 && matIdx < length materialsList) $ do
                    let mat = materialsList !! matIdx
                        occStrength = GLTFTypes.materialOcclusionStrength mat
                    when (occStrength /= 1.0) $ do
                      logInfoIO LogGeneral $ "entity " <> showT entity <> " occlusion strength=" <> showT occStrength
                    ECS.setOcclusionStrength world entity occStrength
                  -- Set emissive texture if present
                  when (matIdx >= 0 && matIdx < length materialEmissiveTextures) $ do
                    case materialEmissiveTextures !! matIdx of
                      Just texHandle -> do
                        logInfoIO LogGeneral $ "entity " <> showT entity <> " emissive texture assigned"
                        ECS.setEmissiveTexture world entity texHandle
                      Nothing -> pure ()
                Nothing -> do
                  logInfoIO LogGeneral $ "entity " <> showT entity <> " -> no material"
            [] -> pure ()
    Nothing -> pure ()

  -- Check for physics body naming convention
  let maybeSpec = case nodeName node of
        Just name
          | "_physics_box" `Text.isSuffixOf` name ->
              let pos = tPosition transform
                  scale = tScale transform
                  halfExtents = scale * 0.5
               in Just $ PhysicsBodySpec (BoxBody halfExtents 10.0) pos entity
        _ -> Nothing

  -- Process children
  childSpecs <- fmap concat $ forM (Vector.toList (nodeChildren node)) $ \childIdx -> do
    (_, cs) <- processNode world gltf meshes materialTextures materialMRTextures materialNormalTextures materialOcclusionTextures materialEmissiveTextures childIdx entity
    pure cs

  pure (entity, maybeToList maybeSpec ++ childSpecs)

maybeToList :: Maybe a -> [a]
maybeToList Nothing = []
maybeToList (Just x) = [x]

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
        { tPosition = translation,
          tRotation = quat,
          tScale = scale
        }

v3ToCFloat :: V3 Float -> V3 Foreign.C.CFloat
v3ToCFloat (V3 x y z) = V3 (realToFrac x) (realToFrac y) (realToFrac z)

v4ToCFloat :: V4 Float -> V4 Foreign.C.CFloat
v4ToCFloat (V4 x y z w) = V4 (realToFrac x) (realToFrac y) (realToFrac z) (realToFrac w)

v2ToCFloat :: V2 Float -> V2 Foreign.C.CFloat
v2ToCFloat (V2 x y) = V2 (realToFrac x) (realToFrac y)
