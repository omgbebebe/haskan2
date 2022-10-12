module Graphics.Haskan.Utils.ObjLoader where

-- base
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Functor (void)
import Data.Maybe (fromMaybe)
import Data.Void

-- linear
import Linear (V2(..), V3(..), V4(..))

-- megaparsec
import Text.Megaparsec
import Text.Megaparsec.Char
import Text.Megaparsec.Char.Lexer hiding (space)
import Text.Megaparsec.Debug

-- scientific
import Data.Scientific (toRealFloat)

-- text
import Data.Text (Text)
import qualified Data.Text.IO as T

-- haskan
import qualified Graphics.Haskan.Vertex as Haskan


type Vertex = V3 Float
type Normal = V3 Float
type UV = V2 Float
type Index = Int

type FaceTriplet = (Index,Index,Index)
data Face
  = Triangle (V3 FaceTriplet)
  | Quad (V4 FaceTriplet)
  deriving Show

data Obj
  = Obj { v :: [Vertex]
        , vt :: [UV]
        , vn :: [Normal]
        , f :: [Face]
        } deriving Show

type Parser = Parsec Void Text

parseObj :: (MonadFail m, MonadIO m) => FilePath -> m Obj
parseObj path = do
  fileData <- liftIO (T.readFile path)
  case runParser objP path fileData of
    Left e -> fail ("failed to parse '" <> show e <> "'")
    Right p -> pure p

objP :: Parser Obj
objP = do
  many (skipLineComment "#" <* eol)
  objName <- objNameP
  vs <- some vertexP
  vts <- some uvP
  vns <- some normalP
  s <- sModeP
  faces <- facesP
  pure $ Obj vs vts vns faces


objNameP :: Parser String
objNameP = do
  void $ string "o " <* skipSpaces
  manyTill (alphaNumChar <|> punctuationChar) eol

sModeP :: Parser String
sModeP = do
  void $ string "s " <* skipSpaces
  manyTill alphaNumChar eol

vertexP :: Parser Vertex
vertexP = do
  void $ string "v " <* skipSpaces
  v3FloatP <* skipSpaces <* eol

uvP :: Parser UV
uvP = do
  void $ string "vt " <* skipSpaces
  v2FloatP <* skipSpaces <* eol

normalP :: Parser Normal
normalP = do
  void $ string "vn " <* skipSpaces
  v3FloatP <* skipSpaces <* eol

facesP :: Parser [Face]
facesP = some (faceP <* (void eol <|> eof))

faceP :: Parser Face
faceP = do
  points <- faceTripletsP
  case points of
    [a,b,c,d] -> pure $ Quad (V4 a b c d)
    [a,b,c] -> pure $ Triangle (V3 a b c)
    _ -> fail "can't parse face"
   
faceTripletsP :: Parser [FaceTriplet]
faceTripletsP = do
  void $ string "f " <* skipSpaces
  triplets <- some faceTripletP
  pure triplets

faceTripletP :: Parser FaceTriplet
faceTripletP = do
  void skipSpaces
  index <- uintP <* char '/'
  uv <- uintP <* char '/'
  normal <- uintP
  pure (fromIntegral (index-1), fromIntegral (uv-1), fromIntegral (normal-1))

skipSpaces :: Parser ()
skipSpaces = skipMany separatorChar

floatP :: Parser Float
floatP = toRealFloat <$> signed skipSpaces (lexeme skipSpaces scientific)

intP :: Parser Int
intP = signed skipSpaces uintP

uintP :: Parser Int
uintP = lexeme skipSpaces decimal

v3IntP :: Parser (V3 Int)
v3IntP =
  V3 <$> intP <*> intP <*> intP

v3FloatP :: Parser (V3 Float)
v3FloatP =
  V3 <$> floatP <*> floatP <*> floatP

v2FloatP :: Parser (V2 Float)
v2FloatP =
  V2 <$> floatP <*> floatP
