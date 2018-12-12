{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TupleSections #-}

-- |
-- Module: Chainweb.Test.Utils
-- Copyright: Copyright © 2018 Kadena LLC.
-- License: MIT
-- Maintainer: Lars Kuhtz <lars@kadena.io>
-- Stability: experimental
--
-- TODO
--
module Chainweb.Test.Utils
(
-- * BlockHeaderDb Generation
  toyBlockHeaderDb
, withDB
, insertN

-- * Test BlockHeaderDbs Configurations
, peterson
, testBlockHeaderDbs
, petersonGenesisBlockHeaderDbs
, singletonGenesisBlockHeaderDbs
, linearBlockHeaderDbs
, starBlockHeaderDbs

-- * Toy Server Interaction
, withServer

-- * Tasty TestTree Server and ClientEnv
, testHost
, TestClientEnv(..)
, pattern BlockHeaderDbsTestClientEnv
, pattern PeerDbsTestClientEnv
, withTestServer
, withChainwebServer
, withBlockHeaderDbsServer
, withPeerDbsServer

-- * QuickCheck Properties
, prop_iso
, prop_iso'
, prop_encodeDecodeRoundtrip

-- * Expectations
, assertExpectation
) where

import Control.Concurrent
import Control.Concurrent.Async
import Control.Exception (bracket)
import Control.Monad.IO.Class

import Data.Bifunctor
import Data.Bytes.Get
import Data.Bytes.Put
import Data.Foldable
import Data.Reflection (give)
import qualified Data.Text as T
import Data.Word (Word64)

import qualified Network.HTTP.Client as HTTP
import Network.Socket (close)
import qualified Network.Wai as W
import qualified Network.Wai.Handler.Warp as W

import Numeric.Natural

import Servant.Client (BaseUrl(..), ClientEnv, Scheme(..), mkClientEnv)

import Test.QuickCheck
import Test.Tasty
import Test.Tasty.HUnit

-- internal modules

import Chainweb.BlockHeader
import Chainweb.BlockHeaderDB
import Chainweb.ChainId
import Chainweb.Graph
import Chainweb.RestAPI (chainwebApplication)
import Chainweb.RestAPI.NetworkID
import Chainweb.TreeDB
import Chainweb.Utils
import Chainweb.Version (ChainwebVersion(..))

import qualified Data.DiGraph as G

import qualified P2P.Node.PeerDB as P2P

-- -------------------------------------------------------------------------- --
-- BlockHeaderDb Generation

-- | Initialize an length-1 `BlockHeaderDb` for testing purposes.
--
-- Borrowed from TrivialSync.hs
--
toyBlockHeaderDb :: ChainId -> IO (BlockHeader, BlockHeaderDb)
toyBlockHeaderDb cid = (genesis,) <$> initBlockHeaderDb (Configuration genesis)
  where
    graph = toChainGraph (const cid) singleton
    genesis = genesisBlockHeader Test graph cid

-- | Given a function that accepts a Genesis Block and
-- an initialized `BlockHeaderDb`, perform some action
-- and cleanly close the DB.
--
withDB :: ChainId -> (BlockHeader -> BlockHeaderDb -> IO ()) -> IO ()
withDB cid = bracket (toyBlockHeaderDb cid) (closeBlockHeaderDb . snd) . uncurry

-- | Populate a `BlockHeaderDb` with /n/ generated `BlockHeader`s.
--
insertN :: Int -> BlockHeader -> BlockHeaderDb -> IO ()
insertN n g db = traverse_ (insert db) bhs
  where
    bhs = take n $ testBlockHeaders g

-- -------------------------------------------------------------------------- --
-- Test Chain Database Configurations

peterson :: ChainGraph
peterson = toChainGraph (testChainId . int) G.petersonGraph

singleton :: ChainGraph
singleton = toChainGraph (testChainId . int) G.singleton

testBlockHeaderDbs :: ChainGraph -> ChainwebVersion -> IO [(ChainId, BlockHeaderDb)]
testBlockHeaderDbs g v = mapM (\c -> (c,) <$> db c) $ give g $ toList chainIds
  where
    db c = initBlockHeaderDb . Configuration $ genesisBlockHeader v g c

petersonGenesisBlockHeaderDbs :: IO [(ChainId, BlockHeaderDb)]
petersonGenesisBlockHeaderDbs = testBlockHeaderDbs peterson Test

singletonGenesisBlockHeaderDbs :: IO [(ChainId, BlockHeaderDb)]
singletonGenesisBlockHeaderDbs = testBlockHeaderDbs singleton Test

linearBlockHeaderDbs :: Natural -> IO [(ChainId, BlockHeaderDb)] -> IO [(ChainId, BlockHeaderDb)]
linearBlockHeaderDbs n genDbs = do
    dbs <- genDbs
    mapM_ (uncurry populateDb) dbs
    return dbs
  where
    populateDb :: ChainId -> BlockHeaderDb -> IO ()
    populateDb cid db = do
        let gbh0 = genesisBlockHeader Test peterson cid
        traverse_ (insert db) . take (int n) $ testBlockHeaders gbh0

starBlockHeaderDbs :: Natural -> IO [(ChainId, BlockHeaderDb)] -> IO [(ChainId, BlockHeaderDb)]
starBlockHeaderDbs n genDbs = do
    dbs <- genDbs
    mapM_ (uncurry populateDb) dbs
    return dbs
  where
    populateDb :: ChainId -> BlockHeaderDb -> IO ()
    populateDb cid db = do
        let gbh0 = genesisBlockHeader Test peterson cid
        traverse_ (\i -> insert db $ newEntry i gbh0) [0 .. (int n-1)]

    newEntry :: Word64 -> BlockHeader -> BlockHeader
    newEntry i h = head $ testBlockHeadersWithNonce (Nonce i) h

-- -------------------------------------------------------------------------- --
-- Toy Server Interaction

-- | Spawn a server that acts as a peer node for the purpose of querying / syncing.
--
withServer
    :: [(ChainId, BlockHeaderDb)]
    -> [(NetworkId, P2P.PeerDb)]
    -> (ClientEnv -> IO a)
    -> IO a
withServer chainDbs peerDbs f = W.testWithApplication (pure app) work
  where
    app = chainwebApplication Test chainDbs peerDbs
    work port = do
      mgr <- HTTP.newManager HTTP.defaultManagerSettings
      f $ mkClientEnv mgr (BaseUrl Http "localhost" port "")

-- -------------------------------------------------------------------------- --
-- Tasty TestTree Server and Client Environment

testHost :: String
testHost = "localhost"

data TestClientEnv = TestClientEnv
    { _envClientEnv :: !ClientEnv
    , _envBlockHeaderDbs :: ![(ChainId, BlockHeaderDb)]
    , _envPeerDbs :: ![(NetworkId, P2P.PeerDb)]
    }

pattern BlockHeaderDbsTestClientEnv
    :: ClientEnv
    -> [(ChainId, BlockHeaderDb)]
    -> TestClientEnv
pattern BlockHeaderDbsTestClientEnv { _cdbEnvClientEnv, _cdbEnvBlockHeaderDbs }
    = TestClientEnv _cdbEnvClientEnv _cdbEnvBlockHeaderDbs []

pattern PeerDbsTestClientEnv
    :: ClientEnv
    -> [(NetworkId, P2P.PeerDb)]
    -> TestClientEnv
pattern PeerDbsTestClientEnv { _pdbEnvClientEnv, _pdbEnvPeerDbs }
    = TestClientEnv _pdbEnvClientEnv [] _pdbEnvPeerDbs

-- TODO: catch, wrap, and forward exceptions from chainwebApplication
--
withTestServer
    :: IO W.Application
    -> (Int -> IO a)
    -> (IO a -> TestTree)
    -> TestTree
withTestServer appIO envIO test = withResource start stop $ \x ->
    test $ x >>= \(_, _, env) -> return env
  where
    start = do
        app <- appIO
        (port, sock) <- W.openFreePort
        readyVar <- newEmptyMVar
        server <- async $ do
            let settings = W.setBeforeMainLoop (putMVar readyVar ()) W.defaultSettings
            W.runSettingsSocket settings sock app
        link server
        _ <- takeMVar readyVar
        env <- envIO port
        return (server, sock, env)

    stop (server, sock, _) = do
        uninterruptibleCancel server
        close sock

withChainwebServer
    :: IO [(ChainId, BlockHeaderDb)]
    -> IO [(NetworkId, P2P.PeerDb)]
    -> (IO TestClientEnv -> TestTree)
    -> TestTree
withChainwebServer chainDbsIO peerDbsIO = withTestServer mkApp mkEnv
  where
    mkApp = chainwebApplication Test <$> chainDbsIO <*> peerDbsIO
    mkEnv port = do
        mgr <- HTTP.newManager HTTP.defaultManagerSettings
        TestClientEnv (mkClientEnv mgr (BaseUrl Http testHost port ""))
            <$> chainDbsIO
            <*> peerDbsIO

withPeerDbsServer
    :: IO [(NetworkId, P2P.PeerDb)]
    -> (IO TestClientEnv -> TestTree)
    -> TestTree
withPeerDbsServer = withChainwebServer (return [])

withBlockHeaderDbsServer
    :: IO [(ChainId, BlockHeaderDb)]
    -> (IO TestClientEnv -> TestTree)
    -> TestTree
withBlockHeaderDbsServer chainDbsIO = withChainwebServer chainDbsIO (return [])

-- -------------------------------------------------------------------------- --
-- Isomorphisms and Roundtrips

prop_iso :: Eq a => Show a => (b -> a) -> (a -> b) -> a -> Property
prop_iso d e a = a === d (e a)

prop_iso'
    :: Show e
    => Eq a
    => Show a
    => (b -> Either e a)
    -> (a -> b)
    -> a
    -> Property
prop_iso' d e a = Right a === first show (d (e a))

prop_encodeDecodeRoundtrip
    :: Eq a
    => Show a
    => (forall m . MonadGet m => m a)
    -> (forall m . MonadPut m => a -> m ())
    -> a
    -> Property
prop_encodeDecodeRoundtrip d e = prop_iso' (runGetEither d) (runPutS . e)

-- -------------------------------------------------------------------------- --
-- Expectations

assertExpectation
    :: MonadIO m
    => Eq a
    => Show a
    => T.Text
    -> Expected a
    -> Actual a
    -> m ()
assertExpectation msg expected actual = liftIO $ assertBool
    (T.unpack $ unexpectedMsg msg expected actual)
    (getExpected expected == getActual actual)