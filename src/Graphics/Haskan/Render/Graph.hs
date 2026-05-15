{-# LANGUAGE GeneralizedNewtypeDeriving #-}

module Graphics.Haskan.Render.Graph
  ( -- * Resource IDs
    ResourceId (..),
    resourceId,

    -- * Graph resources
    GraphResource (..),
    ImageDesc (..),
    BufferDesc (..),

    -- * Pass definition
    RenderPassNode (..),
    PassRecordFunc (..),
    PassContext (..),

    -- * Graph builder
    RenderGraph,
    RenderGraphBuilder,
    runRenderGraphBuilder,
    execRenderGraphBuilder,

    -- * Builder operations
    addResource,
    addPass,
    transientImage,
    transientBuffer,
    getGraphResources,
    getGraphPasses,

    -- * Compiled graph
    CompiledGraph (..),
    CompiledPass (..),
    compileGraph,
  )
where

import Control.Monad.State.Strict (State, execState, gets, modify', runState)
import Data.HashMap.Strict (HashMap)
import Data.HashMap.Strict qualified as HashMap
import Data.Hashable (Hashable)
import Data.List (sortBy)
import Data.Ord (comparing)
import Data.Text (Text)
import Data.Text qualified as Text
import Graphics.Vulkan qualified as Vulkan
import Graphics.Vulkan.Core_1_0 qualified as Vulkan

-- ---------------------------------------------------------------------------
-- Resource IDs
-- ---------------------------------------------------------------------------

newtype ResourceId = ResourceId {unResourceId :: Text}
  deriving (Eq, Ord, Show, Hashable)

resourceId :: Text -> ResourceId
resourceId = ResourceId

-- ---------------------------------------------------------------------------
-- Graph resources
-- ---------------------------------------------------------------------------

data GraphResource
  = GRImage ImageDesc
  | GRBuffer BufferDesc
  | GRPersistent ResourceId
  deriving (Eq, Show)

data BufferDesc = BufferDesc
  { bdSize :: !Vulkan.VkDeviceSize,
    bdUsage :: !(Vulkan.VkBufferUsageBitmask Vulkan.FlagMask)
  }
  deriving (Eq, Show)

data ImageDesc = ImageDesc
  { idFormat :: !Vulkan.VkFormat,
    idExtent :: !Vulkan.VkExtent2D,
    idUsage :: !(Vulkan.VkImageUsageBitmask Vulkan.FlagMask),
    idSamples :: !Vulkan.VkSampleCountFlagBits
  }
  deriving (Eq, Show)

-- ---------------------------------------------------------------------------
-- Pass definition
-- ---------------------------------------------------------------------------

data RenderPassNode = RenderPassNode
  { rpName :: !Text,
    rpInputs :: ![ResourceId],
    rpOutputs :: ![ResourceId],
    rpRecord :: !PassRecordFunc
  }

-- | Opaque function that records Vulkan commands for a pass.
-- Stored in an existential to allow different pass types.
data PassRecordFunc = PassRecordFunc
  { unPassRecordFunc :: PassContext -> IO ()
  }

data PassContext = PassContext
  { pcCommandBuffer :: !Vulkan.VkCommandBuffer,
    pcPipeline :: !Vulkan.VkPipeline,
    pcPipelineLayout :: !Vulkan.VkPipelineLayout,
    pcDescriptorSet :: !Vulkan.VkDescriptorSet,
    pcFramebuffer :: !Vulkan.VkFramebuffer,
    pcRenderPass :: !Vulkan.VkRenderPass,
    pcExtent :: !Vulkan.VkExtent2D
  }

-- ---------------------------------------------------------------------------
-- Graph builder
-- ---------------------------------------------------------------------------

data GraphBuildState = GraphBuildState
  { gbsResources :: !(HashMap ResourceId GraphResource),
    gbsPasses :: ![RenderPassNode],
    gbsNextId :: !Int
  }

emptyGraphState :: GraphBuildState
emptyGraphState = GraphBuildState HashMap.empty [] 0

newtype RenderGraphBuilder a = RenderGraphBuilder
  { runBuilder :: State GraphBuildState a
  }
  deriving (Functor, Applicative, Monad)

type RenderGraph = RenderGraphBuilder ()

runRenderGraphBuilder :: RenderGraphBuilder a -> (a, HashMap ResourceId GraphResource, [RenderPassNode])
runRenderGraphBuilder (RenderGraphBuilder m) =
  let (a, s) = runState m emptyGraphState
   in (a, gbsResources s, reverse (gbsPasses s))

execRenderGraphBuilder :: RenderGraphBuilder a -> (HashMap ResourceId GraphResource, [RenderPassNode])
execRenderGraphBuilder m =
  let (_, res, passes) = runRenderGraphBuilder m
   in (res, passes)

-- | Add a named resource to the graph.
addResource :: ResourceId -> GraphResource -> RenderGraphBuilder ()
addResource rid gr = RenderGraphBuilder $ modify' $ \s ->
  s {gbsResources = HashMap.insert rid gr (gbsResources s)}

-- | Add a pass to the graph.
addPass :: RenderPassNode -> RenderGraphBuilder ()
addPass pass = RenderGraphBuilder $ modify' $ \s ->
  s {gbsPasses = pass : gbsPasses s}

-- | Create a transient image resource with an auto-generated ID.
transientImage ::
  Text ->
  Vulkan.VkFormat ->
  Vulkan.VkExtent2D ->
  Vulkan.VkImageUsageFlags ->
  RenderGraphBuilder ResourceId
transientImage name fmt extent usage = do
  idx <- RenderGraphBuilder $ gets gbsNextId
  RenderGraphBuilder $ modify' $ \s -> s {gbsNextId = gbsNextId s + 1}
  let rid = ResourceId (name <> "_" <> Text.pack (show idx))
  addResource rid (GRImage (ImageDesc fmt extent usage Vulkan.VK_SAMPLE_COUNT_1_BIT))
  pure rid

-- | Create a transient buffer resource with an auto-generated ID.
transientBuffer ::
  Text ->
  Vulkan.VkDeviceSize ->
  Vulkan.VkBufferUsageBitmask Vulkan.FlagMask ->
  RenderGraphBuilder ResourceId
transientBuffer name size usage = do
  idx <- RenderGraphBuilder $ gets gbsNextId
  RenderGraphBuilder $ modify' $ \s -> s {gbsNextId = gbsNextId s + 1}
  let rid = ResourceId (name <> "_" <> Text.pack (show idx))
  addResource rid (GRBuffer (BufferDesc size usage))
  pure rid

getGraphResources :: RenderGraphBuilder (HashMap ResourceId GraphResource)
getGraphResources = RenderGraphBuilder $ gets gbsResources

getGraphPasses :: RenderGraphBuilder [RenderPassNode]
getGraphPasses = RenderGraphBuilder $ gets (reverse . gbsPasses)

-- ---------------------------------------------------------------------------
-- Graph compilation
-- ---------------------------------------------------------------------------

data CompiledGraph = CompiledGraph
  { cgPasses :: ![CompiledPass]
  }

data CompiledPass = CompiledPass
  { cpPass :: !RenderPassNode,
    cpIndex :: !Int
  }

-- | Compile a render graph by topologically sorting passes based on
-- resource dependencies (read-after-write ordering).
compileGraph ::
  HashMap ResourceId GraphResource ->
  [RenderPassNode] ->
  Either Text CompiledGraph
compileGraph resources passes =
  case topologicalSort passes of
    Nothing -> Left "render graph contains a dependency cycle"
    Just sorted ->
      let compiled = zipWith (flip CompiledPass) [0 ..] sorted
       in Right (CompiledGraph compiled)

-- | Topological sort of passes: if Pass B reads a resource written by Pass A,
-- A must come before B.
topologicalSort :: [RenderPassNode] -> Maybe [RenderPassNode]
topologicalSort passes = go inDegrees queue [] []
  where
    -- Build write map: resource -> index of pass that writes it
    writeMap =
      HashMap.fromList
        [ (res, idx)
        | (idx, pass) <- zip [0 ..] passes,
          res <- rpOutputs pass
        ]
    -- For each pass, find dependencies: passes that write resources this pass reads
    deps pass =
      [ HashMap.lookupDefault (-1) res writeMap
      | res <- rpInputs pass,
        HashMap.member res writeMap
      ]
    n = length passes
    edges =
      [ (dep, i)
      | (i, pass) <- zip [0 ..] passes,
        dep <- deps pass,
        dep >= 0 && dep /= i
      ]
    incDegree m (_, dst) = HashMap.insertWith (+) dst 1 m
    inDegrees = foldl' incDegree (HashMap.fromList [(i, 0) | i <- [0 .. n - 1]]) edges
    adjList = HashMap.fromListWith (++) [(src, [dst]) | (src, dst) <- edges]
    queue = [i | i <- [0 .. n - 1], HashMap.lookupDefault 0 i inDegrees == 0]
    go _ [] visited result
      | length result == n = Just (reverse result)
      | otherwise = Nothing
    go indeg (u : q) visited result =
      let neighbors = HashMap.lookupDefault [] u adjList
          processNeighbor (qAcc, m) v =
            let deg = HashMap.lookupDefault 0 v m - 1
                m' = HashMap.insert v deg m
                qAcc' = if deg == 0 then v : qAcc else qAcc
             in (qAcc', m')
          (q', indeg') = foldl' processNeighbor (q, indeg) neighbors
       in go indeg' q' (u : visited) (passes !! u : result)
