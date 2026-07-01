/* mayhem/embed_launcher.c — the ELF Mayhem actually launches for the "fuzz-sc2" target.
 *
 * Mayhem requires a target's Mayhemfile `cmd` to be a real ELF, and atheris' fuzzer itself is a
 * plain Python script. Rather than exec()-ing into a separate python3 process (which swaps the
 * process image Mayhem is tracking coverage for, and empirically zeroes edges_covered even though
 * the fuzzer runs fine), this launcher EMBEDS the interpreter via the CPython C API and stays in
 * ONE process end to end: Py_InitializeFromConfig() here, then straight into
 * `import fuzz_sc2; fuzz_sc2.main()`, which calls atheris.Setup()/atheris.Fuzz() — atheris's own
 * compiled core (dlopen'd into THIS process) is what actually implements the libFuzzer driver
 * loop and coverage counters, so Mayhem sees them exactly as if it had launched `python3
 * fuzz_sc2.py` directly, while this binary supplies the on-disk ELF (+ DWARF-3 debug info, see
 * build.sh) identity Mayhem's static checks require.
 *
 * PY_HOME is baked in at compile time (build.sh) to the fuzz-venv's base prefix, so the embedded
 * interpreter finds its stdlib regardless of where this launcher binary itself lives on disk.
 */
#include <Python.h>
#include <stdio.h>

#ifndef PY_HOME
#define PY_HOME ""
#endif

int main(int argc, char *argv[]) {
    PyStatus status;
    PyConfig config;
    PyConfig_InitPythonConfig(&config);

    /* Our own argv (libFuzzer/atheris flags like -runs=N, -max_total_time=N, a corpus dir, a
     * crashing-input path, ...) must land verbatim in sys.argv for atheris.Setup() to parse —
     * NOT be interpreted as `python3` CLI flags (the default parse_argv=1 would choke on
     * "-runs=200" as an unknown interpreter option). */
    config.parse_argv = 0;

    if (PY_HOME[0] != '\0') {
        status = PyConfig_SetBytesString(&config, &config.home, PY_HOME);
        if (PyStatus_Exception(status)) goto fail;
    }

    status = PyConfig_SetBytesArgv(&config, argc, argv);
    if (PyStatus_Exception(status)) goto fail;

    status = Py_InitializeFromConfig(&config);
    if (PyStatus_Exception(status)) goto fail;
    PyConfig_Clear(&config);

    /* site.addsitedir() (not a plain sys.path.insert) — sc2reader is pip-installed *editable*
     * in the fuzz-venv, which registers its import finder via a .pth file in site-packages;
     * .pth files are only executed by site-processing a directory, never by just appending it
     * to sys.path, so a plain insert leaves "import sc2reader" unresolved. */
    int rc = PyRun_SimpleString(
        "import sys, glob, site\n"
        "sp = glob.glob('/mayhem/fuzz-venv/lib/python3.*/site-packages')\n"
        "if sp:\n"
        "    site.addsitedir(sp[0])\n"
        "sys.path.insert(0, '/mayhem/mayhem')\n"
        "import fuzz_sc2\n"
        "fuzz_sc2.main()\n"
    );

    if (Py_FinalizeEx() < 0) rc = 120;
    return rc;

fail:
    PyConfig_Clear(&config);
    Py_ExitStatusException(status);
    return 1; /* unreachable: Py_ExitStatusException() exits the process */
}
