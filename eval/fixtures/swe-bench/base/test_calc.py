import unittest

import calc


class Calc(unittest.TestCase):
    def test_add(self):
        self.assertEqual(calc.add(2, 1), 3)
