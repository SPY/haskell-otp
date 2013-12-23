module Concurrency.OTP.Internal.Types
  ( Status(..)
  ) where

-- | Status of the started process
data Status a = Ok a | Fail deriving (Show)
