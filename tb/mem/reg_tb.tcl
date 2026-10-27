# GTKWave setup for reg_tb.
# Usage from the repository root:
#   gtkwave -S tb/mem/reg_tb.tcl tb/mem/reg_tb.vcd

# Add one signal and apply its display format and waveform color.
proc add_wave {signal format color} {
    set trace [list $signal]
    gtkwave::addSignalsFromList $trace
    gtkwave::highlightSignalsFromList $trace

    switch -- $format {
        ascii   { gtkwave::/Edit/Data_Format/ASCII }
        binary  { gtkwave::/Edit/Data_Format/Binary }
        decimal { gtkwave::/Edit/Data_Format/Decimal }
        hex     { gtkwave::/Edit/Data_Format/Hex }
        # Normal is GTKWave's default representation; no menu action needed.
        normal  { }
        default { puts "Formato desconhecido para $signal: $format" }
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
        default { puts "Cor desconhecida para $signal: $color" }
    }

    gtkwave::unhighlightSignalsFromList $trace
}

# Comment traces work as visual separators between functional groups.
proc add_separator {title} {
    gtkwave::addCommentTracesFromList [list "--- $title ---"]
}

# Remove any traces that may have been loaded by a previous session.
set displayed [gtkwave::getDisplayedSignals]
if {[llength $displayed] > 0} {
    gtkwave::deleteSignalsFromListIncludingDuplicates $displayed
}

# -----------------------------------------------------------------------------
# Clock and control: blue clock, red reset, orange write enable.
# -----------------------------------------------------------------------------
add_separator "CLOCK E CONTROLE"
add_wave "reg_tb.clk"           normal  blue
add_wave "reg_tb.rst"           normal  red
add_wave "reg_tb.we"            normal  orange

# -----------------------------------------------------------------------------
# Data path: inputs and output are hexadecimal for compact word-level reading.
# -----------------------------------------------------------------------------
add_separator "CAMINHO DE DADOS"
add_wave {reg_tb.in[31:0]}       hex     green
add_wave {reg_tb.out[31:0]}      hex     violet

# -----------------------------------------------------------------------------
# Verification status: sim_status is an 80-bit ASCII field (10 characters).
# Counters use decimal representation to make the test progress obvious.
# -----------------------------------------------------------------------------
add_separator "STATUS DA VERIFICACAO"
add_wave {reg_tb.sim_status[79:0]} ascii  yellow
add_wave {reg_tb.test_num[31:0]}   decimal indigo
add_wave {reg_tb.failure_count[31:0]} decimal red

# Simulation constants are useful when correlating stimulus with the testbench.
add_separator "PARAMETROS DO TESTE"
add_wave {reg_tb.TEST_WORD_1[31:0]} hex normal
add_wave {reg_tb.TEST_WORD_2[31:0]} hex normal

# Named markers (VCD time unit is ps; 20 ns clock period = 20000 ps).
gtkwave::setNamedMarker A 40000  "fim do reset inicial"
gtkwave::setNamedMarker B 80000  "retenção sem we"
gtkwave::setNamedMarker C 140000 "reset prioritário"
gtkwave::setNamedMarker D 160000 "fim da simulação"

gtkwave::setLeftJustifySigs on
gtkwave::/Time/Zoom/Zoom_Full
gtkwave::presentWindow

puts "GTKWave: ondas do reg_tb carregadas e formatadas."
