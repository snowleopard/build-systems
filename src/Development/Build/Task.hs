{-# LANGUAGE ConstraintKinds, RankNTypes #-}
{-# OPTIONS_GHC -Wno-unused-top-binds #-}
module Development.Build.Task (Task, inputTask, isInput, sprsh1, sprsh2) where

import Control.Applicative
import Control.Monad
import Data.Maybe
import Data.Proxy

-- | Task a value corresponding to a given key by performing necessary
-- lookups of the dependencies using the provided lookup function. Returns
-- @Nothing@ to indicate that a given key is an input.
type Task c k v = forall f. c f => (k -> f v) -> k -> Maybe (f v)

-- | The trivial task that considers all keys as inputs.
inputTask :: (k -> f v) -> k -> Maybe (f v)
inputTask _ _ = Nothing

-- TODO: How do we express this in terms of Task? Drop forall in Task?
isInput :: ((k -> Proxy v) -> k -> Maybe (Proxy v)) -> k -> Bool
isInput task = isNothing . task (const Proxy)

--------------------------- Task Functor: Collatz ---------------------------
-- Collatz sequence:
-- c[0] = n
-- c[k] = f(c[k - 1]) where
-- For example, if n = 12, the sequence is 3, 10, 5, 16, 8, 4, 2, 1, ...
data Collatz = Collatz Int

collatz :: Task Functor Collatz Int
collatz get (Collatz k) | k <= 0    = Nothing
                        | otherwise = Just $ f <$> get (Collatz (k - 1))
  where
    f n | even n    = n `div` 2
        | otherwise = 3 * n + 1

-- A good demonstration of early cut-off:
-- * Task Collatz sequence from n = 6: 6, 3, 10, 5, 16, 8, 4, 2, 1, ...
-- * Change n from 6 to 40 and rebuild: 40, 20, 10, 5, 16, 8, 4, 2, 1, ...
-- * The recomputation should be cut-off after 10.
------------------------ Task Applicative: Fibonacci ------------------------
-- Generalised Fibonacci sequence:
-- f[0] = n
-- f[1] = m
-- f[k] = f[k - 1] + f[k - 2]
-- For example, with (n, m) = (0, 1) we get usual Fibonacci sequence, and if
-- (n, m) = (2, 1) we get Lucas sequence: 2, 1, 3, 4, 7, 11, 18, 29, 47, ...
data Fibonacci = Fibonacci Int

fibonacci :: Task Applicative Fibonacci Int
fibonacci get (Fibonacci k) | k <= 1    = Nothing
                            | otherwise = Just $ (+) <$> get (Fibonacci (k - 1))
                                                     <*> get (Fibonacci (k - 2))

-- Fibonacci numbers are a classic example of memoization: a non-minimal build
-- system will take ages to compute f[100], doing O(f[100]) recursive calls.
-- The right approach is to build the dependency graph and execute computations
-- in the topological order.
--------------------------- Task Monad: Ackermann ---------------------------
-- Ackermann function:
-- a[0, n] = n + 1
-- a[m, 0] = a[m - 1, 1]
-- a[m, n] = a[m - 1, a[m, n - 1]]
-- Formally, it has no inputs, but we return Nothing for negative inputs.
-- For example, a[m, 1] = 2, 3, 5, 13, 65535, ...

data Ackermann = Ackermann Int Int

ackermann :: Task Monad Ackermann Int
ackermann get (Ackermann m n)
    | m < 0 || n < 0 = Nothing
    | m == 0    = Just $ return (n + 1)
    | n == 0    = Just $ get (Ackermann (m - 1) 1)
    | otherwise = Just $ do
        index <- get (Ackermann m (n - 1))
        get (Ackermann (m - 1) index)

-- Unlike Collatz and Fibonacci computations, the Ackermann computation cannot
-- be statically analysed for dependencies. We can only find the first dependency
-- statically (Ackermann m (n - 1)), but not the second one.

----------------------------- Spreadsheet examples -----------------------------
add :: Task Applicative String Integer
add fetch key | key /= "B1" = Nothing
              | otherwise   = Just $ (+) <$> fetch "A1" <*> fetch "A2"

select :: Task Monad String Integer
select fetch key | key /= "B1" = Nothing
                 | otherwise   = Just $ do
                     c1 <- fetch "C1"
                     if c1 == 1 then fetch "A1" else fetch "A2"

indirect :: Task Monad String Integer
indirect fetch key | key /= "B1" = Nothing
                   | otherwise   = Just $ do
                       c1 <- fetch "C1"
                       fetch ("A" ++ show c1)

sprsh1 :: Task Applicative String Integer
sprsh1 fetch "B1" = Just ((+) <$> fetch "A1" <*> fetch "A2")
sprsh1 fetch "B2" = Just ((* 2) <$> fetch "B1")
sprsh1 _     _    = Nothing

sprsh2 :: Task Monad String Integer
sprsh2 fetch "B1" = Just $ do c1 <- fetch "C1"
                              if c1 == 1 then fetch "B2" else fetch "A2"
sprsh2 fetch "B2" = Just $ do c1 <- fetch "C1"
                              if c1 == 1 then fetch "A1" else fetch "B1"
sprsh2 _     _    = Nothing

sprsh3 :: Task MonadPlus String Integer
sprsh3 fetch "B1" = Just $ (+) <$> fetch "A1" <*> pure 1 `mplus` pure 2
sprsh3 _     _    = Nothing

fetchIO :: String -> IO Integer
fetchIO k = do putStr (k ++ ": "); read <$> getLine

data Key = A Integer | B Integer | D Integer Integer

editDistance :: Task Monad Key Integer
editDistance _     (D i 0) = Just $ pure i
editDistance _     (D 0 j) = Just $ pure j
editDistance fetch (D i j) = Just $ do
    ai <- fetch (A i)
    bj <- fetch (B j)
    if ai == bj
        then fetch (D (i - 1) (j - 1))
        else do
            insert  <- fetch (D  i      (j - 1))
            delete  <- fetch (D (i - 1)  j     )
            replace <- fetch (D (i - 1) (j - 1))
            return (1 + minimum [insert, delete, replace])
editDistance _ _ = Nothing

-- These type synonyms are not very useful, but enumerate all interesting cases.
type FunctorialTask  k v = forall f. Functor     f => (k -> f v) -> k -> Maybe (f v)
type ApplicativeTask k v = forall f. Applicative f => (k -> f v) -> k -> Maybe (f v)
type AlternativeTask k v = forall f. Alternative f => (k -> f v) -> k -> Maybe (f v)
type MonadicTask     k v = forall f. Monad       f => (k -> f v) -> k -> Maybe (f v)
type MonadPlusedTask k v = forall f. MonadPlus   f => (k -> f v) -> k -> Maybe (f v)
