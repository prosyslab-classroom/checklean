# checklean

`checklean` scans the Lean project for forbidden tactics

## Use as a dependency

Add `checklean` to your project's `lakefile.lean`:

```lean
require checklean from git
  "https://github.com/prosyslab-classroom/checklean" @ "main"
```

Fetch the dependency, then run its executable from the root of your project:

```sh
lake update checklean
lake exe @checklean/check-lean
```

Pass prefixes after the executable name to replace the defaults:

```sh
lake exe @checklean/check-lean omega native_decide
```

The `@checklean/` qualifier selects the executable supplied by the dependency rather than a target in your own package.

## Command-line usage

```sh
lake exe check-lean
```

With no arguments, the forbidden prefixes are `simp`, `aesop`, `grind`, `omega`, and `trivial`. Positional arguments replace those defaults:

```sh
lake exe check-lean omega native_decide
```

Matching is case-sensitive substring matching in tactic positions. For example, `simp` also rejects `simpa`, `simp_all`, `dsimp`, and any user-defined tactic containing `simp`. Comments, strings, and ordinary identifiers are ignored. Tactic quotations such as `` `(tactic| simp) `` are checked, but macro expansion results and dependency source files are not.

The command recursively checks every `.lean` file below the current directory, excluding `.git`, `.lake`, and symbolic links. Diagnostics are written to stderr.

| Exit code | Meaning |
| --- | --- |
| `0` | Scan completed with no forbidden tactics; the executable prints nothing. |
| `1` | At least one forbidden tactic was found. |
| `2` | A file could not be read or analyzed by the Lean frontend. |

Run the test suite with `lake test`.
