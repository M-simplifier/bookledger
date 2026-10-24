module Main (main) where

import qualified BookLedger.BackupTest as BackupTest
import qualified BookLedger.ActionsTest as ActionsTest
import qualified BookLedger.DomainTest as DomainTest
import qualified BookLedger.ExportTest as ExportTest
import qualified BookLedger.StoreTest as StoreTest
import qualified BookLedger.WebTest as WebTest
import Test.Tasty (defaultMain, testGroup)

main :: IO ()
main =
  defaultMain
    ( testGroup
        "Bookledger"
        [ DomainTest.tests
        , StoreTest.tests
        , BackupTest.tests
        , ActionsTest.tests
        , ExportTest.tests
        , WebTest.tests
        ]
    )
