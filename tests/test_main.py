"""Tests for the example utility function."""

from project_name.utils.name import add


def test_add_function() -> None:
    """
    Test the add function with various inputs to ensure it returns the correct sum.
    """
    assert add(2, 3) == 5
    assert add(-1, 1) == 0
