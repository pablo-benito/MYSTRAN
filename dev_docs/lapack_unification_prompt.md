# LAPACK unification — follow-up agent prompt

This document is the briefing for a future agent invocation that will
extend MYSTRAN's BLAS provider knob (`MYSTRAN_BLAS`) into a combined
`MYSTRAN_BLAS_LAPACK` knob, allowing MYSTRAN to use a system-provided
LAPACK (OpenBLAS / MKL / Netlib) instead of the embedded reference
implementations under `Source/Modules/LAPACK/`.

The first half of the work — unifying BLAS — has already landed on the
`system_blas_fix` branch. This document captures everything the
follow-up agent needs to know about the LAPACK side so it does not have
to rediscover it.

---

## Current state (post BLAS-only PR)

- `MYSTRAN_BLAS={AUTO,SYSTEM,EMBEDDED}` is wired up in
  [CMakeLists.txt](../CMakeLists.txt). It controls (a) whether
  `BLAS/*.f` reference routines get bundled into mystran, (b) whether
  SuperLU/SuperLU_MT build their own CBLAS, and (c) whether mystran is
  linked against `${BLAS_LIBRARIES}`.
- Legacy `enable_internal_blaslib=YES/NO` still works and emits a
  `DEPRECATION` warning that points at the new option.
- The build-info subroutines (`PRINT_BUILD_CONSTANTS`,
  `PRINT_STATIC_LIB_LIST`) and the auto-generated license subroutines
  read from the `_MYSTRAN_STATIC_DEFS` list and the
  `_MYSTRAN_LICENSE_MAP`. `_STATIC_LAPACK` is currently force-appended
  unconditionally — see the comment that explicitly flags it for this
  follow-up.
- LAPACK is **always embedded**: every `Source/Modules/LAPACK/*.f`
  module file is unconditionally compiled in via the
  `file(GLOB_RECURSE ALL_FORTRAN_FILES ...)` in CMakeLists.txt.

---

## Why LAPACK is harder than BLAS

The embedded BLAS is **13 loose `.f` files** in `BLAS/`. Each defines
exactly one routine (e.g. `DGEMM.f` ⇒ `dgemm_`). They get included or
excluded as object files; system OpenBLAS provides identically-named
symbols, so all-or-nothing replacement at link time works trivially.

The embedded LAPACK is **9 Fortran `MODULE`s** under
`Source/Modules/LAPACK/`, each containing many subroutines:

| Module | Purpose |
|---|---|
| `LAPACK_BLAS_AUX` | Auxiliary routines used by other LAPACK code |
| `LAPACK_GIV_MGIV_EIG` | Generalised eigenvalue (Givens) helpers |
| `LAPACK_LANCZOS_EIG` | Lanczos eigenvalue helpers |
| `LAPACK_LIN_EQN_DGB` | General banded linear systems (DGBTRF/DGBTRS) |
| `LAPACK_LIN_EQN_DGE` | General dense linear systems (DGETRF/DGETRS) |
| `LAPACK_LIN_EQN_DPB` | Symmetric positive-definite banded |
| `LAPACK_MISCEL` | DSTEV, DSTERF, DSTEQR, DTRTRS |
| `LAPACK_STD_EIG_1` | DSYEV and friends |
| `LAPACK_SYM_MAT_INV` | DPOTRF/DPOTF2 |

In total they define **95 procedures**. Because they are module
procedures, every consumer in the rest of MYSTRAN does
`USE LAPACK_<something>` and the procedure references resolve at the
**source level** to module-mangled symbols
(`__lapack_blas_aux_MOD_dgemv` etc.). They never appear as bare
`dgemv_` symbols at link time and therefore *cannot* be silently
replaced by linking system LAPACK.

There are roughly **70+ `USE LAPACK_*` sites** scattered across
`Source/`, including in the auto-generated `Source/Interfaces/*.f90`
files.

---

## Routines that must stay embedded forever

A grep of the module sources turns up at least four procedures that are
either MYSTRAN-specific or have non-standard signatures and have **no
direct system equivalent**:

| Procedure | Reason |
|---|---|
| `DPTTRF_MYSTRAN` | MYSTRAN-specific name |
| `DSBGVX_GIV_MGIV` | Renamed/customized variant of LAPACK's `DSBGVX` |
| `DLACON(N, V, X, ISGN, EST, KASE, itmax)` | Extra `itmax` arg vs upstream `DLACON` |
| `EIGENVALUE_CONVERGENCE_FAILURE` | MYSTRAN error helper |

Any other routines that have been locally patched (look for `! My ...`
comments and similar) need to stay too. **The audit below must
identify every such case.**

---

## Recommended approach

1. **Audit each of the 95 procedures** against the upstream Netlib
   LAPACK reference (or whatever vintage of LAPACK these were copied
   from — best guess from comments is LAPACK 3.x) and classify into:
   - **Standard** — signature byte-for-byte identical to upstream
     LAPACK. Safe to replace with an `INTERFACE` block in SYSTEM mode.
   - **Custom** — different name, extra args, MYSTRAN error reporting,
     or any other deviation. Must remain compiled in always.
   Produce a Markdown table with one row per routine: name, module,
   classification, notes.

2. **Convert the 9 module files to use the C preprocessor.** They are
   currently `.f` (no preprocessing). Either rename to `.F` or set
   `set_source_files_properties(... PROPERTIES Fortran_PREPROCESS ON)`.
   The codebase already uses uppercase `.F90` for some preprocessed
   files, so renaming is consistent.

3. **Restructure each module** as:
   ```fortran
   MODULE LAPACK_BLAS_AUX
     ! ... existing USE statements ...
     IMPLICIT NONE
   #ifdef MYSTRAN_SYSTEM_LAPACK
     INTERFACE
       ! Explicit interface block per standard routine, copied
       ! verbatim from netlib so INTENT/dimensions match exactly.
       SUBROUTINE DGEMV(TRANS,M,N,ALPHA,A,LDA,X,INCX,BETA,Y,INCY)
         ...
       END SUBROUTINE DGEMV
       ! ...
     END INTERFACE
   #endif
   CONTAINS
   #ifndef MYSTRAN_SYSTEM_LAPACK
     ! All embedded standard-routine bodies.
   #endif
     ! Custom / always-compiled routines (DPTTRF_MYSTRAN, DLACON
     ! with itmax, etc.) live outside the #ifdef and are always built.
   END MODULE
   ```

4. **CMake wiring** (small):
   - Promote `MYSTRAN_BLAS` to `MYSTRAN_BLAS_LAPACK` (keep `MYSTRAN_BLAS`
     as a deprecation alias the same way `enable_internal_blaslib` is
     handled today).
   - In SYSTEM mode also call `find_package(LAPACK)`; FATAL_ERROR if
     missing.
   - In SYSTEM mode: `target_compile_definitions(mystran PRIVATE
     MYSTRAN_SYSTEM_LAPACK)` and append `${LAPACK_LIBRARIES}` to
     `target_link_libraries(mystran ...)` (LAPACK before BLAS).
   - Make `_STATIC_LAPACK` conditional on EMBEDDED mode (currently
     unconditionally appended; the comment in CMakeLists.txt flags
     this site explicitly).
   - Restore the `_LAPACK_INFO` build-info field (it was added and
     reverted during the BLAS-only PR — git log will show the diff).
   - Update `BUILD.md` to describe the now-combined option and remove
     the "LAPACK is always embedded" caveat.

5. **Numerical regression testing.** Wrong INTENTs in interface blocks
   produce silently wrong results. Run the full `Build_Test_Cases/`
   statics + buckling + dynamics suite under both EMBEDDED and SYSTEM
   modes and diff the outputs. Treat any diff beyond floating-point
   noise as a bug in an interface block.

---

## Key files / starting points

- [CMakeLists.txt](../CMakeLists.txt) — search for
  `MYSTRAN_BLAS`, `_MYSTRAN_BLAS_MODE`, `_STATIC_LAPACK`, `_BLAS_INFO`.
- [Source/Modules/LAPACK/](../Source/Modules/LAPACK) — the 9 files to
  restructure.
- [BLAS/](../BLAS) — pattern for what loose-file standard routines look
  like (this directory is *not* affected by the LAPACK work).
- [Source/MAIN/PRINT_BUILD_INFO.F90](../Source/MAIN/PRINT_BUILD_INFO.F90)
  — already keys off `_STATIC_*` macros; nothing to change here.
- [BUILD.md](../BUILD.md) — user-facing docs.

To enumerate every consumer:

```bash
grep -rE '^\s+USE\s+LAPACK_' Source/ | sort -u
```

To list every procedure declared in the embedded modules:

```bash
cd Source/Modules/LAPACK
grep -hE '^\s+(SUBROUTINE|.*FUNCTION)\s+[A-Z_][A-Z0-9_]*' *.f | sort -u
```

---

## Test environment

- Linux dev machine has OpenBLAS at `/usr/lib/libopenblas.so` which
  exposes the LAPACK API. `find_package(LAPACK)` succeeds out of the
  box and reports `LAPACK_LIBRARIES = /usr/lib/libopenblas.so;-lm;-ldl`.
- Windows MSYS2 / MinGW64: `pacman -S mingw-w64-x86_64-openblas`
  installs a static OpenBLAS that also covers LAPACK.

---

## Decisions inherited from the BLAS-only PR

- All-or-nothing replacement (no per-routine fallback). LAPACK follows
  the same model — but "all" excludes the always-custom routines
  enumerated above.
- Detection via `find_package(LAPACK)`, no symbol probing.
- Windows static-binary support is non-negotiable; OpenBLAS static
  archive is the recommended provider.
- Legacy CMake flags get deprecation warnings, not removal.
