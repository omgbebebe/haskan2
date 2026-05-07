{-# LANGUAGE RecordWildCards #-}

module Graphics.Haskan.Render.Forward
  ( buildForwardGraph
  , ForwardPassData (..)
  ) where

import Data.Text (Text)
import Data.Text qualified as Text
import Graphics.Haskan.Render.Graph
import Graphics.Haskan.Render.RenderSystem (DrawCall)
import Graphics.Vulkan qualified as Vulkan
import Graphics.Vulkan.Core_1_0 qualified as Vulkan

-- | Data needed to build a forward rendering pass.
data ForwardPassData = ForwardPassData
  { fpdPassName     :: !Text
  , fpdExtent       :: !Vulkan.VkExtent2D
  , fpdRenderPass   :: !Vulkan.VkRenderPass
  , fpdFramebuffer  :: !Vulkan.VkFramebuffer
  , fpdPipeline     :: !Vulkan.VkPipeline
  , fpdPipelineLayout :: !Vulkan.VkPipelineLayout
  , fpdDescriptorSet :: !Vulkan.VkDescriptorSet
  , fpdDrawList     :: ![DrawCall]
  , fpdRecordFunc   :: !(PassContext -> IO ())
  }

-- | Build a forward render graph with a single pass that renders to the
-- swapchain image with a depth attachment.
buildForwardGraph :: ForwardPassData -> RenderGraphBuilder ()
buildForwardGraph ForwardPassData {..} = do
  -- For now, the forward pass doesn't declare explicit transient resources.
  -- The swapchain image and depth buffer are managed externally.
  -- Future: declare them as graph resources for automatic barrier management.
  addPass RenderPassNode
    { rpName    = fpdPassName
    , rpInputs  = []
    , rpOutputs = []
    , rpRecord  = PassRecordFunc fpdRecordFunc
    }
