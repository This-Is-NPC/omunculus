import pathlib
import unittest


class Greeting(unittest.TestCase):
    def test_greeting(self):
        text = pathlib.Path("greeting.txt").read_text()
        self.assertEqual(text.splitlines(), ["Hello, Ana!", "Hello, Bruno!"])
