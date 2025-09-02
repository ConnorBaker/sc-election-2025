{-# OPTIONS_GHC -Wno-orphans #-}

module Main where

import Config
import Contributor
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async.Pool (mapConcurrently, withTaskGroup)
import Control.Exception (SomeException, displayException, handle)
import Control.Lens.Operators
import Control.Monad.Extra (maybeM)
import Data.Aeson (FromJSON, ToJSON (toJSON))
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Either.Extra (mapLeft)
import Data.Foldable qualified as Foldable
import Data.HashMap.Strict (HashMap)
import Data.HashMap.Strict qualified as HashMap
import Data.HashSet qualified as HashSet
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe)
import Data.Sequence (Seq ((:<|), (:|>)))
import Data.Sequence qualified as Seq
import Data.String (IsString (fromString))
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Text.IO qualified as Text
import Data.Text.Lazy qualified as LazyText
import Data.Time (UTCTime, diffUTCTime, getCurrentTime)
import Data.Traversable (for)
import Log (dirtyTraceM, dirtyTraceShowM)
import Network.HTTP.Types (status200)
import Network.Wreq qualified as Wreq
import PullRequests
import Query
import Repositories hiding (Repository)
import Response
import System.Environment (lookupEnv)
import Text.Pretty.Simple (pShow)
import Prelude

getToken :: IO Text
getToken =
    lookupEnv "GITHUB_TOKEN"
        & maybeM
            (fail "You really should set GITHUB_TOKEN")
            (pure . fromString)

post' :: (ToJSON a, FromJSON b) => Text -> a -> IO (Either String b)
post' token a =
    handle @SomeException (pure . Left . displayException) $
        Wreq.postWith opts "https://api.github.com/graphql" (toJSON a) >>= \case
            response
                | response ^. Wreq.responseStatus == status200 ->
                    let body = response ^. Wreq.responseBody
                        showBody = Text.unpack . Text.decodeUtf8 . LazyByteString.toStrict $ body
                     in pure . mapLeft (<> "\n" <> showBody) . Aeson.eitherDecode $ body
            response -> pure . Left . show $ response
  where
    opts =
        Wreq.defaults
            & Wreq.auth
                ?~ Wreq.oauth2Token (Text.encodeUtf8 token)
            & Wreq.header "Accept"
                .~ ["application/vnd.github.v3+json"]

post :: forall a. (FromJSON a) => Query -> IO (Response a)
post q = go 0
  where
    go :: Int -> IO (Response a)
    go 10 = fail "API fail"
    go n = do
        token <- getToken
        post' token q >>= \case
            Right r -> pure r
            Left e -> do
                dirtyTraceM "ERROR"
                dirtyTraceM . LazyText.toStrict $ pShow e
                threadDelay 1_000_000
                go (n + 1)

headl :: Seq a -> Maybe a
headl (x :<| _) = Just x
headl Seq.Empty = Nothing

headr :: Seq a -> Maybe a
headr (_ :|> x) = Just x
headr Seq.Empty = Nothing

getOfficialRepos :: IO (Seq (Text, Text))
getOfficialRepos =
    Foldable.fold <$> for ["NixOS", "NixCon"] \owner ->
        post (repositories owner 100 Nothing)
            <&> \(Response (OrganizationData (Organization Nodes{..}))) ->
                nodes <&> \repo -> (owner, repo.name)

prsForRepo :: Config -> (Text, Text) -> IO (Seq PullRequest)
prsForRepo Config{..} (owner, name) = go Nothing
  where
    validTime :: UTCTime -> Bool
    validTime time = startDate <= time && time < endDate

    validPr :: PullRequest -> Bool
    validPr PullRequest{..} = validTime createdAt && Just True == (validTime <$> mergedAt)

    go :: Maybe Text -> IO (Seq PullRequest)
    go before = do
        time <- getCurrentTime
        Response (RepositoryData (Repository Nodes{..})) <-
            post $ pullRequests owner name 100 before
        dt <- flip diffUTCTime time <$> getCurrentTime
        let oldest = headl nodes <&> (.createdAt)
            newest = headr nodes <&> (.createdAt)
            prs = Seq.filter validPr nodes
        dirtyTraceShowM (owner <> "/" <> name, Seq.length nodes, Seq.length prs, oldest, newest, dt)
        olderPrs <-
            if maybe False (startDate <) oldest
                then go $ pageInfo >>= (.startCursor)
                else pure mempty
        pure $ olderPrs <> prs

main :: IO ()
main = do
    config <- getConfig

    repos <- getOfficialRepos

    prsByRepo <- withTaskGroup 100 \group -> flip (mapConcurrently group) repos $ prsForRepo config

    excludedIds <- HashSet.fromList . Text.lines <$> Text.readFile "excluded.csv"

    let isExcluded Contributor{githubId} = HashSet.member githubId excludedIds

    let commitsByContributor :: HashMap Contributor Int
        commitsByContributor =
            HashMap.filterWithKey (const . not . isExcluded)
                . HashMap.fromListWith (+)
                . mapMaybe (\(k, v) -> k <&> (,v))
                . Foldable.toList
                . Foldable.foldMap (fmap \pr -> (pullRequestAuthor pr, pr.commits.totalCount))
                $ prsByRepo

    let mergesByContributor :: HashMap Contributor Int
        mergesByContributor =
            HashMap.filterWithKey (const . not . isExcluded)
                . HashMap.fromListWith (+)
                . mapMaybe (<&> (,1))
                . Foldable.toList
                . Foldable.foldMap (fmap pullRequestMergedBy)
                $ prsByRepo

    let sortedContributors :: Map Contributor (Int, Int)
        sortedContributors =
            Map.fromListWith (\(m1, c1) (m2, c2) -> (m1 + m2, c1 + c2)) $
                (HashMap.toList commitsByContributor <&> \(c, commits) -> (c, (commits, 0)))
                    <> (HashMap.toList mergesByContributor <&> \(c, merges) -> (c, (0, merges)))

    time <- getCurrentTime

    Text.writeFile "contributors.csv" . Text.unlines $
        let
            toRow = Text.intercalate ","
            contributorRow :: (Contributor, (Int, Int)) -> Text
            contributorRow (Contributor{..}, (merges, commits)) =
                toRow [githubId, githubUsername, ishow merges, ishow commits]
         in
            ("# generated on " <> ishow time <> " with " <> ishow config)
                : toRow ["githubId", "githubUsername", "merges", "commits"]
                : (contributorRow <$> Map.toList sortedContributors)
