{-# LANGUAGE RecordWildCards #-}

module Graphics.Haskan.Render.ShaderProgram
  ( ShaderStage (..),
    ShaderProgram (..),
    MeshShaderProgram (..),
    toPipelineStages,
    stageCount,
  )
where

import Data.Maybe (catMaybes)
import Foreign (Ptr, nullPtr)
import Graphics.Vulkan qualified as Vulkan
import Graphics.Vulkan.Core_1_0 qualified as Vulkan
import Graphics.Vulkan.Marshal.Create (set, setStrRef, (&*))
import Graphics.Vulkan.Marshal.Create qualified as Vulkan

-- | A single shader stage configuration, with optional specialization constants.
data ShaderStage = ShaderStage
  { ssStage :: !Vulkan.VkShaderStageFlagBits,
    ssModule :: !Vulkan.VkShaderModule,
    ssSpecializationInfo :: !(Maybe (Ptr Vulkan.VkSpecializationInfo))
  }

-- | Traditional graphics pipeline shader program.
-- Supports vertex + optional tessellation + optional geometry + fragment.
data ShaderProgram = ShaderProgram
  { spVertex :: !Vulkan.VkShaderModule,
    spTessControl :: !(Maybe Vulkan.VkShaderModule),
    spTessEvaluation :: !(Maybe Vulkan.VkShaderModule),
    spGeometry :: !(Maybe Vulkan.VkShaderModule),
    spFragment :: !Vulkan.VkShaderModule
  }

-- | Mesh shader pipeline program (Vulkan 1.3+ / VK_EXT_mesh_shader).
-- Replaces vertex/tessellation/geometry with task + mesh + fragment.
data MeshShaderProgram = MeshShaderProgram
  { mspTask :: !(Maybe Vulkan.VkShaderModule),
    mspMesh :: !Vulkan.VkShaderModule,
    mspFragment :: !Vulkan.VkShaderModule
  }

-- | Convert a ShaderProgram to a list of Vulkan pipeline stage create infos.
-- No specialization constants by default.
toPipelineStages :: ShaderProgram -> [Vulkan.VkPipelineShaderStageCreateInfo]
toPipelineStages ShaderProgram {..} =
  let mkStage stageFlag mod_ =
        Vulkan.createVk
          ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO
              &* set @"pNext" Vulkan.VK_NULL
              &* set @"stage" stageFlag
              &* set @"module" mod_
              &* setStrRef @"pName" "main"
              &* set @"pSpecializationInfo" nullPtr
          )
   in catMaybes
        [ Just (mkStage Vulkan.VK_SHADER_STAGE_VERTEX_BIT spVertex),
          mkStage Vulkan.VK_SHADER_STAGE_TESSELLATION_CONTROL_BIT <$> spTessControl,
          mkStage Vulkan.VK_SHADER_STAGE_TESSELLATION_EVALUATION_BIT <$> spTessEvaluation,
          mkStage Vulkan.VK_SHADER_STAGE_GEOMETRY_BIT <$> spGeometry,
          Just (mkStage Vulkan.VK_SHADER_STAGE_FRAGMENT_BIT spFragment)
        ]

-- | Convert shader stages with specialization info.
toPipelineStagesWithSpec :: [ShaderStage] -> [Vulkan.VkPipelineShaderStageCreateInfo]
toPipelineStagesWithSpec = map $ \ShaderStage{..} ->
  Vulkan.createVk
    ( set @"sType" Vulkan.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO
        &* set @"pNext" Vulkan.VK_NULL
        &* set @"stage" ssStage
        &* set @"module" ssModule
        &* setStrRef @"pName" "main"
        &* set @"pSpecializationInfo" (maybe nullPtr id ssSpecializationInfo)
    )

-- | Number of active stages in a ShaderProgram.
stageCount :: ShaderProgram -> Int
stageCount = length . toPipelineStages
