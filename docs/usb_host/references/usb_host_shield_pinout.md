# MAX3421E USB Host Shield pinout notes

## Common full-size USB Host Shield 2.0

The Circuits@Home hardware manual describes the common full-size MAX3421E
shield routing as D9 for `INT`, D10 for `SS/CS`, and D11–D13 for SPI (`MOSI`,
`MISO`, `SCK`). The MAX3421E reset input is tied to the Arduino `RESET` rail.
D8 is not used by that shield interface; `GPX` is available on a separate pad.
The manual also describes board variants and solder-jumper/trace modifications,
so a clone or modified shield must be checked against its own schematic.

The connected board is reported to carry the silkscreen “2045L USB Host
Shield”. No authoritative schematic or revision-specific pinout has been found
for that marking. Treat the common full-size routing below as a working
hypothesis until the board's front and back are visually matched to a schematic.

The manual notes that the MAX3421E itself uses 3.3-V logic and that full-size
shield variants differ in their power and level-shifter configuration. Verify
the installed board's `VL`, pull-up, MISO high level, VBUS selection, ground,
and level translators before treating a 3.3-V FPGA connection as electrically
safe. A bus-powered UM2 needs USB VBUS in the USB 5-V range; check for
4.75–5.25 V from USB-A VBUS to GND with the shield powered before connecting
the interface. Do not confuse VBUS power with the shield's separate 3.3-V
MAX3421E logic rail. The repository does not identify the connected shield
revision yet.

## Mapping used by this DE10-Lite top

| MAX3421E signal | USB Host Shield header | DE10-Lite signal | FPGA package pin |
|---|---|---|---|
| `CS` | D10 | `Arduino_IO10` | AB19 |
| `MOSI` | D11 | `Arduino_IO11` | AA19 |
| `MISO` | D12 | `Arduino_IO12` | Y19 |
| `SCK` | D13 | `Arduino_IO13` | AB20 |
| `INT_n` | D9 | `Arduino_IO9` | AA17 |
| `RES_n` | Arduino `RESET` | `arduino_reset_n` | F16 |
| `GPX` | separate pad / unused | D8 left high impedance | AB17 |

The DE10-Lite User Manual labels the Arduino digital pads 3.3-V LVTTL and the
Arduino reset signal active-low. The current top therefore drives MAX3421E
`RES#` from the KEY0 reset conditioner through the dedicated Arduino reset net,
reads `INT#` at D9, and leaves D8 undriven. This is the standard shield
configuration, not a measurement of the unidentified physical shield.

## Sources

- Circuits@Home, [USB Host Shield Hardware Manual](https://chome.nerpa.tech/usb-host-shield-hardware-manual/), full-size shield layout, D9/D10 interface, GPX, reset and power sections.
- Behringer, [UM2 product page](https://behringer.com/en/products/0805-AAL), states the interface is bus-powered over its USB connection.
- Behringer, [U-PHORIA Quick Start Guide](https://mediadl.musictribe.com/media/sys_master/h1f/h9b/8849476255774.pdf), identifies the UM2 POWER LED as the indication that the unit is on.
- Analog Devices/Maxim, [MAX3421E data sheet](https://docs.sparkfun.com/SparkFun_USB-C_Host_Shield/assets/component_documentation/MAX3421E.pdf), specifies USB VBUS from 4.75 V to 5.25 V.
- Terasic, `docs/DE10-Lite_User_Manual.pdf`, Table 3-7/3-8 and Arduino reset assignment; local SHA-256 is recorded in `docs/usb_host/references/SHA256SUMS`.
