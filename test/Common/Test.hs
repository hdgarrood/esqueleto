{-# LANGUAGE CPP #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE EmptyDataDecls #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PartialTypeSignatures #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE Rank2Types #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE UndecidableInstances #-}

{-# OPTIONS_GHC -fno-warn-unused-binds #-}
{-# OPTIONS_GHC -fno-warn-deprecations #-}
module Common.Test
    ( tests
    , testLocking
    , testAscRandom
    , testRandomMath
    , migrateAll
    , migrateUnique
    , cleanDB
    , cleanUniques
    , RunDbMonad
    , Run
    , p1, p2, p3, p4, p5
    , l1, l2, l3
    , u1, u2, u3, u4
    , insert'
    , EntityField (..)
    , Foo (..)
    , Bar (..)
    , Person (..)
    , BlogPost (..)
    , Lord (..)
    , Deed (..)
    , Follow (..)
    , CcList (..)
    , Frontcover (..)
    , Article (..)
    , Tag (..)
    , ArticleTag (..)
    , Article2 (..)
    , Point (..)
    , Circle (..)
    , Numbers (..)
    , OneUnique(..)
    , Unique(..)
    , DateTruncTest(..)
    , DateTruncTestId
    , Key(..)
    ) where

import Control.Monad (forM_, replicateM, replicateM_, void)
import Control.Monad.Catch (MonadCatch)
import Control.Monad.Reader (ask)
import Data.Either
import Data.Time
#if __GLASGOW_HASKELL__ >= 806
import Control.Monad.Fail (MonadFail)
#endif
import Control.Monad.IO.Class (MonadIO(liftIO))
import Control.Monad.Logger (MonadLoggerIO(..), MonadLogger(..), NoLoggingT, runNoLoggingT)
import Control.Monad.Trans.Reader (ReaderT)
import qualified Data.Attoparsec.Text as AP
import Data.Char (toLower, toUpper)
import Data.Monoid ((<>))
import Database.Esqueleto
import Database.Esqueleto.Experimental hiding (from, on)
import qualified Database.Esqueleto.Experimental as Experimental
import Database.Persist.TH
import Test.Hspec
import UnliftIO

import Data.Conduit (ConduitT, runConduit, (.|))
import qualified Data.Conduit.List as CL
import qualified Data.List as L
import qualified Data.Set as S
import qualified Data.Text as Text
import qualified Data.Text.Internal.Lazy as TL
import qualified Data.Text.Lazy.Builder as TLB
import qualified Database.Esqueleto.Internal.ExprParser as P
import qualified Database.Esqueleto.Internal.Sql as EI
import qualified UnliftIO.Resource as R

-- Test schema
share [mkPersist sqlSettings, mkMigrate "migrateAll"] [persistUpperCase|
  Foo
    name Int
    Primary name
    deriving Show Eq Ord
  Bar
    quux FooId
    deriving Show Eq Ord
  Baz
    blargh FooId
    deriving Show Eq
  Shoop
    baz BazId
    deriving Show Eq
  Asdf
    shoop ShoopId
    deriving Show Eq
  Another
    why BazId
  YetAnother
    argh ShoopId

  Person
    name String
    age Int Maybe
    weight Int Maybe
    favNum Int
    deriving Eq Show Ord
  BlogPost
    title String
    authorId PersonId
    deriving Eq Show
  Comment
    body String
    blog BlogPostId
    deriving Eq Show
  CommentReply
    body String
    comment CommentId
  Profile
    name String
    person PersonId
    deriving Eq Show
  Reply
    guy PersonId
    body String
    deriving Eq Show

  Lord
    county String maxlen=100
    dogs Int Maybe
    Primary county
    deriving Eq Show

  Deed
    contract String maxlen=100
    ownerId LordId maxlen=100
    Primary contract
    deriving Eq Show

  Follow
    follower PersonId
    followed PersonId
    deriving Eq Show

  CcList
    names [String]

  Frontcover
    number Int
    title String
    Primary number
    deriving Eq Show
  Article
    title String
    frontcoverNumber Int
    Foreign Frontcover fkfrontcover frontcoverNumber
    deriving Eq Show
  ArticleMetadata
    articleId ArticleId
    Primary articleId
    deriving Eq Show
  Tag
    name String maxlen=100
    Primary name
    deriving Eq Show
  ArticleTag
    articleId ArticleId
    tagId     TagId maxlen=100
    Primary   articleId tagId
    deriving Eq Show
  Article2
    title String
    frontcoverId FrontcoverId
    deriving Eq Show
  Point
    x Int
    y Int
    name String
    Primary x y
    deriving Eq Show
  Circle
    centerX Int
    centerY Int
    name String
    Foreign Point fkpoint centerX centerY
    deriving Eq Show
  Numbers
    int    Int
    double Double
    deriving Eq Show

  JoinOne
    name    String
    deriving Eq Show

  JoinTwo
    joinOne JoinOneId
    name    String
    deriving Eq Show

  JoinThree
    joinTwo JoinTwoId
    name    String
    deriving Eq Show

  JoinFour
    name    String
    joinThree JoinThreeId
    deriving Eq Show

  JoinOther
    name    String
    deriving Eq Show

  JoinMany
    name      String
    joinOther JoinOtherId
    joinOne   JoinOneId
    deriving Eq Show

  DateTruncTest
    created   UTCTime
    deriving Eq Show
|]

-- Unique Test schema
share [mkPersist sqlSettings, mkMigrate "migrateUnique"] [persistUpperCase|
  OneUnique
    name String
    value Int
    UniqueValue value
    deriving Eq Show
|]


instance ToBaseId ArticleMetadata where
    type BaseEnt ArticleMetadata = Article
    toBaseIdWitness articleId = ArticleMetadataKey articleId

-- | this could be achieved with S.fromList, but not all lists
--   have Ord instances
sameElementsAs :: Eq a => [a] -> [a] -> Bool
sameElementsAs l1' l2' = null (l1' L.\\ l2')

-- | Helper for rounding to a specific digit
--   Prelude> map (flip roundTo 12.3456) [0..5]
--   [12.0, 12.3, 12.35, 12.346, 12.3456, 12.3456]
roundTo :: (Fractional a, RealFrac a1, Integral b) => b -> a1 -> a
roundTo n f =
    (fromInteger $ round $ f * (10^n)) / (10.0^^n)

p1 :: Person
p1 = Person "John"   (Just 36) Nothing   1

p2 :: Person
p2 = Person "Rachel" Nothing   (Just 37) 2

p3 :: Person
p3 = Person "Mike"   (Just 17) Nothing   3

p4 :: Person
p4 = Person "Livia"  (Just 17) (Just 18) 4

p5 :: Person
p5 = Person "Mitch"  Nothing   Nothing   5

l1 :: Lord
l1 = Lord "Cornwall" (Just 36)

l2 :: Lord
l2 = Lord "Dorset" Nothing

l3 :: Lord
l3 = Lord "Chester" (Just 17)

u1 :: OneUnique
u1 = OneUnique "First" 0

u2 :: OneUnique
u2 = OneUnique "Second" 1

u3 :: OneUnique
u3 = OneUnique "Third" 0

u4 :: OneUnique
u4 = OneUnique "First" 2

testSelect :: Run -> Spec
testSelect run = do
    describe "select" $ do
        it "works for a single value" $
            run $ do
                ret <- select $ return $ val (3 :: Int)
                liftIO $ ret `shouldBe` [ Value 3 ]

        it "works for a pair of a single value and ()" $
            run $ do
                ret <- select $ return (val (3 :: Int), ())
                liftIO $ ret `shouldBe` [ (Value 3, ()) ]

        it "works for a single ()" $
            run $ do
                ret <- select $ return ()
                liftIO $ ret `shouldBe` [ () ]

        it "works for a single NULL value" $
            run $ do
                ret <- select $ return nothing
                liftIO $ ret `shouldBe` [ Value (Nothing :: Maybe Int) ]

testSubSelect :: Run -> Spec
testSubSelect run = do
    let setup :: MonadIO m => SqlPersistT m ()
        setup = do
            _ <- insert $ Numbers 1 2
            _ <- insert $ Numbers 2 4
            _ <- insert $ Numbers 3 5
            _ <- insert $ Numbers 6 7
            pure ()

    describe "subSelect" $ do
        it "is safe for queries that may return multiple results" $ do
            let query =
                  from $ \n -> do
                  orderBy [asc (n ^. NumbersInt)]
                  pure (n ^. NumbersInt)
            res <- run $ do
                setup
                select $ pure $ subSelect query
            res `shouldBe` [Value (Just 1)]

            eres <- try $ run $ do
                setup
                select $ pure $ sub_select query
            case eres of
                Left (SomeException _) ->
                    -- We should receive an exception, but the different database
                    -- libraries throw different exceptions. Hooray.
                    pure ()
                Right v ->
                    -- This shouldn't happen, but in sqlite land, many things are
                    -- possible.
                    v `shouldBe` [Value 1]

        it "is safe for queries that may not return anything" $ do
            let query =
                    from $ \n -> do
                    orderBy [asc (n ^. NumbersInt)]
                    limit 1
                    pure (n ^. NumbersInt)
            res <- run $ select $ pure $ subSelect query
            res `shouldBe` [Value Nothing]

            eres <- try $ run $ do
                setup
                select $ pure $ sub_select query

            case eres of
                Left (_ :: PersistException) ->
                    -- We expect to receive this exception. However, sqlite evidently has
                    -- no problems with it, so we can't *require* that the exception is
                    -- thrown. Sigh.
                    pure ()
                Right v ->
                    -- This shouldn't happen, but in sqlite land, many things are
                    -- possible.
                    v `shouldBe` [Value 1]

    describe "subSelectList" $ do
        it "is safe on empty databases as well as good databases" $ do
            let query =
                    from $ \n -> do
                    where_ $ n ^. NumbersInt `in_` do
                        subSelectList $
                            from $ \n' -> do
                            where_ $ n' ^. NumbersInt >=. val 3
                            pure (n' ^. NumbersInt)
                    pure n

            empty <- run $ do
                select query

            full <- run $ do
                setup
                select query

            empty `shouldBe` []
            full `shouldSatisfy` (not . null)

    describe "subSelectMaybe" $ do
        it "is equivalent to joinV . subSelect" $ do
            let query
                    :: (SqlQuery (SqlExpr (Value (Maybe Int))) -> SqlExpr (Value (Maybe Int)))
                    -> SqlQuery (SqlExpr (Value (Maybe Int)))
                query selector =
                    from $ \n -> do
                    pure $
                        selector $
                        from $ \n' -> do
                        where_ $ n' ^. NumbersDouble >=. n ^. NumbersDouble
                        pure (max_ (n' ^. NumbersInt))

            a <- run $ do
                setup
                select (query subSelectMaybe)
            b <- run $ do
                setup
                select (query (joinV . subSelect))
            a `shouldBe` b

    describe "subSelectCount" $ do
        it "is a safe way to do a countRows" $ do
            xs0 <- run $ do
                setup
                select $
                    from $ \n -> do
                    pure $ (,) n $
                        subSelectCount @Int $
                        from $ \n' -> do
                        where_ $ n' ^. NumbersInt >=. n ^. NumbersInt

            xs1 <- run $ do
                setup
                select $
                    from $ \n -> do
                    pure $ (,) n $
                        subSelectUnsafe $
                        from $ \n' -> do
                        where_ $ n' ^. NumbersInt >=. n ^. NumbersInt
                        pure (countRows :: SqlExpr (Value Int))

            let getter (Entity _ a, b) = (a, b)
            map getter xs0 `shouldBe` map getter xs1

    describe "subSelectUnsafe" $ do
        it "throws exceptions on multiple results" $ do
            eres <- try $ run $ do
                setup
                bad <- select $
                    from $ \n -> do
                    pure $ (,) (n ^. NumbersInt) $
                        subSelectUnsafe $
                        from $ \n' -> do
                        pure (just (n' ^. NumbersDouble))
                good <- select $
                    from $ \n -> do
                    pure $ (,) (n ^. NumbersInt) $
                        subSelect $
                        from $ \n' -> do
                        pure (n' ^. NumbersDouble)
                pure (bad, good)
            case eres of
                Left (SomeException _) ->
                    -- Must use SomeException because the database libraries throw their
                    -- own errors.
                    pure ()
                Right (bad, good) -> do
                    -- SQLite just takes the first element of the sub-select. lol.
                    --
                    bad `shouldBe` good

        it "throws exceptions on null results" $ do
            eres <- try $ run $ do
                setup
                select $
                    from $ \n -> do
                    pure $ (,) (n ^. NumbersInt) $
                        subSelectUnsafe $
                        from $ \n' -> do
                        where_ $ val False
                        pure (n' ^. NumbersDouble)
            case eres of
                Left (_ :: PersistException) ->
                    pure ()
                Right xs ->
                    xs `shouldBe` []

testSelectSource :: Run -> Spec
testSelectSource run = do
    describe "selectSource" $ do
        it "works for a simple example" $ run $ do
            let query = selectSource $
                        from $ \person ->
                        return person
            p1e <- insert' p1
            ret <- runConduit $ query .| CL.consume
            liftIO $ ret `shouldBe` [ p1e ]

        it "can run a query many times" $ run $ do
            let query = selectSource $
                        from $ \person ->
                        return person
            p1e <- insert' p1
            ret0 <- runConduit $ query .| CL.consume
            ret1 <- runConduit $ query .| CL.consume
            liftIO $ ret0 `shouldBe` [ p1e ]
            liftIO $ ret1 `shouldBe` [ p1e ]

        it "works on repro" $ do
            let selectPerson :: R.MonadResource m => String -> ConduitT () (Key Person) (SqlPersistT m) ()
                selectPerson name = do
                    let source =
                            selectSource $ from $ \person -> do
                            where_ $ person ^. PersonName ==. val name
                            return $ person ^. PersonId
                    source .| CL.map unValue
            run $ do
                p1e <- insert' p1
                p2e <- insert' p2
                r1 <- runConduit $ selectPerson (personName p1) .| CL.consume
                r2 <- runConduit $ selectPerson (personName p2) .| CL.consume
                liftIO $ do
                  r1 `shouldBe` [ entityKey p1e ]
                  r2 `shouldBe` [ entityKey p2e ]

testSelectFrom :: Run -> Spec
testSelectFrom run = do
    describe "select/from" $ do
        it "works for a simple example" $ run $ do
            p1e <- insert' p1
            ret <-
                select $
                from $ \person ->
                return person
            liftIO $ ret `shouldBe` [ p1e ]

        it "works for a simple self-join (one entity)" $ run $ do
            p1e <- insert' p1
            ret <-
                select $
                from $ \(person1, person2) ->
                return (person1, person2)
            liftIO $ ret `shouldBe` [ (p1e, p1e) ]

        it "works for a simple self-join (two entities)" $ run $ do
            p1e <- insert' p1
            p2e <- insert' p2
            ret <-
                select $
                from $ \(person1, person2) ->
                return (person1, person2)
            liftIO $
                ret
                    `shouldSatisfy`
                        sameElementsAs
                            [ (p1e, p1e)
                            , (p1e, p2e)
                            , (p2e, p1e)
                            , (p2e, p2e)
                            ]

        it "works for a self-join via sub_select" $ run $ do
            p1k <- insert p1
            p2k <- insert p2
            _f1k <- insert (Follow p1k p2k)
            _f2k <- insert (Follow p2k p1k)
            ret <- select $
                   from $ \followA -> do
                   let subquery =
                         from $ \followB -> do
                         where_ $ followA ^. FollowFollower ==. followB ^. FollowFollowed
                         return $ followB ^. FollowFollower
                   where_ $ followA ^. FollowFollowed ==. sub_select subquery
                   return followA
            liftIO $ length ret `shouldBe` 2

        it "works for a self-join via exists" $ run $ do
            p1k <- insert p1
            p2k <- insert p2
            _f1k <- insert (Follow p1k p2k)
            _f2k <- insert (Follow p2k p1k)
            ret <- select $
                   from $ \followA -> do
                   where_ $ exists $
                            from $ \followB ->
                            where_ $ followA ^. FollowFollower ==. followB ^. FollowFollowed
                   return followA
            liftIO $ length ret `shouldBe` 2


        it "works for a simple projection" $ run $ do
            p1k <- insert p1
            p2k <- insert p2
            ret <- select $
                   from $ \p ->
                   return (p ^. PersonId, p ^. PersonName)
            liftIO $ ret `shouldBe` [ (Value p1k, Value (personName p1))
                                    , (Value p2k, Value (personName p2)) ]

        it "works for a simple projection with a simple implicit self-join" $ run $ do
            _ <- insert p1
            _ <- insert p2
            ret <- select $
                   from $ \(pa, pb) ->
                   return (pa ^. PersonName, pb ^. PersonName)
            liftIO $ ret `shouldSatisfy` sameElementsAs
                                    [ (Value (personName p1), Value (personName p1))
                                    , (Value (personName p1), Value (personName p2))
                                    , (Value (personName p2), Value (personName p1))
                                    , (Value (personName p2), Value (personName p2)) ]

        it "works with many kinds of LIMITs and OFFSETs" $ run $ do
            [p1e, p2e, p3e, p4e] <- mapM insert' [p1, p2, p3, p4]
            let people =
                    from $ \p -> do
                    orderBy [asc (p ^. PersonName)]
                    return p
            ret1 <-
                select $ do
                p <- people
                limit 2
                limit 1
                return p
            liftIO $ ret1 `shouldBe` [ p1e ]
            ret2 <-
                select $ do
                p <- people
                limit 1
                limit 2
                return p
            liftIO $ ret2 `shouldBe` [ p1e, p4e ]
            ret3 <-
                select $ do
                p <- people
                offset 3
                offset 2
                return p
            liftIO $ ret3 `shouldBe` [ p3e, p2e ]
            ret4 <-
                select $ do
                p <- people
                offset 3
                limit 5
                offset 2
                limit 3
                offset 1
                limit 2
                return p
            liftIO $ ret4 `shouldBe` [ p4e, p3e ]
            ret5 <-
                select $ do
                p <- people
                offset 1000
                limit  1
                limit  1000
                offset 0
                return p
            liftIO $ ret5 `shouldBe` [ p1e, p4e, p3e, p2e ]

        it "works with non-id primary key" $ run $ do
            let fc = Frontcover number ""
                number = 101
                Right thePk = keyFromValues [toPersistValue number]
            fcPk <- insert fc
            [Entity _ ret] <- select $ from return
            liftIO $ do
                ret `shouldBe` fc
                fcPk `shouldBe` thePk

        it "works when returning a custom non-composite primary key from a query" $ run $ do
            let name = "foo"
                t = Tag name
                Right thePk = keyFromValues [toPersistValue name]
            tagPk <- insert t
            [Value ret] <- select $ from $ \t' -> return (t'^.TagId)
            liftIO $ do
                ret `shouldBe` thePk
                thePk `shouldBe` tagPk

        it "works when returning a composite primary key from a query" $ run $ do
            let p = Point 10 20 ""
            thePk <- insert p
            [Value ppk] <- select $ from $ \p' -> return (p'^.PointId)
            liftIO $ ppk `shouldBe` thePk

testSelectJoin :: Run -> Spec
testSelectJoin run = do
  describe "select:JOIN" $ do
    it "works with a LEFT OUTER JOIN" $
      run $ do
        p1e <- insert' p1
        p2e <- insert' p2
        p3e <- insert' p3
        p4e <- insert' p4
        b12e <- insert' $ BlogPost "b" (entityKey p1e)
        b11e <- insert' $ BlogPost "a" (entityKey p1e)
        b31e <- insert' $ BlogPost "c" (entityKey p3e)
        ret <- select $
               from $ \(p `LeftOuterJoin` mb) -> do
               on (just (p ^. PersonId) ==. mb ?. BlogPostAuthorId)
               orderBy [ asc (p ^. PersonName), asc (mb ?. BlogPostTitle) ]
               return (p, mb)
        liftIO $ ret `shouldBe` [ (p1e, Just b11e)
                                , (p1e, Just b12e)
                                , (p4e, Nothing)
                                , (p3e, Just b31e)
                                , (p2e, Nothing) ]

    it "typechecks (A LEFT OUTER JOIN (B LEFT OUTER JOIN C))" $
      let _ = run $
              select $
              from $ \(a `LeftOuterJoin` (b `LeftOuterJoin` c)) ->
              let _ = [a, b, c] :: [ SqlExpr (Entity Person) ]
              in return a
      in return () :: IO ()

    it "typechecks ((A LEFT OUTER JOIN B) LEFT OUTER JOIN C)" $
      let _ = run $
              select $
              from $ \((a `LeftOuterJoin` b) `LeftOuterJoin` c) ->
              let _ = [a, b, c] :: [ SqlExpr (Entity Person) ]
              in return a
      in return () :: IO ()

    it "throws an error for using on without joins" $
      run (select $
           from $ \(p, mb) -> do
           on (just (p ^. PersonId) ==. mb ?. BlogPostAuthorId)
           orderBy [ asc (p ^. PersonName), asc (mb ?. BlogPostTitle) ]
           return (p, mb)
      ) `shouldThrow` (\(OnClauseWithoutMatchingJoinException _) -> True)

    it "throws an error for using too many ons" $
      run (select $
           from $ \(p `FullOuterJoin` mb) -> do
           on (just (p ^. PersonId) ==. mb ?. BlogPostAuthorId)
           on (just (p ^. PersonId) ==. mb ?. BlogPostAuthorId)
           orderBy [ asc (p ^. PersonName), asc (mb ?. BlogPostTitle) ]
           return (p, mb)
      ) `shouldThrow` (\(OnClauseWithoutMatchingJoinException _) -> True)

    it "works with ForeignKey to a non-id primary key returning one entity" $
      run $ do
        let fc = Frontcover number ""
            article = Article "Esqueleto supports composite pks!" number
            number = 101
            Right thePk = keyFromValues [toPersistValue number]
        fcPk <- insert fc
        insert_ article
        [Entity _ retFc] <- select $
          from $ \(a `InnerJoin` f) -> do
            on (f^.FrontcoverNumber ==. a^.ArticleFrontcoverNumber)
            return f
        liftIO $ do
          retFc `shouldBe` fc
          fcPk `shouldBe` thePk
    it "allows using a primary key that is itself a key of another table" $
      run $ do
        let number = 101
        insert_ $ Frontcover number ""
        articleId <- insert $ Article "title" number
        articleMetaE <- insert' (ArticleMetadata articleId)
        result <- select . from $ \articleMetadata -> do
          where_ $ (articleMetadata ^. ArticleMetadataId) ==. (val ((ArticleMetadataKey articleId)))
          pure articleMetadata
        liftIO $ [articleMetaE] `shouldBe` result
    it "allows joining between a primary key that is itself a key of another table, using ToBaseId" $ do
      run $ do
        let number = 101
        insert_ $ Frontcover number ""
        articleE@(Entity articleId _) <- insert' $ Article "title" number
        articleMetaE <- insert' (ArticleMetadata articleId)

        articlesAndMetadata <- select $
          from $ \(article `InnerJoin` articleMetadata) -> do
          on (toBaseId (articleMetadata ^. ArticleMetadataId) ==. article ^. ArticleId)
          return (article, articleMetadata)
        liftIO $ [(articleE, articleMetaE)] `shouldBe` articlesAndMetadata

    it "works with a ForeignKey to a non-id primary key returning both entities" $
      run $ do
        let fc = Frontcover number ""
            article = Article "Esqueleto supports composite pks!" number
            number = 101
            Right thePk = keyFromValues [toPersistValue number]
        fcPk <- insert fc
        insert_ article
        [(Entity _ retFc, Entity _ retArt)] <- select $
          from $ \(a `InnerJoin` f) -> do
            on (f^.FrontcoverNumber ==. a^.ArticleFrontcoverNumber)
            return (f, a)
        liftIO $ do
          retFc `shouldBe` fc
          retArt `shouldBe` article
          fcPk `shouldBe` thePk
          articleFkfrontcover retArt `shouldBe` thePk

    it "works with a non-id primary key returning one entity" $
      run $ do
        let fc = Frontcover number ""
            article = Article2 "Esqueleto supports composite pks!" thePk
            number = 101
            Right thePk = keyFromValues [toPersistValue number]
        fcPk <- insert fc
        insert_ article
        [Entity _ retFc] <- select $
          from $ \(a `InnerJoin` f) -> do
            on (f^.FrontcoverId ==. a^.Article2FrontcoverId)
            return f
        liftIO $ do
          retFc `shouldBe` fc
          fcPk `shouldBe` thePk

    it "works with a composite primary key" $
      pendingWith "Persistent does not create the CircleFkPoint constructor. See: https://github.com/yesodweb/persistent/issues/341"
      {-
      run $ do
        let p = Point x y ""
            c = Circle x y ""
            x = 10
            y = 15
            Right thePk = keyFromValues [toPersistValue x, toPersistValue y]
        pPk <- insert p
        insert_ c
        [Entity _ ret] <- select $ from $ \(c' `InnerJoin` p') -> do
          on (p'^.PointId ==. c'^.CircleFkpoint)
          return p'
        liftIO $ do
          ret `shouldBe` p
          pPk `shouldBe` thePk
     -}

    it "works when joining via a non-id primary key" $
      run $ do
        let fc = Frontcover number ""
            article = Article "Esqueleto supports composite pks!" number
            tag = Tag "foo"
            otherTag = Tag "ignored"
            number = 101
        insert_ fc
        insert_ otherTag
        artId <- insert article
        tagId <- insert tag
        insert_ $ ArticleTag artId tagId
        [(Entity _ retArt, Entity _ retTag)] <- select $
          from $ \(a `InnerJoin` at `InnerJoin` t) -> do
            on (t^.TagId ==. at^.ArticleTagTagId)
            on (a^.ArticleId ==. at^.ArticleTagArticleId)
            return (a, t)
        liftIO $ do
          retArt `shouldBe` article
          retTag `shouldBe` tag

    it "respects the associativity of joins" $
      run $ do
          void $ insert p1
          ps <- select . from $
                    \((p :: SqlExpr (Entity Person))
                     `LeftOuterJoin`
                      ((_q :: SqlExpr (Entity Person))
                       `InnerJoin` (_r :: SqlExpr (Entity Person)))) -> do
              on (val False) -- Inner join is empty
              on (val True)
              return p
          liftIO $ (entityVal <$> ps) `shouldBe` [p1]

testSelectSubQuery :: Run -> Spec
testSelectSubQuery run = describe "select subquery" $ do
    it "works" $ run $ do
        _ <- insert' p1
        let q = do
                p <- Experimental.from $ Table @Person
                return ( p ^. PersonName, p ^. PersonAge)
        ret <- select $ Experimental.from q
        liftIO $ ret `shouldBe` [ (Value $ personName p1, Value $ personAge p1) ]

    it "supports sub-selecting Maybe entities" $ run $ do
        l1e <- insert' l1
        l3e <- insert' l3
        l1Deeds <- mapM (\k -> insert' $ Deed k (entityKey l1e)) (map show [1..3 :: Int])
        let l1WithDeeds = do d <- l1Deeds
                             pure (l1e, Just d)
        ret <- select $ Experimental.from $ do
          (lords :& deeds) <-
              Experimental.from $ Table @Lord
              `LeftOuterJoin` Table @Deed
              `Experimental.on` (\(l :& d) -> just (l ^. LordId) ==. d ?. DeedOwnerId)
          pure (lords, deeds)
        liftIO $ ret `shouldMatchList` ((l3e, Nothing) : l1WithDeeds)

    it "lets you order by alias" $ run $ do
        _ <- insert' p1
        _ <- insert' p3
        let q = do
                (name, age) <-
                  Experimental.from $ SubQuery $ do
                      p <- Experimental.from $ Table @Person
                      return ( p ^. PersonName, p ^. PersonAge)
                orderBy [ asc age ]
                pure name
        ret <- select q
        liftIO $ ret `shouldBe` [ Value $ personName p3, Value $ personName p1 ]

    it "supports groupBy" $ run $ do
        l1k <- insert l1
        l3k <- insert l3
        mapM_ (\k -> insert $ Deed k l1k) (map show [1..3 :: Int])

        mapM_ (\k -> insert $ Deed k l3k) (map show [4..10 :: Int])
        let q = do
                (lord :& deed) <- Experimental.from $ Table @Lord
                                        `InnerJoin` Table @Deed
                                  `Experimental.on` (\(lord :& deed) ->
                                                       lord ^. LordId ==. deed ^. DeedOwnerId)
                return (lord ^. LordId, deed ^. DeedId)
            q' = do
                 (lordId, deedId) <- Experimental.from $ SubQuery q
                 groupBy (lordId)
                 return (lordId, count deedId)
        (ret :: [(Value (Key Lord), Value Int)]) <- select q'

        liftIO $ ret `shouldMatchList` [ (Value l3k, Value 7)
                                       , (Value l1k, Value 3) ]

    it "Can count results of aggregate query" $ run $ do
        l1k <- insert l1
        l3k <- insert l3
        mapM_ (\k -> insert $ Deed k l1k) (map show [1..3 :: Int])

        mapM_ (\k -> insert $ Deed k l3k) (map show [4..10 :: Int])
        let q = do
                (lord :& deed) <- Experimental.from $ Table @Lord
                                        `InnerJoin` Table @Deed
                                  `Experimental.on` (\(lord :& deed) ->
                                                      lord ^. LordId ==. deed ^. DeedOwnerId)
                groupBy (lord ^. LordId)
                return (lord ^. LordId, count (deed ^. DeedId))

        (ret :: [(Value Int)]) <- select $ do
                 (lordId, deedCount) <- Experimental.from $ SubQuery q
                 where_ $ deedCount >. val (3 :: Int)
                 return (count lordId)

        liftIO $ ret `shouldMatchList` [ (Value 1) ]

    it "joins on subqueries" $ run $ do
        l1k <- insert l1
        l3k <- insert l3
        mapM_ (\k -> insert $ Deed k l1k) (map show [1..3 :: Int])

        mapM_ (\k -> insert $ Deed k l3k) (map show [4..10 :: Int])
        let q = do
                (lord :& deed) <- Experimental.from $ Table @Lord
                        `InnerJoin` (Experimental.from $ Table @Deed)
                        `Experimental.on` (\(lord :& deed) ->
                                             lord ^. LordId ==. deed ^. DeedOwnerId)
                groupBy (lord ^. LordId)
                return (lord ^. LordId, count (deed ^. DeedId))
        (ret :: [(Value (Key Lord), Value Int)]) <- select q
        liftIO $ ret `shouldMatchList` [ (Value l3k, Value 7)
                                       , (Value l1k, Value 3) ]

    it "flattens maybe values" $ run $ do
        l1k <- insert l1
        l3k <- insert l3
        let q = do
                (lord :& (_, dogCounts)) <- Experimental.from $ Table @Lord
                        `LeftOuterJoin` do
                            lord <- Experimental.from $ Table @Lord
                            pure (lord ^. LordId, lord ^. LordDogs)
                        `Experimental.on` (\(lord :& (lordId, _)) ->
                                             just (lord ^. LordId) ==. lordId)
                groupBy (lord ^. LordId, dogCounts)
                return (lord ^. LordId, dogCounts)
        (ret :: [(Value (Key Lord), Value (Maybe Int))]) <- select q
        liftIO $ ret `shouldMatchList` [ (Value l3k, Value (lordDogs l3))
                                       , (Value l1k, Value (lordDogs l1)) ]
    it "unions" $ run $ do
          _ <- insert p1
          _ <- insert p2
          let q = Experimental.from $
                  (do
                    p <- Experimental.from $ Table @Person
                    where_ $ not_ $ isNothing $ p ^. PersonAge
                    return (p ^. PersonName))
                  `union_`
                  (do
                    p <- Experimental.from $ Table @Person
                    where_ $ isNothing $ p ^. PersonAge
                    return (p ^. PersonName))
                  `union_`
                  (do
                    p <- Experimental.from $ Table @Person
                    where_ $ isNothing $ p ^. PersonAge
                    return (p ^. PersonName))
          names <- select q
          liftIO $ names `shouldMatchList` [ (Value $ personName p1)
                                           , (Value $ personName p2) ]
testSelectWhere :: Run -> Spec
testSelectWhere run = describe "select where_" $ do
    it "works for a simple example with (==.)" $ run $ do
        p1e <- insert' p1
        _   <- insert' p2
        _   <- insert' p3
        ret <- select $
               from $ \p -> do
               where_ (p ^. PersonName ==. val "John")
               return p
        liftIO $ ret `shouldBe` [ p1e ]

    it "works for a simple example with (==.) and (||.)" $ run $ do
        p1e <- insert' p1
        p2e <- insert' p2
        _   <- insert' p3
        ret <- select $
               from $ \p -> do
               where_ (p ^. PersonName ==. val "John" ||. p ^. PersonName ==. val "Rachel")
               return p
        liftIO $ ret `shouldBe` [ p1e, p2e ]

    it "works for a simple example with (>.) [uses val . Just]" $ run $ do
        p1e <- insert' p1
        _   <- insert' p2
        _   <- insert' p3
        ret <- select $
               from $ \p -> do
               where_ (p ^. PersonAge >. val (Just 17))
               return p
        liftIO $ ret `shouldBe` [ p1e ]

    it "works for a simple example with (>.) and not_ [uses just . val]" $ run $ do
        _   <- insert' p1
        _   <- insert' p2
        p3e <- insert' p3
        ret <- select $
               from $ \p -> do
               where_ (not_ $ p ^. PersonAge >. just (val 17))
               return p
        liftIO $ ret `shouldBe` [ p3e ]

    describe "when using between" $ do
        it "works for a simple example with [uses just . val]" $ run $ do
            p1e  <- insert' p1
            _    <- insert' p2
            _    <- insert' p3
            ret  <- select $
              from $ \p -> do
                where_ ((p ^. PersonAge) `between` (just $ val 20, just $ val 40))
                return p
            liftIO $ ret `shouldBe` [ p1e ]
        it "works for a proyected fields value" $ run $ do
            _ <- insert' p1 >> insert' p2 >> insert' p3
            ret <-
              select $
              from $ \p -> do
              where_ $
                just (p ^. PersonFavNum)
                  `between`
                    (p ^. PersonAge, p ^.  PersonWeight)
            liftIO $ ret `shouldBe` []
        describe "when projecting composite keys" $ do
            it "works when using composite keys with val" $ run $ do
                insert_ $ Point 1 2 ""
                ret <-
                  select $
                  from $ \p -> do
                  where_ $
                    p ^. PointId
                      `between`
                        ( val $ PointKey 1 2
                        , val $ PointKey 5 6 )
                liftIO $ ret `shouldBe` [()]
            it "works when using ECompositeKey constructor" $ run $ do
                insert_ $ Point 1 2 ""
                ret <-
                  select $
                  from $ \p -> do
                  where_ $
                    p ^. PointId
                      `between`
                        ( EI.ECompositeKey $ const ["3", "4"]
                        , EI.ECompositeKey $ const ["5", "6"] )
                liftIO $ ret `shouldBe` []

    it "works with avg_" $ run $ do
        _ <- insert' p1
        _ <- insert' p2
        _ <- insert' p3
        _ <- insert' p4
        ret <- select $
               from $ \p->
               return $ joinV $ avg_ (p ^. PersonAge)
        let testV :: Double
            testV = roundTo (4 :: Integer) $ (36 + 17 + 17) / (3 :: Double)

            retV :: [Value (Maybe Double)]
            retV = map (Value . fmap (roundTo (4 :: Integer)) . unValue) (ret :: [Value (Maybe Double)])
        liftIO $ retV `shouldBe` [ Value $ Just testV ]

    it "works with min_" $
      run $ do
        _ <- insert' p1
        _ <- insert' p2
        _ <- insert' p3
        _ <- insert' p4
        ret <- select $
               from $ \p->
               return $ joinV $ min_ (p ^. PersonAge)
        liftIO $ ret `shouldBe` [ Value $ Just (17 :: Int) ]

    it "works with max_" $ run $ do
        _ <- insert' p1
        _ <- insert' p2
        _ <- insert' p3
        _ <- insert' p4
        ret <- select $
               from $ \p->
               return $ joinV $ max_ (p ^. PersonAge)
        liftIO $ ret `shouldBe` [ Value $ Just (36 :: Int) ]

    it "works with lower_" $ run $ do
        p1e <- insert' p1
        p2e@(Entity _ bob) <- insert' $ Person "bob" (Just 36) Nothing   1

        -- lower(name) == 'john'
        ret1 <- select $
                from $ \p-> do
                where_ (lower_ (p ^. PersonName) ==. val (map toLower $ personName p1))
                return p
        liftIO $ ret1 `shouldBe` [ p1e ]

        -- name == lower('BOB')
        ret2 <- select $
                from $ \p-> do
                where_ (p ^. PersonName ==. lower_ (val $ map toUpper $ personName bob))
                return p
        liftIO $ ret2 `shouldBe` [ p2e ]

    it "works with round_" $ run $ do
        ret <- select $ return $ round_ (val (16.2 :: Double))
        liftIO $ ret `shouldBe` [ Value (16 :: Double) ]

    it "works with isNothing" $ run $ do
        _   <- insert' p1
        p2e <- insert' p2
        _   <- insert' p3
        ret <- select $
               from $ \p -> do
               where_ $ isNothing (p ^. PersonAge)
               return p
        liftIO $ ret `shouldBe` [ p2e ]

    it "works with not_ . isNothing" $ run $ do
        p1e <- insert' p1
        _   <- insert' p2
        ret <- select $
               from $ \p -> do
               where_ $ not_ (isNothing (p ^. PersonAge))
               return p
        liftIO $ ret `shouldBe` [ p1e ]

    it "works for a many-to-many implicit join" $
      run $ do
        p1e@(Entity p1k _) <- insert' p1
        p2e@(Entity p2k _) <- insert' p2
        _                  <- insert' p3
        p4e@(Entity p4k _) <- insert' p4
        f12 <- insert' (Follow p1k p2k)
        f21 <- insert' (Follow p2k p1k)
        f42 <- insert' (Follow p4k p2k)
        f11 <- insert' (Follow p1k p1k)
        ret <- select $
               from $ \(follower, follows, followed) -> do
               where_ $ follower ^. PersonId ==. follows ^. FollowFollower &&.
                        followed ^. PersonId ==. follows ^. FollowFollowed
               orderBy [ asc (follower ^. PersonName)
                       , asc (followed ^. PersonName) ]
               return (follower, follows, followed)
        liftIO $ ret `shouldBe` [ (p1e, f11, p1e)
                                , (p1e, f12, p2e)
                                , (p4e, f42, p2e)
                                , (p2e, f21, p1e) ]

    it "works for a many-to-many explicit join" $ run $ do
        p1e@(Entity p1k _) <- insert' p1
        p2e@(Entity p2k _) <- insert' p2
        _                  <- insert' p3
        p4e@(Entity p4k _) <- insert' p4
        f12 <- insert' (Follow p1k p2k)
        f21 <- insert' (Follow p2k p1k)
        f42 <- insert' (Follow p4k p2k)
        f11 <- insert' (Follow p1k p1k)
        ret <- select $
               from $ \(follower `InnerJoin` follows `InnerJoin` followed) -> do
               on $ followed ^. PersonId ==. follows ^. FollowFollowed
               on $ follower ^. PersonId ==. follows ^. FollowFollower
               orderBy [ asc (follower ^. PersonName)
                       , asc (followed ^. PersonName) ]
               return (follower, follows, followed)
        liftIO $ ret `shouldBe` [ (p1e, f11, p1e)
                                , (p1e, f12, p2e)
                                , (p4e, f42, p2e)
                                , (p2e, f21, p1e) ]

    it "works for a many-to-many explicit join and on order doesn't matter" $ do
      run $ void $
        selectRethrowingQuery $
        from $ \(person `InnerJoin` blog `InnerJoin` comment) -> do
        on $ person ^. PersonId ==. blog ^. BlogPostAuthorId
        on $ blog ^. BlogPostId ==. comment ^. CommentBlog
        pure (person, comment)

      -- we only care that we don't have a SQL error
      True `shouldBe` True

    it "works for a many-to-many explicit join with LEFT OUTER JOINs" $ run $ do
        p1e@(Entity p1k _) <- insert' p1
        p2e@(Entity p2k _) <- insert' p2
        p3e                <- insert' p3
        p4e@(Entity p4k _) <- insert' p4
        f12 <- insert' (Follow p1k p2k)
        f21 <- insert' (Follow p2k p1k)
        f42 <- insert' (Follow p4k p2k)
        f11 <- insert' (Follow p1k p1k)
        ret <- select $
               from $ \(follower `LeftOuterJoin` mfollows `LeftOuterJoin` mfollowed) -> do
               on $      mfollowed ?. PersonId  ==. mfollows ?. FollowFollowed
               on $ just (follower ^. PersonId) ==. mfollows ?. FollowFollower
               orderBy [ asc ( follower ^. PersonName)
                       , asc (mfollowed ?. PersonName) ]
               return (follower, mfollows, mfollowed)
        liftIO $ ret `shouldBe` [ (p1e, Just f11, Just p1e)
                                , (p1e, Just f12, Just p2e)
                                , (p4e, Just f42, Just p2e)
                                , (p3e, Nothing,  Nothing)
                                , (p2e, Just f21, Just p1e) ]

    it "works with a composite primary key" $ run $ do
        let p = Point x y ""
            x = 10
            y = 15
            Right thePk = keyFromValues [toPersistValue x, toPersistValue y]
        pPk <- insert p
        [Entity _ ret] <- select $ from $ \p' -> do
          where_ (p'^.PointId ==. val pPk)
          return p'
        liftIO $ do
          ret `shouldBe` p
          pPk `shouldBe` thePk

testSelectOrderBy :: Run -> Spec
testSelectOrderBy run = describe "select/orderBy" $ do
    it "works with a single ASC field" $ run $ do
        p1e <- insert' p1
        p2e <- insert' p2
        p3e <- insert' p3
        ret <- select $
               from $ \p -> do
               orderBy [asc $ p ^. PersonName]
               return p
        liftIO $ ret `shouldBe` [ p1e, p3e, p2e ]

    it "works with a sub_select" $ run $ do
        [p1k, p2k, p3k, p4k] <- mapM insert [p1, p2, p3, p4]
        [b1k, b2k, b3k, b4k] <- mapM (insert . BlogPost "") [p1k, p2k, p3k, p4k]
        ret <- select $
               from $ \b -> do
               orderBy [desc $ sub_select $
                               from $ \p -> do
                               where_ (p ^. PersonId ==. b ^. BlogPostAuthorId)
                               return (p ^. PersonName)
                       ]
               return (b ^. BlogPostId)
        liftIO $ ret `shouldBe` (Value <$> [b2k, b3k, b4k, b1k])

    it "works on a composite primary key" $ run $ do
        let ps = [Point 2 1 "", Point 1 2 ""]
        mapM_ insert ps
        eps <- select $
          from $ \p' -> do
            orderBy [asc (p'^.PointId)]
            return p'
        liftIO $ map entityVal eps `shouldBe` reverse ps

testAscRandom :: SqlExpr (Value Double) -> Run -> Spec
testAscRandom rand' run = describe "random_" $
    it "asc random_ works" $ run $ do
        _p1e <- insert' p1
        _p2e <- insert' p2
        _p3e <- insert' p3
        _p4e <- insert' p4
        rets <-
          fmap S.fromList $
          replicateM 11 $
          select $
          from $ \p -> do
          orderBy [asc (rand' :: SqlExpr (Value Double))]
          return (p ^. PersonId :: SqlExpr (Value PersonId))
        -- There are 2^4 = 16 possible orderings.  The chance
        -- of 11 random samplings returning the same ordering
        -- is 1/2^40, so this test should pass almost everytime.
        liftIO $ S.size rets `shouldSatisfy` (>2)

testSelectDistinct :: Run -> Spec
testSelectDistinct run = do
  describe "SELECT DISTINCT" $ do
    let selDistTest
          :: (   forall m. RunDbMonad m
              => SqlQuery (SqlExpr (Value String))
              -> SqlPersistT (R.ResourceT m) [Value String])
          -> IO ()
        selDistTest q = run $ do
          p1k <- insert p1
          let (t1, t2, t3) = ("a", "b", "c")
          mapM_ (insert . flip BlogPost p1k) [t1, t3, t2, t2, t1]
          ret <- q $
                 from $ \b -> do
                 let title = b ^. BlogPostTitle
                 orderBy [asc title]
                 return title
          liftIO $ ret `shouldBe` [ Value t1, Value t2, Value t3 ]

    it "works on a simple example (select . distinct)" $
      selDistTest (select . distinct)

    it "works on a simple example (distinct (return ()))" $
      selDistTest (\act -> select $ distinct (return ()) >> act)



testCoasleceDefault :: Run -> Spec
testCoasleceDefault run = describe "coalesce/coalesceDefault" $ do
    it "works on a simple example" $ run $ do
        mapM_ insert' [p1, p2, p3, p4, p5]
        ret1 <- select $
                from $ \p -> do
                orderBy [asc (p ^. PersonId)]
                return (coalesce [p ^. PersonAge, p ^. PersonWeight])
        liftIO $ ret1 `shouldBe` [ Value (Just (36 :: Int))
                                 , Value (Just 37)
                                 , Value (Just 17)
                                 , Value (Just 17)
                                 , Value Nothing
                                 ]

        ret2 <- select $
                from $ \p -> do
                orderBy [asc (p ^. PersonId)]
                return (coalesceDefault [p ^. PersonAge, p ^. PersonWeight] (p ^. PersonFavNum))
        liftIO $ ret2 `shouldBe` [ Value (36 :: Int)
                                 , Value 37
                                 , Value 17
                                 , Value 17
                                 , Value 5
                                 ]

    it "works with sub-queries" $ run $ do
        p1id <- insert p1
        p2id <- insert p2
        p3id <- insert p3
        _    <- insert p4
        _    <- insert p5
        _ <- insert $ BlogPost "a" p1id
        _ <- insert $ BlogPost "b" p2id
        _ <- insert $ BlogPost "c" p3id
        ret <- select $
               from $ \b -> do
                 let sub =
                         from $ \p -> do
                         where_ (p ^. PersonId ==. b ^. BlogPostAuthorId)
                         return $ p ^. PersonAge
                 return $ coalesceDefault [sub_select sub] (val (42 :: Int))
        liftIO $ ret `shouldBe` [ Value (36 :: Int)
                                , Value 42
                                , Value 17
                                ]


testDelete :: Run -> Spec
testDelete run = describe "delete" $ do
    it "works on a simple example" $ run $ do
        p1e <- insert' p1
        p2e <- insert' p2
        p3e <- insert' p3
        let getAll = select $
                     from $ \p -> do
                     orderBy [asc (p ^. PersonName)]
                     return p
        ret1 <- getAll
        liftIO $ ret1 `shouldBe` [ p1e, p3e, p2e ]
        ()   <- delete $
                from $ \p ->
                where_ (p ^. PersonName ==. val (personName p1))
        ret2 <- getAll
        liftIO $ ret2 `shouldBe` [ p3e, p2e ]
        n    <- deleteCount $
                from $ \p ->
                return ((p :: SqlExpr (Entity Person)) `seq` ())
        ret3 <- getAll
        liftIO $ (n, ret3) `shouldBe` (2, [])

testUpdate :: Run -> Spec
testUpdate run = describe "update" $ do
    it "works with a subexpression having COUNT(*)" $ run $ do
        p1k <- insert p1
        p2k <- insert p2
        p3k <- insert p3
        replicateM_ 3 (insert $ BlogPost "" p1k)
        replicateM_ 7 (insert $ BlogPost "" p3k)
        let blogPostsBy p =
              from $ \b -> do
              where_ (b ^. BlogPostAuthorId ==. p ^. PersonId)
              return countRows
        ()  <- update $ \p -> do
               set p [ PersonAge =. just (sub_select (blogPostsBy p)) ]
        ret <- select $
               from $ \p -> do
               orderBy [ asc (p ^. PersonName) ]
               return p
        liftIO $ ret `shouldBe` [ Entity p1k p1 { personAge = Just 3 }
                                , Entity p3k p3 { personAge = Just 7 }
                                , Entity p2k p2 { personAge = Just 0 } ]

    it "works with a composite primary key" $
        pendingWith "Need refactor to support composite pks on ESet"
      {-
      run $ do
        let p = Point x y ""
            x = 10
            y = 15
            newX = 20
            newY = 25
            Right newPk = keyFromValues [toPersistValue newX, toPersistValue newY]
        insert_ p
        () <- update $ \p' -> do
              set p' [PointId =. val newPk]
        [Entity _ ret] <- select $ from $ return
        liftIO $ do
          ret `shouldBe` Point newX newY []
      -}

    it "GROUP BY works with COUNT" $ run $ do
        p1k <- insert p1
        p2k <- insert p2
        p3k <- insert p3
        replicateM_ 3 (insert $ BlogPost "" p1k)
        replicateM_ 7 (insert $ BlogPost "" p3k)
        ret <- select $
               from $ \(p `LeftOuterJoin` b) -> do
               on (p ^. PersonId ==. b ^. BlogPostAuthorId)
               groupBy (p ^. PersonId)
               let cnt = count (b ^. BlogPostId)
               orderBy [ asc cnt ]
               return (p, cnt)
        liftIO $ ret `shouldBe` [ (Entity p2k p2, Value (0 :: Int))
                                , (Entity p1k p1, Value 3)
                                , (Entity p3k p3, Value 7) ]

    it "GROUP BY works with COUNT and InnerJoin" $ run $ do
        l1k <- insert l1
        l3k <- insert l3
        mapM_ (\k -> insert $ Deed k l1k) (map show [1..3 :: Int])

        mapM_ (\k -> insert $ Deed k l3k) (map show [4..10 :: Int])

        (ret :: [(Value (Key Lord), Value Int)]) <- select $ from $
          \ ( lord `InnerJoin` deed ) -> do
          on $ lord ^. LordId ==. deed ^. DeedOwnerId
          groupBy (lord ^. LordId)
          return (lord ^. LordId, count $ deed ^. DeedId)
        liftIO $ ret `shouldMatchList` [ (Value l3k, Value 7)
                                       , (Value l1k, Value 3) ]

    it "GROUP BY works with nested tuples" $ run $ do
        l1k <- insert l1
        l3k <- insert l3
        mapM_ (\k -> insert $ Deed k l1k) (map show [1..3 :: Int])

        mapM_ (\k -> insert $ Deed k l3k) (map show [4..10 :: Int])

        (ret :: [(Value (Key Lord), Value Int)]) <- select $ from $
          \ ( lord `InnerJoin` deed ) -> do
          on $ lord ^. LordId ==. deed ^. DeedOwnerId
          groupBy ((lord ^. LordId, lord ^. LordDogs), deed ^. DeedContract)
          return (lord ^. LordId, count $ deed ^. DeedId)
        liftIO $ length ret `shouldBe` 10

    it "GROUP BY works with HAVING" $ run $ do
        p1k <- insert p1
        _p2k <- insert p2
        p3k <- insert p3
        replicateM_ 3 (insert $ BlogPost "" p1k)
        replicateM_ 7 (insert $ BlogPost "" p3k)
        ret <- select $
               from $ \(p `LeftOuterJoin` b) -> do
               on (p ^. PersonId ==. b ^. BlogPostAuthorId)
               let cnt = count (b ^. BlogPostId)
               groupBy (p ^. PersonId)
               having (cnt >. (val 0))
               orderBy [ asc cnt ]
               return (p, cnt)
        liftIO $ ret `shouldBe` [ (Entity p1k p1, Value (3 :: Int))
                                , (Entity p3k p3, Value 7) ]

-- we only care that this compiles. check that SqlWriteT doesn't fail on
-- updates.
testSqlWriteT :: MonadIO m => SqlWriteT m ()
testSqlWriteT =
  update $ \p -> do
    set p [ PersonAge =. just (val 6) ]

-- we only care that this compiles. checks that the SqlWriteT monad can run
-- select queries.
testSqlWriteTRead :: MonadIO m => SqlWriteT m [(Value (Key Lord), Value Int)]
testSqlWriteTRead =
  select $
  from $ \ ( lord `InnerJoin` deed ) -> do
  on $ lord ^. LordId ==. deed ^. DeedOwnerId
  groupBy (lord ^. LordId)
  return (lord ^. LordId, count $ deed ^. DeedId)

-- we only care that this compiles checks that SqlReadT allows
testSqlReadT :: MonadIO m => SqlReadT m [(Value (Key Lord), Value Int)]
testSqlReadT =
  select $
  from $ \ ( lord `InnerJoin` deed ) -> do
  on $ lord ^. LordId ==. deed ^. DeedOwnerId
  groupBy (lord ^. LordId)
  return (lord ^. LordId, count $ deed ^. DeedId)

testListOfValues :: Run -> Spec
testListOfValues run = describe "lists of values" $ do
    it "IN works for valList" $ run $ do
        p1k <- insert p1
        p2k <- insert p2
        _p3k <- insert p3
        ret <- select $
               from $ \p -> do
               where_ (p ^. PersonName `in_` valList (personName <$> [p1, p2]))
               return p
        liftIO $ ret `shouldBe` [ Entity p1k p1
                                , Entity p2k p2 ]

    it "IN works for valList (null list)" $ run $ do
        _p1k <- insert p1
        _p2k <- insert p2
        _p3k <- insert p3
        ret <- select $
               from $ \p -> do
               where_ (p ^. PersonName `in_` valList [])
               return p
        liftIO $ ret `shouldBe` []

    it "IN works for subList_select" $ run $ do
        p1k <- insert p1
        _p2k <- insert p2
        p3k <- insert p3
        _ <- insert (BlogPost "" p1k)
        _ <- insert (BlogPost "" p3k)
        ret <- select $
               from $ \p -> do
               let subquery =
                     from $ \bp -> do
                     orderBy [ asc (bp ^. BlogPostAuthorId) ]
                     return (bp ^. BlogPostAuthorId)
               where_ (p ^. PersonId `in_` subList_select subquery)
               return p
        liftIO $ L.sort ret `shouldBe` L.sort [Entity p1k p1, Entity p3k p3]

    it "NOT IN works for subList_select" $ run $ do
        p1k <- insert p1
        p2k <- insert p2
        p3k <- insert p3
        _ <- insert (BlogPost "" p1k)
        _ <- insert (BlogPost "" p3k)
        ret <- select $
               from $ \p -> do
               let subquery =
                     from $ \bp ->
                     return (bp ^. BlogPostAuthorId)
               where_ (p ^. PersonId `notIn` subList_select subquery)
               return p
        liftIO $ ret `shouldBe` [ Entity p2k p2 ]

    it "EXISTS works for subList_select" $ run $ do
        p1k <- insert p1
        _p2k <- insert p2
        p3k <- insert p3
        _ <- insert (BlogPost "" p1k)
        _ <- insert (BlogPost "" p3k)
        ret <- select $
               from $ \p -> do
               where_ $ exists $
                        from $ \bp -> do
                        where_ (bp ^. BlogPostAuthorId ==. p ^. PersonId)
               orderBy [asc (p ^. PersonName)]
               return p
        liftIO $ ret `shouldBe` [ Entity p1k p1
                                , Entity p3k p3 ]

    it "EXISTS works for subList_select" $ run $ do
        p1k <- insert p1
        p2k <- insert p2
        p3k <- insert p3
        _ <- insert (BlogPost "" p1k)
        _ <- insert (BlogPost "" p3k)
        ret <- select $
               from $ \p -> do
               where_ $ notExists $
                        from $ \bp -> do
                        where_ (bp ^. BlogPostAuthorId ==. p ^. PersonId)
               return p
        liftIO $ ret `shouldBe` [ Entity p2k p2 ]

testListFields :: Run -> Spec
testListFields run = describe "list fields" $ do
    -- <https://github.com/prowdsponsor/esqueleto/issues/100>
    it "can update list fields" $ run $ do
        cclist <- insert $ CcList []
        update $ \p -> do
            set p [ CcListNames =. val ["fred"]]
            where_ (p ^. CcListId ==. val cclist)

testInsertsBySelect :: Run -> Spec
testInsertsBySelect run = do
  describe "inserts by select" $ do
    it "IN works for insertSelect" $
      run $ do
        _ <- insert p1
        _ <- insert p2
        _ <- insert p3
        insertSelect $ from $ \p -> do
          return $ BlogPost <# val "FakePost" <&> (p ^. PersonId)
        ret <- select $ from (\(_::(SqlExpr (Entity BlogPost))) -> return countRows)
        liftIO $ ret `shouldBe` [Value (3::Int)]





testInsertsBySelectReturnsCount :: Run -> Spec
testInsertsBySelectReturnsCount run = do
  describe "inserts by select, returns count" $ do
    it "IN works for insertSelectCount" $
      run $ do
        _ <- insert p1
        _ <- insert p2
        _ <- insert p3
        cnt <- insertSelectCount $ from $ \p -> do
          return $ BlogPost <# val "FakePost" <&> (p ^. PersonId)
        ret <- select $ from (\(_::(SqlExpr (Entity BlogPost))) -> return countRows)
        liftIO $ ret `shouldBe` [Value (3::Int)]
        liftIO $ cnt `shouldBe` 3




testRandomMath :: Run -> Spec
testRandomMath run = describe "random_ math" $
    it "rand returns result in random order" $
      run $ do
        replicateM_ 20 $ do
          _ <- insert p1
          _ <- insert p2
          _ <- insert p3
          _ <- insert p4
          _ <- insert $ Person "Jane"  Nothing Nothing 0
          _ <- insert $ Person "Mark"  Nothing Nothing 0
          _ <- insert $ Person "Sarah" Nothing Nothing 0
          insert $ Person "Paul"  Nothing Nothing 0
        ret1 <- fmap (map unValue) $ select $ from $ \p -> do
                  orderBy [rand]
                  return (p ^. PersonId)
        ret2 <- fmap (map unValue) $ select $ from $ \p -> do
                  orderBy [rand]
                  return (p ^. PersonId)

        liftIO $ (ret1 == ret2) `shouldBe` False

testMathFunctions :: Run -> Spec
testMathFunctions run = do
  describe "Math-related functions" $ do
    it "castNum works for multiplying Int and Double" $
      run $ do
        mapM_ insert [Numbers 2 3.4, Numbers 7 1.1]
        ret <-
          select $
          from $ \n -> do
          let r = castNum (n ^. NumbersInt) *. n ^. NumbersDouble
          orderBy [asc r]
          return r
        liftIO $ length ret `shouldBe` 2
        let [Value a, Value b] = ret
        liftIO $ max (abs (a - 6.8)) (abs (b - 7.7)) `shouldSatisfy` (< 0.01)





testCase :: Run -> Spec
testCase run = do
  describe "case" $ do
    it "Works for a simple value based when - False" $
      run $ do
        ret <- select $
          return $
            case_
              [ when_ (val False) then_ (val (1 :: Int)) ]
              (else_ (val 2))

        liftIO $ ret `shouldBe` [ Value 2 ]

    it "Works for a simple value based when - True" $
      run $ do
        ret <- select $
          return $
            case_
              [ when_ (val True) then_ (val (1 :: Int)) ]
              (else_ (val 2))

        liftIO $ ret `shouldBe` [ Value 1 ]

    it "works for a semi-complicated query" $
      run $ do
        _ <- insert p1
        _ <- insert p2
        _ <- insert p3
        _ <- insert p4
        _ <- insert p5
        ret <- select $
          return $
            case_
              [ when_
                  (exists $ from $ \p -> do
                      where_ (p ^. PersonName ==. val "Mike"))
                then_
                  (sub_select $ from $ \v -> do
                      let sub =
                              from $ \c -> do
                              where_ (c ^. PersonName ==. val "Mike")
                              return (c ^. PersonFavNum)
                      where_ (v ^. PersonFavNum >. sub_select sub)
                      return $ count (v ^. PersonName) +. val (1 :: Int)) ]
              (else_ $ val (-1))

        liftIO $ ret `shouldBe` [ Value (3) ]





testLocking :: WithConn (NoLoggingT IO) [TL.Text] -> Spec
testLocking withConn = do
  describe "locking" $ do
    -- The locking clause is the last one, so try to use many
    -- others to test if it's at the right position.  We don't
    -- care about the text of the rest, nor with the RDBMS'
    -- reaction to the clause.
    let sanityCheck kind syntax = do
          let complexQuery =
                from $ \(p1' `InnerJoin` p2') -> do
                on (p1' ^. PersonName ==. p2' ^. PersonName)
                where_ (p1' ^. PersonFavNum >. val 2)
                orderBy [desc (p2' ^. PersonAge)]
                limit 3
                offset 9
                groupBy (p1' ^. PersonId)
                having (countRows <. val (0 :: Int))
                return (p1', p2')
              queryWithClause1 = do
                r <- complexQuery
                locking kind
                return r
              queryWithClause2 = do
                locking ForUpdate
                r <- complexQuery
                locking ForShare
                locking kind
                return r
              queryWithClause3 = do
                locking kind
                complexQuery
              toText conn q =
                let (tlb, _) = EI.toRawSql EI.SELECT (conn, EI.initialIdentState) q
                in TLB.toLazyText tlb
          [complex, with1, with2, with3] <-
            runNoLoggingT $ withConn $ \conn -> return $
              map (toText conn) [complexQuery, queryWithClause1, queryWithClause2, queryWithClause3]
          let expected = complex <> "\n" <> syntax
          (with1, with2, with3) `shouldBe` (expected, expected, expected)

    it "looks sane for ForUpdate"           $ sanityCheck ForUpdate           "FOR UPDATE"
    it "looks sane for ForUpdateSkipLocked" $ sanityCheck ForUpdateSkipLocked "FOR UPDATE SKIP LOCKED"
    it "looks sane for ForShare"            $ sanityCheck ForShare            "FOR SHARE"
    it "looks sane for LockInShareMode"     $ sanityCheck LockInShareMode     "LOCK IN SHARE MODE"





testCountingRows :: Run -> Spec
testCountingRows run = do
  describe "counting rows" $ do
    forM_ [ ("count (test A)",    count . (^. PersonAge),         4)
          , ("count (test B)",    count . (^. PersonWeight),      5)
          , ("countRows",         const countRows,                5)
          , ("countDistinct",     countDistinct . (^. PersonAge), 2) ] $
      \(title, countKind, expected) ->
      it (title ++ " works as expected") $
        run $ do
          mapM_ insert
            [ Person "" (Just 1) (Just 1) 1
            , Person "" (Just 2) (Just 1) 1
            , Person "" (Just 2) (Just 1) 1
            , Person "" (Just 2) (Just 2) 1
            , Person "" Nothing  (Just 3) 1]
          [Value n] <- select $ from $ return . countKind
          liftIO $ (n :: Int) `shouldBe` expected

testRenderSql :: Run -> Spec
testRenderSql run = do
  describe "testRenderSql" $ do
    it "works" $ do
      (queryText, queryVals) <- run $ renderQuerySelect $
        from $ \p -> do
        where_ $ p ^. PersonName ==. val "Johhny Depp"
        pure (p ^. PersonName, p ^. PersonAge)
      -- the different backends use different quote marks, so I filter them out
      -- here instead of making a duplicate test
      Text.filter (\c -> c `notElem` ['`', '"']) queryText
        `shouldBe`
          Text.unlines
            [ "SELECT Person.name, Person.age"
            , "FROM Person"
            , "WHERE Person.name = ?"
            ]
      queryVals
        `shouldBe`
          [toPersistValue ("Johhny Depp" :: TL.Text)]

  describe "renderExpr" $ do
    it "renders a value" $ do
      (c, expr) <- run $ do
        conn <- ask
        let Right c = P.mkEscapeChar conn
        pure $ (,) c $ EI.renderExpr conn $
          EI.EEntity (EI.I "user") ^. PersonId
          ==. EI.EEntity (EI.I "blog_post") ^. BlogPostAuthorId
      expr
        `shouldBe`
          Text.intercalate (Text.singleton c) ["", "user", ".", "id", ""]
          <>
          " = "
          <>
          Text.intercalate (Text.singleton c) ["", "blog_post", ".", "authorId", ""]
    it "renders ? for a val" $ do
      expr <- run $ ask >>= \c -> pure $ EI.renderExpr c (val (PersonKey 0) ==. val (PersonKey 1))
      expr `shouldBe` "? = ?"

  describe "EEntity Ident behavior" $ do
      let render :: SqlExpr (Entity val) -> Text.Text
          render (EI.EEntity (EI.I ident)) = ident
          render _ = error "guess we gotta handle this in the test suite now"
      it "renders sensibly" $ run $ do
          _ <- insert $ Foo 2
          _ <- insert $ Foo 3
          _ <- insert $ Person "hello" Nothing Nothing 3
          results <- select $
              from $ \(a `LeftOuterJoin` b) -> do
              on $ a ^. FooName ==. b ^. PersonFavNum
              pure (val (render a), val (render b))
          liftIO $
              head results
              `shouldBe`
              (Value "Foo", Value "Person")

  describe "ExprParser" $ do
    let parse parser = AP.parseOnly (parser '#')
    describe "parseEscapedChars" $ do
      let subject = parse P.parseEscapedChars
      it "parses words" $ do
        subject "hello world"
          `shouldBe`
            Right "hello world"
      it "only returns a single escape-char if present" $ do
        subject "i_am##identifier##"
          `shouldBe`
            Right "i_am#identifier#"
    describe "parseEscapedIdentifier" $ do
      let subject = parse P.parseEscapedIdentifier
      it "parses the quotes out" $ do
        subject "#it's a me, mario#"
          `shouldBe`
            Right "it's a me, mario"
      it "requires a beginning and end quote" $ do
        subject "#alas, i have no end"
          `shouldSatisfy`
            isLeft
    describe "parseTableAccess" $ do
      let subject = parse P.parseTableAccess
      it "parses a table access" $ do
        subject "#foo#.#bar#"
          `shouldBe`
            Right P.TableAccess
              { P.tableAccessTable = "foo"
              , P.tableAccessColumn = "bar"
              }
    describe "onExpr" $ do
      let subject = parse P.onExpr
      it "works" $ do
        subject "#foo#.#bar# = #bar#.#baz#"
          `shouldBe` do
            Right $ S.fromList
              [ P.TableAccess
                { P.tableAccessTable = "foo"
                , P.tableAccessColumn = "bar"
                }
              , P.TableAccess
                { P.tableAccessTable = "bar"
                , P.tableAccessColumn = "baz"
                }
              ]
      it "also works with other nonsense" $ do
        subject "#foo#.#bar# = 3"
          `shouldBe` do
            Right $ S.fromList
              [ P.TableAccess
                { P.tableAccessTable = "foo"
                , P.tableAccessColumn = "bar"
                }
              ]
      it "handles a conjunction" $ do
        subject "#foo#.#bar# = #bar#.#baz# AND #bar#.#baz# > 10"
          `shouldBe` do
            Right $ S.fromList
              [ P.TableAccess
                { P.tableAccessTable = "foo"
                , P.tableAccessColumn = "bar"
                }
              , P.TableAccess
                { P.tableAccessTable = "bar"
                , P.tableAccessColumn = "baz"
                }
              ]
      it "handles ? okay" $ do
        subject "#foo#.#bar# = ?"
          `shouldBe` do
            Right $ S.fromList
              [ P.TableAccess
                { P.tableAccessTable = "foo"
                , P.tableAccessColumn = "bar"
                }
              ]
      it "handles degenerate cases" $ do
        subject "false" `shouldBe` pure mempty
        subject "true" `shouldBe` pure mempty
        subject "1 = 1" `shouldBe` pure mempty
      it "works even if an identifier isn't first" $ do
        subject "true and #foo#.#bar# = 2"
          `shouldBe` do
            Right $ S.fromList
              [ P.TableAccess
                { P.tableAccessTable = "foo"
                , P.tableAccessColumn = "bar"
                }
              ]

testOnClauseOrder :: Run -> Spec
testOnClauseOrder run = describe "On Clause Ordering" $ do
  let
    setup :: MonadIO m => SqlPersistT m ()
    setup = do
      ja1 <- insert (JoinOne "j1 hello")
      ja2 <- insert (JoinOne "j1 world")
      jb1 <- insert (JoinTwo ja1 "j2 hello")
      jb2 <- insert (JoinTwo ja1 "j2 world")
      jb3 <- insert (JoinTwo ja2 "j2 foo")
      _ <- insert (JoinTwo ja2 "j2 bar")
      jc1 <- insert (JoinThree jb1 "j3 hello")
      jc2 <- insert (JoinThree jb1 "j3 world")
      _ <- insert (JoinThree jb2 "j3 foo")
      _ <- insert (JoinThree jb3 "j3 bar")
      _ <- insert (JoinThree jb3 "j3 baz")
      _ <- insert (JoinFour "j4 foo" jc1)
      _ <- insert (JoinFour "j4 bar" jc2)
      jd1 <- insert (JoinOther "foo")
      jd2 <- insert (JoinOther "bar")
      _ <- insert (JoinMany "jm foo hello" jd1 ja1)
      _ <- insert (JoinMany "jm foo world" jd1 ja2)
      _ <- insert (JoinMany "jm bar hello" jd2 ja1)
      _ <- insert (JoinMany "jm bar world" jd2 ja2)
      pure ()
  describe "identical results for" $ do
    it "three tables" $ do
      abcs <- run $ do
        setup
        select $
          from $ \(a `InnerJoin` b `InnerJoin` c) -> do
          on (a ^. JoinOneId ==. b ^. JoinTwoJoinOne)
          on (b ^. JoinTwoId ==. c ^. JoinThreeJoinTwo)
          pure (a, b, c)
      acbs <- run $ do
        setup
        select $
          from $ \(a `InnerJoin` b `InnerJoin` c) -> do
          on (b ^. JoinTwoId ==. c ^. JoinThreeJoinTwo)
          on (a ^. JoinOneId ==. b ^. JoinTwoJoinOne)
          pure (a, b, c)

      listsEqualOn abcs acbs $ \(Entity _ j1, Entity _ j2, Entity _ j3) ->
        (joinOneName j1, joinTwoName j2, joinThreeName j3)

    it "four tables" $ do
      xs0 <- run $ do
        setup
        select $
          from $ \(a `InnerJoin` b `InnerJoin` c `InnerJoin` d) -> do
          on (a ^. JoinOneId ==. b ^. JoinTwoJoinOne)
          on (b ^. JoinTwoId ==. c ^. JoinThreeJoinTwo)
          on (c ^. JoinThreeId ==. d ^. JoinFourJoinThree)
          pure (a, b, c, d)
      xs1 <- run $ do
        setup
        select $
          from $ \(a `InnerJoin` b `InnerJoin` c `InnerJoin` d) -> do
          on (a ^. JoinOneId ==. b ^. JoinTwoJoinOne)
          on (c ^. JoinThreeId ==. d ^. JoinFourJoinThree)
          on (b ^. JoinTwoId ==. c ^. JoinThreeJoinTwo)
          pure (a, b, c, d)
      xs2 <- run $ do
        setup
        select $
          from $ \(a `InnerJoin` b `InnerJoin` c `InnerJoin` d) -> do
          on (b ^. JoinTwoId ==. c ^. JoinThreeJoinTwo)
          on (c ^. JoinThreeId ==. d ^. JoinFourJoinThree)
          on (a ^. JoinOneId ==. b ^. JoinTwoJoinOne)
          pure (a, b, c, d)
      xs3 <- run $ do
        setup
        select $
          from $ \(a `InnerJoin` b `InnerJoin` c `InnerJoin` d) -> do
          on (c ^. JoinThreeId ==. d ^. JoinFourJoinThree)
          on (a ^. JoinOneId ==. b ^. JoinTwoJoinOne)
          on (b ^. JoinTwoId ==. c ^. JoinThreeJoinTwo)
          pure (a, b, c, d)
      xs4 <- run $ do
        setup
        select $
          from $ \(a `InnerJoin` b `InnerJoin` c `InnerJoin` d) -> do
          on (c ^. JoinThreeId ==. d ^. JoinFourJoinThree)
          on (b ^. JoinTwoId ==. c ^. JoinThreeJoinTwo)
          on (a ^. JoinOneId ==. b ^. JoinTwoJoinOne)
          pure (a, b, c, d)

      let getNames (j1, j2, j3, j4) =
            ( joinOneName (entityVal j1)
            , joinTwoName (entityVal j2)
            , joinThreeName (entityVal j3)
            , joinFourName (entityVal j4)
            )
      listsEqualOn xs0 xs1 getNames
      listsEqualOn xs0 xs2 getNames
      listsEqualOn xs0 xs3 getNames
      listsEqualOn xs0 xs4 getNames

    it "associativity of innerjoin" $ do
      xs0 <- run $ do
        setup
        select $
          from $ \(a `InnerJoin` b `InnerJoin` c `InnerJoin` d) -> do
          on (a ^. JoinOneId ==. b ^. JoinTwoJoinOne)
          on (b ^. JoinTwoId ==. c ^. JoinThreeJoinTwo)
          on (c ^. JoinThreeId ==. d ^. JoinFourJoinThree)
          pure (a, b, c, d)

      xs1 <- run $ do
        setup
        select $
          from $ \(a `InnerJoin` b `InnerJoin` (c `InnerJoin` d)) -> do
          on (a ^. JoinOneId ==. b ^. JoinTwoJoinOne)
          on (b ^. JoinTwoId ==. c ^. JoinThreeJoinTwo)
          on (c ^. JoinThreeId ==. d ^. JoinFourJoinThree)
          pure (a, b, c, d)

      xs2 <- run $ do
        setup
        select $
          from $ \(a `InnerJoin` (b `InnerJoin` c) `InnerJoin` d) -> do
          on (a ^. JoinOneId ==. b ^. JoinTwoJoinOne)
          on (b ^. JoinTwoId ==. c ^. JoinThreeJoinTwo)
          on (c ^. JoinThreeId ==. d ^. JoinFourJoinThree)
          pure (a, b, c, d)

      xs3 <- run $ do
        setup
        select $
          from $ \(a `InnerJoin` (b `InnerJoin` c `InnerJoin` d)) -> do
          on (a ^. JoinOneId ==. b ^. JoinTwoJoinOne)
          on (b ^. JoinTwoId ==. c ^. JoinThreeJoinTwo)
          on (c ^. JoinThreeId ==. d ^. JoinFourJoinThree)
          pure (a, b, c, d)

      let getNames (j1, j2, j3, j4) =
            ( joinOneName (entityVal j1)
            , joinTwoName (entityVal j2)
            , joinThreeName (entityVal j3)
            , joinFourName (entityVal j4)
            )
      listsEqualOn xs0 xs1 getNames
      listsEqualOn xs0 xs2 getNames
      listsEqualOn xs0 xs3 getNames

    it "inner join on two entities" $ do
      (xs0, xs1) <- run $ do
        pid <- insert $ Person "hello" Nothing Nothing 3
        _ <- insert $ BlogPost "good poast" pid
        _ <- insert $ Profile "cool" pid
        xs0 <- selectRethrowingQuery $
          from $ \(p `InnerJoin` b `InnerJoin` pr) -> do
          on $ p ^. PersonId ==. b ^. BlogPostAuthorId
          on $ p ^. PersonId ==. pr ^. ProfilePerson
          pure (p, b, pr)
        xs1 <- selectRethrowingQuery $
          from $ \(p `InnerJoin` b `InnerJoin` pr) -> do
          on $ p ^. PersonId ==. pr ^. ProfilePerson
          on $ p ^. PersonId ==. b ^. BlogPostAuthorId
          pure (p, b, pr)
        pure (xs0, xs1)
      listsEqualOn xs0 xs1 $ \(Entity _ p, Entity _ b, Entity _ pr) ->
        (personName p, blogPostTitle b, profileName pr)
    it "inner join on three entities" $ do
      res <- run $ do
        pid <- insert $ Person "hello" Nothing Nothing 3
        _ <- insert $ BlogPost "good poast" pid
        _ <- insert $ BlogPost "good poast #2" pid
        _ <- insert $ Profile "cool" pid
        _ <- insert $ Reply pid "u wot m8"
        _ <- insert $ Reply pid "how dare you"

        bprr <- selectRethrowingQuery $
          from $ \(p `InnerJoin` b `InnerJoin` pr `InnerJoin` r) -> do
          on $ p ^. PersonId ==. b ^. BlogPostAuthorId
          on $ p ^. PersonId ==. pr ^. ProfilePerson
          on $ p ^. PersonId ==. r ^. ReplyGuy
          pure (p, b, pr, r)

        brpr <- selectRethrowingQuery $
          from $ \(p `InnerJoin` b `InnerJoin` pr `InnerJoin` r) -> do
          on $ p ^. PersonId ==. b ^. BlogPostAuthorId
          on $ p ^. PersonId ==. r ^. ReplyGuy
          on $ p ^. PersonId ==. pr ^. ProfilePerson
          pure (p, b, pr, r)

        prbr <- selectRethrowingQuery $
          from $ \(p `InnerJoin` b `InnerJoin` pr `InnerJoin` r) -> do
          on $ p ^. PersonId ==. pr ^. ProfilePerson
          on $ p ^. PersonId ==. b ^. BlogPostAuthorId
          on $ p ^. PersonId ==. r ^. ReplyGuy
          pure (p, b, pr, r)

        prrb <- selectRethrowingQuery $
          from $ \(p `InnerJoin` b `InnerJoin` pr `InnerJoin` r) -> do
          on $ p ^. PersonId ==. pr ^. ProfilePerson
          on $ p ^. PersonId ==. r ^. ReplyGuy
          on $ p ^. PersonId ==. b ^. BlogPostAuthorId
          pure (p, b, pr, r)

        rprb <- selectRethrowingQuery $
          from $ \(p `InnerJoin` b `InnerJoin` pr `InnerJoin` r) -> do
          on $ p ^. PersonId ==. r ^. ReplyGuy
          on $ p ^. PersonId ==. pr ^. ProfilePerson
          on $ p ^. PersonId ==. b ^. BlogPostAuthorId
          pure (p, b, pr, r)

        rbpr <- selectRethrowingQuery $
          from $ \(p `InnerJoin` b `InnerJoin` pr `InnerJoin` r) -> do
          on $ p ^. PersonId ==. r ^. ReplyGuy
          on $ p ^. PersonId ==. b ^. BlogPostAuthorId
          on $ p ^. PersonId ==. pr ^. ProfilePerson
          pure (p, b, pr, r)

        pure [bprr, brpr, prbr, prrb, rprb, rbpr]
      forM_ (zip res (drop 1 (cycle res))) $ \(a, b) -> a `shouldBe` b

    it "many-to-many" $ do
      ac <- run $ do
        setup
        select $
          from $ \(a `InnerJoin` b `InnerJoin` c) -> do
          on (a ^. JoinOneId ==. b ^. JoinManyJoinOne)
          on (c ^. JoinOtherId ==. b ^. JoinManyJoinOther)
          pure (a, c)

      ca <- run $ do
        setup
        select $
          from $ \(a `InnerJoin` b `InnerJoin` c) -> do
          on (c ^. JoinOtherId ==. b ^. JoinManyJoinOther)
          on (a ^. JoinOneId ==. b ^. JoinManyJoinOne)
          pure (a, c)

      listsEqualOn ac ca $ \(Entity _ a, Entity _ b) ->
        (joinOneName a, joinOtherName b)

    it "left joins on order" $ do
      ca <- run $ do
        setup
        select $
          from $ \(a `LeftOuterJoin` b `InnerJoin` c) -> do
          on (c ?. JoinOtherId ==. b ?. JoinManyJoinOther)
          on (just (a ^. JoinOneId) ==. b ?. JoinManyJoinOne)
          orderBy [asc $ a ^. JoinOneId, asc $ c ?. JoinOtherId]
          pure (a, c)
      ac <- run $ do
        setup
        select $
          from $ \(a `LeftOuterJoin` b `InnerJoin` c) -> do
          on (just (a ^. JoinOneId) ==. b ?. JoinManyJoinOne)
          on (c ?. JoinOtherId ==. b ?. JoinManyJoinOther)
          orderBy [asc $ a ^. JoinOneId, asc $ c ?. JoinOtherId]
          pure (a, c)

      listsEqualOn ac ca $ \(Entity _ a, b) ->
        (joinOneName a, maybe "NULL" (joinOtherName . entityVal) b)

    it "doesn't require an on for a crossjoin" $ do
      void $ run $
        select $
        from $ \(a `CrossJoin` b) -> do
        pure (a :: SqlExpr (Entity JoinOne), b :: SqlExpr (Entity JoinTwo))

    it "errors with an on for a crossjoin" $ do
      (void $ run $
        select $
        from $ \(a `CrossJoin` b) -> do
        on $ a ^. JoinOneId ==. b ^. JoinTwoJoinOne
        pure (a, b))
          `shouldThrow` \(OnClauseWithoutMatchingJoinException _) ->
            True

    it "left joins associativity" $ do
      ca <- run $ do
        setup
        select $
          from $ \(a `LeftOuterJoin` (b `InnerJoin` c)) -> do
          on (c ?. JoinOtherId ==. b ?. JoinManyJoinOther)
          on (just (a ^. JoinOneId) ==. b ?. JoinManyJoinOne)
          orderBy [asc $ a ^. JoinOneId, asc $ c ?. JoinOtherId]
          pure (a, c)
      ca' <- run $ do
        setup
        select $
          from $ \(a `LeftOuterJoin` b `InnerJoin` c) -> do
          on (c ?. JoinOtherId ==. b ?. JoinManyJoinOther)
          on (just (a ^. JoinOneId) ==. b ?. JoinManyJoinOne)
          orderBy [asc $ a ^. JoinOneId, asc $ c ?. JoinOtherId]
          pure (a, c)

      listsEqualOn ca ca' $ \(Entity _ a, b) ->
        (joinOneName a, maybe "NULL" (joinOtherName . entityVal) b)

    it "composes queries still" $ do
      let
        query1 =
          from $ \(foo `InnerJoin` bar) -> do
          on (foo ^. FooId ==. bar ^. BarQuux)
          pure (foo, bar)
        query2 =
          from $ \(p `LeftOuterJoin` bp) -> do
          on (p ^. PersonId ==. bp ^. BlogPostAuthorId)
          pure (p, bp)
      (a, b) <- run $ do
        fid <- insert $ Foo 5
        _ <- insert $ Bar fid
        pid <- insert $ Person "hey" Nothing Nothing 30
        _ <- insert $ BlogPost "WHY" pid
        a <- select ((,) <$> query1 <*> query2)
        b <- select (flip (,) <$> query1 <*> query2)
        pure (a, b)
      listsEqualOn a (map (\(x, y) -> (y, x)) b) id

    it "works with joins in subselect" $ do
      run $ void $
        select $
        from $ \(p `InnerJoin` r) -> do
        on $ p ^. PersonId ==. r ^. ReplyGuy
        pure . (,) (p ^. PersonName) $
          subSelect $
          from $ \(c `InnerJoin` bp) -> do
          on $ bp ^. BlogPostId ==. c ^. CommentBlog
          pure (c ^. CommentBody)

    describe "works with nested joins" $ do
      it "unnested" $ do
        run $ void $
          selectRethrowingQuery $
          from $ \(f `InnerJoin` b `LeftOuterJoin` baz `InnerJoin` shoop) -> do
          on $ f ^. FooId ==. b ^. BarQuux
          on $ f ^. FooId ==. baz ^. BazBlargh
          on $ baz ^. BazId ==. shoop ^. ShoopBaz
          pure ( f ^. FooName)
      it "leftmost nesting" $ do
        run $ void $
          selectRethrowingQuery $
          from $ \((f `InnerJoin` b) `LeftOuterJoin` baz `InnerJoin` shoop) -> do
          on $ f ^. FooId ==. b ^. BarQuux
          on $ f ^. FooId ==. baz ^. BazBlargh
          on $ baz ^. BazId ==. shoop ^. ShoopBaz
          pure ( f ^. FooName)
      describe "middle nesting" $ do
        it "direct association" $ do
          run $ void $
            selectRethrowingQuery $
            from $ \(p `InnerJoin` (bp `LeftOuterJoin` c) `LeftOuterJoin` cr) -> do
            on $ p ^. PersonId ==. bp ^. BlogPostAuthorId
            on $ just (bp ^. BlogPostId) ==. c ?. CommentBlog
            on $ c ?. CommentId ==. cr ?. CommentReplyComment
            pure (p,bp,c,cr)
        it "indirect association" $ do
          run $ void $
            selectRethrowingQuery $
            from $ \(f `InnerJoin` b `LeftOuterJoin` (baz `InnerJoin` shoop) `InnerJoin` asdf) -> do
            on $ f ^. FooId ==. b ^. BarQuux
            on $ f ^. FooId ==. baz ^. BazBlargh
            on $ baz ^. BazId ==. shoop ^. ShoopBaz
            on $ asdf ^. AsdfShoop ==. shoop ^. ShoopId
            pure (f ^. FooName)
        it "indirect association across" $ do
          run $ void $
            selectRethrowingQuery $
            from $ \(f `InnerJoin` b `LeftOuterJoin` (baz `InnerJoin` shoop) `InnerJoin` asdf `InnerJoin` another `InnerJoin` yetAnother) -> do
            on $ f ^. FooId ==. b ^. BarQuux
            on $ f ^. FooId ==. baz ^. BazBlargh
            on $ baz ^. BazId ==. shoop ^. ShoopBaz
            on $ asdf ^. AsdfShoop ==. shoop ^. ShoopId
            on $ another ^. AnotherWhy ==. baz ^. BazId
            on $ yetAnother ^. YetAnotherArgh ==. shoop ^. ShoopId
            pure (f ^. FooName)

      describe "rightmost nesting" $ do
        it "direct associations" $ do
          run $ void $
            selectRethrowingQuery $
            from $ \(p `InnerJoin` bp `LeftOuterJoin` (c `LeftOuterJoin` cr)) -> do
            on $ p ^. PersonId ==. bp ^. BlogPostAuthorId
            on $ just (bp ^. BlogPostId) ==. c ?. CommentBlog
            on $ c ?. CommentId ==. cr ?. CommentReplyComment
            pure (p,bp,c,cr)

        it "indirect association" $ do
          run $ void $
            selectRethrowingQuery $
            from $ \(f `InnerJoin` b `LeftOuterJoin` (baz `InnerJoin` shoop)) -> do
            on $ f ^. FooId ==. b ^. BarQuux
            on $ f ^. FooId ==. baz ^. BazBlargh
            on $ baz ^. BazId ==. shoop ^. ShoopBaz
            pure (f ^. FooName)

testExperimentalFrom :: Run -> Spec
testExperimentalFrom run = do
  describe "Experimental From" $ do
    it "supports basic table queries" $ do
      run $ do
        p1e <- insert' p1
        _   <- insert' p2
        p3e <- insert' p3
        peopleWithAges <- select $ do
          people <- Experimental.from $ Table @Person
          where_ $ not_ $ isNothing $ people ^. PersonAge
          return people
        liftIO $ peopleWithAges `shouldMatchList` [p1e, p3e]

    it "supports inner joins" $ do
      run $ do
        l1e <- insert' l1
        _   <- insert  l2
        d1e <- insert' $ Deed "1" (entityKey l1e)
        d2e <- insert' $ Deed "2" (entityKey l1e)
        lordDeeds <- select $ do
          (lords :& deeds) <-
            Experimental.from $ Table @Lord
                    `InnerJoin` Table @Deed
              `Experimental.on` (\(l :& d) -> l ^. LordId ==. d ^. DeedOwnerId)
          pure (lords, deeds)
        liftIO $ lordDeeds `shouldMatchList` [ (l1e, d1e)
                                             , (l1e, d2e)
                                             ]

    it "supports outer joins" $ do
      run $ do
        l1e <- insert' l1
        l2e <- insert' l2
        d1e <- insert' $ Deed "1" (entityKey l1e)
        d2e <- insert' $ Deed "2" (entityKey l1e)
        lordDeeds <- select $ do
          (lords :& deeds) <-
            Experimental.from $ Table @Lord
                `LeftOuterJoin` Table @Deed
                  `Experimental.on` (\(l :& d) -> just (l ^. LordId) ==. d ?. DeedOwnerId)

          pure (lords, deeds)
        liftIO $ lordDeeds `shouldMatchList` [ (l1e, Just d1e)
                                             , (l1e, Just d2e)
                                             , (l2e, Nothing)
                                             ]
    it "supports delete" $ do
      run $ do
        insert_ l1
        insert_ l2
        insert_ l3
        delete $ void $ Experimental.from $ Table @Lord
        lords <- select $ Experimental.from $ Table @Lord
        liftIO $ lords `shouldMatchList` []

    it "supports implicit cross joins" $ do
      run $ do
        l1e <- insert' l1
        l2e <- insert' l2
        ret <- select $ do
          lords1 <- Experimental.from $ Table @Lord
          lords2 <- Experimental.from $ Table @Lord
          pure (lords1, lords2)
        ret2 <- select $ do
          (lords1 :& lords2) <- Experimental.from $ Table @Lord `CrossJoin` Table @Lord
          pure (lords1,lords2)
        liftIO $ ret `shouldMatchList` ret2
        liftIO $ ret `shouldMatchList` [ (l1e, l1e)
                                       , (l1e, l2e)
                                       , (l2e, l1e)
                                       , (l2e, l2e)
                                       ]


    it "compiles" $ do
      run $ void $ do
        let q = do
              (persons :& profiles :& posts) <-
                Experimental.from $  Table @Person
                         `InnerJoin` Table @Profile
                   `Experimental.on` (\(people :& profiles) ->
                                        people ^. PersonId ==. profiles ^. ProfilePerson)
                     `LeftOuterJoin` Table @BlogPost
                   `Experimental.on` (\(people :& _ :& posts) ->
                                        just (people ^. PersonId) ==. posts ?. BlogPostAuthorId)
              pure (persons, posts, profiles)
        --error . show =<< renderQuerySelect q
        pure ()

    it "can call functions on aliased values" $ do
      run $ do
        insert_ p1
        insert_ p3
        -- Pretend this isnt all posts
        upperNames <- select $ do
          author <- Experimental.from $ SelectQuery $ Experimental.from $ Table @Person
          pure $ upper_ $ author ^. PersonName

        liftIO $ upperNames `shouldMatchList` [ Value "JOHN"
                                              , Value "MIKE"
                                              ]

listsEqualOn :: (Show a1, Eq a1) => [a2] -> [a2] -> (a2 -> a1) -> Expectation
listsEqualOn a b f = map f a `shouldBe` map f b

tests :: Run -> Spec
tests run = do
  describe "Tests that are common to all backends" $ do
    testSelect run
    testSubSelect run
    testSelectSource run
    testSelectFrom run
    testSelectJoin run
    testSelectSubQuery run
    testSelectWhere run
    testSelectOrderBy run
    testSelectDistinct run
    testCoasleceDefault run
    testDelete run
    testUpdate run
    testListOfValues run
    testListFields run
    testInsertsBySelect run
    testMathFunctions run
    testCase run
    testCountingRows run
    testRenderSql run
    testOnClauseOrder run
    testExperimentalFrom run


insert' :: ( Functor m
           , BaseBackend backend ~ PersistEntityBackend val
           , PersistStore backend
           , MonadIO m
           , PersistEntity val )
        => val -> ReaderT backend m (Entity val)
insert' v = flip Entity v <$> insert v


type RunDbMonad m = ( MonadUnliftIO m
                    , MonadIO m
                    , MonadLoggerIO m
                    , MonadLogger m
                    , MonadCatch m )

#if __GLASGOW_HASKELL__ >= 806
type Run = forall a. (forall m. (RunDbMonad m, MonadFail m) => SqlPersistT (R.ResourceT m) a) -> IO a
#else
type Run = forall a. (forall m. (RunDbMonad m) => SqlPersistT (R.ResourceT m) a) -> IO a
#endif

type WithConn m a = RunDbMonad m => (SqlBackend -> R.ResourceT m a) -> m a

-- With SQLite and in-memory databases, a separate connection implies a
-- separate database. With 'actual databases', the data is persistent and
-- thus must be cleaned after each test.
-- TODO: there is certainly a better way...
cleanDB
  :: (forall m. RunDbMonad m
  => SqlPersistT (R.ResourceT m) ())
cleanDB = do
  delete $ from $ \(_ :: SqlExpr (Entity Bar))  -> return ()
  delete $ from $ \(_ :: SqlExpr (Entity Foo))  -> return ()

  delete $ from $ \(_ :: SqlExpr (Entity Reply)) -> return ()
  delete $ from $ \(_ :: SqlExpr (Entity Comment)) -> return ()
  delete $ from $ \(_ :: SqlExpr (Entity Profile)) -> return ()
  delete $ from $ \(_ :: SqlExpr (Entity BlogPost)) -> return ()
  delete $ from $ \(_ :: SqlExpr (Entity Follow)) -> return ()
  delete $ from $ \(_ :: SqlExpr (Entity Person)) -> return ()

  delete $ from $ \(_ :: SqlExpr (Entity Deed)) -> return ()
  delete $ from $ \(_ :: SqlExpr (Entity Lord)) -> return ()

  delete $ from $ \(_ :: SqlExpr (Entity CcList))  -> return ()

  delete $ from $ \(_ :: SqlExpr (Entity ArticleTag)) -> return ()
  delete $ from $ \(_ :: SqlExpr (Entity ArticleMetadata)) -> return ()
  delete $ from $ \(_ :: SqlExpr (Entity Article))    -> return ()
  delete $ from $ \(_ :: SqlExpr (Entity Article2))   -> return ()
  delete $ from $ \(_ :: SqlExpr (Entity Tag))        -> return ()
  delete $ from $ \(_ :: SqlExpr (Entity Frontcover)) -> return ()

  delete $ from $ \(_ :: SqlExpr (Entity Circle))     -> return ()
  delete $ from $ \(_ :: SqlExpr (Entity Point))      -> return ()

  delete $ from $ \(_ :: SqlExpr (Entity Numbers))    -> return ()
  delete $ from $ \(_ :: SqlExpr (Entity JoinMany))    -> return ()
  delete $ from $ \(_ :: SqlExpr (Entity JoinFour))    -> return ()
  delete $ from $ \(_ :: SqlExpr (Entity JoinThree))    -> return ()
  delete $ from $ \(_ :: SqlExpr (Entity JoinTwo))    -> return ()
  delete $ from $ \(_ :: SqlExpr (Entity JoinOne))    -> return ()
  delete $ from $ \(_ :: SqlExpr (Entity JoinOther))    -> return ()

  delete $ from $ \(_ :: SqlExpr (Entity DateTruncTest)) -> pure ()


cleanUniques
  :: (forall m. RunDbMonad m
  => SqlPersistT (R.ResourceT m) ())
cleanUniques =
  delete $ from $ \(_ :: SqlExpr (Entity OneUnique))    -> return ()

selectRethrowingQuery
  :: (MonadIO m, EI.SqlSelect a r, MonadUnliftIO m)
  => SqlQuery a
  -> SqlPersistT m [r]
selectRethrowingQuery query =
  select query
    `catch` \(SomeException e) -> do
      (text, _) <- renderQuerySelect query
      liftIO . throwIO . userError $ Text.unpack text <> "\n\n" <> show e
