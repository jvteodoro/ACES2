# GTKWave setup for the SPI frame encoder unit test.
# gtkwave -S tb/spi/spi_frame_encoder_tb.tcl tb/spi/spi_frame_encoder_tb.vcd

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
        red     { gtkwave::/Edit/Color_Format/Red }
        orange  { gtkwave::/Edit/Color_Format/Orange }
        yellow  { gtkwave::/Edit/Color_Format/Yellow }
        green   { gtkwave::/Edit/Color_Format/Green }
        blue    { gtkwave::/Edit/Color_Format/Blue }
        violet  { gtkwave::/Edit/Color_Format/Violet }
        normal  { }
    }
}

set displayed [gtkwave::getDisplayedSignals]
if {[llength $displayed] > 0} {
    gtkwave::deleteSignalsFromListIncludingDuplicates $displayed
}

add_wave {spi_frame_encoder_tb.sim_status[255:0]} ascii yellow
add_wave spi_frame_encoder_tb.clk_i normal blue
add_wave spi_frame_encoder_tb.rst_ni normal red
add_wave {spi_frame_encoder_tb.payload_data_i[31:0]} hex green
add_wave spi_frame_encoder_tb.payload_valid_i normal orange
add_wave spi_frame_encoder_tb.payload_ready_o normal green
add_wave {spi_frame_encoder_tb.tx_data_o[31:0]} hex violet
add_wave spi_frame_encoder_tb.tx_valid_o normal violet
add_wave spi_frame_encoder_tb.tx_ready_i normal green
add_wave {spi_frame_encoder_tb.input_index[31:0]} decimal blue
add_wave {spi_frame_encoder_tb.output_index[31:0]} decimal blue
add_wave {spi_frame_encoder_tb.failures[31:0]} decimal red

# VCD time unit is ps.
gtkwave::setNamedMarker A 0     "início / reset"
gtkwave::setNamedMarker B 35000 "coleta dos 14 payloads"
gtkwave::setNamedMarker C 180000 "envio do header ACED + sequência"
gtkwave::setNamedMarker D 300000 "envio do CRC / fim do quadro"

gtkwave::setLeftJustifySigs on
gtkwave::/Time/Zoom/Zoom_Full
gtkwave::presentWindow
puts "GTKWave: ondas do spi_frame_encoder_tb carregadas."
