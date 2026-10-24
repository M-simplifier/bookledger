{-# LANGUAGE TemplateHaskell #-}

module BookLedger.Export.Assets
  ( viewerHtml
  , viewerCss
  , viewerScript
  ) where

import qualified Data.ByteString as BS
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Language.Haskell.TH (loc_filename, location, runIO, stringE)
import Language.Haskell.TH.Syntax (addDependentFile)
import System.FilePath (takeDirectory, (</>))

-- The pure renderer and installed CLI carry the same assets without runtime files.
viewerHtml :: Text
viewerHtml = T.pack $(do
  source <- location
  let path = takeDirectory (loc_filename source) </> "viewer.html"
  addDependentFile path
  bytes <- runIO (BS.readFile path)
  stringE (T.unpack (TE.decodeUtf8 bytes)))

viewerCss :: Text
viewerCss = T.pack $(do
  source <- location
  let path = takeDirectory (loc_filename source) </> "viewer.css"
  addDependentFile path
  bytes <- runIO (BS.readFile path)
  stringE (T.unpack (TE.decodeUtf8 bytes)))

viewerScript :: Text
viewerScript = T.pack $(do
  source <- location
  let path = takeDirectory (loc_filename source) </> "viewer.js"
  addDependentFile path
  bytes <- runIO (BS.readFile path)
  stringE (T.unpack (TE.decodeUtf8 bytes)))
