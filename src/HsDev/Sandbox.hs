{-# LANGUAGE OverloadedStrings, TemplateHaskell #-}

module HsDev.Sandbox (
	SandboxType(..), Sandbox(..), sandboxType, sandbox,
	isSandbox, guessSandboxType, sandboxFromPath,
	findSandbox, searchSandbox, sandboxPackageDbStack, packageDbSandbox, searchPackageDbStack, restorePackageDbStack,

	-- * cabal-sandbox util
	cabalSandboxLib, cabalSandboxPackageDb,

	getModuleOpts,
	pathInSandbox,

	getProjectSandbox,
	getProjectPackageDbStack
	) where

import Control.Arrow
import Control.DeepSeq (NFData(..))
import Control.Monad
import Control.Monad.Trans.Maybe
import Control.Monad.Except
import Control.Lens (view, makeLenses)
import Data.Aeson
import Data.Maybe (isJust, fromMaybe)
import Data.List (inits)
import qualified Data.Text as T (unpack)
import Distribution.Compiler
import Distribution.System
import qualified Distribution.Text as T (display)
import System.FilePath
import System.Directory
import System.Log.Simple (MonadLog(..))

import System.Directory.Paths
import HsDev.PackageDb
import HsDev.Project.Types
import HsDev.Scan.Browse (browsePackages)
import HsDev.Stack
import HsDev.Symbols (moduleOpts)
import HsDev.Symbols.Types (moduleId, Module(..), ModuleLocation(..), moduleLocation)
import HsDev.Tools.Ghc.Worker (GhcM, tmpSession)
import HsDev.Tools.Ghc.Compat as Compat
import HsDev.Util (searchPath, isParent, directoryContents)

import qualified GHC
import qualified Packages as GHC

data SandboxType = CabalSandbox | StackWork deriving (Eq, Ord, Read, Show, Enum, Bounded)

data Sandbox = Sandbox { _sandboxType :: SandboxType, _sandbox :: FilePath } deriving (Eq, Ord)

makeLenses ''Sandbox

instance NFData SandboxType where
	rnf CabalSandbox = ()
	rnf StackWork = ()

instance NFData Sandbox where
	rnf (Sandbox t p) = rnf t `seq` rnf p

instance Show Sandbox where
	show (Sandbox _ p) = p

instance ToJSON Sandbox where
	toJSON (Sandbox _ p) = toJSON p

instance FromJSON Sandbox where
	parseJSON = withText "sandbox" sandboxPath where
		sandboxPath = maybe (fail "Not a sandbox") return . sandboxFromPath . T.unpack

instance Paths Sandbox where
	paths f (Sandbox st p) = Sandbox st <$> f p

isSandbox :: FilePath -> Bool
isSandbox = isJust . guessSandboxType

guessSandboxType :: FilePath -> Maybe SandboxType
guessSandboxType fpath
	| takeFileName fpath == ".cabal-sandbox" = Just CabalSandbox
	| takeFileName fpath == ".stack-work" = Just StackWork
	| otherwise = Nothing

sandboxFromPath :: FilePath -> Maybe Sandbox
sandboxFromPath fpath = Sandbox <$> guessSandboxType fpath <*> pure fpath

-- | Find sandbox in path
findSandbox :: FilePath -> IO (Maybe Sandbox)
findSandbox fpath = do
	fpath' <- canonicalize fpath
	isDir <- doesDirectoryExist fpath'
	if isDir
		then do
			dirs <- liftM (fpath' :) $ directoryContents fpath'
			return $ msum $ map sandboxFromDir dirs
		else return Nothing
	where
		sandboxFromDir :: FilePath -> Maybe Sandbox
		sandboxFromDir fdir
			| takeFileName fdir == "stack.yaml" = sandboxFromPath (takeDirectory fdir </> ".stack-work")
			| otherwise = sandboxFromPath fdir

-- | Search sandbox by parent directory
searchSandbox :: FilePath -> IO (Maybe Sandbox)
searchSandbox p = runMaybeT $ searchPath p (MaybeT . findSandbox)

-- | Get package-db stack for sandbox
sandboxPackageDbStack :: Sandbox -> GhcM PackageDbStack
sandboxPackageDbStack (Sandbox CabalSandbox fpath) = do
	dir <- cabalSandboxPackageDb
	return $ PackageDbStack [PackageDb $ fpath </> dir]
sandboxPackageDbStack (Sandbox StackWork fpath) = liftM (view stackPackageDbStack) $ projectEnv $ takeDirectory fpath

-- | Get sandbox from package-db
packageDbSandbox :: PackageDb -> Maybe Sandbox
packageDbSandbox GlobalDb = Nothing
packageDbSandbox UserDb = Nothing
packageDbSandbox (PackageDb fpath) = msum [sandboxFromPath p | p <- parents] where
	parents = map joinPath . tail . inits . splitDirectories $ fpath

-- | Search package-db stack with user-db as default
searchPackageDbStack :: FilePath -> GhcM PackageDbStack
searchPackageDbStack p = do
	mbox <- liftIO $ searchSandbox p
	case mbox of
		Nothing -> return userDb
		Just sbox -> sandboxPackageDbStack sbox

-- | Restore package-db stack by package-db
restorePackageDbStack :: PackageDb -> GhcM PackageDbStack
restorePackageDbStack GlobalDb = return globalDb
restorePackageDbStack UserDb = return userDb
restorePackageDbStack (PackageDb p) = liftM (fromMaybe $ fromPackageDbs [p]) $ runMaybeT $ do
	sbox <- MaybeT $ liftIO $ searchSandbox p
	lift $ sandboxPackageDbStack sbox

-- | Get actual sandbox build path: <arch>-<platform>-<compiler>-<version>
cabalSandboxLib :: GhcM FilePath
cabalSandboxLib = do
	tmpSession ["-no-user-package-db"]
	df <- GHC.getSessionDynFlags
	let
		res =
			map (GHC.packageNameString &&& GHC.packageVersion) .
			fromMaybe [] . Compat.pkgDatabase $ df
		compiler = T.display buildCompilerFlavor
		CompilerId _ version = buildCompilerId
		ver = maybe (T.display version) T.display $ lookup compiler res
	return $ T.display buildPlatform ++ "-" ++ compiler ++ "-" ++ ver

-- | Get sandbox package-db: <arch>-<platform>-<compiler>-<version>-packages.conf.d
cabalSandboxPackageDb :: GhcM FilePath
cabalSandboxPackageDb = liftM (++ "-packages.conf.d") cabalSandboxLib

-- | Options for GHC for module and project
getModuleOpts :: [String] -> Module -> GhcM [String]
getModuleOpts opts m = do
	pdbs <- case view (moduleId . moduleLocation) m of
		FileModule fpath _ -> searchPackageDbStack fpath
		InstalledModule _ _ _ -> return userDb
		_ -> return userDb
	pkgs <- browsePackages opts pdbs
	return $ concat [
		packageDbStackOpts pdbs,
		moduleOpts pkgs m,
		opts]

-- | Is file in within sandbox, i.e. sandboxes parent is parent for file
pathInSandbox :: FilePath -> Sandbox -> Bool
pathInSandbox fpath (Sandbox _ spath) = takeDirectory spath `isParent` fpath

-- | Get sandbox of project (if any)
getProjectSandbox :: MonadLog m => Project -> m (Maybe Sandbox)
getProjectSandbox = liftIO . searchSandbox . view projectPath

-- | Get project package-db stack
getProjectPackageDbStack :: Project -> GhcM PackageDbStack
getProjectPackageDbStack = getProjectSandbox >=> maybe (return userDb) sandboxPackageDbStack
