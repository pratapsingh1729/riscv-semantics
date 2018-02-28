{-# LANGUAGE MultiParamTypeClasses, FlexibleInstances, FlexibleContexts, MultiWayIf, UndecidableInstances #-}
module MMIO where
import Data.Bits
import Data.Int
import Data.Char
import Control.Monad.Identity
import Control.Monad.State
import System.IO.Error
import qualified Data.Map as S

import Program
import Utility

type IOState s = StateT s IO

type LoadFunc s = IOState s Int32
type StoreFunc s = Int32 -> IOState s ()

instance (Show (LoadFunc s)) where
  show _ = "<io/loadfunc>"
instance (Show (StoreFunc s)) where
  show _ = "<io/storefunc>"

cGetChar :: IO Int32
cGetChar = catchIOError (fmap (fromIntegral . ord) getChar) (\e -> if isEOFError e then return (-1) else ioError e)

rvGetChar :: LoadFunc s
rvGetChar = liftIO cGetChar
rvPutChar :: StoreFunc s
rvPutChar val = liftIO (putChar $ chr $ fromIntegral val)

-- Addresses for mtime/mtimecmp chosen for Spike compatibility.
mmioTable :: S.Map MachineInt (LoadFunc s, StoreFunc s)
mmioTable = S.fromList [(0xfff4, (rvGetChar, rvPutChar))]

instance (RiscvProgram (State s) t u, Convertible t u, Bounded t, Bounded u, Bits t, Bits u, MachineWidth t) => RiscvProgram (IOState s) t u where
  getRegister r = liftState (getRegister r)
  setRegister r v = liftState (setRegister r v)
  loadByte a = liftState (loadByte a)
  loadHalf a = liftState (loadHalf a)
  loadWord addr =
    case S.lookup (fromIntegral addr) mmioTable of
      Just (getFunc, _) -> getFunc
      Nothing -> liftState (loadWord addr)
  loadDouble a = liftState (loadDouble a)
  storeByte a v = liftState (storeByte a v)
  storeHalf a v = liftState (storeHalf a v)
  storeWord addr val =
    case S.lookup (fromIntegral addr) mmioTable of
      Just (_, setFunc) -> setFunc (fromIntegral val)
      Nothing -> liftState (storeWord addr val)
  storeDouble a v = liftState (storeDouble a v)
  getCSRField f = liftState (getCSRField f)
  setCSRField f v = liftState (setCSRField f v)
  getPC = liftState getPC
  setPC v = liftState (setPC v)
  step = liftState step
