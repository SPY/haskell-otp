{-# OPTIONS_GHC -F -pgmF htfpp #-}
module Main where

-- The main test program.

import Test.Framework
import Test.Framework.BlackBoxTest
import {-@ HTF_TESTS @-} Test.Process
import {-@ HTF_TESTS @-} Test.GenServer

main = htfMain htf_importedTests
