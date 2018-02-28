module Run where
import System.IO
import System.Environment
import System.Exit
import Data.Int
import Data.List
import Data.Word
import Utility
import Program
import Minimal64
import MMIO
import Elf
import qualified CSRField as Field
import CSRFile
import Decode
import Execute
import Control.Monad.Trans
import Control.Monad.Trans.State
import qualified Data.Map as S
import Debug.Trace
import Numeric (showHex, readHex)

processLine :: String -> (Int, [(Int, Word8)]) -> (Int, [(Int, Word8)])
processLine ('@':xs) (p, l) = ((fst $ head $ readHex xs) * 4, l)
processLine s (p, l) = (p + 4, l ++ (zip [p..] $ splitWord (fst $ head $ readHex s :: Word32)))

readHexFile :: FilePath -> IO [(Int, Word8)]
readHexFile f = do
  h <- openFile f ReadMode
  helper h (0, [])
  where helper h l = do
          s <- hGetLine h
          done <- hIsEOF h
          if (null s)
            then return $ snd l
            else if done
                 then return $ snd $ processLine s l
                 else helper h (processLine s l)

checkInterrupt :: IO Bool
checkInterrupt = do
  ready <- hReady stdin
  if ready then do
    c <- hLookAhead stdin
    if c == '!' then do
      _ <- getChar
      _ <- getChar
      return True
    else return False
  else return False

helper :: Maybe Int64 -> IOState Minimal64 Int64
helper maybeToHostAddress = do
  toHostValue <- case maybeToHostAddress of
    Nothing -> return 0 -- default value
    Just toHostAddress -> loadWord toHostAddress
  if toHostValue /= 0
    then do
      -- quit running
      if toHostValue == 1
        then trace "PASSED" (return 0)
        else trace ("FAILED " ++ (show $ quot toHostValue 2)) (return 1)
    else do
      pc <- getPC
      -- trace ("pc: 0x" ++ (showHex pc "")) $ return ()
      -- TODO: Translate PC lookup in supervisor mode.
      inst <- loadWord pc
      if inst == 0x6f -- Stop on infinite loop instruction.
        then do
            cycles <- getCSRField Field.MCycle
            trace ("Cycles: " ++ show cycles) (return ())
            instret <- getCSRField Field.MInstRet
            trace ("Insts: " ++ show instret) (return ())
            getRegister 10
        else do
        setPC (pc + 4)
        size <- getXLEN
        execute (decode size $ fromIntegral inst)
        interrupt <- liftIO checkInterrupt
        if interrupt then do
          -- Signal interrupt by setting MEIP high.
          setCSRField Field.MEIP 1
        else return ()
        step
        helper maybeToHostAddress

runProgram :: Maybe Int64 -> Minimal64 -> IO (Int64, Minimal64)
runProgram maybeToHostAddress = runStateT (helper maybeToHostAddress)

readProgram :: String -> IO (Maybe Int64, [(Int, Word8)])
readProgram f = do
  if ".hex" `isSuffixOf` f
    then do
    mem <- readHexFile f
    return (Nothing, mem)
    else do
    mem <- readElf f
    maybeToHostAddress <- readElfSymbol "tohost" f
    return (fmap fromIntegral maybeToHostAddress, mem)

runFile :: String -> IO Int64
runFile f = do
  (maybeToHostAddress, mem) <- readProgram f
  let c = Minimal64 { registers = (take 31 $ repeat 0), csrs = (resetCSRFile 64), pc = 0x80000000, nextPC = 0,
                      mem = S.fromList mem } in
    fmap fst $ runProgram maybeToHostAddress c

runFiles :: [String] -> IO Int64
runFiles (file:files) = do
    myreturn <- runFile file
    putStr (file ++ ": " ++ (show myreturn) ++ "\n")
    othersreturn <- runFiles files
    if myreturn /= 0
        then return myreturn
        else return othersreturn
runFiles [] = return 0

main :: IO ()
main = do
  args <- getArgs
  retval <- case args of
    [] -> do
      putStr "ERROR: this program expects one or more elf files as command-line arguments\n"
      return 1
    [file] -> runFile file
    files -> runFiles files
  exitWith (if retval == 0 then ExitSuccess else ExitFailure $ fromIntegral retval)
