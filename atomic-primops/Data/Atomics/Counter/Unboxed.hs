{-# LANGUAGE BangPatterns, MagicHash, UnboxedTuples, CPP #-}

-- | This should be the most efficient implementation of atomic counters.
--   You probably don't need the others!  (Except for testing/debugging.)

module Data.Atomics.Counter.Unboxed
       (AtomicCounter, CTicket,
        newCounter, readCounterForCAS, readCounter, peekCTicket,
        writeCounter, casCounter, incrCounter, incrCounter_)
       where

import GHC.Ptr
import Data.Atomics          (casByteArrayInt)
-- import Data.Atomics.Internal (casIntArray#, fetchAddIntArray#)
import Data.Atomics.Internal
#if MIN_VERSION_base(4,7,0)
import GHC.Base  hiding ((==#))
import GHC.Prim hiding ((==#))
import qualified GHC.PrimopWrappers as GPW
#else
import GHC.Base
import GHC.Prim
#endif


-- GHC 7.8 changed some primops
#if MIN_VERSION_base(4,7,0)
(==#) :: Int# -> Int# -> Bool
(==#) x y = case x GPW.==# y of { 0# -> False; _ -> True }
#endif



#ifndef __GLASGOW_HASKELL__
#error "Unboxed Counter: this library is not portable to other Haskell's"
#endif

#include "MachDeps.h"
#ifndef SIZEOF_HSINT
#define SIZEOF_HSINT  INT_SIZE_IN_BYTES
#endif

-- We try to avoid false sharing by padding the Int we modify with two x86-size
-- cache line sizes, so that no matter how it's aligned the counter will always
-- take up an entire cache line.
sIZEOF_2CACHELINES, cACHELINE_PADDED_IX :: Int
sIZEOF_2CACHELINES = 128 -- bytes
cACHELINE_PADDED_IX = 64 `quot` SIZEOF_HSINT

-- | The type of mutable atomic counters.
data AtomicCounter = AtomicCounter (MutableByteArray# RealWorld)

-- | You should not depend on this type.  It varies between different implementations
-- of atomic counters.
type CTicket = Int
-- TODO: Could newtype this.

-- | Create a new counter initialized to the given value.
{-# INLINE newCounter #-}
newCounter :: Int -> IO AtomicCounter
newCounter n = do
  c <- newRawCounter
  writeCounter c n -- Non-atomic is ok; it hasn't been released into the wild.
  return c

-- | Create a new, uninitialized counter.
{-# INLINE newRawCounter #-}
newRawCounter :: IO AtomicCounter  
newRawCounter = IO $ \s ->
  case newByteArray# size s of { (# s, arr #) ->
  (# s, AtomicCounter arr #) }
  where !(I# size) = sIZEOF_2CACHELINES

{-# INLINE readCounter #-}
-- | Equivalent to `readCounterForCAS` followed by `peekCTicket`.        
readCounter :: AtomicCounter -> IO Int
readCounter (AtomicCounter arr) = IO $ \s ->
  case readIntArray# arr ix s of { (# s, i #) ->
  (# s, I# i #) }
  where !(I# ix) = cACHELINE_PADDED_IX

{-# INLINE writeCounter #-}
-- | Make a non-atomic write to the counter.  No memory-barrier.
writeCounter :: AtomicCounter -> Int -> IO ()
writeCounter (AtomicCounter arr) (I# i) = IO $ \s ->
  case writeIntArray# arr ix i s of { s ->
  (# s, () #) }
  where !(I# ix) = cACHELINE_PADDED_IX

{-# INLINE readCounterForCAS #-}
-- | Just like the "Data.Atomics" CAS interface, this routine returns an opaque
-- ticket that can be used in CAS operations.  Except for the difference in return
-- type, the semantics of this are the same as `readCounter`.
readCounterForCAS :: AtomicCounter -> IO CTicket
readCounterForCAS = readCounter

{-# INLINE peekCTicket #-}
-- | Opaque tickets cannot be constructed, but they can be destructed into values.
peekCTicket :: CTicket -> Int
peekCTicket !x = x

{-# INLINE casCounter #-}
-- | Compare and swap for the counter ADT.  Similar behavior to
-- `Data.Atomics.casIORef`, in particular, in both success and failure cases it
-- returns a ticket that you should use for the next attempt.  (That is, in the
-- success case, it actually returns the new value that you provided as input, but in
-- ticket form.)
casCounter :: AtomicCounter -> CTicket -> Int -> IO (Bool, CTicket)
-- casCounter (AtomicCounter barr) !old !new =
casCounter (AtomicCounter mba#) (I# old#) newBox@(I# new#) = IO$ \s1# ->
  let (# s2#, res# #) = casIntArray# mba# ix old# new# s1# in
  case res# ==# old# of 
    False -> (# s2#, (False, I# res# ) #) -- Failure
    True  -> (# s2#, (True , newBox ) #) -- Success
  where !(I# ix) = cACHELINE_PADDED_IX

{-# INLINE sameCTicket #-}
sameCTicket :: CTicket -> CTicket -> Bool
sameCTicket = (==)

{-# INLINE incrCounter #-}
-- | Increment the counter by a given amount.  Returns the value AFTER the increment
--   (in contrast with the behavior of the underlying instruction on architectures
--   like x86.)
--                 
--   Note that UNLIKE with boxed implementations of counters, where increment is
--   based on CAS, this increment is /O(1)/.  Fetch-and-add does not require a retry
--   loop like CAS.
incrCounter :: Int -> AtomicCounter -> IO Int
incrCounter (I# incr#) (AtomicCounter mba#) = IO $ \ s1# -> 
  let (# s2#, res #) = fetchAddIntArray# mba# ix incr# s1# in
  (# s2#, (I# res) #)
  where !(I# ix) = cACHELINE_PADDED_IX

{-# INLINE incrCounter_ #-}
-- | An alternate version for when you don't care about the old value.
incrCounter_ :: Int -> AtomicCounter -> IO ()
incrCounter_ (I# incr#) (AtomicCounter mba#) = IO $ \ s1# -> 
  let (# s2#, res #) = fetchAddIntArray# mba# ix incr# s1# in
  (# s2#, () #)
  where !(I# ix) = cACHELINE_PADDED_IX
