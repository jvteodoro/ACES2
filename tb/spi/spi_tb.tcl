# GTKWave setup for the SPI streaming integration test.
# Run from the repository root with:
#   gtkwave -S tb/spi/spi_tb.tcl tb/spi/spi_tb.vcd

proc add_wave {signal format color} {
    set trace [list $signal]
    gtkwave::addSignalsFromList $trace
    gtkwave::highlightSignalsFromList $trace

    switch -- $format {
        binary  { gtkwave::/Edit/Data_Format/Binary }
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
        indigo { gtkwave::/Edit/Color_Format/Indigo }
        violet { gtkwave::/Edit/Color_Format/Violet }
        normal { gtkwave::/Edit/Color_Format/Normal }
    }
    gtkwave::unhighlightSignalsFromList $trace
}

set displayed [gtkwave::getDisplayedSignals]
if {[llength $displayed] > 0} {
    gtkwave::deleteSignalsFromListIncludingDuplicates $displayed
}

add_wave {spi_tb.sim_status[79:0]} ascii yellow

add_wave spi_tb.clk_i         normal  blue
add_wave spi_tb.rst_ni        normal  red
add_wave spi_tb.tx_valid_i    normal  orange
add_wave spi_tb.tx_ready_o    normal  green
add_wave spi_tb.tx_stall_o    normal  red

add_wave {spi_tb.tx_data_i[31:0]} hex green
add_wave spi_tb.mosi_o         normal  violet
add_wave spi_tb.sck_o          normal  blue
add_wave {spi_tb.cs_n_o[0:0]}  normal  yellow

add_wave spi_tb.miso_i         normal  indigo
add_wave {spi_tb.rx_data_o[31:0]} hex indigo
add_wave spi_tb.rx_valid_o     normal  green
add_wave spi_tb.rx_ready_i     normal  orange

add_wave spi_tb.busy_o         normal  orange
add_wave spi_tb.xfer_done_o    normal  yellow
add_wave {spi_tb.accepted_count[31:0]} decimal green
add_wave {spi_tb.received_count[31:0]} decimal violet
add_wave {spi_tb.cs_fall_count[31:0]} decimal blue
add_wave {spi_tb.cs_rise_count[31:0]} decimal blue
add_wave {spi_tb.failures[31:0]}       decimal red

add_wave {spi_tb.bit_count[31:0]}    decimal normal
add_wave {spi_tb.slave_shift[31:0]} hex     normal

# VCD time unit is ps. These markers match the status transitions in spi_tb.
gtkwave::setNamedMarker A 0       "início da simulação"
gtkwave::setNamedMarker B 35000   "reset liberado"
gtkwave::setNamedMarker C 40000   "envio da palavra 0"
gtkwave::setNamedMarker D 50000   "envio da palavra 1"
gtkwave::setNamedMarker E 60000   "envio da palavra 2"
gtkwave::setNamedMarker F 70000   "envio da palavra 3"
gtkwave::setNamedMarker G 80000   "início da espera pela transferência"
gtkwave::setNamedMarker H 5000000 "checagem e resultado final"

gtkwave::setLeftJustifySigs on
gtkwave::/Time/Zoom/Zoom_Full
gtkwave::presentWindow
puts "GTKWave: ondas do spi_tb carregadas e formatadas."
