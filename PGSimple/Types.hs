module PGSimple.Types where


import Prelude


import Control.Applicative
import Control.Monad
import Control.Monad.Base
import Control.Monad.Catch
import Control.Monad.Cont.Class
import Control.Monad.Error.Class
import Control.Monad.IO.Class
import Control.Monad.Reader
import Control.Monad.State.Class
import Control.Monad.Trans.Control
import Control.Monad.Writer.Class
import Data.Int
import Data.Maybe
import Data.Monoid
import Data.Pool
import Data.Proxy
import Data.String
import Data.Typeable
import Database.PostgreSQL.Simple as PG
import Database.PostgreSQL.Simple.FromField
import Database.PostgreSQL.Simple.FromRow
import Database.PostgreSQL.Simple.Internal
import Database.PostgreSQL.Simple.ToField
import Database.PostgreSQL.Simple.ToRow
import Database.PostgreSQL.Simple.Transaction
import Database.PostgreSQL.Simple.Types

import qualified Data.ByteString as BS
import qualified Data.Set as S
import qualified Data.Text as T
import qualified Data.Text.Encoding as T



-- | type to put and get from db 'inet' and 'cidr' typed postgresql
-- fields. This should be in postgresql-simple in fact.
newtype InetText =
    InetText
    { unInetText :: T.Text
    } deriving ( IsString, Eq, Ord, Read, Show
               , Typeable, Monoid, ToField )

instance FromField InetText where
    fromField fld Nothing = returnError ConversionFailed
                            fld "can not convert Null to InetText"
    fromField fld (Just bs) = do
        n <- typename fld
        case n of
            "inet" -> handle
            "cidr" -> handle
            _ -> returnError
                 ConversionFailed fld
                 "could not convert to InetText"
      where
        handle = return $ InetText
                 $ T.decodeUtf8 bs


class (MonadBase IO m) => HasPostgres m where
    getPGpool :: m (Pool Connection)

withPostgres :: (HasPostgres m, MonadBaseControl IO n, MonadBase n m)
             => (Connection -> n a)
             -> m a
withPostgres action = do
    pool <- getPGpool
    liftBase
        $ withResource pool action


-- | Typeclass for monad which can execute postgres queries
class (Monad m) => PgMonad m where
    mQuery               :: (ToRow q, FromRow r) => Query ->  q  -> m [r]
    mQuery_              :: (FromRow r)          => Query       -> m [r]
    mReturning           :: (ToRow q, FromRow r) => Query -> [q] -> m [r]
    mExecute             :: (ToRow q)            => Query ->  q  -> m Int64
    mExecute_            ::                        Query       -> m Int64
    mExecuteMany         :: (ToRow q)            => Query -> [q] -> m Int64

    -- | Run several queries in transaction. Commit transaction if everything
    -- ok. Rollback if any exception catched.
    -- Usage example:
    --
    -- @
    -- handler :: Handler Id
    -- handler = launchPG $ mWithTransaction defaultTransactionMode $ do
    --     [aid] <- mExecute "INSERT INTO tbl(val) VALUES (?) RETURNING id" [10]
    --     mExecuteMany "INSERT INTO tbl2(tbl_id, val) VALUES (?, ?)"
    --         $ zipWith (,) (repeat aid) [1..10]
    --     return aid
    -- @
    --
    -- After executing we will have either exception thrown either new 11 rows
    -- in database.
    mWithTransactionMode :: TransactionMode -> m a -> m a

    -- | The same as 'mWithTransactionMode' but use some default transaction
    -- mode
    mWithTransaction     :: m a -> m a
    -- | Start transaction in some mode
    mBeginMode           :: TransactionMode -> m ()
    mBegin               :: m ()
    mCommit              :: m ()
    mRollback            :: m ()
    -- FIXME: implement mWithSavepoint       :: m a -> m a


newtype PgMonadT m a =
    PgMonadT
    { unPgMonadT :: ReaderT Connection m a
    } deriving ( Functor, Applicative, Monad, MonadReader Connection
               , MonadWriter w, MonadState s, MonadError e, MonadTrans
               , Alternative, MonadFix, MonadPlus, MonadIO, MonadCont
               , MonadThrow, MonadCatch, MonadMask, MonadBase b )

instance (MonadIO m, MonadCatch m, MonadMask m)
         => PgMonad (PgMonadT m) where
    mQuery q ps = do
        con <- ask
        liftIO $ query con q ps
    mQuery_ q = do
        con <- ask
        liftIO $ query_ con q
    mReturning q ps = do
        con <- ask
        liftIO $ returning con q ps
    mExecute q ps = do
        con <- ask
        liftIO $ execute con q ps
    mExecute_ q = do
        con <- ask
        liftIO $ execute_ con q
    mExecuteMany q ps = do
        con <- ask
        liftIO $ executeMany con q ps

    mWithTransactionMode mode act = do --  NOTE: copy-pasted
          mask $ \restore -> do
              mBeginMode mode
              r <- restore act `onException` mRollback
              mCommit
              return r
    mWithTransaction act = mWithTransactionMode defaultTransactionMode act
    mBeginMode mode = ask >>= liftIO . beginMode mode
    mBegin = ask >>= liftIO . begin
    mCommit = ask >>= liftIO . commit
    mRollback = ask >>= liftIO . rollback


runPgMonadT :: Connection -> PgMonadT m a -> m a
runPgMonadT con (PgMonadT action) = runReaderT action con

-- | Use 'HasPostgres' instnace to run 'ReaderT Connection m' monad.
-- Usage example:
--
-- @
-- handler :: Handler [Int]
-- handler = launchPG $ do
--     mExecute "INSERT INTO tbl(val) values (?)" [10]
--     a <- mQuery_ "SELECT val FROM tbl"
--     return a
-- @
launchPG :: (HasPostgres m, MonadBaseControl IO m, MonadBase m m)
         => PgMonadT m a
         -> m a
launchPG act = withPostgres
               $ \con -> runPgMonadT con act


-- | Auxiliary typeclass for data types which can map to rows of some
-- table. This typeclass is used inside functions like 'pgSelectEntities' to
-- generate queries.
class Entity a where
    -- | Id type for this entity
    data EntityId a :: *
    -- | Table name of this entity
    tableName :: Proxy a -> Query
    -- | Field names without 'id' and 'created'. The order of field names must match
    -- with order of fields in 'ToRow' and 'FromRow' instances of this type.
    fieldNames :: Proxy a -> [Query]

type Ent a = (EntityId a, a)


-- | Auxiliary typeclass used inside such functions like
-- 'pgUpdateEntity'. Instance of this typeclass must be convertable to arbitrary
-- list of pairs (field name, field value).
--
-- @
-- data UpdateAppForm =
--     UpdateAppForm
--     { uafActive    :: !(Maybe Bool)
--     , uafPublished :: !(Maybe Bool)
--     } deriving (Eq, Ord, Typeable)
--
-- instance ToMarkedRow UpdateAppForm where
--     toMarkedRow f =
--         catMaybes
--         [ ((const "active") &&& toField) <$> uafActive f
--         , ((const "published") &&& toField) <$> uafPublished f
--         ]
-- @
--
-- So, no we can update our app like that:
--
-- @
-- pgUpdateEntity aid
--     (Proxy :: Proxy ClientApp)
--     (UpdateAppForm Nothing (Just True))
-- @
--
-- This is especially usable, when 'UpdateAppForm' is constructed from HTTP
-- query.
class ToMarkedRow a where
    -- | generate list of pairs (field name, field value)
    toMarkedRow :: a -> [(Query, Action)]

instance ToMarkedRow [(Query, Action)] where
    toMarkedRow = id
