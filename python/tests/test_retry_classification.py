"""Retry classification: the license-path incident, pinned by tests.

VALIDATION.md section 9 documents the defect ("retry classified by
substring") but cited only the implementation; nothing exercised
classify(), so it could regress to substring matching without any test
noticing. These pin the three properties the fix consists of: permanent
patterns take precedence, matching is word-bounded phrases rather than
substrings, and only the head of the trace is read.
"""
import os
import sys

import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from run_pipeline import classify  # noqa: E402
from pipeline.errors import PermanentError, TransientError  # noqa: E402


def test_syntax_error_in_a_licenses_path_is_permanent():
    """The original incident, verbatim: the file path contained 'licenses',
    a substring match called it transient, and a syntax error that could
    never succeed was retried three times and degraded to stale data."""
    with pytest.raises(PermanentError):
        classify(1, "parse error: syntax error near line 40 of /opt/matlab/licenses/check.m")


def test_a_real_license_checkout_failure_is_transient():
    with pytest.raises(TransientError):
        classify(1, "License checkout failed: could not reach license server")


def test_only_the_head_of_the_trace_is_read():
    """A long stack trace mentions many files; a transient-looking phrase
    buried past the first lines must not rescue an unknown failure."""
    junk = "\n".join(f"frame {i}: anonymous" for i in range(10))
    with pytest.raises(PermanentError):
        classify(1, junk + "\nconnection reset by peer")


def test_unknown_failures_default_to_permanent():
    with pytest.raises(PermanentError):
        classify(1, "failed reading /opt/licenses/data.bin: checksum mismatch")


def test_success_returns_none():
    assert classify(0, "") is None
