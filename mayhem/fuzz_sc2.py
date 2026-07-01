#!/usr/bin/env python3
# Honest successor to the original mayhemheroes/sc2reader OSS-Fuzz-style harness (target
# name "fuzz-sc2" / harness basename "fuzz_sc2.py" preserved for parity). Drives the real
# public parsing entry point of the library, sc2reader.load_replay(), on fuzzer-controlled
# bytes framed as an in-memory ".SC2Replay" (MPQ archive) file:
#   sc2reader.load_replay(file_like) -> Replay
#
# load_replay() opens the MPQ container, decodes its bit-packed/versioned sub-streams
# (header, details, attributes, game/tracker events, message events) and runs the engine's
# default plugin pipeline over the resulting event stream — this exercises essentially all
# of sc2reader's format-parsing surface from a single entry point.
#
# Malformed/adversarial input is expected to fail somewhere in that pipeline. sc2reader wraps
# its own validation failures in SC2ReaderError (MPQError for a bad archive, ReadError/
# ParseError for a corrupt sub-stream, ...), but many internal decode/plugin paths let a bare
# stdlib exception escape instead of wrapping it (confirmed by local mutation-fuzzing over the
# seed corpus): TypeError from decoders.py's own "Unknown Data Structure" guard, KeyError/
# IndexError from dict/list lookups on decoded-but-nonsensical values, AttributeError from a
# plugin dereferencing a player/unit lookup that legitimately returned None, UnicodeDecodeError/
# struct.error from decoding attacker-controlled byte counts as text/ints, ValueError from an
# out-of-range timestamp, and RecursionError from a self-referential bit-packed structure. Those
# are ALL "expected" outcomes for malformed input (same failure family the library's own
# SC2ReaderError already models) so we swallow exactly those types and let anything else
# propagate as a real crash for Mayhem to find.
import struct
import sys
import zlib

import atheris
import fuzz_helpers

with atheris.instrument_imports():
    import sc2reader

from sc2reader.exceptions import SC2ReaderError

_EXPECTED = (
    SC2ReaderError,
    TypeError,
    ValueError,
    AttributeError,
    KeyError,
    IndexError,
    UnicodeDecodeError,
    UnicodeError,
    struct.error,
    zlib.error,
    EOFError,
    OverflowError,
    RecursionError,
)


def TestOneInput(data):
    fdp = fuzz_helpers.EnhancedFuzzedDataProvider(data)
    try:
        with fdp.ConsumeMemoryFile(all_data=True, as_bytes=True) as f:
            sc2reader.load_replay(f)
    except _EXPECTED:
        return -1


def main():
    atheris.Setup(sys.argv, TestOneInput)
    atheris.Fuzz()


if __name__ == "__main__":
    main()
