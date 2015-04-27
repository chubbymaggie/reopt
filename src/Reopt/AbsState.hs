{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeOperators #-}
module Reopt.AbsState
  ( AbsBlockState
  , absX86State
  , absBlockDiff
  , AbsValue(..)
  , ppAbsValue
  , abstractSingleton
  , concreteStackOffset
  , concretize
  , asConcreteSingleton
  , AbsDomain(..)
  , AbsRegs
  , absInitialRegs
  , initAbsRegs
  , absAssignments
  , finalAbsBlockState
  , addAssignment
  , addMemWrite
  , transferValue
  , transferRHS
  ) where

import Control.Applicative ( (<$>) )
import Control.Exception (assert)
import Control.Lens
import Control.Monad.State.Strict
import Data.Maybe
import Data.Map (Map)
import qualified Data.Map.Strict as Map
import Data.Parameterized.Map (MapF)
import qualified Data.Parameterized.Map as MapF
import Data.Parameterized.NatRepr
import Data.Parameterized.Some
import Data.Set (Set)
import qualified Data.Set as Set
import Numeric (showHex)
import Text.PrettyPrint.ANSI.Leijen hiding ((<$>))

import qualified Reopt.Semantics.StateNames as N
import Reopt.Semantics.Types
import Reopt.Semantics.Representation
import Reopt.X86State

------------------------------------------------------------------------
-- Abstract states


class Eq d => AbsDomain d where
  -- | The top element
  top :: d

  -- | A partial ordering over d.  forall x. x `leq` top
  leq :: d -> d -> Bool
  leq x y =
    case joinD y x of
      Nothing -> True
      Just _ -> False

  -- | Least upper bound (always defined, as we have top)
  lub :: d -> d -> d
  lub x y = case joinD x y of
              Nothing -> x
              Just r -> r

  -- | Join the old and new states and return the updated state iff
  -- the result is larger than the old state.
  joinD :: d -> d -> Maybe d
  joinD old new
    | new `leq` old = Nothing
    | otherwise     = Just $ lub old new

  {-# MINIMAL (top, ((leq,lub) | joinD)) #-}


type ValueSet = Set Integer

------------------------------------------------------------------------
-- AbsValue

data AbsValue (tp :: Type) where
  -- | An absolute value.
  AbsValue :: !ValueSet -> AbsValue (BVType n)
  -- | Offset of stack at beginning of the block.
  StackOffset :: !ValueSet -> AbsValue (BVType 64)
  -- | An address (doesn't constraint value precisely).
  SomeStackOffset :: AbsValue (BVType 64)
  -- | Any value
  TopV :: AbsValue tp

instance Eq (AbsValue tp) where
  AbsValue x    == AbsValue y    = x == y
  StackOffset s == StackOffset t = s == t
  SomeStackOffset          == SomeStackOffset          = True
  TopV          == TopV          = True
  _             ==               _ = False

instance EqF AbsValue where
  eqF = (==)

instance Pretty (AbsValue tp) where
  pretty (AbsValue s) = ppIntegerSet s
  pretty (StackOffset s) = text "rsp_0 +" <+> ppIntegerSet s
  pretty SomeStackOffset = text "rsp_0 + ?"
  pretty TopV = text "top"

ppIntegerSet :: (Show w, Integral w) => Set w -> Doc
ppIntegerSet vs = encloseSep lbrace rbrace comma (map ppv (Set.toList vs))
  where ppv v' = assert (v' >= 0) $ text ("0x" ++ showHex v' "")


-- | Returns a set of concrete integers that this value may be.
-- This function will neither return the complete set or an
-- known under-approximation.
concretize :: AbsValue tp -> Maybe (Set Integer)
concretize (AbsValue s) = Just s
concretize _ = Nothing

-- | Return single value is the abstract value can only take on one value.
asConcreteSingleton :: AbsValue tp -> Maybe Integer
asConcreteSingleton v =
  case Set.toList <$> concretize v of
    Just [e] -> Just e
    _ -> Nothing

instance AbsDomain (AbsValue tp) where
  top = TopV

{-
  leq _ TopV = True
  leq TopV _ = False
  leq (StackOffset s) (StackOffset t) = s `Set.isSubsetOf` t
  leq (AbsValue v) (AbsValue v') = v `Set.isSubsetOf` v'
  leq _ _ = False

  lub (StackOffset s) (StackOffset t) = StackOffset $ s `Set.union` t
  lub (AbsValue v) (AbsValue v') = AbsValue $ v `Set.union` v'
  lub _ _ = TopV
-}

  -- | Join the old and new states and return the updated state iff
  -- the result is larger than the old state.
  joinD TopV _ = Nothing
  joinD (AbsValue old) (AbsValue new)
      | new `Set.isSubsetOf` old = Nothing
      | Set.size r > 5 = Just TopV
      | otherwise = Just (AbsValue r)
    where r = Set.union old new
  joinD (StackOffset old) (StackOffset new)
      | new `Set.isSubsetOf` old = Nothing
      | Set.size r > 5 = Just TopV
      | otherwise = Just (StackOffset r)
    where r = Set.union old new

  -- Join addresses
  joinD SomeStackOffset StackOffset{} = Nothing
  joinD StackOffset{} SomeStackOffset = Just SomeStackOffset
  joinD SomeStackOffset SomeStackOffset = Nothing

  joinD _ _ = Just TopV

trunc :: (v+1 <= u)
      => AbsValue (BVType u)
      -> NatRepr v
      -> AbsValue (BVType v)
trunc (AbsValue s) w = AbsValue (Set.map (toUnsigned w) s)
trunc (StackOffset _) _ = TopV
trunc SomeStackOffset _ = TopV
trunc TopV _ = TopV

uext :: (u+1 <= v) => AbsValue (BVType u) -> NatRepr v -> AbsValue (BVType v)
uext (AbsValue s) _ = AbsValue s
uext (StackOffset _) _ = TopV
uext SomeStackOffset _ = TopV
uext TopV _ = TopV

bvadd :: NatRepr u
      -> AbsValue (BVType u)
      -> AbsValue (BVType u)
      -> AbsValue (BVType u)
bvadd w (StackOffset s) (AbsValue t) | [o] <- Set.toList t = do
  StackOffset $ Set.map (addOff w o) s
bvadd w (AbsValue t) (StackOffset s) | [o] <- Set.toList t = do
  StackOffset $ Set.map (addOff w o) s
bvadd _ StackOffset{} _ = SomeStackOffset
bvadd _ _ StackOffset{} = SomeStackOffset
bvadd _ SomeStackOffset _ = SomeStackOffset
bvadd _ _ SomeStackOffset = SomeStackOffset
bvadd _ _ _ = TopV

setL :: AbsValue (BVType n)
     -> (Set Integer -> AbsValue (BVType n))
     -> [Integer]
     -> AbsValue (BVType n)
setL def c l | length l > 5 = def
             | otherwise = c (Set.fromList l)

bvsub :: NatRepr u
      -> AbsValue (BVType u)
      -> AbsValue (BVType u)
      -> AbsValue (BVType u)
bvsub w (AbsValue s) (AbsValue t) = setL TopV AbsValue $ do
  x <- Set.toList s
  y <- Set.toList t
  return (toUnsigned w (x - y))
bvsub w (StackOffset s) (AbsValue t) = setL SomeStackOffset StackOffset $ do
  x <- Set.toList s
  y <- Set.toList t
  return (toUnsigned w (x - y))
bvsub _ StackOffset{} _ = SomeStackOffset
bvsub _ _ StackOffset{} = TopV
bvsub _ SomeStackOffset _ = SomeStackOffset
bvsub _ _ SomeStackOffset = TopV
bvsub _ TopV _ = TopV
bvsub _ _ TopV = TopV

bvmul :: NatRepr u
      -> AbsValue (BVType u)
      -> AbsValue (BVType u)
      -> AbsValue (BVType u)
bvmul w (AbsValue s) (AbsValue t) = setL TopV AbsValue $ do
  x <- Set.toList s
  y <- Set.toList t
  return (toUnsigned w (x * y))
bvmul _ _ _ = TopV

ppAbsValue :: AbsValue tp -> Maybe Doc
ppAbsValue TopV = Nothing
ppAbsValue v = Just (pretty v)

-- | Print a list of Docs vertically separated.
instance PrettyRegValue AbsValue where
  ppValueEq _ TopV = Nothing
  ppValueEq r v = Just (text (show r) <+> text "=" <+> pretty v)

abstractSingleton :: NatRepr n -> Integer -> AbsValue (BVType n)
abstractSingleton n i
  | 0 <= i && i <= maxUnsigned n = AbsValue (Set.singleton i)
  | otherwise = error $ "abstractSingleton given bad value: " ++ show i ++ " " ++ show n

concreteStackOffset :: Integer -> AbsValue (BVType 64)
concreteStackOffset o = StackOffset (Set.singleton o)

------------------------------------------------------------------------
-- AbsBlockState

data StackEntry where
  StackEntry :: TypeRepr tp -> AbsValue tp -> StackEntry

instance Eq StackEntry where
  StackEntry x_tp x_v == StackEntry y_tp y_v
    | Just Refl <- testEquality x_tp y_tp = x_v == y_v
    | otherwise = False


type AbsBlockStack = Map Integer StackEntry

absStackLeq :: AbsBlockStack -> AbsBlockStack -> Bool
absStackLeq x y = all entryLeq (Map.toList y)
  where entryLeq (o, StackEntry y_tp y_v) =
          case Map.lookup o x of
            Just (StackEntry x_tp x_v) | Just Refl <- testEquality x_tp y_tp ->
              leq x_v y_v
            _ -> False

absStackLub :: AbsBlockStack -> AbsBlockStack -> AbsBlockStack
absStackLub = Map.mergeWithKey merge (\_ -> Map.empty) (\_ -> Map.empty)
  where merge :: Integer -> StackEntry -> StackEntry -> Maybe StackEntry
        merge _ (StackEntry x_tp x_v) (StackEntry y_tp y_v) =
          case testEquality x_tp y_tp of
            Just Refl ->
              case lub x_v y_v of
                TopV -> Nothing
                v -> Just (StackEntry x_tp v)
            Nothing -> Nothing

ppAbsStack :: AbsBlockStack -> Doc
ppAbsStack m = vcat (pp <$> Map.toList m)
  where pp (o,StackEntry _ v) = text (show o) <+> text ":=" <+> pretty v

-- | State at beginning of a block.
data AbsBlockState
      = AbsBlockState { _absX86State :: !(X86State AbsValue)
                      , _startAbsStack :: !AbsBlockStack
                      }
  deriving Eq


absX86State :: Simple Lens AbsBlockState (X86State AbsValue)
absX86State = lens _absX86State (\s v -> s { _absX86State = v })

startAbsStack :: Simple Lens AbsBlockState AbsBlockStack
startAbsStack = lens _startAbsStack (\s v -> s { _startAbsStack = v })


instance AbsDomain AbsBlockState where
  top = AbsBlockState { _absX86State = mkX86State (\_ -> top)
                      , _startAbsStack = Map.empty
                      }

  leq x y =
    cmpX86State leq (x^.absX86State) (y^.absX86State)
      && absStackLeq (x^.startAbsStack) (y^.startAbsStack)

  lub x y =
    AbsBlockState { _absX86State   = zipWithX86State lub (x^.absX86State) (y^.absX86State)
                  , _startAbsStack = absStackLub (x^.startAbsStack) (y^.startAbsStack)
                  }

instance Pretty AbsBlockState where
  pretty s =
      text "registers:" <$$>
      indent 2 (pretty (s^.absX86State)) <$$>
      stack_d
    where stack = s^.startAbsStack
          stack_d | Map.null stack = empty
                  | otherwise = text "stack:" <$$>
                                indent 2 (ppAbsStack (s^.startAbsStack))

instance Show AbsBlockState where
  show s = show (pretty s)


absBlockDiff :: AbsBlockState -> AbsBlockState -> [Some N.RegisterName]
absBlockDiff x y = filter isDifferent x86StateRegisters
  where isDifferent (Some n) = x^.absX86State^.register n /= y^.absX86State^.register n

------------------------------------------------------------------------
-- AbsRegs

-- | This is used to cache all changes to a state within a block.
data AbsRegs = AbsRegs { absInitialRegs :: !(X86State AbsValue)
                       , _absAssignments :: !(MapF Assignment AbsValue)
                       , _curAbsStack :: !AbsBlockStack
                       }

initAbsRegs :: AbsBlockState -> AbsRegs
initAbsRegs s = AbsRegs { absInitialRegs = s^.absX86State
                        , _absAssignments = MapF.empty
                        , _curAbsStack = s^.startAbsStack
                        }

absAssignments :: Simple Lens AbsRegs (MapF Assignment AbsValue)
absAssignments = lens _absAssignments (\s v -> s { _absAssignments = v })

curAbsStack :: Simple Lens AbsRegs AbsBlockStack
curAbsStack = lens _curAbsStack (\s v -> s { _curAbsStack = v })

addAssignment :: Assignment tp -> AbsRegs -> AbsRegs
addAssignment a c = c & absAssignments %~ MapF.insert a (transferRHS c (assignRhs a))

deleteRange :: Integer -> Integer -> Map Integer v -> Map Integer v
deleteRange l h m
  | h < l = m
  | otherwise =
    case Map.lookupGE l m of
      Just (k,_) | k <= h -> deleteRange (k+1) h (Map.delete k m)
      _ -> m

someValueWidth :: Value tp -> Integer
someValueWidth v =
  case valueType v of
    BVTypeRepr w -> natValue w

addMemWrite :: Value (BVType 64) -> Value tp -> AbsRegs -> AbsRegs
addMemWrite a v r =
  case (transferValue r a, transferValue r v) of
    (_,TopV) -> r
    (StackOffset s, v_abs) | [o] <- Set.toList s -> do
      let w = someValueWidth v
          e = StackEntry (valueType v) v_abs
       in r & curAbsStack %~ Map.insert o e . deleteRange o (o+w-1)
    _ -> r

addOff :: NatRepr w -> Integer -> Integer -> Integer
addOff w o v = toUnsigned w (o + v)

subOff :: NatRepr w -> Integer -> Integer -> Integer
subOff w o v = toUnsigned w (o - v)

resetRSP :: (N.RegisterName cl -> AbsValue (N.RegisterType cl))
         -> (N.RegisterName cl -> AbsValue (N.RegisterType cl))
resetRSP otherFn r
  | Just Refl <- testEquality r N.rsp = concreteStackOffset 0
  | otherwise = otherFn r

-- | Return state for after value has run.
finalAbsBlockState :: AbsRegs -> X86State Value -> AbsBlockState
finalAbsBlockState c s = do
  let mkState :: (forall cl . N.RegisterName cl -> AbsValue (N.RegisterType cl))
              -> AbsBlockStack
              -> AbsBlockState
      mkState trans newStack =
        AbsBlockState { _absX86State = mkX86State (resetRSP trans)
                      , _startAbsStack = newStack
                      }
  case transferValue c (s^.register N.rsp) of
    StackOffset offsets | [0] <- Set.toList offsets ->
      let transferReg :: N.RegisterName cl -> AbsValue (N.RegisterType cl)
          transferReg r = transferValue c (s^.register r)
       in mkState transferReg (c^.curAbsStack)
    StackOffset offsets | [o] <- Set.toList offsets ->
      let transferReg :: N.RegisterName cl -> AbsValue (N.RegisterType cl)
          transferReg r =
            case transferValue c (s^.register r) of
              StackOffset t -> StackOffset (Set.map (\v -> subOff n64 v o) t)
              v -> v
          newStack = Map.fromList $
            [ (subOff n64 a o, v) | (a,v) <- Map.toList (c^.curAbsStack) ]
       in mkState transferReg newStack
    SomeStackOffset ->
      let transferReg :: N.RegisterName cl -> AbsValue (N.RegisterType cl)
          transferReg r =
            case transferValue c (s^.register r) of
              StackOffset _ -> SomeStackOffset
              v -> v
       in mkState transferReg Map.empty
    _ ->
      let transferReg :: N.RegisterName cl -> AbsValue (N.RegisterType cl)
          transferReg r =
            case transferValue c (s^.register r) of
              StackOffset _ -> TopV
              SomeStackOffset -> TopV
              v -> v
       in mkState transferReg Map.empty

------------------------------------------------------------------------
-- Transfer functions

transferValue :: AbsRegs
              -> Value tp
              -> AbsValue tp
transferValue c v =
  case v of
   BVValue w i
     | 0 <= i && i <= maxUnsigned w -> abstractSingleton w i
     | otherwise -> error $ "transferValue given illegal value " ++ show (pretty v)
   -- Invariant: v is in m
   AssignedValue a ->
     fromMaybe (error $ "Missing assignment for " ++ show (assignId a))
               (MapF.lookup a (c^.absAssignments))
   Initial r
     | Just Refl <- testEquality r N.rsp -> do
       StackOffset (Set.singleton 0)
     | otherwise -> absInitialRegs c ^. register r

transferApp :: AbsRegs
            -> App Value tp
            -> AbsValue tp
transferApp r a =
  case a of
    Trunc v w -> trunc (transferValue r v) w
    UExt  v w -> uext  (transferValue r v) w
    BVAdd w x y -> bvadd w (transferValue r x) (transferValue r y)
    BVSub w x y -> bvsub w (transferValue r x) (transferValue r y)
    BVMul w x y -> bvmul w (transferValue r x) (transferValue r y)
    _ -> top

transferRHS :: forall tp
            .  AbsRegs
            -> AssignRhs tp
            -> AbsValue tp
transferRHS r rhs =
  case rhs of
    EvalApp app    -> transferApp r app
    SetUndefined _ -> top
    Read (MemLoc a tp)
      | StackOffset s <- transferValue r a
      , [o] <- Set.toList s
      , Just (StackEntry v_tp v) <- Map.lookup o (r^.curAbsStack)
      , Just Refl <- testEquality tp v_tp ->
         v
    Read _ -> top