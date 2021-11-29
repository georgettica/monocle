{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# OPTIONS_GHC -Wno-partial-fields #-}

-- | The CLI entrpoints
module CLI (main) where

import Env hiding (Parser, footer)
import qualified Lentille.Gerrit as G
import Macroscope.Main (runMacroscope)
import qualified Monocle.Api
import Monocle.Client (withClient)
import Monocle.Prelude hiding ((:::))
import Monocle.Search.Query (parseDateValue)
import Options.Applicative hiding (header, help, str)
import Options.Applicative.Help.Pretty (string)
import Options.Generic
import qualified Streaming.Prelude as S

---------------------------------------------------------------
-- Unified CLI
---------------------------------------------------------------

-- | usage is an optparse-applicative Parser that provides the final action
-- See the last example of https://github.com/pcapriotti/optparse-applicative#commands
usage :: Parser (IO ())
usage =
  subparser
    ( mkCommand "Start the API" "api" usageApi (Just usageApiEnv)
        <> mkCommand "Start the Crawlers" "crawler" usageCrawler (Just usageCrawlerEnv)
        <> mkCommand "Maintain the database" "janitor" usageJanitor Nothing
        <> mkCommand "Run a single crawler standlone" "lentille" usageLentille Nothing
    )
  where
    -- The API entrypoint (no CLI argument).
    usageApi = pure $ do
      -- get parameters from the environment
      (config, elastic, port) <- getFromEnv usageApiEnv
      -- start the API
      Monocle.Api.run (getInt port) (getURL elastic) config
    usageApiEnv = ((,,) <$> envConf <*> envElastic <*> envApiPort)

    -- The Crawler entrypoint (no CLI argument).
    usageCrawler = pure $ do
      -- get parameters from the environment
      (config, url, monitoringPort) <- getFromEnv usageCrawlerEnv
      -- start the Crawler
      withClient url Nothing $ runMacroscope (getInt monitoringPort) config
    usageCrawlerEnv = (,,) <$> envConf <*> envPublicUrl <*> envMonitoring

    -- The standalone lentille entrypoint (re-using optparse-generic record)
    usageLentille = mainLentille <$> parseRecord

    -- The janitor entrypoint
    usageJanitor = pure $ putStrLn "NotImplemented"

    -- Helper to create sub command
    mkEnvDoc envParser = string (Env.helpDoc envParser)
    mkCommand doc name parser envParser = command name . infos $ progDesc doc <> extraHelp
      where
        -- We only add `--help` to sub command which uses environment
        extraHelp = maybe idm (footerDoc . Just . mkEnvDoc) envParser
        infos = case envParser of
          Just _ -> info (parser <**> helper)
          Nothing -> info parser

    -- Helpers to get value fromm the env
    getFromEnv = Env.parse (header "monocle")
    envConf = var str "CONFIG" (help "The Monocle configuration" <> def "/etc/monocle/config.yaml" <> helpDef show)
    envElastic = var str "ELASTIC_CONN" (help "The Elasticsearch endpoint" <> def "elastic:9200")
    envApiPort = var str "MONOCLE_API_PORT" (help "The API Port" <> def "9898")
    envPublicUrl = var str "MONOCLE_PUBLIC_URL" (help "The Monocle URL" <> def "http://web:8080")
    envMonitoring = var str "MONOCLE_CRAWLER_MONITORING" (help "The Monitoring Port" <> def "9001")
    getInt txt = fromMaybe (error . from $ "Invalid number: " <> txt) $ readMaybe txt

main :: IO ()
main = join $ execParser opts
  where
    opts =
      info
        (usage <**> helper)
        (fullDesc <> progDesc "changemetrics.io | monocle")

getURL :: String -> Text
getURL url =
  let hasScheme = isPrefixOf "http://" url || isPrefixOf "https://" url
      url' = if hasScheme then url else "http://" <> url
   in toText url'

---------------------------------------------------------------
-- Lentille cli
---------------------------------------------------------------

data Lentille
  = GerritChange {url :: Text, change :: Int}
  | GerritProjects {url :: Text, query :: Text}
  | GerritChanges {url :: Text, project :: Text, since :: Text, limit :: Maybe Int}
  deriving stock (Generic)

instance ParseRecord Lentille where
  parseRecord = parseRecordWithModifiers lispCaseModifiers

dump :: (MonadCatch m, MonadIO m, ToJSON a) => Maybe Int -> Stream (Of a) m () -> m ()
dump limitM stream = do
  xsE <- tryAny $ S.toList_ $ brk stream
  case xsE of
    Right xs -> liftIO . putBSLn . from . encodePrettyWithSpace 2 $ xs
    Left _ -> liftIO . putBSLn $ "Couldn't evalue the stream"
  liftIO . putLBSLn =<< exportMetricsAsText
  where
    brk = maybe id S.take limitM

mainLentille :: Lentille -> IO ()
mainLentille args =
  case args of
    GerritChange url change -> do
      env <- getGerritEnv url
      dump Nothing $ G.streamChange env [G.ChangeId $ show change]
    GerritProjects url query -> do
      env <- getGerritEnv url
      dump Nothing $ G.streamProject env $ G.Regexp query
    GerritChanges url project since limit -> do
      env <- getGerritEnv url
      dump limit $ G.streamChange env [G.Project project, G.After (toSince since)]
  where
    toSince txt = case Monocle.Search.Query.parseDateValue txt of
      Just x -> x
      Nothing -> error $ "Invalid date: " <> show txt
    getGerritEnv url = do
      client <- G.getGerritClient url Nothing
      pure $ G.GerritEnv client Nothing (const Nothing) "cli"
