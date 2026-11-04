# Run from quartus/de10_lite after programming aces2_usb_audio_debug.sof:
# quartus_stp -t capture_usb_debug.tcl
package require ::quartus::stp

set instance auto_signaltap_0
set signal_set {signal_set: 2016/06/13 11:30:02  #0}
set trigger_set {trigger: MAX3421E activity}
set data_log usb_debug_capture
set capture_file [file normalize /tmp/aces2_usb_debug_capture.csv]

open_session -name [file normalize aces2_usb_audio_debug.stp]
if {[catch {
    run -instance $instance \
        -signal_set $signal_set \
        -trigger $trigger_set \
        -data_log $data_log \
        -timeout 60
} err]} {
    puts stderr "SignalTap capture failed: $err"
    close_session
    exit 1
}

export_data_log -instance $instance \
    -signal_set $signal_set \
    -trigger $trigger_set \
    -data_log $data_log \
    -filename $capture_file \
    -format csv
close_session
puts "SignalTap capture written to $capture_file"
