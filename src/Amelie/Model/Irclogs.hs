{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE OverloadedStrings #-}
module Amelie.Model.Irclogs where

import           Amelie.Types

import           Control.Applicative
import           Control.Arrow
import           Control.Monad.IO
import           Control.Monad.Reader
import           Data.ByteString       (ByteString)
import qualified Data.ByteString       as S
import           Data.Char
import           Data.Either
import           Data.List             (find)
import           Data.List.Utils
import           Data.Maybe
import           Data.Monoid.Operator  ((++))
import           Data.Text             (Text)
import qualified Data.Text             as T
import           Data.Text.Encoding
import           Data.Time
import           Data.Time.Calendar
import           Network.Curl.Download
import           Prelude               hiding ((++))
import           System.Directory
import           System.FilePath
import           System.Locale

-- | Get IRC logs for the given channel narrowed down to the given date/time.
getNarrowedLogs :: String -- ^ Channel name.
                -> String -- ^ Date.
                -> String -- ^ Time.
                -> Controller (Either String [Text])
getNarrowedLogs channel year time = do
  case parseIrcDate year of
    Nothing -> return $ Left $ "Unable to parse year: " ++ year
    Just date -> do
      days <- mapM (getLogs channel . showIrcDate) [addDays (-1) date,date,addDays 1 date]
      let events = concat (rights days)
      return (Right (fromMaybe events
                               (narrowBy (T.isPrefixOf datetime) events <|>
                                narrowBy (T.isPrefixOf dateminute) events <|>
                                narrowBy (T.isPrefixOf datehour) events <|>
                                narrowBy (T.isPrefixOf datestr) events <|>
                                narrowBy (T.isPrefixOf dateday) events)))
  
  where narrowBy pred events =
          case find pred (filter crap events) of
            Nothing -> Nothing
            Just res -> Just $ narrow count pred (filter crap events)
        count = 50
        datetime   = T.pack $ year ++ "-" ++ replace "-" ":" time
        dateminute = T.pack $ year ++ "-" ++ replace "-" ":" (reverse . drop 2 . reverse $ time)
        datehour   = T.pack $ year ++ "-" ++ replace "-" ":" (reverse . drop 5 . reverse $ time)
        datestr    = T.pack $ year ++ "-"
        dateday    = T.pack $ reverse . drop 2 . reverse $ year
        crap = not . T.isPrefixOf " --- " . T.dropWhile (not . isSpace)

-- | Narrow to surrounding predicate.
narrow :: Int -> (a -> Bool) -> [a] -> [a]
narrow n f = uncurry (++) . (reverse . take n . reverse *** take n) . break f

-- | Get IRC logs for the given channel and date.
getLogs :: String -- ^ Channel name.
        -> String -- ^ Date.
        -> Controller (Either String [Text])
getLogs channel year = do
  dir <- asks $ configIrcDir . controllerStateConfig
  io $ do
    now <- fmap (showIrcDate . utctDay) getCurrentTime
    result <- openURICached (year /= now) (file dir) uri
    case result of
      Left err    -> return $ Left $ uri ++ ": " ++ err
      Right bytes -> return $ Right (map addYear (T.lines (decodeASCII bytes)))

  where uri = "http://tunes.org/~nef/logs/" ++ channel ++ "/" ++ yearStr
        file dir = dir </> channel ++ "-" ++ yearStr
        yearStr = replace "-" "." (drop 2 year)
        addYear line = T.pack year ++ "-" ++ line

-- | Open the URI and cache the result.
openURICached :: Bool -> FilePath -> String -> IO (Either String ByteString)
openURICached noCache path url = do
  exists <- doesFileExist path
  if exists && not noCache
     then fmap Right $ S.readFile path
     else do result <- openURI url
             case result of
               Right bytes -> S.writeFile path bytes
               _           -> return ()
             return result

-- | Parse an IRC date string into a date.
parseIrcDate :: String -> Maybe Day
parseIrcDate = parseTime defaultTimeLocale "%Y-%m-%d"

-- | Show a date to an IRC date format.
showIrcDate :: Day -> String
showIrcDate = formatTime defaultTimeLocale "%Y-%m-%d"

-- | Show a date to an IRC date format.
showIrcDateTime :: UTCTime -> String
showIrcDateTime =
  formatTime defaultTimeLocale "%Y-%m-%d/%H-%M-%S" . addUTCTime ((40*60)+((-9)*60*60))
