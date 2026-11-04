// Timing-aware SPI/MAX3421E and PCM2902 behavioral model for top-level tests.
// SIE abstraction retains real register transactions, two 64-byte receive
// banks, full-speed frame cadence, and USB payload-byte arrival cadence.
module max3421e_um2_model #(
  parameter int unsigned CLK_HZ = 50_000_000,
  parameter int unsigned OSC_STARTUP_MS = 1,
  parameter int unsigned BUS_RESET_MS = 2,
  parameter DEVICE_FILE = "tb/usb/pcm2902_device.mem",
  parameter CONFIG_FILE = "tb/usb/pcm2902_config.mem"
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic connect_i,
  input  logic sck_i,
  input  logic mosi_i,
  input  logic cs_n_i,
  output logic miso_o,
  output logic int_n_o,

  input  logic inject_nak_i,
  input  logic inject_stall_i,
  input  logic inject_crc_i,
  input  logic inject_timeout_i,
  input  logic inject_overrun_i,
  input  logic suppress_frame_irq_i,

  output logic [31:0] frame_count_o,
  output logic [31:0] iso_packet_count_o,
  output logic [31:0] missed_iso_frame_count_o,
  output logic [31:0] lost_sample_count_o,
  output logic [31:0] overrun_count_o,
  output logic [31:0] setup_count_o,
  output logic [31:0] status_count_o,
  output logic [31:0] control_nak_count_o,
  output logic [31:0] spi_transaction_count_o,
  output logic [31:0] spi_protocol_error_count_o,
  output logic [31:0] usb_protocol_error_count_o,
  output logic [31:0] max_bank_release_latency_o,
  output logic [31:0] bank_reassert_count_o,
  output logic [1:0]  max_bank_occupancy_o,
  output logic [31:0] byte_gap_min_cycles_o,
  output logic [31:0] byte_gap_max_cycles_o,
  output logic [31:0] device_descriptor_bytes_o,
  output logic [31:0] configuration_descriptor_bytes_o,
  output logic        configured_o,
  output logic        streaming_o
);
  localparam int unsigned OSC_CYCLES = (CLK_HZ * OSC_STARTUP_MS) / 1000;
  localparam int unsigned BUS_CYCLES = (CLK_HZ * BUS_RESET_MS) / 1000;
  localparam int unsigned SOF_CYCLES = CLK_HZ / 1000;
  localparam logic [4:0] RCVFIFO=1, SUDFIFO=4, RCVBC=6, HIRQ=25,
                         PERADDR=28, HCTL=29, HXFR=30, HRSL=31;
  localparam logic [3:0] HRSL_SUCCESS=4'h0, HRSL_NAK=4'h4,
                         HRSL_STALL=4'h5, HRSL_ISO_OVERRUN=4'h6,
                         HRSL_CRC=4'hb, HRSL_TIMEOUT=4'he;
  localparam int CONFIG_BYTES=1191;

  logic [7:0] regs[0:31];
  logic [7:0] config_desc[0:CONFIG_BYTES-1];
  logic [7:0] device_desc[0:17];
  logic [7:0] setup_fifo[0:7];
  logic [7:0] rx_bank[0:1][0:63];
  logic [7:0] pcm_frame[0:195];
  logic rx_bank_valid[0:1];
  logic [6:0] rx_bank_length[0:1];
  logic [31:0] rx_bank_ready_cycle[0:1];

  logic [7:0] hirq_q, hi_enable_q;
  logic cpu_interrupt_enable_q;
  logic [7:0] control_hctl_q;
  logic [5:0] transfer_result_q;
  logic [6:0] active_address_q, pending_address_q;
  logic [7:0] configured_value_q, pending_config_q;
  logic [7:0] active_interface_q, active_alt_q, pending_interface_q, pending_alt_q;
  logic [15:0] setup_length_q;
  logic [15:0] control_delivered_q;
  logic [15:0] setup_expected_data_q;
  logic control_data_stage_q, control_pending_status_q, control_is_descriptor_q;
  logic control_desc_config_q, control_desc_header_q, control_full_config_q;
  logic control_set_address_q, control_set_config_q, control_set_interface_q;
  logic control_toggle_q, stream_frame_pending_q, iso_active_q, iso_overrun_q;
  logic [15:0] desc_offset_q;
  logic [7:0] transfer_data[0:7];
  logic [3:0] bank_head_q, bank_tail_q;
  logic [1:0] bank_count_q;
  logic [6:0] fill_count_q;
  logic [7:0] iso_byte_index_q;
  logic [31:0] cycles_q, osc_timer_q, bus_reset_timer_q, frame_timer_q;
  logic [31:0] iso_byte_phase_q, iso_last_byte_cycle_q;
  logic [7:0] current_packet_length_q;
  logic [31:0] sample_clock_q, packet_sample_base_q;
  logic [7:0] spi_command_q;
  logic [7:0] spi_command_shift_q, spi_data_shift_q;
  logic [7:0] spi_write_data_q[0:63];
  logic [4:0] spi_reg_addr_q;
  logic [9:0] spi_bit_count_q;
  logic [6:0] spi_data_count_q;
  logic spi_write_q, spi_command_valid_q, spi_prev_sck_q, spi_prev_cs_n_q;
  logic connect_prev_q, chip_reset_q, oscillator_running_q, oscillator_ready_q;
  logic bus_reset_running_q, bus_reset_done_q, frame_irq_enable_q;
  logic [31:0] frame_sample_count_q;

  assign int_n_o = !(cpu_interrupt_enable_q && |(hirq_q & hi_enable_q));
  assign configured_o = configured_value_q == 1;
  assign streaming_o = configured_value_q == 1 && active_interface_q == 2 && active_alt_q == 1;
  assign frame_count_o = frame_count_q;
  assign iso_packet_count_o = iso_packet_count_q;
  assign missed_iso_frame_count_o = missed_frames_q;
  assign lost_sample_count_o = lost_samples_q;
  assign overrun_count_o = overruns_q;
  assign setup_count_o = setup_count_q;
  assign status_count_o = statuses_q;
  assign control_nak_count_o = control_naks_q;
  assign spi_transaction_count_o = spi_transactions_q;
  assign spi_protocol_error_count_o = spi_errors_q;
  assign usb_protocol_error_count_o = usb_errors_q;
  assign max_bank_release_latency_o = max_bank_latency_q;
  assign bank_reassert_count_o = bank_reassert_count_q;
  assign max_bank_occupancy_o = max_bank_occupancy_q;
  assign byte_gap_min_cycles_o = byte_gap_min_q;
  assign byte_gap_max_cycles_o = byte_gap_max_q;
  assign device_descriptor_bytes_o = device_bytes_q;
  assign configuration_descriptor_bytes_o = configuration_bytes_q;

  logic [31:0] frame_count_q, iso_packet_count_q, missed_frames_q, lost_samples_q, overruns_q;
  logic [31:0] setup_count_q, statuses_q, control_naks_q, spi_transactions_q, spi_errors_q, usb_errors_q;
  logic [31:0] max_bank_latency_q, device_bytes_q, configuration_bytes_q;
  logic [31:0] bank_reassert_count_q;
  logic [1:0] max_bank_occupancy_q;
  logic [31:0] byte_gap_min_q, byte_gap_max_q;

  function automatic logic [7:0] descriptor_byte(input logic config_sel, input int offset);
    if (config_sel) begin
      if (offset >= 0 && offset < CONFIG_BYTES) descriptor_byte = config_desc[offset];
      else descriptor_byte = 8'h00;
    end else begin
      if (offset >= 0 && offset < 18) descriptor_byte = device_desc[offset];
      else descriptor_byte = 8'h00;
    end
  endfunction

  function automatic logic [7:0] read_register(input logic [4:0] address, input int byte_index);
    logic bank;
    begin
      case (address)
        5'd13: read_register = oscillator_ready_q ? 8'h01 : 8'h00;
        HIRQ: read_register = hirq_q;
        RCVBC: read_register = (bank_count_q != 0) ? {1'b0,rx_bank_length[bank_head_q[0]]} : 8'h00;
        RCVFIFO: begin
          bank = bank_head_q[0];
          if (bank_count_q != 0 && byte_index < rx_bank_length[bank]) read_register = rx_bank[bank][byte_index];
          else read_register = 8'h00;
        end
        HCTL: read_register = control_hctl_q;
        HRSL: read_register = {connect_i,1'b0,transfer_result_q[5:4],transfer_result_q[3:0]};
        default: read_register = regs[int'(address) + byte_index];
      endcase
    end
  endfunction

  task automatic update_bank_highwater;
    begin
      if (bank_count_q > max_bank_occupancy_q) max_bank_occupancy_q = bank_count_q;
    end
  endtask

  task automatic push_rx_byte(input logic [7:0] value);
    logic tail;
    begin
      tail = bank_tail_q[0];
      if (rx_bank_valid[tail]) begin
        if (!iso_overrun_q) overruns_q = overruns_q + 1'b1;
        iso_overrun_q = 1'b1;
      end else begin
        rx_bank[tail][fill_count_q[5:0]] = value;
        fill_count_q = fill_count_q + 1'b1;
        if (fill_count_q == 64) begin
          rx_bank_valid[tail] = 1'b1;
          rx_bank_length[tail] = 64;
          rx_bank_ready_cycle[tail] = cycles_q;
          bank_count_q = bank_count_q + 1'b1;
          bank_tail_q = bank_tail_q + 1'b1;
          fill_count_q = 0;
          hirq_q = hirq_q | 8'h04;
          update_bank_highwater();
        end
      end
    end
  endtask

  task automatic finish_rx_packet;
    logic tail;
    begin
      tail = bank_tail_q[0];
      if (fill_count_q != 0 && !rx_bank_valid[tail]) begin
        rx_bank_valid[tail] = 1'b1;
        rx_bank_length[tail] = fill_count_q;
        rx_bank_ready_cycle[tail] = cycles_q;
        bank_count_q = bank_count_q + 1'b1;
        bank_tail_q = bank_tail_q + 1'b1;
        fill_count_q = 0;
        hirq_q = hirq_q | 8'h04;
        update_bank_highwater();
      end
    end
  endtask

  task automatic release_rx_bank;
    logic head;
    logic [31:0] latency;
    begin
      head = bank_head_q[0];
      if (bank_count_q != 0 && rx_bank_valid[head]) begin
        latency = cycles_q - rx_bank_ready_cycle[head];
        if (latency > max_bank_latency_q) max_bank_latency_q = latency;
        rx_bank_valid[head] = 1'b0;
        rx_bank_length[head] = 0;
        bank_head_q = bank_head_q + 1'b1;
        bank_count_q = bank_count_q - 1'b1;
        if (bank_count_q != 0) begin
          hirq_q = hirq_q | 8'h04;
          bank_reassert_count_q = bank_reassert_count_q + 1'b1;
        end
      end else usb_errors_q = usb_errors_q + 1'b1;
    end
  endtask

  task automatic reset_usb_device;
    begin
      active_address_q=0; pending_address_q=0;
      configured_value_q=0; pending_config_q=0;
      active_interface_q=0; active_alt_q=0; pending_interface_q=0; pending_alt_q=0;
      control_pending_status_q=0; control_data_stage_q=0; control_toggle_q=1;
      control_is_descriptor_q=0; control_desc_header_q=0; control_full_config_q=0;
      control_set_address_q=0; control_set_config_q=0; control_set_interface_q=0;
      desc_offset_q=0; control_delivered_q=0; setup_expected_data_q=0;
      bank_head_q=0; bank_tail_q=0; bank_count_q=0; fill_count_q=0;
      rx_bank_valid[0]=0; rx_bank_valid[1]=0;
      rx_bank_length[0]=0; rx_bank_length[1]=0;
      stream_frame_pending_q=0; iso_active_q=0; iso_overrun_q=0;
    end
  endtask

  task automatic complete_host_transfer(input logic [3:0] result_code);
    begin
      transfer_result_q[3:0] = result_code[3:0];
      hirq_q = hirq_q | 8'h80;
    end
  endtask

  task automatic start_iso_frame;
    integer n;
    logic [15:0] sample_index;
    logic [15:0] sample_word;
    logic [15:0] left_word, right_word;
    begin
      if (stream_frame_pending_q || iso_active_q) begin
        missed_frames_q = missed_frames_q + 1'b1;
        lost_samples_q = lost_samples_q + int'(current_packet_length_q)/4;
      end
      if (iso_active_q) begin
        iso_active_q = 1'b0;
        if (!iso_overrun_q) overruns_q = overruns_q + 1'b1;
        iso_overrun_q = 1'b0;
        finish_rx_packet();
        complete_host_transfer(HRSL_ISO_OVERRUN);
      end
      stream_frame_pending_q = 1'b1;
      case (frame_sample_count_q[1:0])
        2'd0: current_packet_length_q = 188; // 47 stereo sample frames
        2'd1: current_packet_length_q = 192; // 48
        2'd2: current_packet_length_q = 196; // 49
        default: current_packet_length_q = 192; // 48; four-frame average = 48
      endcase
      packet_sample_base_q = sample_clock_q;
      for (n=0;n<196;n++) begin
        if (n < current_packet_length_q) begin
          sample_index = 16'(packet_sample_base_q + n/4);
          sample_word = sample_index;
          left_word = sample_word;
          right_word = ~sample_word;
          case (n % 4)
            0: pcm_frame[n] = left_word[7:0];
            1: pcm_frame[n] = left_word[15:8];
            2: pcm_frame[n] = right_word[7:0];
            3: pcm_frame[n] = right_word[15:8];
          endcase
        end
      end
      sample_clock_q = sample_clock_q + int'(current_packet_length_q)/4;
      frame_sample_count_q = frame_sample_count_q + 1'b1;
      frame_count_q = frame_count_q + 1'b1;
      if (!suppress_frame_irq_i) hirq_q = hirq_q | 8'h40;
    end
  endtask

  task automatic complete_control_status(input bit status_in);
    begin
      if (!control_pending_status_q || status_in == control_data_stage_q) begin
        // For IN-data requests, status is OUT (status_in=0); no-data writes
        // use an IN status (status_in=1). Reject direction mismatches.
        usb_errors_q = usb_errors_q + 1'b1;
        complete_host_transfer(HRSL_STALL);
      end else begin
        statuses_q = statuses_q + 1'b1;
        if (control_set_address_q) begin
          active_address_q = pending_address_q;
          control_set_address_q = 1'b0;
        end
        if (control_set_config_q) begin
          configured_value_q = pending_config_q;
          control_set_config_q = 1'b0;
        end
        if (control_set_interface_q) begin
          active_interface_q = pending_interface_q;
          active_alt_q = pending_alt_q;
          control_set_interface_q = 1'b0;
          if (pending_interface_q == 2 && pending_alt_q == 1) begin
            frame_sample_count_q = 0;
            sample_clock_q = 0;
            stream_frame_pending_q = 1'b0;
            iso_active_q = 1'b0;
          end
        end
        if (control_is_descriptor_q && control_desc_config_q && setup_length_q == 9)
          control_desc_header_q = 1'b1;
        if (control_is_descriptor_q && control_desc_config_q && setup_length_q == 16'd1191)
          control_full_config_q = 1'b1;
        control_pending_status_q = 1'b0;
        control_data_stage_q = 1'b0;
        control_is_descriptor_q = 1'b0;
        complete_host_transfer(HRSL_SUCCESS);
      end
    end
  endtask

  task automatic accept_setup_packet;
    logic [15:0] value, index, length;
    logic [7:0] request, request_type;
    logic accepted_setup;
    begin
      accepted_setup = 1'b0;
      setup_count_q = setup_count_q + 1'b1;
      request_type = setup_fifo[0]; request = setup_fifo[1];
      value = {setup_fifo[3],setup_fifo[2]};
      index = {setup_fifo[5],setup_fifo[4]};
      length = {setup_fifo[7],setup_fifo[6]};
      setup_length_q = length;
      control_delivered_q = 0;
      control_pending_status_q = 1'b0;
      control_data_stage_q = request_type[7];
      control_is_descriptor_q = 1'b0;
      control_desc_config_q = 1'b0;
      control_set_address_q = 1'b0;
      control_set_config_q = 1'b0;
      control_set_interface_q = 1'b0;
      control_toggle_q = 1'b1; // SETUP resets EP0's next DATA PID to DATA1.

      if (!connect_i || regs[28][6:0] != active_address_q) begin
        usb_errors_q = usb_errors_q + 1'b1;
        complete_host_transfer(HRSL_TIMEOUT);
      end else if (request_type == 8'h80 && request == 8'h06 && length != 0) begin
        control_is_descriptor_q = 1'b1;
        if (value == 16'h0100 && (length == 8 || length == 18)) begin
          control_desc_config_q = 1'b0;
          setup_expected_data_q = length;
          desc_offset_q = 0;
          accepted_setup=1'b1; control_pending_status_q=1'b1;
        end else if (value == 16'h0200 && length == 9 && active_address_q == 1) begin
          control_desc_config_q = 1'b1;
          setup_expected_data_q = 9;
          desc_offset_q = 0;
          accepted_setup=1'b1; control_pending_status_q=1'b1;
        end else if (value == 16'h0200 && length == 16'd1191 && active_address_q == 1 && control_desc_header_q) begin
          control_desc_config_q = 1'b1;
          setup_expected_data_q = 16'd1191;
          desc_offset_q = 0;
          accepted_setup=1'b1; control_pending_status_q=1'b1;
        end else begin
          usb_errors_q = usb_errors_q + 1'b1;
          complete_host_transfer(HRSL_STALL);
        end
      end else if (request_type == 8'h00 && request == 8'h05 && length == 0 && value[15:7] == 0) begin
        if (active_address_q != 0 || value[6:0] == 0) begin
          usb_errors_q = usb_errors_q + 1'b1;
          complete_host_transfer(HRSL_STALL);
        end else begin pending_address_q = value[6:0]; control_set_address_q = 1'b1; accepted_setup=1'b1; control_pending_status_q=1'b1; end
      end else if (request_type == 8'h00 && request == 8'h09 && length == 0 &&
                   value[7:0] == 1 && value[15:8] == 0 && control_full_config_q) begin
        pending_config_q = value[7:0]; control_set_config_q = 1'b1; accepted_setup=1'b1; control_pending_status_q=1'b1;
      end else if (request_type == 8'h01 && request == 8'h0b && length == 0 &&
                   index == 2 && value[15:8] == 0 && value[7:0] == 1 && configured_value_q == 1) begin
        pending_interface_q = index[7:0]; pending_alt_q = value[7:0]; control_set_interface_q = 1'b1; accepted_setup=1'b1; control_pending_status_q=1'b1;
      end else begin
        usb_errors_q = usb_errors_q + 1'b1;
        complete_host_transfer(HRSL_STALL);
      end
      if (accepted_setup) begin
        if (control_is_descriptor_q) control_data_stage_q = 1'b1;
        complete_host_transfer(HRSL_SUCCESS);
      end
    end
  endtask

  task automatic accept_host_token(input logic [7:0] token);
    integer byte_n;
    integer n;
    logic [7:0] value;
    logic [15:0] left_to_send;
    logic [7:0] token_ep;
    begin
      token_ep = {4'b0,token[3:0]};
      transfer_result_q[5:4] = {regs[29][5],regs[29][4]};
      if (inject_nak_i && token != 8'h44) begin
        control_naks_q = control_naks_q + 1'b1;
        complete_host_transfer(HRSL_NAK);
      end else if (inject_stall_i && token != 8'h44) begin
        complete_host_transfer(HRSL_STALL);
      end else if (inject_crc_i && token != 8'h44) begin
        complete_host_transfer(HRSL_CRC);
      end else if (inject_timeout_i && token != 8'h44) begin
        // Return the SIE's explicit timeout HRSL result rather than pretending
        // the controller can wait forever without a completion indication.
        complete_host_transfer(HRSL_TIMEOUT);
      end else if (token == 8'h10) begin
        if (token_ep != 0 || control_pending_status_q || regs[28][6:0] != active_address_q) begin
          usb_errors_q = usb_errors_q + 1'b1;
          complete_host_transfer(HRSL_STALL);
        end else accept_setup_packet();
      end else if (token == 8'h00) begin
        if (token_ep != 0 || !control_pending_status_q || !control_data_stage_q ||
            regs[28][6:0] != active_address_q) begin
          usb_errors_q = usb_errors_q + 1'b1;
          complete_host_transfer(HRSL_STALL);
        end else if (regs[29][5:4] != (control_toggle_q ? 2'b10 : 2'b01)) begin
          usb_errors_q = usb_errors_q + 1'b1;
          complete_host_transfer(HRSL_ISO_OVERRUN);
        end else begin
          left_to_send = setup_expected_data_q - control_delivered_q;
          byte_n = (left_to_send > 8) ? 8 : int'(left_to_send);
          if (byte_n <= 0) begin
            usb_errors_q = usb_errors_q + 1'b1;
            complete_host_transfer(HRSL_STALL);
          end else begin
            for (n=0;n<8;n++) begin
              if (n<byte_n) begin
                value = descriptor_byte(control_desc_config_q, int'(desc_offset_q)+n);
                transfer_data[n] = value;
              end
            end
            for (n=0;n<byte_n;n++) push_rx_byte(transfer_data[n]);
            finish_rx_packet();
            control_delivered_q = control_delivered_q + 16'(byte_n);
            desc_offset_q = desc_offset_q + 16'(byte_n);
            device_bytes_q = device_bytes_q + (control_desc_config_q ? 0 : byte_n);
            configuration_bytes_q = configuration_bytes_q + (control_desc_config_q ? byte_n : 0);
            control_toggle_q = !control_toggle_q;
            regs[29][5] = control_toggle_q;
            regs[29][4] = !control_toggle_q;
            transfer_result_q[4] = control_toggle_q;
            transfer_result_q[5] = !control_toggle_q;
            complete_host_transfer(HRSL_SUCCESS);
          end
        end
      end else if (token == 8'ha0) begin
        if (regs[28][6:0] != active_address_q || !control_pending_status_q || !control_data_stage_q ||
            control_delivered_q != setup_expected_data_q) begin
          usb_errors_q = usb_errors_q + 1'b1;
          complete_host_transfer(HRSL_STALL);
        end else complete_control_status(1'b0);
      end else if (token == 8'h80) begin
        if (regs[28][6:0] != active_address_q || !control_pending_status_q || control_data_stage_q) begin
          usb_errors_q = usb_errors_q + 1'b1;
          complete_host_transfer(HRSL_STALL);
        end else complete_control_status(1'b1);
      end else if (token == 8'h44) begin
        if (!streaming_o || !connect_i || regs[28][6:0] != active_address_q || !stream_frame_pending_q) begin
          complete_host_transfer(HRSL_NAK);
        end else begin
          if (regs[29][5:4] != 2'b01) usb_errors_q = usb_errors_q + 1'b1;
          stream_frame_pending_q = 1'b0;
          iso_active_q = 1'b1;
          iso_byte_index_q = 0;
          iso_byte_phase_q = 0;
          iso_last_byte_cycle_q = cycles_q;
          iso_overrun_q = inject_overrun_i;
          if (inject_overrun_i) overruns_q = overruns_q + 1'b1;
        end
      end else begin
        usb_errors_q = usb_errors_q + 1'b1;
        complete_host_transfer(HRSL_STALL);
      end
    end
  endtask

  task automatic commit_spi_write(input logic [4:0] address, input logic [7:0] value);
    logic [4:0] a;
    begin
      a = address;
      case (a)
        HIRQ: begin
          hirq_q = hirq_q & ~value;
          if (value[2]) release_rx_bank();
        end
        SUDFIFO: setup_fifo[0] = value;
        HXFR: accept_host_token(value);
        5'd15: begin
          regs[a] = value;
          if (value[5]) begin
            chip_reset_q = 1'b1; oscillator_ready_q = 1'b0;
            oscillator_running_q = 1'b0; osc_timer_q = 0;
            hirq_q = 0; hi_enable_q = 0; cpu_interrupt_enable_q = 0;
          end else if (chip_reset_q) begin
            chip_reset_q = 1'b0; oscillator_running_q = 1'b1; osc_timer_q = 0;
          end
        end
        HCTL: begin
          control_hctl_q=value;
          regs[29]=value;
          if (value[0]) begin bus_reset_running_q=1'b1; bus_reset_done_q=1'b0; bus_reset_timer_q=0; end
          else if (bus_reset_done_q) begin bus_reset_done_q=1'b0; control_hctl_q[0]=0; regs[29][0]=0; end
        end
        5'd16: begin regs[a]=value; cpu_interrupt_enable_q=value[0]; end
        5'd26: begin regs[a]=value; hi_enable_q=value; end
        PERADDR: begin regs[a]=value; end
        default: regs[a]=value;
      endcase
      if (a == 27) begin
        regs[27]=value;
        frame_irq_enable_q=(value==8'hc9);
        if (value!=8'hc9) frame_timer_q=0;
      end
      if (a==16) cpu_interrupt_enable_q=value[0];
    end
  endtask

  task automatic commit_spi_transaction;
    integer n;
    logic [4:0] address;
    begin
      spi_transactions_q = spi_transactions_q + 1'b1;
      if (!spi_command_valid_q || spi_command_q[2] || spi_command_q[0]) begin
        $display("MODEL bad SPI txn cmdvalid=%b cmd=%02x bits=%0d data=%0d",spi_command_valid_q,spi_command_q,spi_bit_count_q,spi_data_count_q);
        spi_errors_q = spi_errors_q + 1'b1;
      end else begin
        address = spi_command_q[7:3];
        if (spi_write_q) begin
          if (spi_data_count_q==0) spi_errors_q=spi_errors_q+1'b1;
          else if (address==SUDFIFO) begin
            if (spi_data_count_q!=8) spi_errors_q=spi_errors_q+1'b1;
            else for (n=0;n<8;n++) setup_fifo[n]=spi_write_data_q[n];
          end else begin
            for(n=0;n<spi_data_count_q;n++) begin
              if (address==2 || address==7) commit_spi_write(address,spi_write_data_q[n]);
              else commit_spi_write(5'((int'(address)+n)&31),spi_write_data_q[n]);
            end
          end
        end
      end
      spi_command_valid_q=1'b0;
    end
  endtask

  initial begin
    $readmemh(CONFIG_FILE,config_desc);
    $readmemh(DEVICE_FILE,device_desc);
  end

  always @(posedge clk_i) begin : model_clocked
    integer offset;
    integer bit_index;
    integer data_index;
    integer sample_cycles;
    logic [7:0] data_byte;
    logic [7:0] command_byte;
    logic [4:0] addr;
    logic [7:0] result;
    logic [7:0] set_value;
    if (!rst_ni) begin
      miso_o=0;
      spi_prev_sck_q=0; spi_prev_cs_n_q=1;
      spi_bit_count_q=0; spi_data_count_q=0; spi_command_q=0; spi_command_shift_q=0;
      spi_data_shift_q=0; spi_reg_addr_q=0; spi_write_q=0; spi_command_valid_q=0;
      cycles_q=0; osc_timer_q=0; bus_reset_timer_q=0; frame_timer_q=0; iso_byte_phase_q=0; iso_last_byte_cycle_q=0;
      hirq_q=0; hi_enable_q=0; cpu_interrupt_enable_q=0; control_hctl_q=0; transfer_result_q=0;
      active_address_q=0; pending_address_q=0; configured_value_q=0; pending_config_q=0;
      active_interface_q=0; active_alt_q=0; pending_interface_q=0; pending_alt_q=0;
      setup_length_q=0; control_delivered_q=0; setup_expected_data_q=0;
      control_data_stage_q=0; control_pending_status_q=0; control_is_descriptor_q=0;
      control_desc_config_q=0; control_desc_header_q=0; control_full_config_q=0;
      control_set_address_q=0; control_set_config_q=0; control_set_interface_q=0; control_toggle_q=1;
      bank_head_q=0; bank_tail_q=0; bank_count_q=0; fill_count_q=0; iso_byte_index_q=0;
      sample_clock_q=0; packet_sample_base_q=0; current_packet_length_q=0;
      stream_frame_pending_q=0; iso_active_q=0; iso_overrun_q=0;
      desc_offset_q=0; connect_prev_q=connect_i; chip_reset_q=0;
      oscillator_running_q=0; oscillator_ready_q=0; bus_reset_running_q=0; bus_reset_done_q=0;
      frame_irq_enable_q=0;
      frame_sample_count_q=0;
      frame_count_q=0; iso_packet_count_q=0; missed_frames_q=0; lost_samples_q=0; overruns_q=0;
      setup_count_q=0; statuses_q=0; control_naks_q=0; spi_transactions_q=0; spi_errors_q=0; usb_errors_q=0;
      max_bank_latency_q=0; max_bank_occupancy_q=0; byte_gap_min_q=32'hffffffff; byte_gap_max_q=0;
      bank_reassert_count_q=0;
      device_bytes_q=0; configuration_bytes_q=0;
      rx_bank_valid[0]=0; rx_bank_valid[1]=0; rx_bank_length[0]=0; rx_bank_length[1]=0;
      rx_bank_ready_cycle[0]=0; rx_bank_ready_cycle[1]=0;
      regs[0]=0; for (int r=1;r<32;r++) regs[r]=0;
      regs[17]=0; regs[15]=0; regs[27]=0; regs[29]=0;
      for (int b=0;b<64;b++) begin rx_bank[0][b]=0; rx_bank[1][b]=0; spi_write_data_q[b]=0; end
      for (int b=0;b<8;b++) begin setup_fifo[b]=0; transfer_data[b]=0; end
    end else begin
      cycles_q = cycles_q + 1'b1;
      if (connect_i != connect_prev_q) begin
        hirq_q = hirq_q | 8'h20;
        connect_prev_q = connect_i;
        if (!connect_i) begin
          stream_frame_pending_q=0; iso_active_q=0;
          control_pending_status_q=0; control_data_stage_q=0;
          bank_count_q=0; bank_head_q=0; bank_tail_q=0; fill_count_q=0;
          rx_bank_valid[0]=0; rx_bank_valid[1]=0;
        end
      end
      if (oscillator_running_q && !oscillator_ready_q) begin
        if (osc_timer_q+1 >= OSC_CYCLES) oscillator_ready_q=1;
        else osc_timer_q=osc_timer_q+1'b1;
      end
      if (bus_reset_running_q) begin
        if (bus_reset_timer_q+1 >= BUS_CYCLES) begin
          bus_reset_running_q=0; bus_reset_done_q=1; bus_reset_timer_q=0; regs[29][0]=0; control_hctl_q[0]=0;
          reset_usb_device();
        end else bus_reset_timer_q=bus_reset_timer_q+1'b1;
      end
      if (frame_irq_enable_q) begin
        if (frame_timer_q+1 >= SOF_CYCLES) begin
          frame_timer_q=0;
          if (streaming_o) start_iso_frame();
          else if (!suppress_frame_irq_i) hirq_q=hirq_q|8'h40;
        end else frame_timer_q=frame_timer_q+1'b1;
      end
      if (iso_active_q) begin
        iso_byte_phase_q = iso_byte_phase_q + 1_500_000;
        if (iso_byte_phase_q >= CLK_HZ) begin
          iso_byte_phase_q = iso_byte_phase_q - CLK_HZ;
          if (iso_byte_index_q < current_packet_length_q) begin
            if (!iso_overrun_q) push_rx_byte(pcm_frame[iso_byte_index_q]);
            if (iso_last_byte_cycle_q != 0) begin
              sample_cycles = cycles_q - iso_last_byte_cycle_q;
              if (sample_cycles < byte_gap_min_q) byte_gap_min_q=sample_cycles;
              if (sample_cycles > byte_gap_max_q) byte_gap_max_q=sample_cycles;
            end
            iso_last_byte_cycle_q=cycles_q;
            iso_byte_index_q=iso_byte_index_q+1'b1;
            if (iso_byte_index_q == current_packet_length_q) begin
              if (!iso_overrun_q) finish_rx_packet();
              iso_active_q=0;
              if (iso_overrun_q) begin
            lost_samples_q=lost_samples_q+int'(current_packet_length_q)/4;
                complete_host_transfer(HRSL_ISO_OVERRUN);
              end else begin
                iso_packet_count_q=iso_packet_count_q+1'b1;
                complete_host_transfer(HRSL_SUCCESS);
              end
            end
          end
        end
      end

      spi_prev_sck_q=sck_i;
      spi_prev_cs_n_q=cs_n_i;
    end
  end

  // SPI pins are asynchronous to the model clock edges at which they change.
  // Decode on the actual mode-0 SCK edges so CPHA=0 data is sampled correctly.
  always @(negedge cs_n_i or negedge rst_ni) begin
    if (!rst_ni) begin
      spi_bit_count_q=0; spi_data_count_q=0; spi_command_shift_q=0;
      spi_data_shift_q=0; spi_command_valid_q=0; miso_o=0;
    end else begin
      spi_bit_count_q=0; spi_data_count_q=0; spi_command_shift_q=0;
      spi_data_shift_q=0; spi_command_valid_q=0; miso_o=0;
    end
  end

  always @(posedge sck_i) begin : spi_sample_edge
    integer data_index;
    logic [7:0] command_byte;
    if (rst_ni && !cs_n_i) begin
      if (spi_bit_count_q < 8) begin
        spi_command_shift_q={spi_command_shift_q[6:0],mosi_i};
        if (spi_bit_count_q==7) begin
          command_byte=spi_command_shift_q;
          spi_command_q=command_byte;
          spi_reg_addr_q=command_byte[7:3];
          spi_write_q=command_byte[1];
          spi_command_valid_q=1;
        end
      end else if (spi_write_q) begin
        spi_data_shift_q={spi_data_shift_q[6:0],mosi_i};
        if ((int'(spi_bit_count_q)-8)%8==7) begin
          data_index=(int'(spi_bit_count_q)-8)/8;
          if (data_index<64) begin
            spi_write_data_q[data_index]=spi_data_shift_q;
            spi_data_count_q=7'(data_index+1);
          end else spi_errors_q=spi_errors_q+1'b1;
          spi_data_shift_q=0;
        end
      end
      spi_bit_count_q=spi_bit_count_q+1'b1;
    end
  end

  always @(negedge sck_i) begin : spi_drive_edge
    integer data_index;
    integer bit_index;
    logic [7:0] data_byte;
    if (rst_ni && !cs_n_i && spi_command_valid_q && !spi_write_q && spi_bit_count_q>=8) begin
      data_index=(int'(spi_bit_count_q)-8)/8;
      bit_index=(int'(spi_bit_count_q)-8)%8;
      data_byte=read_register(spi_reg_addr_q,data_index);
      miso_o=data_byte[7-bit_index];
    end
  end

  always @(posedge cs_n_i or negedge rst_ni) begin : spi_finish_transaction
    if (!rst_ni) begin
      spi_transactions_q=0;
      spi_errors_q=0;
    end else if (spi_command_valid_q) begin
      if (spi_command_q[2] || spi_command_q[0]) spi_errors_q=spi_errors_q+1'b1;
      if (spi_write_q) commit_spi_transaction();
      else spi_transactions_q=spi_transactions_q+1'b1;
      miso_o=0;
    end else spi_errors_q=spi_errors_q+1'b1;
  end
endmodule
