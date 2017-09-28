! Licensed under the Apache License, Version 2.0 (the "License");
! you may not use this file except in compliance with the License.
! You may obtain a copy of the License at
!
!     https://www.apache.org/licenses/LICENSE-2.0
!
! Unless required by applicable law or agreed to in writing, software
! distributed under the License is distributed on an "AS IS" BASIS,
! WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
! See the License for the specific language governing permissions and
! limitations under the License.

module curve

  use iso_c_binding, only: c_double, c_int, c_bool
  use types, only: dp
  use helpers, only: cross_product, contains_nd
  implicit none
  private &
       LocateCandidate, MAX_LOCATE_SUBDIVISIONS, LOCATE_STD_CAP, &
       SQRT_PREC, REDUCE_THRESHOLD, scalar_func, dqagse, &
       specialize_curve_generic, specialize_curve_quadratic, &
       subdivide_nodes_generic, split_candidate
  public &
       LOCATE_MISS, LOCATE_INVALID, evaluate_curve_barycentric, &
       evaluate_multi, specialize_curve, evaluate_hodograph, subdivide_nodes, &
       newton_refine, locate_point, elevate_nodes, get_curvature, &
       reduce_pseudo_inverse, projection_error, can_reduce, full_reduce, &
       compute_length

  ! For ``locate_point``.
  type :: LocateCandidate
     real(c_double) :: start
     real(c_double) :: end_
     real(c_double), allocatable :: nodes(:, :)
  end type LocateCandidate

  ! NOTE: These values are also defined in `src/bezier/_curve_helpers.py`.
  integer(c_int), parameter :: MAX_LOCATE_SUBDIVISIONS = 20
  real(c_double), parameter :: LOCATE_STD_CAP = 0.5_dp**20
  ! NOTE: Should probably use ``d1mach`` to determine ``SQRT_PREC``.
  real(c_double), parameter :: SQRT_PREC = 0.5_dp**26
  real(c_double), parameter :: REDUCE_THRESHOLD = SQRT_PREC
  real(c_double), parameter :: LOCATE_MISS = -1
  real(c_double), parameter :: LOCATE_INVALID = -2

  ! Interface blocks for QUADPACK:dqagse
  abstract interface
     ! f: real(c_double) --> real(c_double)
     real(c_double) function scalar_func(x)
       use iso_c_binding, only: c_double
       implicit none

       real(c_double), intent(in) :: x
     end function scalar_func
  end interface

  interface
     ! D - double precision
     ! Q - quadrature
     ! A - adaptive
     ! G - General integrand (i.e. INT f(x), not weighted INT w(x) f(x))
     ! S - Singularities handled
     ! E - Extended
     ! See: https://en.wikipedia.org/wiki/QUADPACK
     ! QUADPACK is "Public Domain"
     subroutine dqagse( &
          f, a, b, epsabs, epsrel, limit, result_, &
          abserr, neval, ier, alist, blist, rlist, &
          elist, iord, last)
       use iso_c_binding, only: c_double, c_int
       implicit none

       procedure(scalar_func) :: f
       real(c_double), intent(in) :: a, b
       real(c_double), intent(in) :: epsabs, epsrel
       integer(c_int), intent(in) :: limit
       real(c_double), intent(out) :: result_, abserr
       integer(c_int), intent(out) :: neval, ier
       real(c_double), intent(out) :: alist(limit)
       real(c_double), intent(out) :: blist(limit)
       real(c_double), intent(out) :: rlist(limit)
       real(c_double), intent(out) :: elist(limit)
       integer(c_int), intent(out) :: iord(limit)
       integer(c_int), intent(out) :: last

     end subroutine dqagse
  end interface

contains

  subroutine evaluate_curve_barycentric( &
       degree, dimension_, nodes, num_vals, lambda1, lambda2, evaluated) &
       bind(c, name='evaluate_curve_barycentric')

    ! NOTE: This is evaluate_multi_barycentric for a Bezier curve.

    integer(c_int), intent(in) :: degree, dimension_
    real(c_double), intent(in) :: nodes(degree + 1, dimension_)
    integer(c_int), intent(in) :: num_vals
    real(c_double), intent(in) :: lambda1(num_vals)
    real(c_double), intent(in) :: lambda2(num_vals)
    real(c_double), intent(out) :: evaluated(num_vals, dimension_)
    ! Variables outside of signature.
    integer(c_int) :: i, j
    real(c_double) :: lambda2_pow(num_vals)
    integer(c_int) :: binom_val

    lambda2_pow = 1.0_dp
    binom_val = 1

    forall (i = 1:num_vals)
       evaluated(i, :) = lambda1(i) * nodes(1, :)
    end forall

    do i = 2, degree
       lambda2_pow = lambda2_pow * lambda2
       binom_val = (binom_val * (degree - i + 2)) / (i - 1)
       forall (j = 1:num_vals)
          evaluated(j, :) = ( &
               evaluated(j, :) + &
               binom_val * lambda2_pow(j) * nodes(i, :)) * lambda1(j)
       end forall
    end do

    forall (i = 1:num_vals)
       evaluated(i, :) = ( &
            evaluated(i, :) + &
            lambda2_pow(i) * lambda2(i) * nodes(degree + 1, :))
    end forall

  end subroutine evaluate_curve_barycentric

  subroutine evaluate_multi( &
       degree, dimension_, nodes, num_vals, s_vals, evaluated) &
       bind(c, name='evaluate_multi')

    ! NOTE: This is evaluate_multi for a Bezier curve.

    integer(c_int), intent(in) :: degree, dimension_
    real(c_double), intent(in) :: nodes(degree + 1, dimension_)
    integer(c_int), intent(in) :: num_vals
    real(c_double), intent(in) :: s_vals(num_vals)
    real(c_double), intent(out) :: evaluated(num_vals, dimension_)
    ! Variables outside of signature.
    real(c_double) :: one_less(num_vals)

    one_less = 1.0_dp - s_vals
    call evaluate_curve_barycentric( &
         degree, dimension_, nodes, num_vals, one_less, s_vals, evaluated)
  end subroutine evaluate_multi

  subroutine specialize_curve_generic( &
       degree, dimension_, nodes, start, end_, new_nodes)

    ! NOTE: This is a helper for ``specialize_curve`` that works on any degree.

    integer(c_int), intent(in) :: degree, dimension_
    real(c_double), intent(in) :: nodes(degree + 1, dimension_)
    real(c_double), intent(in) :: start, end_
    real(c_double), intent(out) :: new_nodes(degree + 1, dimension_)
    ! Variables outside of signature.
    real(c_double) :: workspace(degree, dimension_, degree + 1)
    integer(c_int) :: index_, curr_size, j
    real(c_double) :: minus_start, minus_end

    minus_start = 1.0_dp - start
    minus_end = 1.0_dp - end_
    workspace(:, :, 1) = minus_start * nodes(:degree, :) + start * nodes(2:, :)
    workspace(:, :, 2) = minus_end * nodes(:degree, :) + end_ * nodes(2:, :)

    curr_size = degree
    do index_ = 3, degree + 1
       curr_size = curr_size - 1
       ! First add a new "column" (or whatever the 3rd dimension is called)
       ! at the end using ``end_``.
       workspace(:curr_size, :, index_) = ( &
            minus_end * workspace(:curr_size, :, index_ - 1) + &
            end_ * workspace(2:curr_size + 1, :, index_ - 1))
       ! Update all the values in place by using de Casteljau with the
       ! ``start`` parameter.
       forall (j = 1:index_ - 1)
          workspace(:curr_size, :, j) = ( &
               minus_start * workspace(:curr_size, :, j) + &
               start * workspace(2:curr_size + 1, :, j))
       end forall
    end do

    ! Move the final "column" (or whatever the 3rd dimension is called)
    ! of the workspace into ``new_nodes``.
    forall (index_ = 1:degree + 1)
       new_nodes(index_, :) = workspace(1, :, index_)
    end forall

  end subroutine specialize_curve_generic

  subroutine specialize_curve_quadratic( &
       dimension_, nodes, start, end_, new_nodes)

    integer(c_int), intent(in) :: dimension_
    real(c_double), intent(in) :: nodes(3, dimension_)
    real(c_double), intent(in) :: start, end_
    real(c_double), intent(out) :: new_nodes(3, dimension_)
    ! Variables outside of signature.
    real(c_double) :: minus_start, minus_end, prod_both

    minus_start = 1.0_dp - start
    minus_end = 1.0_dp - end_
    prod_both = start * end_

    new_nodes(1, :) = ( &
         minus_start * minus_start * nodes(1, :) + &
         2.0_dp * start * minus_start * nodes(2, :) + &
         start * start * nodes(3, :))
    new_nodes(2, :) = ( &
         minus_start * minus_end * nodes(1, :) + &
         (end_ + start - 2.0_dp * prod_both) * nodes(2, :) + &
         prod_both * nodes(3, :))
    new_nodes(3, :) = ( &
         minus_end * minus_end * nodes(1, :) + &
         2.0_dp * end_ * minus_end * nodes(2, :) + &
         end_ * end_ * nodes(3, :))

  end subroutine specialize_curve_quadratic

  subroutine specialize_curve( &
       degree, dimension_, nodes, start, end_, curve_start, curve_end, &
       new_nodes, true_start, true_end) &
       bind(c, name='specialize_curve')

    integer(c_int), intent(in) :: degree, dimension_
    real(c_double), intent(in) :: nodes(degree + 1, dimension_)
    real(c_double), intent(in) :: start, end_, curve_start, curve_end
    real(c_double), intent(out) :: new_nodes(degree + 1, dimension_)
    real(c_double), intent(out) :: true_start, true_end
    ! Variables outside of signature.
    real(c_double) :: interval_delta

    if (degree == 1) then
       new_nodes(1, :) = (1.0_dp - start) * nodes(1, :) + start * nodes(2, :)
       new_nodes(2, :) = (1.0_dp - end_) * nodes(1, :) + end_ * nodes(2, :)
    else if (degree == 2) then
       call specialize_curve_quadratic( &
            dimension_, nodes, start, end_, new_nodes)
    else
       call specialize_curve_generic( &
            degree, dimension_, nodes, start, end_, new_nodes)
    end if

    ! Now, compute the new interval.
    interval_delta = curve_end - curve_start
    true_start = curve_start + start * interval_delta
    true_end = curve_start + end_ * interval_delta

  end subroutine specialize_curve

  subroutine evaluate_hodograph( &
       s, degree, dimension_, nodes, hodograph) &
       bind(c, name='evaluate_hodograph')

    real(c_double), intent(in) :: s
    integer(c_int), intent(in) :: degree, dimension_
    real(c_double), intent(in) :: nodes(degree + 1, dimension_)
    real(c_double), intent(out) :: hodograph(1, dimension_)
    ! Variables outside of signature.
    real(c_double) :: first_deriv(degree, dimension_)

    first_deriv = nodes(2:, :) - nodes(:degree, :)
    call evaluate_multi( &
         degree - 1, dimension_, first_deriv, 1, [s], hodograph)
    hodograph = degree * hodograph

  end subroutine evaluate_hodograph

  subroutine subdivide_nodes_generic( &
       num_nodes, dimension_, nodes, left_nodes, right_nodes)

    integer(c_int), intent(in) :: num_nodes, dimension_
    real(c_double), intent(in) :: nodes(num_nodes, dimension_)
    real(c_double), intent(out) :: left_nodes(num_nodes, dimension_)
    real(c_double), intent(out) :: right_nodes(num_nodes, dimension_)
    ! Variables outside of signature.
    real(c_double) :: pascals_triangle(num_nodes)
    integer(c_int) :: elt_index, pascal_index

    pascals_triangle = 0  ! Make sure all zero.
    pascals_triangle(1) = 1

    do elt_index = 1, num_nodes
       ! Update Pascal's triangle (intentionally at beginning, not end).
       if (elt_index > 1) then
          pascals_triangle(:elt_index) = 0.5_dp * ( &
               pascals_triangle(:elt_index) + pascals_triangle(elt_index:1:-1))
       end if

       left_nodes(elt_index, :) = 0
       right_nodes(num_nodes + 1 - elt_index, :) = 0
       do pascal_index = 1, elt_index
          left_nodes(elt_index, :) = ( &
               left_nodes(elt_index, :) + &
               pascals_triangle(pascal_index) * nodes(pascal_index, :))
          right_nodes(num_nodes + 1 - elt_index, :) = ( &
               right_nodes(num_nodes + 1 - elt_index, :) + &
               pascals_triangle(pascal_index) * &
               nodes(num_nodes + 1 - pascal_index, :))
       end do
    end do

  end subroutine subdivide_nodes_generic

  subroutine subdivide_nodes( &
       num_nodes, dimension_, nodes, left_nodes, right_nodes) &
       bind(c, name='subdivide_nodes')

    integer(c_int), intent(in) :: num_nodes, dimension_
    real(c_double), intent(in) :: nodes(num_nodes, dimension_)
    real(c_double), intent(out) :: left_nodes(num_nodes, dimension_)
    real(c_double), intent(out) :: right_nodes(num_nodes, dimension_)

    if (num_nodes == 2) then
       left_nodes(1, :) = nodes(1, :)
       left_nodes(2, :) = 0.5_dp * (nodes(1, :) + nodes(2, :))
       right_nodes(1, :) = left_nodes(2, :)
       right_nodes(2, :) = nodes(2, :)
    else if (num_nodes == 3) then
       left_nodes(1, :) = nodes(1, :)
       left_nodes(2, :) = 0.5_dp * (nodes(1, :) + nodes(2, :))
       left_nodes(3, :) = 0.25_dp * ( &
            nodes(1, :) + 2 * nodes(2, :) + nodes(3, :))
       right_nodes(1, :) = left_nodes(3, :)
       right_nodes(2, :) = 0.5_dp * (nodes(2, :) + nodes(3, :))
       right_nodes(3, :) = nodes(3, :)
    else if (num_nodes == 4) then
       left_nodes(1, :) = nodes(1, :)
       left_nodes(2, :) = 0.5_dp * (nodes(1, :) + nodes(2, :))
       left_nodes(3, :) = 0.25_dp * ( &
            nodes(1, :) + 2 * nodes(2, :) + nodes(3, :))
       left_nodes(4, :) = 0.125_dp * ( &
            nodes(1, :) + 3 * nodes(2, :) + 3 * nodes(3, :) + nodes(4, :))
       right_nodes(1, :) = left_nodes(4, :)
       right_nodes(2, :) = 0.25_dp * ( &
            nodes(2, :) + 2 * nodes(3, :) + nodes(4, :))
       right_nodes(3, :) = 0.5_dp * (nodes(3, :) + nodes(4, :))
       right_nodes(4, :) = nodes(4, :)
    else
       call subdivide_nodes_generic( &
            num_nodes, dimension_, nodes, left_nodes, right_nodes)
    end if

  end subroutine subdivide_nodes

  subroutine newton_refine( &
       num_nodes, dimension_, nodes, point, s, updated_s) &
       bind(c, name='newton_refine')

    integer(c_int), intent(in) :: num_nodes, dimension_
    real(c_double), intent(in) :: nodes(num_nodes, dimension_)
    real(c_double), intent(in) :: point(1, dimension_)
    real(c_double), intent(in) :: s
    real(c_double), intent(out) :: updated_s
    ! Variables outside of signature.
    real(c_double) :: pt_delta(1, dimension_)
    real(c_double) :: derivative(1, dimension_)

    call evaluate_multi( &
         num_nodes - 1, dimension_, nodes, 1, [s], pt_delta)
    pt_delta = point - pt_delta
    ! At this point `pt_delta` is `p - B(s)`.
    call evaluate_hodograph( &
         s, num_nodes - 1, dimension_, nodes, derivative)

    updated_s = ( &
         s + &
         (dot_product(pt_delta(1, :), derivative(1, :)) / &
         dot_product(derivative(1, :), derivative(1, :))))

  end subroutine newton_refine

  subroutine split_candidate(num_nodes, dimension_, candidate, both_halves)

    integer(c_int), intent(in) :: num_nodes, dimension_
    type(LocateCandidate), intent(in) :: candidate
    type(LocateCandidate), intent(out) :: both_halves(2)

    ! Left half.
    both_halves(1)%start = candidate%start
    both_halves(1)%end_ = 0.5_dp * (candidate%start + candidate%end_)
    ! Right half.
    both_halves(2)%start = both_halves(1)%end_
    both_halves(2)%end_ = candidate%end_

    ! Allocate the new nodes and call sub-divide.
    allocate(both_halves(1)%nodes(num_nodes, dimension_))
    allocate(both_halves(2)%nodes(num_nodes, dimension_))
    call subdivide_nodes( &
         num_nodes, dimension_, candidate%nodes, &
         both_halves(1)%nodes, both_halves(2)%nodes)

  end subroutine split_candidate

  subroutine locate_point( &
       num_nodes, dimension_, nodes, point, s_approx) &
       bind(c, name='locate_point')

    ! NOTE: This returns ``-1`` (``LOCATE_MISS``) as a signal for "point is
    !       not on the curve" and ``-2`` (``LOCATE_INVALID``) for "point is
    !       on separate segments" (i.e. the standard deviation of the
    !       parameters is too large).

    integer(c_int), intent(in) :: num_nodes, dimension_
    real(c_double), intent(in) :: nodes(num_nodes, dimension_)
    real(c_double), intent(in) :: point(1, dimension_)
    real(c_double), intent(out) :: s_approx
    ! Variables outside of signature.
    type(LocateCandidate), allocatable :: candidates(:), next_candidates(:)
    integer(c_int) :: sub_index, cand_index
    integer(c_int) :: num_candidates, num_next_candidates
    type(LocateCandidate) :: candidate
    real(c_double), allocatable :: s_params(:)
    real(c_double) :: std_dev
    logical(c_bool) :: predicate

    ! Start out with the full curve.
    allocate(candidates(1))
    candidates(1) = LocateCandidate(0.0_dp, 1.0_dp, nodes)
    ! NOTE: `num_candidates` will be tracked separately
    !       from `size(candidates)`.
    num_candidates = 1
    s_approx = LOCATE_MISS

    do sub_index = 1, MAX_LOCATE_SUBDIVISIONS + 1
       num_next_candidates = 0
       ! Allocate maximum amount of space needed.
       allocate(next_candidates(2 * num_candidates))
       do cand_index = 1, num_candidates
          candidate = candidates(cand_index)
          call contains_nd( &
               num_nodes, dimension_, candidate%nodes, point(1, :), predicate)
          if (predicate) then
             num_next_candidates = num_next_candidates + 2
             call split_candidate( &
                  num_nodes, dimension_, candidate, &
                  next_candidates(num_next_candidates - 1:num_next_candidates))
          end if
       end do

       ! NOTE: This may copy empty slots, but this is OK since we track
       !       `num_candidates` separately.
       call move_alloc(next_candidates, candidates)
       num_candidates = num_next_candidates

       ! If there are no more candidates, we are done.
       if (num_candidates == 0) then
          return
       end if

    end do

    ! Compute the s-parameter as the mean of the **start** and
    ! **end** parameters.
    allocate(s_params(2 * num_candidates))
    s_params(:num_candidates) = candidates(:num_candidates)%start
    s_params(num_candidates + 1:) = candidates(:num_candidates)%end_
    s_approx = sum(s_params) / (2 * num_candidates)

    std_dev = sqrt(sum((s_params - s_approx)**2) / (2 * num_candidates))
    if (std_dev > LOCATE_STD_CAP) then
       s_approx = LOCATE_INVALID
       return
    end if

    ! NOTE: Use ``std_dev`` variable as a "placeholder" for the update.
    call newton_refine( &
         num_nodes, dimension_, nodes, point, s_approx, std_dev)
    s_approx = std_dev

  end subroutine locate_point

  subroutine elevate_nodes( &
       num_nodes, dimension_, nodes, elevated) &
       bind(c, name='elevate_nodes')

    integer(c_int), intent(in) :: num_nodes, dimension_
    real(c_double), intent(in) :: nodes(num_nodes, dimension_)
    real(c_double), intent(out) :: elevated(num_nodes + 1, dimension_)
    ! Variables outside of signature.
    integer(c_int) :: i

    elevated(1, :) = nodes(1, :)
    forall (i = 1:num_nodes)
       elevated(i + 1, :) = ( &
            i * nodes(i, :) + (num_nodes - i) * nodes(i + 1, :)) / num_nodes
    end forall
    elevated(num_nodes + 1, :) = nodes(num_nodes, :)

  end subroutine elevate_nodes

  subroutine get_curvature( &
       num_nodes, dimension_, nodes, tangent_vec, s, curvature) &
       bind(c, name='get_curvature')

    integer(c_int), intent(in) :: num_nodes, dimension_
    real(c_double), intent(in) :: nodes(num_nodes, dimension_)
    real(c_double), intent(in) :: tangent_vec(1, dimension_)
    real(c_double), intent(in) :: s
    real(c_double), intent(out) :: curvature
    ! Variables outside of signature.
    real(c_double) :: work(num_nodes - 1, dimension_)
    real(c_double) :: concavity(1, dimension_)

    if (num_nodes == 2) then
       curvature = 0
       return
    end if

    ! NOTE: We somewhat replicate code in ``evaluate_hodograph()``
    !       here. It may be worthwhile to implement store the hodograph
    !       and "concavity" nodes for a given curve to avoid re-computing the
    !       first and second node differences.

    ! First derivative:
    work = nodes(2:, :) - nodes(:num_nodes - 1, :)
    ! Second derivative (no need for last element of work array):
    work(:num_nodes - 2, :) = work(2:, :) - work(:num_nodes - 2, :)

    ! NOTE: The degree being evaluated is ``degree - 2 == num_nodes - 3``.
    call evaluate_multi( &
         num_nodes - 3, dimension_, work(:num_nodes - 2, :), 1, [s], concavity)
    ! B''(s) = d (d - 1) D(s) where D(s) is defined by the "double hodograph".
    concavity = concavity * (num_nodes - 1) * (num_nodes - 2)

    call cross_product(tangent_vec, concavity, curvature)
    curvature = curvature / norm2(tangent_vec)**3

  end subroutine get_curvature

  subroutine reduce_pseudo_inverse( &
       num_nodes, dimension_, nodes, reduced, not_implemented) &
       bind(c, name='reduce_pseudo_inverse')

    integer(c_int), intent(in) :: num_nodes, dimension_
    real(c_double), intent(in) :: nodes(num_nodes, dimension_)
    real(c_double), intent(out) :: reduced(num_nodes - 1, dimension_)
    logical(c_bool), intent(out) :: not_implemented

    not_implemented = .FALSE.
    if (num_nodes == 2) then
       reduced(1, :) = 0.5_dp * (nodes(1, :) + nodes(2, :))
    else if (num_nodes == 3) then
       reduced(1, :) = (5 * nodes(1, :) + 2 * nodes(2, :) - nodes(3, :)) / 6
       reduced(2, :) = (-nodes(1, :) + 2 * nodes(2, :) + 5 * nodes(3, :)) / 6
    else if (num_nodes == 4) then
       reduced(1, :) = ( &
            19 * nodes(1, :) + 3 * nodes(2, :) - &
            3 * nodes(3, :) + nodes(4, :)) / 20
       reduced(2, :) = 0.25_dp * ( &
            -nodes(1, :) + 3 * nodes(2, :) + &
            3 * nodes(3, :) - nodes(4, :))
       reduced(3, :) = ( &
            nodes(1, :) - 3 * nodes(2, :) + &
            3 * nodes(3, :) + 19 * nodes(4, :)) / 20
    else if (num_nodes == 5) then
       reduced(1, :) = ( &
            69 * nodes(1, :) + 4 * nodes(2, :) - 6 * nodes(3, :) + &
            4 * nodes(4, :) - nodes(5, :)) / 70
       reduced(2, :) = ( &
            -53 * nodes(1, :) + 212 * nodes(2, :) + 102 * nodes(3, :) - &
            68 * nodes(4, :) + 17 * nodes(5, :)) / 210
       reduced(3, :) = ( &
            17 * nodes(1, :) - 68 * nodes(2, :) + 102 * nodes(3, :) + &
            212 * nodes(4, :) - 53 * nodes(5, :)) / 210
       reduced(4, :) = ( &
            -nodes(1, :) + 4 * nodes(2, :) - 6 * nodes(3, :) + &
            4 * nodes(4, :) + 69 * nodes(5, :)) / 70
    else
       not_implemented = .TRUE.
    end if

  end subroutine reduce_pseudo_inverse

  subroutine projection_error( &
       num_nodes, dimension_, nodes, projected, error)

    ! NOTE: This subroutine is not part of the C ABI for this module,
    !       but it is (for now) public, so that it can be tested.

    integer(c_int), intent(in) :: num_nodes, dimension_
    real(c_double), intent(in) :: nodes(num_nodes, dimension_)
    real(c_double), intent(in) :: projected(num_nodes, dimension_)
    real(c_double), intent(out) :: error

    ! If "dim" is not passed to ``norm2``, will be Frobenius norm.
    error = norm2(nodes - projected)
    if (error == 0.0_dp) then
       return
    end if

    ! Make the error relative (in Frobenius norm).
    error = error / norm2(nodes)

  end subroutine projection_error

  subroutine can_reduce( &
       num_nodes, dimension_, nodes, success)

    ! NOTE: This returns ``success = 0`` for "Failure", ``success = 1`` for
    !       "Success" and ``success = -1`` for "Not Implemented".
    ! NOTE: This subroutine is not part of the C ABI for this module,
    !       but it is (for now) public, so that it can be tested.

    integer(c_int), intent(in) :: num_nodes, dimension_
    real(c_double), intent(in) :: nodes(num_nodes, dimension_)
    integer(c_int), intent(out) :: success
    ! Variables outside of signature.
    real(c_double) :: reduced(num_nodes, dimension_)
    real(c_double) :: relative_err

    if (num_nodes < 2) then
       ! Can't reduce past degree 1.
       success = 0
       return
    else if (num_nodes > 5) then
       ! Not Implemented.
       success = -1
       return
    end if

    ! First, put the "projection" in ``reduced``.
    if (num_nodes == 2) then
       reduced(1, :) = 0.5_dp * (nodes(1, :) + nodes(2, :))
       reduced(2, :) = reduced(1, :)
    else if (num_nodes == 3) then
       reduced(1, :) = (5 * nodes(1, :) + 2 * nodes(2, :) - nodes(3, :)) / 6
       reduced(2, :) = (nodes(1, :) + nodes(2, :) + nodes(3, :)) / 3
       reduced(3, :) = (-nodes(1, :) + 2 * nodes(2, :) + 5 * nodes(3, :)) / 6
    else if (num_nodes == 4) then
       reduced(1, :) = ( &
            19 * nodes(1, :) + 3 * nodes(2, :) - &
            3 * nodes(3, :) + nodes(4, :)) / 20
       reduced(2, :) = ( &
            3 * nodes(1, :) + 11 * nodes(2, :) + &
            9 * nodes(3, :) - 3 * nodes(4, :)) / 20
       reduced(3, :) = ( &
            -3 * nodes(1, :) + 9 * nodes(2, :) + &
            11 * nodes(3, :) + 3 * nodes(4, :)) / 20
       reduced(4, :) = ( &
            nodes(1, :) - 3 * nodes(2, :) + &
            3 * nodes(3, :) + 19 * nodes(4, :)) / 20
    else if (num_nodes == 5) then
       reduced(1, :) = ( &
            69 * nodes(1, :) + 4 * nodes(2, :) - 6 * nodes(3, :) + &
            4 * nodes(4, :) - nodes(5, :)) / 70
       reduced(2, :) = ( &
            2 * nodes(1, :) + 27 * nodes(2, :) + 12 * nodes(3, :) - &
            8 * nodes(4, :) + 2 * nodes(5, :)) / 35
       reduced(3, :) = ( &
            -3 * nodes(1, :) + 12 * nodes(2, :) + 17 * nodes(3, :) + &
            12 * nodes(4, :) - 3 * nodes(5, :)) / 35
       reduced(4, :) = ( &
            2 * nodes(1, :) - 8 * nodes(2, :) + 12 * nodes(3, :) + &
            27 * nodes(4, :) + 2 * nodes(5, :)) / 35
       reduced(5, :) = ( &
            -nodes(1, :) + 4 * nodes(2, :) - 6 * nodes(3, :) + &
            4 * nodes(4, :) + 69 * nodes(5, :)) / 70
    end if

    call projection_error(num_nodes, dimension_, nodes, reduced, relative_err)
    if (relative_err < REDUCE_THRESHOLD) then
       success = 1
    else
       success = 0
    end if

  end subroutine can_reduce

  subroutine full_reduce( &
       num_nodes, dimension_, nodes, num_reduced_nodes, &
       reduced, not_implemented) &
       bind(c, name='full_reduce')

    ! NOTE: The size of ``reduced`` represents the **maximum** possible
    !       size, but ``num_reduced_nodes`` actually reflects the number
    !       of nodes in the fully reduced nodes.

    integer(c_int), intent(in) :: num_nodes, dimension_
    real(c_double), intent(in) :: nodes(num_nodes, dimension_)
    integer(c_int), intent(out) :: num_reduced_nodes
    real(c_double), intent(out) :: reduced(num_nodes, dimension_)
    logical(c_bool), intent(out) :: not_implemented
    ! Variables outside of signature.
    integer(c_int) :: i, cr_success
    real(c_double) :: work(num_nodes - 1, dimension_)

    reduced = nodes
    num_reduced_nodes = num_nodes
    not_implemented = .FALSE.
    ! We can make at most ``num_nodes - 1`` reductions since
    ! we can't reduce past one node (i.e. degree zero).
    do i = 1, num_nodes - 1
       call can_reduce( &
            num_reduced_nodes, dimension_, &
            reduced(:num_reduced_nodes, :), cr_success)

       if (cr_success == 1) then
          ! Actually reduce the nodes.
          call reduce_pseudo_inverse( &
               num_reduced_nodes, dimension_, reduced(:num_reduced_nodes, :), &
               work(:num_reduced_nodes - 1, :), not_implemented)
          if (not_implemented) then
             return
          else
             num_reduced_nodes = num_reduced_nodes - 1
             ! Update `reduced` based on the **new** number of nodes.
             reduced(:num_reduced_nodes, :) = work(:num_reduced_nodes, :)
          end if
       else if (cr_success == 0) then
          return
       else
          ! ``cr_success == -1`` means "Not Implemented"
          not_implemented = .TRUE.
          return
       end if
    end do

  end subroutine full_reduce

  subroutine compute_length( &
       num_nodes, dimension_, nodes, length, error_val) &
       bind(c, name='compute_length')

    integer(c_int), intent(in) :: num_nodes, dimension_
    real(c_double), intent(in) :: nodes(num_nodes, dimension_)
    real(c_double), intent(out) :: length
    integer(c_int), intent(out) :: error_val
    ! Variables outside of signature.
    real(c_double) :: first_deriv(num_nodes - 1, dimension_)
    real(c_double) :: abserr
    integer(c_int) :: neval
    real(c_double) :: alist(50)
    real(c_double) :: blist(50)
    real(c_double) :: rlist(50)
    real(c_double) :: elist(50)
    integer(c_int) :: iord(50)
    integer(c_int) :: last

    ! NOTE: We somewhat replicate code in ``evaluate_hodograph()``
    !       here. This is so we don't re-compute the nodes for the first
    !       derivative every time it is evaluated.
    first_deriv = (num_nodes - 1) * (nodes(2:, :) - nodes(:num_nodes - 1, :))
    if (num_nodes == 2) then
       length = norm2(first_deriv)
       error_val = 0
       return
    end if

    call dqagse( &
         vec_size, 0.0_dp, 1.0_dp, SQRT_PREC, SQRT_PREC, 50, length, &
         abserr, neval, error_val, alist, blist, rlist, &
         elist, iord, last)

  contains

    ! Define a closure that evaluates ||B'(s)||_2 where ``s``
    ! is the argument and ``B'(s)`` is parameterized by ``first_deriv``.
    real(c_double) function vec_size(s_val) result(norm_)
      real(c_double), intent(in) :: s_val
      ! Variables outside of signature.
      real(c_double) :: evaluated(1, dimension_)

      ! ``evaluate_multi`` takes degree, which is one less than the number
      ! of nodes, so our derivative is one less than that.
      call evaluate_multi( &
           num_nodes - 2, dimension_, first_deriv, 1, [s_val], evaluated)
      norm_ = norm2(evaluated)

    end function vec_size

  end subroutine compute_length

end module curve
