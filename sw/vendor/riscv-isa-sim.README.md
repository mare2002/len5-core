# Spike reference dependency

`riscv-isa-sim/` is an unmodified import of Spike v1.1.0, revision
`530af85d83781a3dae31a4ace84a573ec255fefa`, using `util/vendor.py` and the adjacent
`.vendor.hjson` / `.lock.hjson` files. Upstream license files are preserved.
`.github` and Git metadata are excluded, like the other vendor imports.

The source directory is ignored by Git; the adjacent metadata remains tracked.
On a fresh checkout, run `make vendor-update-spike` once to import the sources.
Normal builds then use these local sources without network access. The optional
RTL checker (`make verilator-build DIFF=1` or `make diff-build`) builds its static
reference libraries under `build/diff/spike-build` only when necessary. An ordinary
`make verilator-build` keeps verification disabled and has no Spike dependency.
`make diff-spike` builds just the libraries, not the standalone Spike executable.

Use `make vendor-update-spike` only to explicitly reimport the pinned upstream
revision. Changing the pin requires adapting and validating the C++ integration.
See [the verification guide](../../tb/verilator/diff/README.md) for details.
