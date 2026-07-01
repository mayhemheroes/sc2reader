# syntax=docker/dockerfile:1.7
#
# Commit-image Dockerfile — PYTHON target (pip / atheris). sc2reader is a pure-Python
# library (no C extensions of its own; its only binary dependency, pillow, ships prebuilt
# manylinux wheels), so this builds ON TOP of the org C/C++ base image only for its
# identities/build-contract ENV and a compiler to build our tiny ELF launcher (see
# mayhem/trampoline.c) — no language toolchain under /opt/toolchains/<lang> is needed here
# beyond the pip wheelhouse cache described below.
#
# Build (from the repo root, on the `mayhem` branch):
#   DOCKER_BUILDKIT=1 docker build -f mayhem/Dockerfile \
#       --build-arg COMMIT=$(git rev-parse HEAD) \
#       [--build-arg SOURCE_DATE_EPOCH=$(date +%s)] -t mytag .

FROM ghcr.io/mayhemheroes/base:20260621

ARG COMMIT
ARG REPO_URL
# SOURCE_DATE_EPOCH stays an ARG (available to build.sh); do NOT bake it as an ENV — an
# empty value breaks clang both here and for any in-image rebuild.
ARG SOURCE_DATE_EPOCH
ARG SANITIZER_FLAGS
ARG MAYHEM_JOBS=

# Python toolchain (python3-venv for isolated build/test venvs; python3-dev for any C
# extension pip needs to build from source; python-is-python3 so `python` resolves).
USER root
RUN [ -n "$SOURCE_DATE_EPOCH" ] && repro-sources-list.sh || true ; \
    apt-get update && apt-get install -yq --no-install-recommends \
      python3 python3-dev python3-venv python3-pip python-is-python3 \
    && rm -rf /var/lib/apt/lists/*

# ── Python wheelhouse @ a FIXED, lockable, $HOME-independent prefix (SPEC §6.2 item 8, §6.5) ──
# Populated HERE, ONLINE, at image-build time (the only network access this Dockerfile needs);
# mayhem/build.sh (incl. the air-gapped PATCH re-run) installs EXCLUSIVELY from this cache via
# `pip install --no-index --find-links=$PIP_WHEELHOUSE`, so a later offline re-run never reaches
# PyPI. Owned by mayhem (2000) so build.sh (running as mayhem) can read it.
ENV PIP_WHEELHOUSE=/opt/toolchains/python/wheelhouse
RUN install -d -o 2000 -g 2000 "$PIP_WHEELHOUSE" \
 && pip3 download --dest "$PIP_WHEELHOUSE" --no-cache-dir \
      "pip" "setuptools>=61.2" "wheel" "mpyq" "pillow" "pytest" "atheris"

USER mayhem
WORKDIR /mayhem
COPY --chown=2000:2000 . /mayhem

RUN bash mayhem/build.sh

RUN if [ -f mayhem/test.sh ]; then bash mayhem/test.sh; else echo "no mayhem/test.sh — repo ships no functional tests"; fi

LABEL org.opencontainers.image.source="${REPO_URL}" \
      org.opencontainers.image.revision="${COMMIT}" \
      rlenv.tier="commit" \
      rlenv.source_date_epoch="${SOURCE_DATE_EPOCH}" \
      rlenv.user="mayhem"

USER mayhem
WORKDIR /mayhem
