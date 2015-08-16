------------------------------------------------------------------------
-- |
-- Module           : Reopt.Concrete.Semantics
-- Description      : Monadic interpreter for Reopt.Reified.Semantics
--                    Stmt & Expr types
-- Copyright        : (c) Galois, Inc 2015
-- Maintainer       : Nathan Collins <conathan@galois.com>
-- Stability        : provisional
--
-- This contains an implementation of the classes defined in
-- Reopt.Semantics.Monad that treat some class methods as
-- uninterpreted functions.
------------------------------------------------------------------------
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DoAndIfThenElse #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE ViewPatterns #-}

module Reopt.Concrete.Semantics
       ( evalStmt
       , module Reopt.Reified.Semantics
       ) where

import           Control.Exception (assert)
import           Control.Monad.Cont
import           Control.Monad.Reader
import           Control.Monad.State.Strict
import           Data.Binary.IEEE754
import           Data.Bits
import           Data.BitVector (BV)
import qualified Data.BitVector as BV
import           Data.Parameterized.Map (MapF)
import qualified Data.Parameterized.Map as MapF
import           Data.Parameterized.NatRepr

import           GHC.Float (float2Double, double2Float)

import           Reopt.Semantics.Monad
  ( Type(..)
  , TypeRepr(..)
  , BoolType
  )
import qualified Reopt.Semantics.Monad as S
import           Reopt.Reified.Semantics
import qualified Reopt.CFG.Representation as R
import qualified Reopt.Machine.StateNames as N
import qualified Reopt.Concrete.MachineState as CS
import           Reopt.Machine.Types ( FloatInfoRepr, FloatType
                                     , floatInfoBits, n1, n80
                                     )

------------------------------------------------------------------------
-- Expression evaluation

type Env = MapF Variable CS.Value

-- `c` in this context means `concrete value`.
evalExpr :: (MonadReader Env m, Applicative m) => Expr tp -> m (CS.Value tp)
evalExpr (LitExpr nr i) = return $ CS.Literal bVec
  where
    bVec = CS.bitVector nr (BV.bitVec bitWidth i)
    bitWidth = fromInteger (natValue nr)

evalExpr (VarExpr var@(Variable _ name)) = do
  maybeVal <- asks (MapF.lookup var)
  let msg = "Bug: unbound variable " ++ name ++ " in expr"
  maybe (error msg) return maybeVal

evalExpr (AppExpr a) = do
  a' <- R.traverseApp evalExpr a
  return $ case a' of
    -- Mux is if-then-else
    R.Mux nr c1 c2 c3 -> CS.liftValue3 doMux nr c1 c2 c3

    -- Resize ops
    R.MMXExtend c -> let ones = BV.ones 16
                      in CS.liftValue (BV.# ones) extPrecisionNatRepr c
    R.ConcatV nr c1 c2 -> CS.liftValue2 (BV.#) (addNat nr nr) c1 c2
    R.UpperHalf nr c -> CS.liftValue (upperBV nr) nr c
    R.Trunc c nr -> CS.liftValue (truncBV nr) nr c
    R.SExt c nr -> CS.liftValue (sExtBV nr) nr c
    R.UExt c nr -> CS.liftValue (uExtBV nr) nr c

    -- Boolean ops
    R.AndApp c1 c2 -> CS.liftValue2 (.&.) boolNatRepr c1 c2
    R.OrApp c1 c2 -> CS.liftValue2 (.|.) boolNatRepr c1 c2
    R.NotApp c -> CS.liftValue (complement) boolNatRepr c

    -- Arithmetic ops
    R.BVAdd nr c1 c2 -> CS.liftValue2 (+) nr c1 c2
    R.BVSub nr c1 c2 -> CS.liftValue2 (-) nr c1 c2
    R.BVMul nr c1 c2 -> CS.liftValue2 (*) nr c1 c2
    R.BVQuot _nr _c1 _c2 -> error "Impossible: BVQuot should be unreachable"
    R.BVRem _nr _c1 _c2 -> error "Impossible: BVRem should be unreachable"
    R.BVSignedQuot _nr _c1 _c2 -> error "Impossible: BVSignedQuot should be unreachable"
    R.BVSignedRem _nr _c1 _c2 -> error "Impossible: BVSignedRem should be unreachable"

    -- Comparisons
    R.BVUnsignedLt c1 c2 -> CS.liftValue2 (predBV (BV.<.)) boolNatRepr c1 c2
    R.BVSignedLt c1 c2 -> CS.liftValue2 (predBV (BV.slt)) boolNatRepr c1 c2
    R.BVUnsignedLe c1 c2 -> CS.liftValue2 (predBV (BV.<=.)) boolNatRepr c1 c2
    R.BVSignedLe c1 c2 -> CS.liftValue2 (predBV BV.sle) boolNatRepr c1 c2
    R.BVTestBit c1 c2 -> CS.liftValue2 bitIdx boolNatRepr c1 c2

    -- Bit vector ops
    R.BVComplement nr c -> CS.liftValue (complement) nr c
    R.BVAnd nr c1 c2 -> CS.liftValue2 (.&.) nr c1 c2
    R.BVOr nr c1 c2 -> CS.liftValue2 (.|.) nr c1 c2
    R.BVXor nr c1 c2 -> CS.liftValue2 (xor) nr c1 c2
    R.BVShl nr c1 c2 -> CS.liftValue2 (BV.shl) nr c1 c2
    R.BVShr nr c1 c2 -> CS.liftValue2 (BV.shr) nr c1 c2
    R.BVSar nr c1 c2 -> CS.liftValue2 (BV.ashr) nr c1 c2
    R.BVEq c1 c2 -> CS.liftValue2 (predBV (BV.==.)) boolNatRepr c1 c2

    R.EvenParity c -> CS.liftValue isEvenParity boolNatRepr c
    R.ReverseBytes nr c -> CS.liftValue BV.reverse nr c
    R.UadcOverflows _nr c1 c2 carryBit ->
      CS.liftValue3 checkUadcOverflow boolNatRepr c1 c2 carryBit
    R.SadcOverflows _nr c1 c2 carryBit ->
      CS.liftValue3 checkSadcOverflow boolNatRepr c1 c2 carryBit
    R.UsbbOverflows _nr c1 c2 borrowBit ->
      CS.liftValue3 checkUsbbOverflow boolNatRepr c1 c2 borrowBit
    R.SsbbOverflows _nr c1 c2 borrowBit ->
      CS.liftValue3 checkSsbbOverflow boolNatRepr c1 c2 borrowBit

    R.Bsf nr c -> CS.liftValueMaybe (bsf nr) nr c
    R.Bsr nr c -> CS.liftValueMaybe (bsr nr) nr c


    --       _~
    --    _~ )_)_~
    --    )_))_))_)
    --    _!__!__!_
    --    \_______/
    -- ~~~~~~~~~~~~~~~
    -- Floating point
    -- (Pirate ship to indicate these are treacherous waters. Arrr.)
    -- ===============
    --
    -- XXX These are defined using simply isNaN because SNaN is a "signaling"
    -- NaN which triggers a hardware exception. We're punting on this for now.
    R.FPIsQNaN fr c -> liftFPPred isNaN fr c
    R.FPIsSNaN fr c -> liftFPPred isNaN fr c

    -- Arith
    R.FPAdd fr c1 c2 -> liftFP2 (+) fr c1 c2
    R.FPSub fr c1 c2 -> liftFP2 (-) fr c1 c2
    R.FPMul fr c1 c2 -> liftFP2 (-) fr c1 c2
    R.FPDiv fr c1 c2 -> liftFP2 (/) fr c1 c2

    -- XXX For now we return `Undefined` for whether a given PF (precision fault)
    -- was due to rounding up or down. This means the C1 x87 FPU flag will be
    -- Undefined, so we'll see if that's problematic.
    R.FPAddRoundedUp _fr c1 c2 ->
      CS.liftValueMaybe2 (\_ _ -> Nothing) boolNatRepr c1 c2
    R.FPSubRoundedUp _fr c1 c2 ->
      CS.liftValueMaybe2 (\_ _ -> Nothing) boolNatRepr c1 c2
    R.FPMulRoundedUp _fr c1 c2 ->
      CS.liftValueMaybe2 (\_ _ -> Nothing) boolNatRepr c1 c2
    R.FPCvtRoundsUp _fr1 c _fr2 ->
      CS.liftValueMaybe (const Nothing) boolNatRepr c

    -- Tests
    R.FPLt fr c1 c2 -> liftFPPred2 (<)  fr c1 c2
    R.FPEq fr c1 c2 -> liftFPPred2 (==) fr c1 c2

    -- Conversion
    R.FPCvt fr1 c fr2 -> convertFP fr1 fr2 c
    R.FPFromBV fr c -> convertBVtoFP fr c
    -- XXX FIXME: If a conversion is out of the range of the bitvector, we
    -- should raise a floating point exception. If that is masked, we should
    -- return -1 as a BV.
    R.TruncFPToSignedBV fr c nr -> liftFPtoBV (truncateIfValid nr) fr nr c

------------------------------------------------------------------------
-- Statement evaluation

-- | A version of 'evalExpr' for use in the state monad of 'evalStmt'.
evalExpr' :: (Applicative m, MonadState Env m) => Expr tp -> m (CS.Value tp)
evalExpr' e = runReader (evalExpr e) <$> get

extendEnv :: MonadState Env m => Variable tp -> CS.Value tp -> m ()
extendEnv x v = modify (MapF.insert x v)

-- | Slice a subrange from a 'BV'.
--
-- This is a wrapper around 'BV.@@' which differs by supporting empty
-- slices.
(@@) :: Integral ix => BV -> (ix, ix) -> BV
bv @@ (high, low) =
  if high >= low
  then bv BV.@@ (high, low)
  else empty
  where
    empty = BV.zeros 0

-- | Helper for division ops in 'evalStmt' below.
bvDivOp :: (Applicative m, CS.MonadMachineState m, MonadState Env m)
    => (BV -> BV -> BV)
    -> Variable (BVType n)
    -> Expr (BVType n)
    -> Expr (BVType n)
    -> m ()
bvDivOp op var ns1 ns2 = do
  v1 <- evalExpr' ns1
  v2 <- evalExpr' ns2
  let tr = CS.asTypeRepr v2
      q = case v2 of
            CS.Literal (CS.unBitVector -> (nr,bv)) ->
              -- The caller should have already checked for non-zero
              -- denominator.
              assert (bv /= 0) $
                CS.liftValue2 op nr v1 v2
            _ -> CS.Undefined tr
  extendEnv var q

evalStmt :: forall m. (Applicative m, CS.MonadMachineState m, MonadState Env m) => Stmt -> m ()
evalStmt (MakeUndefined x tr) =
  extendEnv x (CS.Undefined tr)
evalStmt (Get x l) =
  -- Force 'tp' to be a 'BVType n'.
  case S.loc_type l of
  BVTypeRepr _ -> do

  let nr = S.loc_width l

  let memCont :: forall tp0 i.
                 Integer ~ i
              => (i, i) -> i -> (Expr (BVType 64), TypeRepr tp0) -> m ()
      memCont (low, high) _width (addr, BVTypeRepr nr0) = do
        vaddr <- evalExpr' addr
        case vaddr of
          CS.Undefined _ -> error "evalStmt: undefined address in 'Get'!"
          CS.Literal bvaddr -> do
            let a = CS.Address nr0 bvaddr
            v0 <- CS.getMem a
            let v1 = CS.liftValue (sliceBV (low, high)) nr v0
            extendEnv x v1

  let regCont :: forall cl i.
                 Integer ~ i
              => (i, i) -> i -> N.RegisterName cl -> m ()
      regCont (low, high) _width rn =
        -- Force 'tp' to be a 'BVType n'.
        case S.loc_type l of
        BVTypeRepr _ -> do
        v0 <- CS.getReg rn
        let v1 = CS.liftValue (sliceBV (low, high)) nr v0
        extendEnv x v1

  let x87Cont :: forall i. Integer ~ i => (i, i) -> i -> Int -> m()
      x87Cont (low, high) width i =
        case S.loc_type l
          of BVTypeRepr n -> do
             topReg <- CS.getReg N.X87TopReg
             case topReg
               of CS.Literal bv -> do
                    let top = BV.nat $ snd $ CS.unBitVector bv
                    regCont (low, high) width (N.X87FPUReg (
                     (fromIntegral top + i) `mod` 8))
                  CS.Undefined _ -> extendEnv x $ CS.Undefined $ BVTypeRepr n

  S.elimLocation memCont regCont x87Cont l
  where
    sliceBV :: Integer ~ i
            => (i, i) -> BV -> BV
    sliceBV (low, high) super = super @@ (high - 1, low)
evalStmt (BVQuot x ns1 ns2) = bvDivOp div x ns1 ns2
evalStmt (BVRem x ns1 ns2) = bvDivOp mod x ns1 ns2
-- TODO(conathan): BUG: We use @sdiv@ and @smod@ here, but they round
-- towards negative infinity; we want @squot@ and @srem@ instead,
-- which round towards zero in agreement with the x86 @idiv@
-- semantics, but 'BV' does not provide an @squot@' operation.
evalStmt (BVSignedQuot x ns1 ns2) = bvDivOp BV.sdiv x ns1 ns2
evalStmt (BVSignedRem x ns1 ns2) = bvDivOp BV.smod x ns1 ns2
-- Based on 'MemCopy' eval below.
evalStmt (MemCmp x bytes compares src dst reversed) = do
  case bytes of
    1 -> go S.n8
    2 -> go S.n16
    4 -> go S.n32
    8 -> go S.n64
    _ -> error "evalStmt: MemCmp: unsupported number of bytes!"
  where
    go :: NatRepr n -> m ()
    go nr = do
      [vcompares, vsrc, vdst] <- mapM evalExpr' [compares, src, dst]
      vreversed <- evalExpr' reversed
      let srcAddrs = addressSequence vsrc nr vcompares vreversed
      let dstAddrs = addressSequence vdst nr vcompares vreversed

      matches <- forM (zip srcAddrs dstAddrs) $ \(s, d) -> do
        l <- CS.getMem s
        r <- CS.getMem d
        return $ if l == r then 1 else 0

      let lit :: CS.Value (BVType 64)
          lit = CS.Literal $ CS.bitVector knownNat (sum matches)
      extendEnv x lit
evalStmt (GetSegmentBase x seg) = do
  base <- CS.getSegmentBase seg
  extendEnv x base

-- Strategy for handling subregion writes: read the current value of
-- the full memory or register underlying the subregion in 'l',
-- redefine the subregion 'l' of the current value with the given
-- value in 'e', write back the updated value.
--
-- For example, the subregister write
--
--   %rax[8:16] := e
--
-- is effected by
--
--   v0 <- getReg %rax
--   let v1 = v0[0:8] ++ e ++ v0[16:64]
--   setReg %rax v1
--
evalStmt (l := e) =
  -- Force 'tp' to be a 'BVType n'.
  case S.loc_type l of
  BVTypeRepr _ -> do

  ve <- evalExpr' e
  let memCont :: forall tp i.
                 Integer ~ i
              => (i, i) -> i -> (Expr (BVType 64), TypeRepr tp) -> m ()
      memCont (low, high) width (addr, BVTypeRepr nr) = do
        vaddr <- evalExpr' addr
        case vaddr of
          -- Alternatively, we could mark memory values known to
          -- the machine state monad 'm' as 'Undefined' here.
          CS.Undefined _ -> error "evalStmt: undefined address in (:=)!"
          CS.Literal bvaddr -> do
            let a = CS.Address nr bvaddr
            v0 <- CS.getMem a
            let v1 = CS.liftValue2 (combineBV (low, high) width) nr v0 ve
            CS.setMem a v1
  let regCont :: forall cl i.
                 Integer ~ i
              => (i, i) -> i -> N.RegisterName cl -> m ()
      regCont (low, high) width rn = do
        let nr = N.registerWidth rn
        v0 <- CS.getReg rn
        let v1 = CS.liftValue2 (combineBV (low, high) width) nr v0 ve
        CS.setReg rn v1
  let x87Cont :: forall i. Integer ~ i => (i, i) -> i -> Int -> m()
      x87Cont (low, high) width i =
        case S.loc_type l
          of BVTypeRepr _n -> do
             topReg <- CS.getReg N.X87TopReg
             case topReg
               of CS.Literal bv -> do
                    let top = BV.nat $ snd $ CS.unBitVector bv
                    regCont (low, high) width (N.X87FPUReg (
                     (fromIntegral top + i) `mod` 8))
                  CS.Undefined _ -> do
                    -- undefine all the floating point registers, I guess?
                    mapM_
                      (\reg -> CS.setReg reg
                               (CS.Undefined $ N.registerType reg))
                      N.x87FPURegs
  S.elimLocation memCont regCont x87Cont l
  where
    combineBV :: Integer ~ i
              => (i, i) -> i -> BV -> BV -> BV
    combineBV (low, high) width super sub =
      (super @@ (width - 1, high)) BV.#
      sub BV.#
      (super @@ (low - 1, 0))

evalStmt (Ifte_ c t f) = do
  vc <- evalExpr' c
  case vc of
    CS.Undefined _ -> error "evalStmt: Ifte_: undefined condition!"
    CS.Literal (CS.unBitVector -> (_, bv)) -> do
      -- All names in the environment are only defined once, and usage
      -- of names in the enviroment is constrained by scoping in the
      -- meta language, Haskell, so this save and restore of the
      -- environment here should be technically unnecessary.
      env0 <- get
      if BV.nat bv /= 0
      then mapM_ evalStmt t
      else mapM_ evalStmt f
      put env0
evalStmt (MemCopy bytes copies src dst reversed) = do
  case bytes of
    1 -> go S.n8
    2 -> go S.n16
    4 -> go S.n32
    8 -> go S.n64
    _ -> error "evalStmt: MemCopy: unsupported number of bytes!"
  where
    -- Construct source and destination address sequences of type
    -- @CS.Address (BVType (bytes * 8))@ and do the copies.  The
    -- address type depends on the incoming integer 'bytes', so we
    -- can't type the addresses in general; if 'bytes' were a
    -- 'NatRepr' we could.
    go :: NatRepr n -> m ()
    go nr = do
      [vcopies, vsrc, vdst] <- mapM evalExpr' [copies, src, dst]
      vreversed <- evalExpr' reversed
      let srcAddrs = addressSequence vsrc nr vcopies vreversed
      let dstAddrs = addressSequence vdst nr vcopies vreversed

      forM_ (zip srcAddrs dstAddrs) $ \(s, d) -> do
        CS.setMem d =<< CS.getMem s
evalStmt (MemSet n v a) = do
  vn <- evalExpr' n
  vv <- evalExpr' v
  va <- evalExpr' a
  let addrs = addressSequence va (CS.width vv) vn (CS.Literal CS.false)
  forM_ addrs $ \addr -> do
    CS.setMem addr vv
evalStmt (Primitive p) = CS.primitive p
-- TODO(conathan): implement exception handling.
evalStmt (Exception _s1 _s2 _s3) = return ()
evalStmt (X87Push s) = do
  let top = N.X87TopReg
  vTop <- CS.getReg top
  let vTop' = CS.liftValueSame ((-) 1) vTop
  CS.setReg top vTop'
  case vTop' of
    CS.Undefined _ -> error "evalStmt: X87Push: Undefined Top index"
    CS.Literal (CS.unBitVector -> (_, bv)) -> do
      let idx = fromIntegral $ BV.uint bv
      if idx > 7
         then error "evalStmt: X87Push: index out of bounds"
         else CS.setReg (N.X87FPUReg idx) =<< evalExpr' s
evalStmt X87Pop = do
  let top = N.X87TopReg
  vTop <- CS.getReg top
  CS.setReg top $ CS.liftValueSame (+1) vTop

-- | Convert a base address, increment (in bits), and count, into a sequence of
-- addresses.
--
-- TODO(conathan): move into 'MachineState' and refactor
-- 'byteAddresses' in terms of this.
addressSequence :: forall n.
                   CS.Value (BVType 64)
                -> NatRepr n
                -> CS.Value (BVType 64)
                -> CS.Value BoolType
                -> [CS.Address (BVType n)]
addressSequence (CS.Literal baseB) nr (CS.Literal countB) (CS.Literal reversedB) =
  [ CS.modifyAddr (incBv k) baseAddr
  | k <- [0..count - 1] ]
  where
    baseAddr :: CS.Address (BVType n)
    baseAddr = CS.Address nr baseB
    -- | Increment 'BV' by given number of byte-steps.
    incBv :: Integer -> BV -> BV
    incBv k = op (BV.bitVec 64 (k * byteInc))
      where
        op = if reversed == 1 then (-) else (+)
    -- | Convert bit increment to byte increment.
    byteInc :: Integer
    byteInc =
      if natValue nr `mod` 8 /= 0
      then error "addressSequence: requested number of bits is not a multiple of 8!"
      else natValue nr `div` 8
    count, reversed :: Integer
    count = CS.nat countB
    reversed = CS.nat reversedB
addressSequence _ _ _ _ = error "addressSequence: undefined argument!"

------------------------------------------------------------------------

boolNatRepr :: NatRepr 1
boolNatRepr =  n1

extPrecisionNatRepr :: NatRepr 80
extPrecisionNatRepr = n80



------------------------------------------------------------------------
-- Helper functions ----------------------------------------------------
------------------------------------------------------------------------

doMux :: BV -> BV -> BV -> BV
doMux tst thn els = case BV.toBits tst of
  [b] -> if b then thn else els
  _   -> error "Impossible: type mismatch with BV"

sExtBV :: NatRepr n -> BV -> BV
sExtBV nr bv = BV.signExtend diff bv
  where
    diff = (fromInteger (natValue nr)) - BV.width bv

uExtBV :: NatRepr n -> BV -> BV
uExtBV nr bv = BV.zeroExtend diff bv
  where
    diff = (fromInteger (natValue nr)) - BV.width bv

upperBV :: NatRepr n -> BV -> BV
upperBV nr = BV.most (fromInteger (natValue nr) :: Int)

truncBV :: NatRepr n -> BV -> BV
truncBV nr = BV.least (fromInteger (natValue nr) :: Int)

bitIdx :: BV -> BV -> BV
bitIdx x i = BV.fromBool $ BV.index (BV.uint i) x


-- Wraps the result of a predicate into a BV
predBV :: (BV -> BV -> Bool) -> BV -> BV -> BV
predBV f a b = BV.fromBool $ f a b

isEvenParity :: BV -> BV
isEvenParity bv = BV.fromBool isEven
  where
    isEven = 0 == (trueCount `mod` 2)
    trueCount = length $ filter id (BV.toBits bv)

checkUadcOverflow :: BV -> BV -> BV -> BV
checkUadcOverflow a b carry = BV.fromBool didOverflow
  where
    didOverflow = total >= (2 ^ bitWidth)
    bitWidth = max (BV.width a) (BV.width b)
    total = sum $ map BV.uint [a,b,carry]

checkSadcOverflow :: BV -> BV -> BV -> BV
checkSadcOverflow a b carry = BV.fromBool didUnderOverflow
  where
    didUnderOverflow = total >= (2 ^ (bitWidth-1)) || total < (- (2 ^ (bitWidth-1)))
    bitWidth = max (BV.width a) (BV.width b)
    total = sum $ map BV.int [a,b,carry]

checkUsbbOverflow :: BV -> BV -> BV -> BV
checkUsbbOverflow a b borrow = BV.fromBool didUnderflow
  where
    didUnderflow = total < 0
    total = foldl1 (-) $ map BV.uint [a,b,borrow]

checkSsbbOverflow :: BV -> BV -> BV -> BV
checkSsbbOverflow a b borrow = BV.fromBool didUnderOverflow
  where
    didUnderOverflow = total >= (2 ^ (bitWidth-1)) || total < (- (2 ^ (bitWidth-1)))
    bitWidth = max (BV.width a) (BV.width b)
    total = foldl1 (-) $ map BV.int [a,b,borrow]

-- Index of least significant non-zero bit
bsf :: NatRepr n -> BV -> Maybe BV
bsf nr bv = case BV.nat bv of
  0 -> Nothing
  _ -> Just . BV.bitVec destWidth $ BV.lsb1 bv
  where
    destWidth = fromInteger $ natValue nr :: Int

-- Index of most significant non-zero bit
bsr :: NatRepr n -> BV -> Maybe BV
bsr nr bv = case BV.nat bv of
  0 -> Nothing
  _ -> Just . BV.bitVec destWidth $ BV.msb1 bv
  where
    destWidth = fromInteger $ natValue nr :: Int

truncateIfValid :: RealFloat a
                => NatRepr n -> a -> Integer
truncateIfValid nr c = if -(2^width) <= i || i < (2^width)
                          then i
                          else -1
  where
    i     = truncate c
    width = natValue nr


------------------------------------------------------------------------
-- Float madness

-- XXX For now we are punting on 16, 80, and 128 bit floats. We're just
-- using GHC's Float & Double types. We are also punting on rounding modes,
-- since we assume those will be rarely used and don't want to invest
-- energy if it is not necessary. We will just use the GHC default behavior,
-- which (I believe) is round-to-nearest. It is hard to find good information
-- about this though.

bvToFloat :: BV -> Float
bvToFloat = wordToFloat . fromInteger . BV.int

bvToDouble :: BV -> Double
bvToDouble = wordToDouble . fromInteger . BV.int

floatToBV :: Int -> Float -> BV
floatToBV width = BV.bitVec width . toInteger . floatToWord

doubleToBV :: Int -> Double -> BV
doubleToBV width = BV.bitVec width . toInteger . doubleToWord

liftFPtoBV :: (forall a. (RealFloat a) => (a -> Integer))
           -> FloatInfoRepr flt
           -> NatRepr n
           -> CS.Value (FloatType flt)
           -> CS.Value (BVType n)
liftFPtoBV f fr nr = CS.liftValue wrap nr
  where
    width = fromIntegral $ natValue nr
    --
    wrap :: BV -> BV
    wrap bv = case natValue (floatInfoBits fr) of
      32 -> BV.bitVec width $ f (bvToFloat bv)
      64 -> BV.bitVec width $ f (bvToDouble bv)
      _  -> error "Sorry, 32 or 64 bit floats only"

liftFP2 :: (forall a. (Floating a, Num a) => (a -> a -> a))
        -> FloatInfoRepr flt
        -> CS.Value (FloatType flt)
        -> CS.Value (FloatType flt)
        -> CS.Value (FloatType flt)
liftFP2 f fr = CS.liftValue2 wrap2 nr
  where
    nr = floatInfoBits fr
    --
    wrap2 :: BV -> BV -> BV
    wrap2 bv1 bv2 = case natValue nr of
      32 -> floatToBV w $ f (bvToFloat bv1) (bvToFloat bv2)
      64 -> doubleToBV w $ f (bvToDouble bv1) (bvToDouble bv2)
      _  -> error "Sorry, 32 or 64 bit floats only"
      where
        w = max (BV.width bv1) (BV.width bv2)

convertBVtoFP :: CS.Value (BVType n)
              -> FloatInfoRepr flt
              -> CS.Value (FloatType flt)
convertBVtoFP c fr = CS.liftValue wrap nr c
  where
    nr = floatInfoBits fr
    width = fromIntegral $ natValue nr
    --
    wrap :: BV -> BV
    wrap bv = case width of
      32 -> floatToBV width $ bvToFloat bv
      64 -> doubleToBV width $ bvToDouble bv
      _  -> error "Sorry, 32 or 64 bit floats only"

convertFP :: FloatInfoRepr flt1
          -> FloatInfoRepr flt2
          -> CS.Value (FloatType flt1)
          -> CS.Value (FloatType flt2)
convertFP fr1 fr2 = CS.liftValue wrap nr2
  where
    nr1 = floatInfoBits fr1
    nr2 = floatInfoBits fr2
    destWidth = fromIntegral $ natValue nr2
    --
    wrap :: BV -> BV
    wrap bv = case (natValue nr1, natValue nr2) of
      (32,64) -> doubleToBV destWidth $ float2Double (bvToFloat bv)
      (64,32) -> floatToBV destWidth $ double2Float (bvToDouble bv)
      _       -> error "Sorry, can only convert between 32 & 64 bit floats"


---
-- Predicates
---
liftFPPred :: (forall a. (RealFloat a) => (a -> Bool))
           -> FloatInfoRepr flt
           -> CS.Value (FloatType flt)
           -> CS.Value BoolType
liftFPPred f fr = liftFPtoBV f' fr boolNatRepr
  where
    f' :: (forall a. (RealFloat a) => (a -> Integer))
    f' x = if (f x) then 1 else 0

liftFPPred2 :: (forall a. (Eq a, Ord a) => (a -> a -> Bool))
            -> FloatInfoRepr flt
            -> CS.Value (FloatType flt)
            -> CS.Value (FloatType flt)
            -> CS.Value BoolType
liftFPPred2 f fr = CS.liftValue2 wrap2 boolNatRepr
  where
    wrap2 :: BV -> BV -> BV
    wrap2 bv1 bv2 = case natValue (floatInfoBits fr) of
      32 -> let fromBV :: BV -> Float
                fromBV = wordToFloat . fromInteger . BV.int
             in BV.fromBool $ f (fromBV bv1) (fromBV bv2)

      64 -> let fromBV :: BV -> Double
                fromBV = wordToDouble . fromInteger . BV.int
             in BV.fromBool $ f (fromBV bv1) (fromBV bv2)

      _  -> error "Sorry, 32 or 64 bit floats only"
