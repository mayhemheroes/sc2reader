#!/usr/bin/env bash
#
# mayhem/build.sh — build sc2reader's atheris fuzz target ("fuzz-sc2").
#
# sc2reader is pure Python (no C extension of its own; its only binary dependency, pillow,
# installs from a prebuilt manylinux wheel) — there is no "sanitize the project" compile step
# the way a C/C++ repo has one. What this script actually builds:
#   1) /mayhem/test-venv  — the project + pytest, NORMAL flags, for mayhem/test.sh's oracle.
#   2) /mayhem/fuzz-venv  — the project + atheris, for mayhem/fuzz_sc2.py.
#   3) /mayhem/fuzz_sc2   — a tiny C launcher (mayhem/embed_launcher.c) that EMBEDS the Python
#      interpreter via the CPython C API (Py_Initialize + import/run fuzz_sc2.main()) IN THE SAME
#      PROCESS, rather than exec()-ing into a separate python3. An exec() swaps the whole process
#      image out from under Mayhem's coverage collector — the fuzzer runs fine but edges_covered
#      comes back 0 (verified: our first cut of this integration did exactly that). Embedding
#      keeps one continuous process from launch through atheris's own libFuzzer driver loop, so
#      atheris's compiled coverage counters (loaded into that same process) are visible to Mayhem.
#      This launcher is also fully our own compile, so it's what carries DEBUG_FLAGS (DWARF <= 3,
#      see §6.2 item 10) and links against $SANITIZER_FLAGS.
#
# Air-gapped (SPEC §6.2 item 9 / §6.5): every pip install below is `--no-index
# --find-links=$PIP_WHEELHOUSE` against the wheelhouse the Dockerfile populated ONLINE — no step
# here ever reaches PyPI, so a `docker run --network none ... bash mayhem/build.sh` re-run (and
# the air-gapped PATCH re-run) succeeds identically. Re-running on an already-built tree is also
# idempotent: `python3 -m venv` on an existing venv directory and `pip install` on an
# already-satisfied requirement are both no-ops.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — it must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# Build knobs from the ENVIRONMENT (overridable; base image ENV supplies the defaults).
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
# DEBUG_FLAGS carries DWARF debug info (DWARF MUST be < 4 — Mayhem triage can't read >= 4; clang-19's
# plain `-g` emits DWARF-5, so `-gdwarf-3` is explicit) into the launcher — the one binary here we
# actually compile ourselves (libpython/atheris are dynamically loaded .so's, contributing no CUs
# into the launcher's own ELF, so its .debug_info is exactly our one DWARF-3 CU, no anchor needed).
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}"
: "${MAYHEM_JOBS:=$(nproc)}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX MAYHEM_JOBS

WHEELHOUSE="${PIP_WHEELHOUSE:-/opt/toolchains/python/wheelhouse}"

cd "$SRC"

# 1) Test oracle venv: the project + pytest, installed from the wheelhouse only.
# --copies (not the default symlink-to-system-python venv): mayhem/test.sh's anti-reward-hack
# sabotage check (verify-repo.sh §6.3) neuters "the program" by LD_PRELOADing a constructor that
# _exit(0)s any executable whose OWN on-disk path isn't under a system prefix (/usr/bin, /bin, ...).
# A symlink venv's bin/python resolves (via /proc/self/exe) straight through to the SYSTEM
# python3 binary, so it would never trip that check and the sabotage run would be indistinguishable
# from normal — not because the oracle is behavioral, but because there's no project-owned
# executable to neuter. --copies gives /mayhem/test-venv/bin/python its own on-disk identity under
# /mayhem, so it IS the thing that gets neutered, exactly like a compiled harness binary would be.
python3 -m venv --copies /mayhem/test-venv
/mayhem/test-venv/bin/pip install --no-index --find-links="$WHEELHOUSE" --upgrade pip setuptools wheel
/mayhem/test-venv/bin/pip install --no-index --find-links="$WHEELHOUSE" -e "$SRC" pytest

# 2) Fuzz venv: the project + atheris, same offline source.
python3 -m venv --copies /mayhem/fuzz-venv
/mayhem/fuzz-venv/bin/pip install --no-index --find-links="$WHEELHOUSE" --upgrade pip setuptools wheel
/mayhem/fuzz-venv/bin/pip install --no-index --find-links="$WHEELHOUSE" -e "$SRC" atheris

# 3) The embedding launcher ELF Mayhem's Mayhemfile points at (see mayhem/embed_launcher.c).
# Uses the fuzz-venv's own python3 to derive the exact include/lib flags + base prefix (PY_HOME)
# so the embedded interpreter matches the venv that has atheris/sc2reader installed.
PYBIN=/mayhem/fuzz-venv/bin/python3
PY_INC="$("$PYBIN" -c 'import sysconfig; print(sysconfig.get_path("include"))')"
PY_LIBDIR="$("$PYBIN" -c 'import sysconfig; print(sysconfig.get_config_var("LIBDIR"))')"
PY_ABI="$("$PYBIN" -c 'import sysconfig; print(sysconfig.get_config_var("LDVERSION") or sysconfig.get_config_var("VERSION"))')"
PY_HOME="$("$PYBIN" -c 'import sys; print(sys.base_prefix)')"
$CC $DEBUG_FLAGS -O0 "-I$PY_INC" "-DPY_HOME=\"$PY_HOME\"" \
    "$SRC/mayhem/embed_launcher.c" -o /mayhem/fuzz_sc2 \
    "-L$PY_LIBDIR" "-lpython$PY_ABI" -lpthread -ldl -lutil
