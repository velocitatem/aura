{-# LANGUAGE OverloadedStrings, MultiWayIf #-}

-- |
-- Module    : Aura.Types
-- Copyright : (c) Colin Woodbury, 2012 - 2018
-- License   : GPL3
-- Maintainer: Colin Woodbury <colin@fosskers.ca>
--
-- Core Aura types.

module Aura.Types
  ( -- * Package Types
    Package(..)
  , SimplePkg(..), simplepkg, simplepkg'
  , Dep(..), parseDep
  , Buildable(..)
    -- * Package Building
  , VersionDemand(..), _VersionDemand
  , InstallType(..)
    -- * Errors
  , DepError(..)
  , Failure(..)
    -- * Language
  , Language(..)
    -- * Other Wrappers
  , PackagePath(..)
  , Pkgbuild(..)
  , Provides(..)
  , Environment(..)
  , User(..)
    -- * Misc.
  , list
  ) where

import           BasePrelude hiding (FilePath, try)
import           Data.Bitraversable
import           Data.List.NonEmpty (nonEmpty)
import qualified Data.Map.Strict as M
import qualified Data.Text as T
import           Data.Text.Prettyprint.Doc hiding (space, list)
import           Data.Text.Prettyprint.Doc.Render.Terminal
import           Data.Versions
import           Filesystem.Path (filename)
import           Shelly (FilePath, toTextIgnore)
import           Text.Megaparsec
import           Text.Megaparsec.Char

---

-- TODO Make all these fields strict, here and elsewhere.
-- | A package to be installed.
data Package = Package { _pkgName        :: T.Text
                       , _pkgVersion     :: Maybe Versioning
                       , _pkgBaseName    :: T.Text
                       , _pkgProvides    :: Provides
                       , _pkgDeps        :: [Dep]
                       , _pkgInstallType :: InstallType }

-- | Hacky instance to allow `Package` to be used in a `Set`. Beware.
instance Eq Package where
  a == b = _pkgName a == _pkgName b && _pkgVersion a == _pkgVersion b

instance Ord Package where
  compare a b = case compare (_pkgName a) (_pkgName b) of
    EQ  -> compare (_pkgVersion a) (_pkgVersion b)
    oth -> oth
  -- a <= b = pkgNameOf a <= pkgNameOf b && pkgVersionOf a <= pkgVersionOf b

instance Show Package where
  show p = printf "%s (%s)" (show $ _pkgName p) (show . fmap prettyV $ _pkgVersion p)

-- | A dependency on another package.
data Dep = Dep { depNameOf      :: T.Text
               , depVerDemandOf :: VersionDemand } deriving (Eq, Ord, Show)

-- TODO Return an Either if it failed to parse?
-- TODO Doctest here, and fix up the haddock
-- | Parse a dependency entry as it would appear in a PKGBUILD:
parseDep :: T.Text -> Maybe Dep
parseDep = either (const Nothing) Just . parse dep "dep"
  where dep :: Parsec Void T.Text Dep
        dep = Dep <$> takeWhile1P Nothing (\c -> c /= '<' && c /= '>' && c /= '=') <*> ver

        ver :: Parsec Void T.Text VersionDemand
        ver = do
          end <- atEnd
          if | end       -> pure Anything
             | otherwise -> choice [ char '<'    *> fmap LessThan versioning'
                                   , string ">=" *> fmap AtLeast  versioning'
                                   , char '>'    *> fmap MoreThan versioning'
                                   , char '='    *> fmap MustBe   versioning'
                                   , pure Anything ]

-- | The versioning requirement of some package's dependency.
data VersionDemand = LessThan Versioning
                   | AtLeast  Versioning
                   | MoreThan Versioning
                   | MustBe   Versioning
                   | Anything
                   deriving (Eq, Ord)

instance Show VersionDemand where
    show (LessThan v) = T.unpack $ "<"  <> prettyV v
    show (AtLeast  v) = T.unpack $ ">=" <> prettyV v
    show (MoreThan v) = T.unpack $ ">"  <> prettyV v
    show (MustBe   v) = T.unpack $ "="  <> prettyV v
    show Anything     = "Anything"

-- | Attempt to zoom into the `Versioning` hiding within a `VersionDemand`.
_VersionDemand :: Traversal' VersionDemand Versioning
_VersionDemand f (LessThan v) = LessThan <$> f v
_VersionDemand f (AtLeast v)  = AtLeast  <$> f v
_VersionDemand f (MoreThan v) = MoreThan <$> f v
_VersionDemand f (MustBe v)   = MustBe   <$> f v
_VersionDemand _ p            = pure p

-- | The installation method.
data InstallType = Pacman T.Text | Build Buildable

-- | A package name with its version number.
data SimplePkg = SimplePkg { _spName :: T.Text, _spVersion :: Versioning } deriving (Eq, Ord, Show)

-- | Attempt to create a `SimplePkg` from filepaths like
--   @\/var\/cache\/pacman\/pkg\/linux-3.2.14-1-x86_64.pkg.tar.xz@
simplepkg :: PackagePath -> Maybe SimplePkg
simplepkg (PackagePath t) = uncurry SimplePkg <$> bitraverse f f (parse n "name" t', parse v "version" t')
  where t' = toTextIgnore $ filename t

        n :: Parsec Void T.Text T.Text
        n = T.pack <$> manyTill anyChar (try finished)

        -- | Assumes that a version number will never start with a letter,
        -- and that a package name section (i.e. abc-def-ghi) will never start
        -- with a number.
        finished = char '-' *> lookAhead digitChar
        v    = manyTill anyChar (try finished) *> ver
        ver  = try (fmap Ideal semver' <* post) <|> try (fmap General version' <* post) <|> fmap Complex mess'
        post = char '-' *> (string "x86_64" <|> string "any") *> string ".pkg.tar.xz"
        f    = either (const Nothing) Just

-- | Attempt to create a `SimplePkg` from text like:
--     xchat 2.8.8-19
simplepkg' :: T.Text -> Maybe SimplePkg
simplepkg' = either (const Nothing) Just . parse parser "name-and-version"
  where parser = SimplePkg <$> takeWhile1P Nothing (/= ' ') <*> (space *> versioning')

-- | Filepaths like:
--
--   * \/var\/cache\/pacman\/pkg\/linux-3.2.14-1-x86_64.pkg.tar.xz
--   * \/var\/cache\/pacman\/pkg\/wine-1.4rc6-1-x86_64.pkg.tar.xz
--   * \/var\/cache\/pacman\/pkg\/ruby-1.9.3_p125-4-x86_64.pkg.tar.xz
newtype PackagePath = PackagePath { _pkgpath :: FilePath } deriving (Eq)

instance Ord PackagePath where
  compare a b | nameA /= nameB = compare (_pkgpath a) (_pkgpath b)
              | otherwise      = compare verA verB
    where (nameA, verA) = f a
          (nameB, verB) = f b
          f = (fmap _spName &&& fmap _spVersion) . simplepkg

-- | The contents of a PKGBUILD file.
newtype Pkgbuild = Pkgbuild { _pkgbuild :: T.Text } deriving (Eq, Ord)

-- | The dependency which some package provides. May not be the same name
-- as the package itself (e.g. cronie provides cron).
newtype Provides = Provides { _provides :: T.Text } deriving (Eq, Ord)

-- | A package to be built manually before installing.
data Buildable = Buildable
    { bldNameOf     :: T.Text
    , bldBaseNameOf :: T.Text
    , bldProvidesOf :: Provides
    , pkgbuildOf    :: Pkgbuild
    , bldDepsOf     :: [Dep]
    , bldVersionOf  :: Maybe Versioning
    -- | Did the user select this package, or is it being built as a dep?
    , isExplicit    :: Bool } deriving (Eq, Ord)

-- | All human languages available for text output.
data Language = English
              | Japanese
              | Polish
              | Croatian
              | Swedish
              | German
              | Spanish
              | Portuguese
              | French
              | Russian
              | Italian
              | Serbian
              | Norwegian
              | Indonesia
              | Chinese
                deriving (Eq, Enum, Bounded, Ord, Show)

-- | The various ways that dependency resolution can fail.
data DepError = NonExistant T.Text
              | VerConflict (Doc AnsiStyle)
              | Ignored (Doc AnsiStyle)
              | UnparsableVersion T.Text
              | BrokenProvides T.Text T.Text T.Text

-- | Some failure message that when given the current runtime `Language`
-- will produce a human-friendly error.
newtype Failure = Failure { _failure :: Language -> Doc AnsiStyle }

-- | Shell environment variables.
type Environment = M.Map T.Text T.Text

-- | The name of a user account on a Linux system.
newtype User = User { _user :: T.Text } deriving (Eq, Show)

-- | Similar to `maybe` and `either`, but not quite the same.
list :: b -> (NonEmpty a -> b) -> [a] -> b
list def f as = maybe def f $ nonEmpty as