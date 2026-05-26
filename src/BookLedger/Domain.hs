{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}

module BookLedger.Domain
  ( Status(..)
  , allStatuses
  , parseStatus
  , statusText
  , statusLabel
  , Book(..)
  , NewBook(..)
  , BookFilter(..)
  ) where

import Data.Aeson (FromJSON(..), ToJSON(..), Value(String), object, withObject, withText, (.=), (.:), (.:?))
import Data.Text (Text)
import qualified Data.Text as T
import GHC.Generics (Generic)

data Status
  = Unread
  | Reading
  | Finished
  | Disposed
  deriving (Eq, Ord, Show, Read, Enum, Bounded, Generic)

allStatuses :: [Status]
allStatuses = [minBound .. maxBound]

statusText :: Status -> Text
statusText status =
  case status of
    Unread -> "unread"
    Reading -> "reading"
    Finished -> "finished"
    Disposed -> "disposed"

statusLabel :: Status -> Text
statusLabel status =
  case status of
    Unread -> "未読"
    Reading -> "読書中"
    Finished -> "読了"
    Disposed -> "処分"

parseStatus :: Text -> Maybe Status
parseStatus value =
  case T.toLower (T.strip value) of
    "unread" -> Just Unread
    "reading" -> Just Reading
    "finished" -> Just Finished
    "disposed" -> Just Disposed
    "未読" -> Just Unread
    "読書中" -> Just Reading
    "読了" -> Just Finished
    "処分" -> Just Disposed
    _ -> Nothing

instance ToJSON Status where
  toJSON = String . statusText

instance FromJSON Status where
  parseJSON = withText "Status" $ \value ->
    maybe (fail ("unknown status: " <> T.unpack value)) pure (parseStatus value)

data Book = Book
  { bookId :: Int
  , bookTitle :: Text
  , bookAuthor :: Text
  , bookStatus :: Status
  , bookCategory :: Text
  , bookSeries :: Maybe Text
  , bookVolumeNo :: Maybe Double
  , bookMemo :: Text
  , bookCreatedAt :: Text
  , bookUpdatedAt :: Text
  } deriving (Eq, Show, Generic)

instance ToJSON Book where
  toJSON book = object
    [ "id" .= bookId book
    , "title" .= bookTitle book
    , "author" .= bookAuthor book
    , "status" .= bookStatus book
    , "statusLabel" .= statusLabel (bookStatus book)
    , "category" .= bookCategory book
    , "series" .= bookSeries book
    , "volumeNo" .= bookVolumeNo book
    , "memo" .= bookMemo book
    , "createdAt" .= bookCreatedAt book
    , "updatedAt" .= bookUpdatedAt book
    ]

data NewBook = NewBook
  { newTitle :: Text
  , newAuthor :: Text
  , newStatus :: Status
  , newCategory :: Text
  , newSeries :: Maybe Text
  , newVolumeNo :: Maybe Double
  , newMemo :: Text
  } deriving (Eq, Show, Generic)

instance FromJSON NewBook where
  parseJSON = withObject "NewBook" $ \obj -> do
    title <- obj .: "title"
    author <- obj .: "author"
    status <- obj .:? "status" >>= pure . maybe Unread id
    category <- obj .: "category"
    series <- obj .:? "series"
    volumeNo <- obj .:? "volumeNo"
    memo <- obj .:? "memo" >>= pure . maybe "" id
    pure NewBook
      { newTitle = title
      , newAuthor = author
      , newStatus = status
      , newCategory = category
      , newSeries = normalizeMaybe series
      , newVolumeNo = volumeNo
      , newMemo = memo
      }

data BookFilter = BookFilter
  { filterStatus :: Maybe Status
  , filterCategory :: Maybe Text
  , filterSeries :: Maybe Text
  , filterSearch :: Maybe Text
  } deriving (Eq, Show)

normalizeMaybe :: Maybe Text -> Maybe Text
normalizeMaybe Nothing = Nothing
normalizeMaybe (Just value)
  | T.null (T.strip value) = Nothing
  | otherwise = Just (T.strip value)
