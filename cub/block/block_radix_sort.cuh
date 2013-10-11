/******************************************************************************
 * Copyright (c) 2011, Duane Merrill.  All rights reserved.
 * Copyright (c) 2011-2013, NVIDIA CORPORATION.  All rights reserved.
 * 
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *     * Redistributions of source code must retain the above copyright
 *       notice, this list of conditions and the following disclaimer.
 *     * Redistributions in binary form must reproduce the above copyright
 *       notice, this list of conditions and the following disclaimer in the
 *       documentation and/or other materials provided with the distribution.
 *     * Neither the name of the NVIDIA CORPORATION nor the
 *       names of its contributors may be used to endorse or promote products
 *       derived from this software without specific prior written permission.
 * 
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 * WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 * DISCLAIMED. IN NO EVENT SHALL NVIDIA CORPORATION BE LIABLE FOR ANY
 * DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 * (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 * LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 * ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 * SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 *
 ******************************************************************************/

/**
 * \file
 * The cub::BlockRadixSort class provides [<em>collective</em>](index.html#sec0) methods for radix sorting of items partitioned across a CUDA thread block.
 */


#pragma once

#include "../util_namespace.cuh"
#include "../util_arch.cuh"
#include "../util_type.cuh"
#include "block_exchange.cuh"
#include "block_radix_rank.cuh"

/// Optional outer namespace(s)
CUB_NS_PREFIX

/// CUB namespace
namespace cub {

/**
 * \brief The cub::BlockRadixSort class provides [<em>collective</em>](index.html#sec0) methods for sorting items partitioned across a CUDA thread block using a radix sorting method.  ![](sorting_logo.png)
 * \ingroup BlockModule
 *
 * \par Overview
 * The [<em>radix sorting method</em>](http://en.wikipedia.org/wiki/Radix_sort) arranges
 * items into ascending order.  It relies upon a positional representation for
 * keys, i.e., each key is comprised of an ordered sequence of symbols (e.g., digits,
 * characters, etc.) specified from least-significant to most-significant.  For a
 * given input sequence of keys and a set of rules specifying a total ordering
 * of the symbolic alphabet, the radix sorting method produces a lexicographic
 * ordering of those keys.
 *
 * \par
 * BlockRadixSort can sort all of the built-in C++ numeric primitive types, e.g.:
 * <tt>unsigned char</tt>, \p int, \p double, etc.  Within each key, the implementation treats fixed-length
 * bit-sequences of \p RADIX_BITS as radix digit places.  Although the direct radix sorting
 * method can only be applied to unsigned integral types, BlockRadixSort
 * is able to sort signed and floating-point types via simple bit-wise transformations
 * that ensure lexicographic key ordering.
 *
 * \tparam Key                  Key type
 * \tparam BLOCK_THREADS        The thread block size in threads
 * \tparam ITEMS_PER_THREAD     The number of items per thread
 * \tparam Value                <b>[optional]</b> Value type (default: cub::NullType, which indicates a keys-only sort)
 * \tparam RADIX_BITS           <b>[optional]</b> The number of radix bits per digit place (default: 4 bits)
 * \tparam MEMOIZE_OUTER_SCAN   <b>[optional]</b> Whether or not to buffer outer raking scan partials to incur fewer shared memory reads at the expense of higher register pressure (default: true for architectures SM35 and newer, false otherwise).
 * \tparam INNER_SCAN_ALGORITHM <b>[optional]</b> The cub::BlockScanAlgorithm algorithm to use (default: cub::BLOCK_SCAN_WARP_SCANS)
 * \tparam SMEM_CONFIG          <b>[optional]</b> Shared memory bank mode (default: \p cudaSharedMemBankSizeFourByte)
 *
 * \par A Simple Example
 * \blockcollective{BlockRadixSort}
 * \par
 * The code snippet below illustrates a sort of 512 integer keys that
 * are partitioned in a [<em>blocked arrangement</em>](index.html#sec5sec4) across 128 threads
 * where each thread owns 4 consecutive items.
 * \par
 * \code
 * #include <cub/cub.cuh>
 *
 * __global__ void ExampleKernel(...)
 * {
 *     // Specialize BlockRadixSort for 128 threads owning 4 integer items each
 *     typedef cub::BlockRadixSort<int, 128, 4> BlockRadixSort;
 *
 *     // Allocate shared memory for BlockRadixSort
 *     __shared__ typename BlockRadixSort::TempStorage temp_storage;
 *
 *     // Obtain a segment of consecutive items that are blocked across threads
 *     int thread_keys[4];
 *     ...
 *
 *     // Collectively sort the keys
 *     BlockRadixSort(temp_storage).Sort(thread_keys);
 *
 *     ...
 * \endcode
 * \par
 * Suppose the set of input \p thread_keys across the block of threads is
 * <tt>{ [0,511,1,510], [2,509,3,508], [4,507,5,506], ..., [254,257,255,256] }</tt>.  The
 * corresponding output \p thread_keys in those threads will be
 * <tt>{ [0,1,2,3], [4,5,6,7], [8,9,10,11], ..., [508,509,510,511] }</tt>.
 *
 */
template <
    typename                Key,
    int                     BLOCK_THREADS,
    int                     ITEMS_PER_THREAD,
    typename                Value                   = NullType,
    int                     RADIX_BITS              = 4,
    bool                    MEMOIZE_OUTER_SCAN      = (CUB_PTX_VERSION >= 350) ? true : false,
    BlockScanAlgorithm      INNER_SCAN_ALGORITHM    = BLOCK_SCAN_WARP_SCANS,
    cudaSharedMemConfig     SMEM_CONFIG             = cudaSharedMemBankSizeFourByte>
class BlockRadixSort
{
private:

    /******************************************************************************
     * Constants and type definitions
     ******************************************************************************/

    enum
    {
        KEYS_ONLY = Equals<Value, NullType>::VALUE,
    };

    // Key traits and unsigned bits type
    typedef NumericTraits<Key>                  KeyTraits;
    typedef typename KeyTraits::UnsignedBits    UnsignedBits;

    /// Ascending BlockRadixRank utility type
    typedef BlockRadixRank<
            BLOCK_THREADS,
            RADIX_BITS,
            false,
            MEMOIZE_OUTER_SCAN,
            INNER_SCAN_ALGORITHM,
            SMEM_CONFIG>
        AscendingBlockRadixRank;

    /// Descending BlockRadixRank utility type
    typedef BlockRadixRank<
            BLOCK_THREADS,
            RADIX_BITS,
            true,
            MEMOIZE_OUTER_SCAN,
            INNER_SCAN_ALGORITHM,
            SMEM_CONFIG>
        DescendingBlockRadixRank;

    /// BlockExchange utility type for keys
    typedef BlockExchange<Key, BLOCK_THREADS, ITEMS_PER_THREAD> BlockExchangeKeys;

    /// BlockExchange utility type for values
    typedef BlockExchange<Value, BLOCK_THREADS, ITEMS_PER_THREAD> BlockExchangeValues;

    /// Shared memory storage layout type
    struct _TempStorage
    {
        union
        {
            typename AscendingBlockRadixRank::TempStorage  asending_ranking_storage;
            typename DescendingBlockRadixRank::TempStorage descending_ranking_storage;
            typename BlockExchangeKeys::TempStorage        exchange_keys;
            typename BlockExchangeValues::TempStorage      exchange_values;
        };
    };


    /******************************************************************************
     * Thread fields
     ******************************************************************************/

    /// Shared storage reference
    _TempStorage &temp_storage;

    /// Linear thread-id
    int linear_tid;

    /******************************************************************************
     * Utility methods
     ******************************************************************************/

    /// Internal storage allocator
    __device__ __forceinline__ _TempStorage& PrivateStorage()
    {
        __shared__ _TempStorage private_storage;
        return private_storage;
    }

    /// Rank keys (specialized for ascending sort)
    __device__ __forceinline__ void RankKeys(
        UnsignedBits    (&unsigned_keys)[ITEMS_PER_THREAD],
        int             (&ranks)[ITEMS_PER_THREAD],
        int             begin_bit,
        Int2Type<false> is_descending)
    {
        AscendingBlockRadixRank(temp_storage.asending_ranking_storage, linear_tid).RankKeys(
            unsigned_keys,
            ranks,
            begin_bit);
    }

    /// Rank keys (specialized for descending sort)
    __device__ __forceinline__ void RankKeys(
        UnsignedBits    (&unsigned_keys)[ITEMS_PER_THREAD],
        int             (&ranks)[ITEMS_PER_THREAD],
        int             begin_bit,
        Int2Type<true>  is_descending)
    {
        DescendingBlockRadixRank(temp_storage.descending_ranking_storage, linear_tid).RankKeys(
            unsigned_keys,
            ranks,
            begin_bit);
    }

    /// ExchangeValues (specialized for key-value sort, to-blocked arrangement)
    __device__ __forceinline__ void ExchangeValues(
        Value           (&values)[ITEMS_PER_THREAD],
        int             (&ranks)[ITEMS_PER_THREAD],
        Int2Type<false> is_keys_only,
        Int2Type<true>  is_blocked)
    {
        __syncthreads();

        // Exchange values through shared memory in blocked arrangement
        BlockExchangeValues(temp_storage.exchange_values, linear_tid).ScatterToBlocked(values, ranks);
    }

    /// ExchangeValues (specialized for key-value sort, to-striped arrangement)
    __device__ __forceinline__ void ExchangeValues(
        Value           (&values)[ITEMS_PER_THREAD],
        int             (&ranks)[ITEMS_PER_THREAD],
        Int2Type<false> is_keys_only,
        Int2Type<false> is_blocked)
    {
        __syncthreads();

        // Exchange values through shared memory in blocked arrangement
        BlockExchangeValues(temp_storage.exchange_values, linear_tid).ScatterToStriped(values, ranks);
    }

    /// ExchangeValues (specialized for keys-only sort)
    template <int IS_BLOCKED>
    __device__ __forceinline__ void ExchangeValues(
        Value                   (&values)[ITEMS_PER_THREAD],
        int                     (&ranks)[ITEMS_PER_THREAD],
        Int2Type<true>          is_keys_only,
        Int2Type<IS_BLOCKED>    is_blocked)
    {}

    /// Sort blocked arrangement
    template <int DESCENDING, int KEYS_ONLY>
    __device__ __forceinline__ void SortBlocked(
        Key                     (&keys)[ITEMS_PER_THREAD],          ///< Keys to sort
        Value                   (&values)[ITEMS_PER_THREAD],        ///< Values to sort
        int                     begin_bit,                          ///< The beginning (least-significant) bit index needed for key comparison
        int                     end_bit,                            ///< The past-the-end (most-significant) bit index needed for key comparison
        Int2Type<DESCENDING>    is_descending,                      ///< Tag whether is a descending-order sort
        Int2Type<KEYS_ONLY>     is_keys_only)                       ///< Tag whether is keys-only sort
    {
        UnsignedBits (&unsigned_keys)[ITEMS_PER_THREAD] =
            reinterpret_cast<UnsignedBits (&)[ITEMS_PER_THREAD]>(keys);

        // Twiddle bits if necessary
        #pragma unroll
        for (int KEY = 0; KEY < ITEMS_PER_THREAD; KEY++)
        {
            unsigned_keys[KEY] = KeyTraits::TwiddleIn(unsigned_keys[KEY]);
        }

        // Radix sorting passes
        while (true)
        {
            // Rank the blocked keys
            int ranks[ITEMS_PER_THREAD];
            RankKeys(unsigned_keys, ranks, begin_bit, is_descending);
            begin_bit += RADIX_BITS;

            __syncthreads();

            // Exchange keys through shared memory in blocked arrangement
            BlockExchangeKeys(temp_storage.exchange_keys, linear_tid).ScatterToBlocked(keys, ranks);

            // Exchange values through shared memory in blocked arrangement
            ExchangeValues(values, ranks, is_keys_only, Int2Type<true>());

            // Quit if done
            if (begin_bit >= end_bit) break;

            __syncthreads();
        }

        // Untwiddle bits if necessary
        #pragma unroll
        for (int KEY = 0; KEY < ITEMS_PER_THREAD; KEY++)
        {
            unsigned_keys[KEY] = KeyTraits::TwiddleOut(unsigned_keys[KEY]);
        }
    }

    /// Sort blocked -> striped arrangement
    template <int DESCENDING, int KEYS_ONLY>
    __device__ __forceinline__ void SortBlockedToStriped(
        Key                     (&keys)[ITEMS_PER_THREAD],          ///< Keys to sort
        Value                   (&values)[ITEMS_PER_THREAD],        ///< Values to sort
        int                     begin_bit,                          ///< The beginning (least-significant) bit index needed for key comparison
        int                     end_bit,                            ///< The past-the-end (most-significant) bit index needed for key comparison
        Int2Type<DESCENDING>    is_descending,                      ///< Tag whether is a descending-order sort
        Int2Type<KEYS_ONLY>     is_keys_only)                       ///< Tag whether is keys-only sort
    {
        UnsignedBits (&unsigned_keys)[ITEMS_PER_THREAD] =
            reinterpret_cast<UnsignedBits (&)[ITEMS_PER_THREAD]>(keys);

        // Twiddle bits if necessary
        #pragma unroll
        for (int KEY = 0; KEY < ITEMS_PER_THREAD; KEY++)
        {
            unsigned_keys[KEY] = KeyTraits::TwiddleIn(unsigned_keys[KEY]);
        }

        // Radix sorting passes
        while (true)
        {
            // Rank the blocked keys
            int ranks[ITEMS_PER_THREAD];
            RankKeys(unsigned_keys, ranks, begin_bit, is_descending);
            begin_bit += RADIX_BITS;

            __syncthreads();

            // Check if this is the last pass
            if (begin_bit >= end_bit)
            {
                // Last pass exchanges keys through shared memory in striped arrangement
                BlockExchangeKeys(temp_storage.exchange_keys, linear_tid).ScatterToStriped(keys, ranks);

                // Last pass exchanges through shared memory in striped arrangement
                ExchangeValues(values, ranks, is_keys_only, Int2Type<false>());

                // Quit
                break;
            }

            // Exchange keys through shared memory in blocked arrangement
            BlockExchangeKeys(temp_storage.exchange_keys, linear_tid).ScatterToBlocked(keys, ranks);

            // Exchange values through shared memory in blocked arrangement
            ExchangeValues(values, ranks, is_keys_only, Int2Type<true>());

            __syncthreads();
        }

        // Untwiddle bits if necessary
        #pragma unroll
        for (int KEY = 0; KEY < ITEMS_PER_THREAD; KEY++)
        {
            unsigned_keys[KEY] = KeyTraits::TwiddleOut(unsigned_keys[KEY]);
        }
    }



public:

    /// \smemstorage{BlockScan}
    struct TempStorage : Uninitialized<_TempStorage> {};


    /******************************************************************//**
     * \name Collective constructors
     *********************************************************************/
    //@{

    /**
     * \brief Collective constructor for 1D thread blocks using a private static allocation of shared memory as temporary storage.  Threads are identified using <tt>threadIdx.x</tt>.
     */
    __device__ __forceinline__ BlockRadixSort()
    :
        temp_storage(PrivateStorage()),
        linear_tid(threadIdx.x)
    {}


    /**
     * \brief Collective constructor for 1D thread blocks using the specified memory allocation as temporary storage.  Threads are identified using <tt>threadIdx.x</tt>.
     */
    __device__ __forceinline__ BlockRadixSort(
        TempStorage &temp_storage)             ///< [in] Reference to memory allocation having layout type TempStorage
    :
        temp_storage(temp_storage.Alias()),
        linear_tid(threadIdx.x)
    {}


    /**
     * \brief Collective constructor using a private static allocation of shared memory as temporary storage.  Each thread is identified using the supplied linear thread identifier
     */
    __device__ __forceinline__ BlockRadixSort(
        int linear_tid)                        ///< [in] A suitable 1D thread-identifier for the calling thread (e.g., <tt>(threadIdx.y * blockDim.x) + linear_tid</tt> for 2D thread blocks)
    :
        temp_storage(PrivateStorage()),
        linear_tid(linear_tid)
    {}


    /**
     * \brief Collective constructor using the specified memory allocation as temporary storage.  Each thread is identified using the supplied linear thread identifier.
     */
    __device__ __forceinline__ BlockRadixSort(
        TempStorage &temp_storage,             ///< [in] Reference to memory allocation having layout type TempStorage
        int linear_tid)                        ///< [in] <b>[optional]</b> A suitable 1D thread-identifier for the calling thread (e.g., <tt>(threadIdx.y * blockDim.x) + linear_tid</tt> for 2D thread blocks)
    :
        temp_storage(temp_storage.Alias()),
        linear_tid(linear_tid)
    {}



    //@}  end member group
    /******************************************************************//**
     * \name Sorting (blocked arrangements)
     *********************************************************************/
    //@{

    /**
     * \brief Performs an ascending block-wide radix sort over a [<em>blocked arrangement</em>](index.html#sec5sec4) of keys.
     *
     * \smemreuse
     *
     * The code snippet below illustrates a sort of 512 integer keys that
     * are partitioned in a [<em>blocked arrangement</em>](index.html#sec5sec4) across 128 threads
     * where each thread owns 4 consecutive keys.
     * \par
     * \code
     * #include <cub/cub.cuh>
     *
     * __global__ void ExampleKernel(...)
     * {
     *     // Specialize BlockRadixSort for 128 threads owning 4 integer keys each
     *     typedef cub::BlockRadixSort<int, 128, 4> BlockRadixSort;
     *
     *     // Allocate shared memory for BlockRadixSort
     *     __shared__ typename BlockRadixSort::TempStorage temp_storage;
     *
     *     // Obtain a segment of consecutive items that are blocked across threads
     *     int thread_keys[4];
     *     ...
     *
     *     // Collectively sort the keys
     *     BlockRadixSort(temp_storage).Sort(thread_keys);
     *
     * \endcode
     * \par
     * Suppose the set of input \p thread_keys across the block of threads is
     * <tt>{ [0,511,1,510], [2,509,3,508], [4,507,5,506], ..., [254,257,255,256] }</tt>.
     * The corresponding output \p thread_keys in those threads will be
     * <tt>{ [0,1,2,3], [4,5,6,7], [8,9,10,11], ..., [508,509,510,511] }</tt>.
     */
    __device__ __forceinline__ void Sort(
        Key     (&keys)[ITEMS_PER_THREAD],          ///< [in-out] Keys to sort
        int     begin_bit   = 0,                    ///< [in] <b>[optional]</b> The beginning (least-significant) bit index needed for key comparison
        int     end_bit     = sizeof(Key) * 8)      ///< [in] <b>[optional]</b> The past-the-end (most-significant) bit index needed for key comparison
    {
        NullType values[ITEMS_PER_THREAD];

        SortBlocked(keys, values, begin_bit, end_bit, Int2Type<false>(), Int2Type<KEYS_ONLY>());
    }


    /**
     * \brief Performs an ascending block-wide radix sort across a [<em>blocked arrangement</em>](index.html#sec5sec4) of keys and values.
     *
     * BlockRadixSort can only accommodate one associated tile of values. To "truck along"
     * more than one tile of values, simply perform a key-value sort of the keys paired
     * with a temporary value array that enumerates the key indices.  The reordered indices
     * can then be used as a gather-vector for exchanging other associated tile data through
     * shared memory.
     *
     * \smemreuse
     *
     * The code snippet below illustrates a sort of 512 integer keys and values that
     * are partitioned in a [<em>blocked arrangement</em>](index.html#sec5sec4) across 128 threads
     * where each thread owns 4 consecutive pairs.
     * \par
     * \code
     * #include <cub/cub.cuh>
     *
     * __global__ void ExampleKernel(...)
     * {
     *     // Specialize BlockRadixSort for 128 threads owning 4 integer keys and values each
     *     typedef cub::BlockRadixSort<int, 128, 4, int> BlockRadixSort;
     *
     *     // Allocate shared memory for BlockRadixSort
     *     __shared__ typename BlockRadixSort::TempStorage temp_storage;
     *
     *     // Obtain a segment of consecutive items that are blocked across threads
     *     int thread_keys[4];
     *     int thread_values[4];
     *     ...
     *
     *     // Collectively sort the keys and values among block threads
     *     BlockRadixSort(temp_storage).Sort(thread_keys, thread_values);
     *
     * \endcode
     * \par
     * Suppose the set of input \p thread_keys across the block of threads is
     * <tt>{ [0,511,1,510], [2,509,3,508], [4,507,5,506], ..., [254,257,255,256] }</tt>.  The
     * corresponding output \p thread_keys in those threads will be
     * <tt>{ [0,1,2,3], [4,5,6,7], [8,9,10,11], ..., [508,509,510,511] }</tt>.
     *
     */
    __device__ __forceinline__ void Sort(
        Key     (&keys)[ITEMS_PER_THREAD],          ///< [in-out] Keys to sort
        Value   (&values)[ITEMS_PER_THREAD],        ///< [in-out] Values to sort
        int     begin_bit   = 0,                    ///< [in] <b>[optional]</b> The beginning (least-significant) bit index needed for key comparison
        int     end_bit     = sizeof(Key) * 8)      ///< [in] <b>[optional]</b> The past-the-end (most-significant) bit index needed for key comparison
    {
        SortBlocked(keys, values, begin_bit, end_bit, Int2Type<false>(), Int2Type<KEYS_ONLY>());
    }

    /**
     * \brief Performs a descending block-wide radix sort over a [<em>blocked arrangement</em>](index.html#sec5sec4) of keys.
     *
     * \smemreuse
     *
     * The code snippet below illustrates a sort of 512 integer keys that
     * are partitioned in a [<em>blocked arrangement</em>](index.html#sec5sec4) across 128 threads
     * where each thread owns 4 consecutive keys.
     * \par
     * \code
     * #include <cub/cub.cuh>
     *
     * __global__ void ExampleKernel(...)
     * {
     *     // Specialize BlockRadixSort for 128 threads owning 4 integer keys each
     *     typedef cub::BlockRadixSort<int, 128, 4> BlockRadixSort;
     *
     *     // Allocate shared memory for BlockRadixSort
     *     __shared__ typename BlockRadixSort::TempStorage temp_storage;
     *
     *     // Obtain a segment of consecutive items that are blocked across threads
     *     int thread_keys[4];
     *     ...
     *
     *     // Collectively sort the keys
     *     BlockRadixSort(temp_storage).Sort(thread_keys);
     *
     * \endcode
     * \par
     * Suppose the set of input \p thread_keys across the block of threads is
     * <tt>{ [0,511,1,510], [2,509,3,508], [4,507,5,506], ..., [254,257,255,256] }</tt>.
     * The corresponding output \p thread_keys in those threads will be
     * <tt>{ [511,510,509,508], [11,10,9,8], [7,6,5,4], ..., [3,2,1,0] }</tt>.
     */
    __device__ __forceinline__ void SortDescending(
        Key     (&keys)[ITEMS_PER_THREAD],          ///< [in-out] Keys to sort
        int     begin_bit   = 0,                    ///< [in] <b>[optional]</b> The beginning (least-significant) bit index needed for key comparison
        int     end_bit     = sizeof(Key) * 8)      ///< [in] <b>[optional]</b> The past-the-end (most-significant) bit index needed for key comparison
    {
        NullType values[ITEMS_PER_THREAD];

        SortBlocked(keys, values, begin_bit, end_bit, Int2Type<true>(), Int2Type<KEYS_ONLY>());
    }


    /**
     * \brief Performs a descending block-wide radix sort across a [<em>blocked arrangement</em>](index.html#sec5sec4) of keys and values.
     *
     * BlockRadixSort can only accommodate one associated tile of values. To "truck along"
     * more than one tile of values, simply perform a key-value sort of the keys paired
     * with a temporary value array that enumerates the key indices.  The reordered indices
     * can then be used as a gather-vector for exchanging other associated tile data through
     * shared memory.
     *
     * \smemreuse
     *
     * The code snippet below illustrates a sort of 512 integer keys and values that
     * are partitioned in a [<em>blocked arrangement</em>](index.html#sec5sec4) across 128 threads
     * where each thread owns 4 consecutive pairs.
     * \par
     * \code
     * #include <cub/cub.cuh>
     *
     * __global__ void ExampleKernel(...)
     * {
     *     // Specialize BlockRadixSort for 128 threads owning 4 integer keys and values each
     *     typedef cub::BlockRadixSort<int, 128, 4, int> BlockRadixSort;
     *
     *     // Allocate shared memory for BlockRadixSort
     *     __shared__ typename BlockRadixSort::TempStorage temp_storage;
     *
     *     // Obtain a segment of consecutive items that are blocked across threads
     *     int thread_keys[4];
     *     int thread_values[4];
     *     ...
     *
     *     // Collectively sort the keys and values among block threads
     *     BlockRadixSort(temp_storage).Sort(thread_keys, thread_values);
     *
     * \endcode
     * \par
     * Suppose the set of input \p thread_keys across the block of threads is
     * <tt>{ [0,511,1,510], [2,509,3,508], [4,507,5,506], ..., [254,257,255,256] }</tt>.  The
     * corresponding output \p thread_keys in those threads will be
     * <tt>{ [511,510,509,508], [11,10,9,8], [7,6,5,4], ..., [3,2,1,0] }</tt>.
     *
     */
    __device__ __forceinline__ void SortDescending(
        Key     (&keys)[ITEMS_PER_THREAD],          ///< [in-out] Keys to sort
        Value   (&values)[ITEMS_PER_THREAD],        ///< [in-out] Values to sort
        int     begin_bit   = 0,                    ///< [in] <b>[optional]</b> The beginning (least-significant) bit index needed for key comparison
        int     end_bit     = sizeof(Key) * 8)      ///< [in] <b>[optional]</b> The past-the-end (most-significant) bit index needed for key comparison
    {
        SortBlocked(keys, values, begin_bit, end_bit, Int2Type<true>(), Int2Type<KEYS_ONLY>());
    }


    //@}  end member group
    /******************************************************************//**
     * \name Sorting (blocked arrangement -> striped arrangement)
     *********************************************************************/
    //@{


    /**
     * \brief Performs an ascending radix sort across a [<em>blocked arrangement</em>](index.html#sec5sec4) of keys, leaving them in a [<em>striped arrangement</em>](index.html#sec5sec4).
     *
     * \smemreuse
     *
     * The code snippet below illustrates a sort of 512 integer keys that
     * are initially partitioned in a [<em>blocked arrangement</em>](index.html#sec5sec4) across 128 threads
     * where each thread owns 4 consecutive keys.  The final partitioning is striped.
     * \par
     * \code
     * #include <cub/cub.cuh>
     *
     * __global__ void ExampleKernel(...)
     * {
     *     // Specialize BlockRadixSort for 128 threads owning 4 integer keys each
     *     typedef cub::BlockRadixSort<int, 128, 4> BlockRadixSort;
     *
     *     // Allocate shared memory for BlockRadixSort
     *     __shared__ typename BlockRadixSort::TempStorage temp_storage;
     *
     *     // Obtain a segment of consecutive items that are blocked across threads
     *     int thread_keys[4];
     *     ...
     *
     *     // Collectively sort the keys
     *     BlockRadixSort(temp_storage).SortBlockedToStriped(thread_keys);
     *
     * \endcode
     * \par
     * Suppose the set of input \p thread_keys across the block of threads is
     * <tt>{ [0,511,1,510], [2,509,3,508], [4,507,5,506], ..., [254,257,255,256] }</tt>.  The
     * corresponding output \p thread_keys in those threads will be
     * <tt>{ [0,128,256,384], [1,129,257,385], [2,130,258,386], ..., [127,255,383,511] }</tt>.
     *
     */
    __device__ __forceinline__ void SortBlockedToStriped(
        Key     (&keys)[ITEMS_PER_THREAD],          ///< [in-out] Keys to sort
        int     begin_bit   = 0,                    ///< [in] <b>[optional]</b> The beginning (least-significant) bit index needed for key comparison
        int     end_bit     = sizeof(Key) * 8)      ///< [in] <b>[optional]</b> The past-the-end (most-significant) bit index needed for key comparison
    {
        NullType values[ITEMS_PER_THREAD];

        SortBlockedToStriped(keys, values, begin_bit, end_bit, Int2Type<false>(), Int2Type<KEYS_ONLY>());
    }


    /**
     * \brief Performs an ascending radix sort across a [<em>blocked arrangement</em>](index.html#sec5sec4) of keys and values, leaving them in a [<em>striped arrangement</em>](index.html#sec5sec4).
     *
     * BlockRadixSort can only accommodate one associated tile of values. To "truck along"
     * more than one tile of values, simply perform a key-value sort of the keys paired
     * with a temporary value array that enumerates the key indices.  The reordered indices
     * can then be used as a gather-vector for exchanging other associated tile data through
     * shared memory.
     *
     * \smemreuse
     *
     * The code snippet below illustrates a sort of 512 integer keys and values that
     * are initially partitioned in a [<em>blocked arrangement</em>](index.html#sec5sec4) across 128 threads
     * where each thread owns 4 consecutive pairs.  The final partitioning is striped.
     * \par
     * \code
     * #include <cub/cub.cuh>
     *
     * __global__ void ExampleKernel(...)
     * {
     *     // Specialize BlockRadixSort for 128 threads owning 4 integer keys and values each
     *     typedef cub::BlockRadixSort<int, 128, 4, int> BlockRadixSort;
     *
     *     // Allocate shared memory for BlockRadixSort
     *     __shared__ typename BlockRadixSort::TempStorage temp_storage;
     *
     *     // Obtain a segment of consecutive items that are blocked across threads
     *     int thread_keys[4];
     *     int thread_values[4];
     *     ...
     *
     *     // Collectively sort the keys and values among block threads
     *     BlockRadixSort(temp_storage).SortBlockedToStriped(thread_keys, thread_values);
     *
     * \endcode
     * \par
     * Suppose the set of input \p thread_keys across the block of threads is
     * <tt>{ [0,511,1,510], [2,509,3,508], [4,507,5,506], ..., [254,257,255,256] }</tt>.  The
     * corresponding output \p thread_keys in those threads will be
     * <tt>{ [0,128,256,384], [1,129,257,385], [2,130,258,386], ..., [127,255,383,511] }</tt>.
     *
     */
    __device__ __forceinline__ void SortBlockedToStriped(
        Key     (&keys)[ITEMS_PER_THREAD],          ///< [in-out] Keys to sort
        Value   (&values)[ITEMS_PER_THREAD],        ///< [in-out] Values to sort
        int     begin_bit   = 0,                    ///< [in] <b>[optional]</b> The beginning (least-significant) bit index needed for key comparison
        int     end_bit     = sizeof(Key) * 8)      ///< [in] <b>[optional]</b> The past-the-end (most-significant) bit index needed for key comparison
    {
        SortBlockedToStriped(keys, values, begin_bit, end_bit, Int2Type<false>(), Int2Type<KEYS_ONLY>());
    }


    /**
     * \brief Performs a descending radix sort across a [<em>blocked arrangement</em>](index.html#sec5sec4) of keys, leaving them in a [<em>striped arrangement</em>](index.html#sec5sec4).
     *
     * \smemreuse
     *
     * The code snippet below illustrates a sort of 512 integer keys that
     * are initially partitioned in a [<em>blocked arrangement</em>](index.html#sec5sec4) across 128 threads
     * where each thread owns 4 consecutive keys.  The final partitioning is striped.
     * \par
     * \code
     * #include <cub/cub.cuh>
     *
     * __global__ void ExampleKernel(...)
     * {
     *     // Specialize BlockRadixSort for 128 threads owning 4 integer keys each
     *     typedef cub::BlockRadixSort<int, 128, 4> BlockRadixSort;
     *
     *     // Allocate shared memory for BlockRadixSort
     *     __shared__ typename BlockRadixSort::TempStorage temp_storage;
     *
     *     // Obtain a segment of consecutive items that are blocked across threads
     *     int thread_keys[4];
     *     ...
     *
     *     // Collectively sort the keys
     *     BlockRadixSort(temp_storage).SortBlockedToStriped(thread_keys);
     *
     * \endcode
     * \par
     * Suppose the set of input \p thread_keys across the block of threads is
     * <tt>{ [0,511,1,510], [2,509,3,508], [4,507,5,506], ..., [254,257,255,256] }</tt>.  The
     * corresponding output \p thread_keys in those threads will be
     * <tt>{ [511,383,255,127], [386,258,130,2], [385,257,128,1], ..., [384,256,128,0] }</tt>.
     *
     */
    __device__ __forceinline__ void SortDescendingBlockedToStriped(
        Key     (&keys)[ITEMS_PER_THREAD],          ///< [in-out] Keys to sort
        int     begin_bit   = 0,                    ///< [in] <b>[optional]</b> The beginning (least-significant) bit index needed for key comparison
        int     end_bit     = sizeof(Key) * 8)      ///< [in] <b>[optional]</b> The past-the-end (most-significant) bit index needed for key comparison
    {
        NullType values[ITEMS_PER_THREAD];

        SortBlockedToStriped(keys, values, begin_bit, end_bit, Int2Type<true>(), Int2Type<KEYS_ONLY>());
    }


    /**
     * \brief Performs a descending radix sort across a [<em>blocked arrangement</em>](index.html#sec5sec4) of keys and values, leaving them in a [<em>striped arrangement</em>](index.html#sec5sec4).
     *
     * BlockRadixSort can only accommodate one associated tile of values. To "truck along"
     * more than one tile of values, simply perform a key-value sort of the keys paired
     * with a temporary value array that enumerates the key indices.  The reordered indices
     * can then be used as a gather-vector for exchanging other associated tile data through
     * shared memory.
     *
     * \smemreuse
     *
     * The code snippet below illustrates a sort of 512 integer keys and values that
     * are initially partitioned in a [<em>blocked arrangement</em>](index.html#sec5sec4) across 128 threads
     * where each thread owns 4 consecutive pairs.  The final partitioning is striped.
     * \par
     * \code
     * #include <cub/cub.cuh>
     *
     * __global__ void ExampleKernel(...)
     * {
     *     // Specialize BlockRadixSort for 128 threads owning 4 integer keys and values each
     *     typedef cub::BlockRadixSort<int, 128, 4, int> BlockRadixSort;
     *
     *     // Allocate shared memory for BlockRadixSort
     *     __shared__ typename BlockRadixSort::TempStorage temp_storage;
     *
     *     // Obtain a segment of consecutive items that are blocked across threads
     *     int thread_keys[4];
     *     int thread_values[4];
     *     ...
     *
     *     // Collectively sort the keys and values among block threads
     *     BlockRadixSort(temp_storage).SortBlockedToStriped(thread_keys, thread_values);
     *
     * \endcode
     * \par
     * Suppose the set of input \p thread_keys across the block of threads is
     * <tt>{ [0,511,1,510], [2,509,3,508], [4,507,5,506], ..., [254,257,255,256] }</tt>.  The
     * corresponding output \p thread_keys in those threads will be
     * <tt>{ [511,383,255,127], [386,258,130,2], [385,257,128,1], ..., [384,256,128,0] }</tt>.
     *
     */
    __device__ __forceinline__ void SortDescendingBlockedToStriped(
        Key     (&keys)[ITEMS_PER_THREAD],          ///< [in-out] Keys to sort
        Value   (&values)[ITEMS_PER_THREAD],        ///< [in-out] Values to sort
        int     begin_bit   = 0,                    ///< [in] <b>[optional]</b> The beginning (least-significant) bit index needed for key comparison
        int     end_bit     = sizeof(Key) * 8)      ///< [in] <b>[optional]</b> The past-the-end (most-significant) bit index needed for key comparison
    {
        SortBlockedToStriped(keys, values, begin_bit, end_bit, Int2Type<true>(), Int2Type<KEYS_ONLY>());
    }


    //@}  end member group

};

}               // CUB namespace
CUB_NS_POSTFIX  // Optional outer namespace(s)

