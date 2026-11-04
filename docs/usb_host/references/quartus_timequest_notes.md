# Quartus TimeQuest SDC reference notes

Consulted for the DE10-Lite MAX3421E host timing project on 2026-11-01.
The local tool is Quartus Prime Standard Edition 25.1.0 Build 1129.

## Official references

- [Quartus Prime Standard Edition User Guides](https://www.intel.com/programmable/technical-pdfs/qps-ugs.pdf), including the Timing Analyzer guide. The collection-search section documents `get_pins` hierarchical matching and `-compatibility_mode`.
- [Quartus Prime Timing Analyzer User Guide, document 683243](https://www.intel.com/programmable/technical-pdfs/683243.pdf), version dated 2025-09-29. Used for generated-clock and path-reporting concepts.
- [Quartus Prime Scripting User Guide, document 683432](https://www.intel.com/programmable/technical-pdfs/683432.pdf), version dated 2025-09-29. Used for the `get_pins`, `report_timing`, and timing-netlist Tcl commands.
- [Quartus Prime Standard Edition User Guide: Design Optimization, I/O Timing Optimization Techniques](https://docs.altera.com/r/docs/683230/18.1/quartus-prime-standard-edition-user-guide-design-optimization/i/o-timing-optimization-techniques). Documents the instance-level `FAST_OUTPUT_REGISTER` assignment used to request MAX 10 output-register packing.
- [MAX 10 General Purpose I/O User Guide, document 683751](https://www.intel.com/programmable/technical-pdfs/683751.pdf), section 2.2. Describes the MAX 10 IOE output-register resources.

The Intel PDF endpoint for document 683432 returned HTTP 403 to the local
download attempt, so this note preserves the relevant command use and the
official source links; it is not a local copy of that manual.

## Project-specific command and findings

The post-fit design exposes the SPI master's output register pin in TimeQuest
as `u_controller|u_bridge|u_spi|sck_q|q`. Quartus's hierarchy-aware wildcard
rules did not match a guessed module-instance path. The verified query is:

```tcl
get_pins -compatibility_mode {*sck_q|q}
```

It returns exactly one pin in the current design. `-compatibility_mode` lets
the wildcard span pipe-separated hierarchy levels. The generated 40 ns clock
is constrained at that register output and propagated to the physical
`sck_o` port. The MISO input delay is referenced to the generated clock at
the output port, with the MAX3421E Rev. 4 maximum `tDO` of 14.2 ns after SCK
fall. Unknown shield and jumper delays remain excluded until measured.

For a detailed setup path from SCK to the 50 MHz capture registers, use:

```tcl
report_timing -setup -npaths 5 \
  -from_clock spi_sck_pin -to_clock clk50 -detail full_path
```

The path report is necessary to distinguish a real constrained MISO path
from an ignored or unmatched SDC collection. A successful `quartus_sta`
process alone does not establish timing closure; inspect clock status,
ignored-constraint messages, setup/hold slack, TNS, and unconstrained I/O.

The `FAST_OUTPUT_REGISTER` setting is only a placement request. Verify in the
post-fit report that each targeted output register is actually packed into its
IOE, then review routed setup/hold timing. It does not compensate for an
unregistered combinational source, and it does not replace external pin timing
constraints or bench measurements of protocol-level CS setup/hold.

The command patterns and reports are specific to the checked Quartus 25.1
Standard Edition build. Recheck collection matches and generated-clock
propagation after hierarchy, fitter, or tool-version changes.
