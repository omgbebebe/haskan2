{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module Graphics.Haskan.Render.ShaderProgram
  ( ShaderStage (..),
    ShaderProgram (..),
    MeshShaderProgram (..),
    toPipelineStages,
    stageCount,
  )
where

import Data.ByteString (ByteString)
import Data.Maybe (catMaybes)
import Vulkan qualified as Vulkan
import Vulkan.Core10 qualified as Vulkan
import Vulkan.Zero (zero)

-- | A single shader stage configuration, with optional specialization constants.
data ShaderStage = ShaderStage
  { ssStage :: !Vulkan.ShaderStageFlagBits,
    ssModule :: !Vulkan.ShaderModule,
    ssSpecializationInfo :: !(Maybe Vulkan.SpecializationInfo)
  }

-- | Traditional graphics pipeline shader program.
-- Supports vertex + optional tessellation + optional geometry + fragment.
data ShaderProgram = ShaderProgram
  { spVertex :: !Vulkan.ShaderModule,
    spTessControl :: !(Maybe Vulkan.ShaderModule),
    spTessEvaluation :: !(Maybe Vulkan.ShaderModule),
    spGeometry :: !(Maybe Vulkan.ShaderModule),
    spFragment :: !Vulkan.ShaderModule,
    spSpecializationInfo :: !(Maybe Vulkan.SpecializationInfo)
  }

-- | Mesh shader pipeline program (Vulkan 1.3+ / VK_EXT_mesh_shader).
-- Replaces vertex/tessellation/geometry with task + mesh + fragment.
data MeshShaderProgram = MeshShaderProgram
  { mspTask :: !(Maybe Vulkan.ShaderModule),
    mspMesh :: !Vulkan.ShaderModule,
    mspFragment :: !Vulkan.ShaderModule
  }

-- | Convert a ShaderProgram to a list of Vulkan pipeline stage create infos.
-- Uses the specialization info from the ShaderProgram if present.
toPipelineStages :: ShaderProgram -> [Vulkan.PipelineShaderStageCreateInfo '[]]
toPipelineStages ShaderProgram {..} =
  let mkStage stageFlag mod_ =
        Vulkan.PipelineShaderStageCreateInfo
          { next = (),
            flags = zero,
            stage = stageFlag,
            module' = mod_,
            name = "main",
            specializationInfo = spSpecializationInfo
          }
   in catMaybes
        [ Just (mkStage Vulkan.SHADER_STAGE_VERTEX_BIT spVertex),
          mkStage Vulkan.SHADER_STAGE_TESSELLATION_CONTROL_BIT <$> spTessControl,
          mkStage Vulkan.SHADER_STAGE_TESSELLATION_EVALUATION_BIT <$> spTessEvaluation,
          mkStage Vulkan.SHADER_STAGE_GEOMETRY_BIT <$> spGeometry,
          Just (mkStage Vulkan.SHADER_STAGE_FRAGMENT_BIT spFragment)
        ]

-- | Convert shader stages with specialization info.
toPipelineStagesWithSpec :: [ShaderStage] -> [Vulkan.PipelineShaderStageCreateInfo '[]]
toPipelineStagesWithSpec = map $ \ShaderStage {..} ->
  Vulkan.PipelineShaderStageCreateInfo
    { next = (),
      flags = zero,
      stage = ssStage,
      module' = ssModule,
      name = "main",
      specializationInfo = ssSpecializationInfo
    }

-- | Number of active stages in a ShaderProgram.
stageCount :: ShaderProgram -> Int
stageCount = length . toPipelineStages
