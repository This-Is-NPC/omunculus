#!/bin/bash
python3 -m unittest discover -s "$TEST_DIR" -p 'test_*.py' -v
