# See the License for the specific language governing permissions and
# limitations under the License.
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

import unittest


class TestSurface(unittest.TestCase):

    @staticmethod
    def _get_target_class():
        from bezier import surface

        return surface.Surface

    def _make_one(self, *args, **kwargs):
        klass = self._get_target_class()
        return klass(*args, **kwargs)

    def test_constructor(self):
        import numpy as np

        nodes = np.array([
            [0.0, 0.0],
            [0.625, 0.5],
            [1.0, 0.75],
        ])
        surface = self._make_one(nodes)
        self.assertEqual(surface._degree, 1)
        self.assertEqual(surface._dimension, 2)
        self.assertIs(surface._nodes, nodes)
        self.assertIsNone(surface._area)

    def test_constructor_wrong_dimension(self):
        import numpy as np

        nodes = np.array([1.0, 2.0])
        with self.assertRaises(ValueError):
            self._make_one(nodes)

        nodes = np.zeros((2, 2, 2))
        with self.assertRaises(ValueError):
            self._make_one(nodes)

    def test_constructor_bad_degree(self):
        import numpy as np

        nodes = np.array([
            [0.0, 0.0],
        ])
        with self.assertRaises(ValueError):
            self._make_one(nodes)

    def test__get_degree_valid(self):
        klass = self._get_target_class()

        self.assertEqual(0, klass._get_degree(1))
        self.assertEqual(1, klass._get_degree(3))
        self.assertEqual(2, klass._get_degree(6))
        self.assertEqual(3, klass._get_degree(10))
        self.assertEqual(11, klass._get_degree(78))

    def test__get_degree_invalid(self):
        klass = self._get_target_class()

        with self.assertRaises(ValueError):
            klass._get_degree(2)

        with self.assertRaises(ValueError):
            klass._get_degree(9)

    def test___repr__(self):
        import numpy as np

        nodes = np.zeros((15, 3))
        surface = self._make_one(nodes)
        expected = '<Surface (degree=4, dimension=3)>'
        self.assertEqual(repr(surface), expected)

    def test_area_property_not_cached(self):
        import numpy as np

        nodes = np.array([
            [0.0, 0.0],
            [1.0, 2.0],
            [2.0, 3.0],
        ])
        surface = self._make_one(nodes)
        self.assertIsNone(surface._area)
        with self.assertRaises(NotImplementedError):
            getattr(surface, 'area')

    def test_area_property(self):
        import numpy as np

        nodes = np.array([
            [0.0, 0.0],
            [1.0, 2.0],
            [2.0, 3.0],
        ])
        surface = self._make_one(nodes)
        area = 3.14159
        surface._area = area
        self.assertEqual(surface.area, area)