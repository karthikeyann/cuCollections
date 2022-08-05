/*
 * Copyright (c) 2022, NVIDIA CORPORATION.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#pragma once

#include <cuco/allocator.hpp>
#include <cuco/detail/error.hpp>
#include <cuco/detail/prime.hpp>
#include <cuco/detail/storage.cuh>
#include <cuco/probe_sequences.cuh>
#include <cuco/sentinel.cuh>
#include <cuco/traits.hpp>

#include <thrust/functional.h>

#include <cuda/atomic>
#if defined(CUDART_VERSION) && (CUDART_VERSION >= 11000) && defined(__CUDA_ARCH__) && \
  (__CUDA_ARCH__ >= 700)
#define CUCO_HAS_CUDA_BARRIER
#endif

// cg::memcpy_aysnc is supported for CUDA 11.1 and up
#if defined(CUDART_VERSION) && (CUDART_VERSION >= 11100)
#define CUCO_HAS_CG_MEMCPY_ASYNC
#endif

#if defined(CUCO_HAS_CUDA_BARRIER)
#include <cuda/barrier>
#endif

#include <cooperative_groups.h>

#include <cstddef>
#include <memory>
#include <type_traits>
#include <utility>

namespace cuco {

/**
 * @brief A GPU-accelerated, unordered, associative container of unique keys.
 *
 * Allows constant time concurrent inserts or concurrent find operations from threads in device
 * code. Concurrent insert/find is allowed only when
 * <tt>static_set<Key>::supports_concurrent_insert_find()</tt> is true.
 *
 * @tparam Key Type used for keys. Requires `cuco::is_bitwise_comparable_v<Key>`
 * @tparam Scope The scope in which set operations will be performed by individual threads
 * @tparam KeyEqual Binary callable type used to compare two keys for equality
 * @tparam ProbeScheme Probe scheme chosen between `cuco::linear_probing`
 * and `cuco::double_hashing`. (see `detail/probe_sequences.cuh`)
 * @tparam Allocator Type of allocator used for device storage
 * @tparam Storage Slot storage type
 */
// template<
// class Key,
// class Hash = std::hash<Key>,
// class KeyEqual = std::equal_to<Key>,
// class Allocator = std::allocator<Key>
// > class unordered_set;
template <class Key,
          cuda::thread_scope Scope = cuda::thread_scope_device,
          class KeyEqual           = thrust::equal_to<Key>,
          class ProbeScheme =
            cuco::double_hashing<2,                                  // CG size
                                 2,                                  // Window size (vector length)
                                 uses_window_probing::YES,           // uses window probing
                                 cuco::detail::MurmurHash3_32<Key>,  // First hasher
                                 cuco::detail::MurmurHash3_32<Key>   // Second hasher
                                 >,
          class Allocator = cuco::cuda_allocator<char>,
          class Storage   = cuco::detail::aos_storage<Key, Allocator>>
class static_set {
  static_assert(
    cuco::is_bitwise_comparable_v<Key>,
    "Key type must have unique object representations or have been explicitly declared as safe for "
    "bitwise comparison via specialization of cuco::is_bitwise_comparable_v<Key>.");

  static_assert(
    std::is_base_of_v<cuco::detail::probe_sequence_base<ProbeScheme::cg_size>, ProbeScheme>,
    "ProbeScheme must be a specialization of either cuco::double_hashing or "
    "cuco::linear_probing.");

 public:
  using key_type   = Key;      ///< Key type
  using value_type = Key;      ///< Key type
  using key_equal  = KeyEqual  ///< Key equality comparator type
    using probe_scheme_type =
      detail::probe_scheme<ProbeScheme, Key, Key, Scope>;                  ///< Probe scheme type
  using allocator_type       = Allocator;                                  ///< Allocator type
  using slot_storage_type    = Storage;                                    ///< Slot storage type
  using counter_storage_type = detail::counter_storage<Scope, Allocator>;  ///< Counter storage type

  static_set(static_set const&) = delete;
  static_set& operator=(static_set const&) = delete;

  static_set(static_set&&) = default;  ///< Move constructor

  /**
   * @brief Replaces the contents of the map with another map.
   *
   * @return Reference of the current map object
   */
  static_set& operator=(static_set&&) = default;
  ~static_set()                       = default;

  /**
   * @brief Indicate if concurrent insert/find is supported for the key/value types.
   *
   * @return Boolean indicating if concurrent insert/find is supported.
   */
  __host__ __device__ __forceinline__ static constexpr bool
  supports_concurrent_insert_find() noexcept
  {
    return cuco::detail::is_packable<value_type>();
  }

  /**
   * @brief The size of the CUDA cooperative thread group.
   */
  __host__ __device__ static constexpr uint32_t cg_size = ProbeScheme::cg_size;

  /**
   * @brief Construct a statically-sized set with the specified initial capacity,
   * sentinel values and CUDA stream.
   *
   * The capacity of the set is fixed. Insert operations will not automatically
   * grow the set. Attempting to insert more unique keys than the capacity of
   * the map results in undefined behavior.
   *
   * The `empty_key_sentinel` is reserved and behavior is undefined when attempting to insert
   * this sentinel value.
   *
   * @param capacity The total number of slots in the set
   * @param empty_key_sentinel The reserved key value for empty slots
   * @param alloc Allocator used for allocating device storage
   * @param stream CUDA stream used to initialize the map
   */
  static_set(std::size_t capacity,
             sentinel::empty_key<Key> empty_key_sentinel,
             Allocator const& alloc = Allocator{},
             cudaStream_t stream    = 0);

  /**
   * @brief Inserts all keys in the range `[first, last)`.
   *
   * @tparam InputIt Device accessible random access input iterator where
   * <tt>std::is_convertible<std::iterator_traits<InputIt>::value_type,
   * static_set<K>::value_type></tt> is `true`
   *
   * @param first Beginning of the sequence of keys
   * @param last End of the sequence of keys
   * @param stream CUDA stream used for insert
   */
  template <typename InputIt>
  void insert(InputIt first, InputIt last, cudaStream_t stream = 0);

  /**
   * @brief Indicates whether the keys in the range `[first, last)` are contained in the map.
   *
   * Stores `true` or `false` to `(output + i)` indicating if the key `*(first + i)` exists in the
   * map.
   *
   * ProbeScheme hashers should be callable with both
   * <tt>std::iterator_traits<InputIt>::value_type</tt> and Key type.
   * <tt>std::invoke_result<KeyEqual, std::iterator_traits<InputIt>::value_type, Key></tt> must be
   * well-formed.
   *
   * @tparam InputIt Device accessible input iterator
   * @tparam OutputIt Device accessible output iterator assignable from `bool`
   *
   * @param first Beginning of the sequence of keys
   * @param last End of the sequence of keys
   * @param output_begin Beginning of the output sequence indicating whether each key is present
   * @param stream CUDA stream used for contains
   */
  template <typename InputIt, typename OutputIt>
  void contains(InputIt first, InputIt last, OutputIt output_begin, cudaStream_t stream = 0) const;

  /**
   * @brief Gets the maximum number of elements the hash map can hold.
   *
   * @return The maximum number of elements the hash map can hold
   */
  std::size_t capacity() const noexcept { return capacity_; }

  /**
   * @brief Gets the number of elements in the hash map.
   *
   * @param stream CUDA stream used to get the number of inserted elements
   * @return The number of elements in the map
   */
  std::size_t size(cudaStream_t stream = 0) const noexcept;

  /**
   * @brief Gets the load factor of the hash map.
   *
   * @param stream CUDA stream used to get the load factor
   * @return The load factor of the hash map
   */
  float load_factor(cudaStream_t stream = 0) const noexcept;

  /**
   * @brief Gets the sentinel value used to represent an empty key slot.
   *
   * @return The sentinel value used to represent an empty key slot
   */
  Key empty_key_sentinel() const noexcept { return empty_key_sentinel_; }

 private:
  std::size_t capacity_;            ///< Total number of slots
  key_type empty_key_sentinel_;     ///< Key value that represents an empty slot
  key_equal key_eq_;                ///< Key equality binary predicate
  counter_storage_type d_counter_;  ///< Device counter storage
  slot_storage_type slot_storage_;  ///< Flat slot storage
};

}  // namespace cuco

#include <cuco/detail/static_set/static_set.inl>
