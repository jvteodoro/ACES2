# GTKWave setup for the one-CS-pulse-per-word SPI test.
# Run from the repository root with:
#   gtkwave -S tb/spi/spi_pulsed_tb.tcl tb/spi/spi_pulsed_tb.vcd

proc add_wave {signal format color} {
    set trace [list $signal]
    gtkwave::addSignalsFromList $trace
    switch -- $format {
        decimal { gtkwave::/Edit/Data_Format/Decimal }
        hex     { gtkwave::/Edit/Data_Format/Hex }
        ascii   { gtkwave::/Edit/Data_Format/ASCII }
        normal  { }
    }
    switch -- $color {
        red    { gtkwave::/Edit/Color_Format/Red }
        orange { gtkwave::/Edit/Color_Format/Orange }
        yellow { gtkwave::/Edit/Color_Format/Yellow }
        green  { gtkwave::/Edit/Color_Format/Green }
        blue   { gtkwave::/Edit/Color_Format/Blue }
        violet { gtkwave::/Edit/Color_Format/Violet }
        normal { }
    }
}

set displayed [gtkwave::getDisplayedSignals]
if {[llength $displayed] > 0} {
    gtkwave::deleteSignalsFromListIncludingDuplicates $displayed
}

add_wave {spi_pulsed_tb.sim_status[79:0]} ascii yellow
add_wave spi_pulsed_tb.clk_i normal blue
add_wave spi_pulsed_tb.rst_ni normal red
add_wave spi_pulsed_tb.tx_valid_i normal orange
add_wave spi_pulsed_tb.tx_ready_o normal green
add_wave {spi_pulsed_tb.tx_data_i[31:0]} hex green
add_wave spi_pulsed_tb.mosi_o normal violet
add_wave spi_pulsed_tb.sck_o normal blue
add_wave {spi_pulsed_tb.cs_n_o[0:0]} normal yellow
add_wave spi_pulsed_tb.busy_o normal orange
add_wave spi_pulsed_tb.xfer_done_o normal yellow
add_wave {spi_pulsed_tb.accepted_count[31:0]} decimal green
add_wave {spi_pulsed_tb.received_count[31:0]} decimal violet
add_wave {spi_pulsed_tb.cs_fall_count[31:0]} decimal blue
add_wave {spi_pulsed_tb.cs_rise_count[31:0]} decimal blue
add_wave {spi_pulsed_tb.bit_count[31:0]} decimal normal
add_wave {spi_pulsed_tb.slave_shift[31:0]} hex normal
add_wave {spi_pulsed_tb.failures[31:0]} decimal red

# VCD time unit is ps. Markers delimit reset, each word and validation.
gtkwave::setNamedMarker A 0       "início"
gtkwave::setNamedMarker B 35000   "reset liberado"
gtkwave::setNamedMarker C 40000   "palavra 0 / CS pulse"
gtkwave::setNamedMarker D 50000   "palavra 1 / CS pulse"
gtkwave::setNamedMarker E 60000   "palavra 2 / CS pulse"
gtkwave::setNamedMarker F 70000   "palavra 3 / CS pulse"
gtkwave::setNamedMarker G 5000000 "checagem final"

gtkwave::setLeftJustifySigs on
gtkwave::/Time/Zoom/Zoom_Full
gtkwave::presentWindow
puts "GTKWave: ondas do spi_pulsed_tb carregadas."
