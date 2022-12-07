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

#include <cuco/detail/equal_wrapper.cuh>
#include <cuco/operator.hpp>
#include <cuco/sentinel.cuh>  // TODO .hpp

#include <cuda/std/atomic>

namespace cuco {
namespace experimental {

/**
 * @brief Device reference of static_set.
 */
template <typename Key,
          cuda::thread_scope Scope,
          typename KeyEqual,
          typename ProbingScheme,
          typename StorageRef,
          typename... Operators>
class static_set_ref
  : public detail::operator_impl<
      Operators,
      static_set_ref<Key, Scope, KeyEqual, ProbingScheme, StorageRef, Operators...>>... {
 public:
  using key_type            = Key;                             ///< Key Type
  using probing_scheme_type = ProbingScheme;                   ///< Type of probing scheme
  using storage_ref_type    = StorageRef;                      ///< Type of slot storage ref
  using window_type = typename storage_ref_type::window_type;  ///< Probing scheme element type
  using value_type  = typename storage_ref_type::value_type;   ///< Probing scheme element type
  using size_type   = typename storage_ref_type::size_type;    ///< Probing scheme size type
  using key_equal   = KeyEqual;  ///< Type of key equality binary callable

  static constexpr int cg_size = probing_scheme_type::cg_size;  ///< Cooperative group size
  static constexpr int window_size =
    storage_ref_type::window_size;                    ///< Number of elements handled per window
  static constexpr cuda::thread_scope scope = Scope;  ///< Thread scope

  // TODO default ctor?

  /**
   * @brief Constructs static_set_ref.
   *
   * @param empty_key_sentinel Sentinel indicating empty key
   * @param predicate Key equality binary callable
   * @param probing_scheme Probing scheme
   * @param storage_ref Non-owning ref of slot storage
   */
  __host__ __device__ static_set_ref(cuco::sentinel::empty_key<Key> empty_key_sentinel,
                                     KeyEqual const& predicate,
                                     ProbingScheme const& probing_scheme,
                                     StorageRef storage_ref) noexcept
    : empty_key_sentinel_{empty_key_sentinel},
      predicate_{empty_key_sentinel_.value, predicate},
      probing_scheme_{probing_scheme},
      storage_ref_{storage_ref}
  {
  }

  /**
   * @brief Gets the maximum number of elements the hash map can hold.
   *
   * @return The maximum number of elements the hash map can hold
   */
  [[nodiscard]] __host__ __device__ inline size_type capacity() const noexcept
  {
    return storage_ref_.capacity();
  }

  /**
   * @brief Gets the sentinel value used to represent an empty key slot.
   *
   * @return The sentinel value used to represent an empty key slot
   */
  [[nodiscard]] __host__ __device__ inline key_type empty_key_sentinel() const noexcept
  {
    return empty_key_sentinel_;
  }

  /**
   * @brief Create a reference with new operators from the current object.
   *
   * @tparam NewOperators List of `cuco::op::*_tag` types
   *
   * @param ops List of operators, e.g., `cuco::insert`
   *
   * @return copy of `*this` with `newOperators`
   */
  template <typename... NewOperators>
  [[nodiscard]] __host__ __device__ auto with(NewOperators... ops) const noexcept;

 private:
  cuco::sentinel::empty_key<key_type> empty_key_sentinel_;  ///< Empty key sentinel
  detail::equal_wrapper<value_type, key_equal> predicate_;  ///< Key equality binary callable
  probing_scheme_type probing_scheme_;                      ///< Probing scheme
  storage_ref_type storage_ref_;                            ///< Slot storage ref

  // Mixins need to be friends with this class in order to access private members
  template <typename Op, typename Ref>
  friend class detail::operator_impl;
};

}  // namespace experimental
}  // namespace cuco

#include <cuco/detail/static_set/static_set_ref.inl>
