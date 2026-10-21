"""This module contains pytest fixtures for providing sample data to test functions."""

import pytest


@pytest.fixture
def sample_data() -> dict[str, int]:
    """Provide standard sample data for test functions."""
    return {"a": 2, "b": 3}
