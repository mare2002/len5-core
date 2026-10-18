# Pinned PULP TC_SRAM

Unmodified `src/rtl/tc_sram.sv` and `LICENSE` from
https://github.com/pulp-platform/tech_cells_generic at commit
`55cb54513e2d426be5992d311cb9d5dbcad10c78`.

Only the SRAM source is vendored; no AXI or other tech-cell dependencies are used.
To update, review a specific upstream commit and copy these two files verbatim,
then rerun the memory backend verification. Ordinary builds require no network.
