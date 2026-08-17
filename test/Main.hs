module Main (main) where

import qualified BookLedger.BackupTest as BackupTest
import qualified BookLedger.DomainTest as DomainTest
import qualified BookLedger.ExportTest as ExportTest
import qualified BookLedger.StoreTest as StoreTest
import Test.Tasty (defaultMain, testGroup)

main :: IO ()
main =
  defaultMain
    ( testGroup
        "Bookledger"
        [ DomainTest.tests
        , StoreTest.tests
        , BackupTest.tests
        , ExportTest.tests
        ]
    )
