"""Tests for the iOS track.

These live *inside* the ``emubackend`` package rather than in a top-level ``tests/``
directory: the BE checkout has its own plain ``tests/`` directory, and with the BE on
``sys.path`` two same-named plain directories would merge into one implicit namespace
package. Nesting them here makes that collision impossible by construction.
"""
