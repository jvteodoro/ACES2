# GTKWave setup for the SPI control-unit test.
# Run from the repository root with:
#   gtkwave -S tb/spi/spi_uc_tb.tcl tb/spi/spi_uc_tb.vcd

proc add_wave {signal format color} {
    set trace [list $signal]
    gtkwave::addSignalsFromList $trace
    gtkwave::highlightSignalsFromList $trace
    switch -- $format {
        binary  { gtkwave::/Edit/Data_Format/Binary }
        decimal { gtkwave::/Edit/Data_Format/Decimal }
        hex     { gtkwave::/Edit/Data_Format/Hex }
        normal  { }
    }
    switch -- $color {
        red    { gtkwave::/Edit/Color_Format/Red }
        orange { gtkwave::/Edit/Color_Format/Orange }
        yellow { gtkwave::/Edit/Color_Format/Yellow }
        green  { gtkwave::/Edit/Color_Format/Green }
        blue   { gtkwave::/Edit/Color_Format/Blue }
        violet { gtkwave::/Edit/Color_Format/Violet }
        normal { gtkwave::/Edit/Color_Format/Normal }
    }
    gtkwave::unhighlightSignalsFromList $trace
}

set displayed [gtkwave::getDisplayedSignals]
if {[llength $displayed] > 0} {
    gtkwave::deleteSignalsFromListIncludingDuplicates $displayed
}

add_wave {spi_uc_tb.sim_status[79:0]} ascii yellow

add_wave {spi_uc_tb.tx_data[31:0]} hex green
add_wave spi_uc_tb.tx_valid       normal orange
add_wave spi_uc_tb.tx_ready       normal green
add_wave spi_uc_tb.tx_full        normal red
add_wave spi_uc_tb.tx_empty       normal blue
add_wave spi_uc_tb.tx_we          normal violet
add_wave spi_uc_tb.start          normal yellow

add_wave spi_uc_tb.rx_empty       normal blue
add_wave spi_uc_tb.rx_ready       normal green
add_wave spi_uc_tb.rx_re          normal violet
add_wave spi_uc_tb.busy           normal orange

add_wave spi_uc_tb.cpol           normal normal
add_wave spi_uc_tb.cpha           normal normal
add_wave spi_uc_tb.lsb_first      normal normal
add_wave {spi_uc_tb.cs_sel[0:0]}  binary normal
add_wave {spi_uc_tb.clk_div[7:0]} decimal blue
add_wave {spi_uc_tb.cs_setup[1:0]} decimal yellow
add_wave {spi_uc_tb.cs_hold[1:0]} decimal yellow
add_wave spi_uc_tb.cs_inter_byte normal orange

add_wave {spi_uc_tb.checks[31:0]}   decimal green
add_wave {spi_uc_tb.failures[31:0]} decimal red

# VCD time unit is ps. Markers identify the main phases of the UC test.
gtkwave::setNamedMarker A 0    "início / INIT"
gtkwave::setNamedMarker B 1000 "reset"
gtkwave::setNamedMarker C 2000 "verificação TX"
gtkwave::setNamedMarker D 3000 "backpressure e start"
gtkwave::setNamedMarker E 5000 "verificação RX"
gtkwave::setNamedMarker F 6000 "configuração SPI"
gtkwave::setNamedMarker G 7000 "resultado final"

gtkwave::setLeftJustifySigs on
gtkwave::/Time/Zoom/Zoom_Full
gtkwave::presentWindow
puts "GTKWave: ondas do spi_uc_tb carregadas e formatadas."
