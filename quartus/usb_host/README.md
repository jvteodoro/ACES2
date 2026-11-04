# USB host Quartus project

Open `usb_host.qpf` with Quartus Prime for the DE10-Lite MAX 10
10M50DAF484C7G. `usb_host.qsf` includes the USB host top and reused SPI core.
The only physical user I/O assignments are the documented board 50 MHz clock,
KEY0 reset, and Arduino D10-D13 SPI pins. The shield's INT, power, reset, and
ground routing has not been established, so those paths remain virtual.

Most top outputs are virtual to permit isolated synthesis without inventing a
board connector. Quartus Prime Standard 25.1std is installed at
`/home/enoch/altera_lite/25.1std/quartus/bin`; use its absolute path because
it is not on the default `PATH`. The checked-in Quartus report set contains a
successful Analysis & Synthesis map summary, but no fitter report tied to the
current RTL/QSF/SDC hashes. The saved TimeQuest reports are also from a
different source/constraint set and include global setup violations and
unconstrained ports. This project therefore does not establish current fitting
or physical board timing closure: it uses virtual I/O and the external shield
route is unknown. See `../../docs/usb_host/results/core_synthesis/manifest.json`
and the reports under `../../docs/usb_host/results/core_timing/`; rerun the
flow before using the results as final acceptance evidence.

The SDC defines the 50 MHz input and divide-by-two generated SPI clock, plus a
14.2 ns falling-edge MISO maximum delay from the MAX3421E datasheet. It omits
unknown board and shield propagation delays. Review the saved setup, hold,
constraint, and unconstrained-path reports; the current negative setup slack
must be resolved or explained by a protocol-accurate constraint before
claiming timing feasibility. Update external delays after confirming the
module revision and wiring.
