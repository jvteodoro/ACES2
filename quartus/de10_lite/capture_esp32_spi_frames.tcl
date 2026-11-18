# Capture several complete FPGA-to-ESP32 framed SPI transfers from SignalTap.
# Run from quartus/de10_lite while the matching debug .sof is loaded:
#   quartus_stp -t capture_esp32_spi_frames.tcl
package require ::quartus::stp

set instance auto_signaltap_0
set signal_set {signal_set: 2016/06/13 11:30:02  #0}
set trigger_set {trigger: MAX3421E activity}
set hardware {USB-Blaster [1-2]}
set device {@1: 10M50DA(.|ES)/10M50DC (0x031050DD)}
set frame_count 3
set output_dir [file normalize ../../docs/usb_host/captures]

open_session -name [file normalize aces2_usb_audio_debug.stp]
for {set frame 1} {$frame <= $frame_count} {incr frame} {
    set data_log "esp32_spi_frame_$frame"
    set capture_file [file join $output_dir "esp32_spi_frame_${frame}_20261116.csv"]
    if {[catch {
        run -instance $instance \
            -hardware_name $hardware \
            -device_name $device \
            -signal_set $signal_set \
            -trigger $trigger_set \
            -data_log $data_log \
            -timeout 10
        export_data_log -instance $instance \
            -signal_set $signal_set \
            -trigger $trigger_set \
            -data_log $data_log \
            -filename $capture_file \
            -format csv
    } err]} {
        puts stderr "SignalTap frame $frame failed: $err"
        close_session
        exit 1
    }
    puts "SignalTap frame $frame written to $capture_file"
}
close_session
