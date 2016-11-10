# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""Helper for B |eacute| zier Surfaces / Triangles.

.. |eacute| unicode:: U+000E9 .. LATIN SMALL LETTER E WITH ACUTE
   :trim:
"""


import numpy as np

from bezier import _base


class Surface(_base.Base):
    r"""Represents a B |eacute| zier `surface`_.

    .. _surface: https://en.wikipedia.org/wiki/B%C3%A9zier_triangle
    .. _unit simplex:
        https://en.wikipedia.org/wiki/Simplex#The_standard_simplex
    .. _barycentric coordinates:
        https://en.wikipedia.org/wiki/Barycentric_coordinate_system

    We define a B |eacute| zier triangle as a mapping from the
    `unit simplex`_ in 2D (i.e. the unit triangle) onto a surface in an
    arbitrary dimension. We use `barycentric coordinates`

    .. math::

       \lambda_1 = 1 - s - t, \lambda_2 = s, \lambda_3 = t

    for points in

    .. math::

       \left\{(s, t) \mid 0 \leq s, t, s + t \leq 1\right\}.

    As with curves, using these weights we get convex combinations
    of points :math:`v_{i, j, k}` in some vector space:

    .. math::

       B\left(\lambda_1, \lambda_2, \lambda_3\right) =
           \sum_{i + j + k = d} \binom{d}{i \, j \, k}
           \lambda_1^i \lambda_2^j \lambda_3^k \cdot v_{i, j, k}

    .. note::

       We assume the nodes are ordered from left-to-right and from
       bottom-to-top. So for example, the linear triangle::

          (0,0,1)

          (1,0,0)  (0,1,0)

       is ordered as

       .. math::

          \left[\begin{array}{c c c}
              v_{1,0,0} & v_{0,1,0} & v_{0,0,1} \end{array}\right]^T

       the quadratic triangle::

          (0,0,2)

          (1,0,1)  (0,1,1)

          (2,0,0)  (1,1,0)  (0,2,0)

       is ordered as

       .. math::

          \left[\begin{array}{c c c c c c}
              v_{2,0,0} & v_{1,1,0} &
              v_{0,2,0} & v_{1,0,1} &
              v_{0,1,1} & v_{0,0,2} \end{array}\right]^T

       the cubic triangle::

          (0,0,3)

          (1,0,2)  (0,1,2)

          (2,0,1)  (1,1,1)  (0,2,1)

          (3,0,0)  (2,1,0)  (1,2,0)  (0,3,0)

       is ordered as

       .. math::

          \left[\begin{array}{c c c c c c c c c c}
              v_{3,0,0} & v_{2,1,0} &
              v_{1,2,0} & v_{0,3,0} &
              v_{2,0,1} & v_{1,1,1} &
              v_{0,2,1} & v_{1,0,2} &
              v_{0,1,2} & v_{0,0,3} \end{array}\right]^T

       and so on.

    Args:
        nodes (numpy.ndarray): The nodes in the surface. The rows
            represent each node while the columns are the dimension
            of the ambient space.
    """

    _area = None

    @staticmethod
    def _get_degree(num_nodes):
        """Get the degree of the current surface.

        Args:
            num_nodes (int): The number of control points for a
                B |eacute| zier surface.

        Returns:
            int: The degree :math:`d` such that :math:`(d + 1)(d + 2)/2`
            equals ```num_nodes``.

        Raises:
            ValueError: If ``num_nodes`` isn't a triangular number.
        """
        # 8 * num_nodes = 4(d + 1)(d + 2)
        #               = 4d^2 + 12d + 8
        #               = (2d + 3)^2 - 1
        d_float = 0.5 * (np.sqrt(8.0 * num_nodes + 1.0) - 3.0)
        d_int = int(np.round(d_float))
        if (d_int + 1) * (d_int + 2) == 2 * num_nodes:
            return d_int
        else:
            raise ValueError(num_nodes, 'not a triangular number')

    @property
    def area(self):
        """float: The area of the current surface.

        Raises:
            NotImplementedError: If the area isn't already cached.
        """
        if self._area is None:
            raise NotImplementedError(
                'Area computation not yet implemented.')
        return self._area