`timescale 1ns/1ps
// Independent enumerator + EP0 sequencer integration against captured bytes.
// MAX transaction responses are abstract here; the physical SPI model is separate.
module usb_enumeration_path_tb;
  logic clk=0;
  always #10 clk=~clk;
  logic rst_n=0, connected=0;
  logic cv,cr,cc,cdv,cdr,done,err;
  logic [63:0] setup;
  logic [15:0] length;
  logic [6:0] address,ep0;
  logic [7:0] data;
  logic enumerated,enum_error;
  logic [3:0] enum_error_code,ctrl_error_code;
  logic [7:0] configuration,intf,alt,endpoint,interval,channels,bits;
  logic [10:0] max_packet;
  logic [15:0] rate;
  logic hv,hr=1,hcancel,rv=0,rr;
  logic [7:0] token;
  logic [6:0] haddr,out_len;
  logic [511:0] wdata;
  logic toggle_valid,rcv_toggle,snd_toggle;
  logic [2047:0] packet='0;
  logic [8:0] packet_len=0;
  logic [3:0] result=0;
  logic [7:0] dev[18],cfg[1191];
  int requests=0,transactions=0,offset=0,expected_bytes=0,naks=0;
  logic [63:0] current_setup=0;
  logic [6:0] peripheral_address=0;
  bit first_data=1,configured=0,capture_selected=0,inject_nak=1;

  usb_enumerator #(.CTRL_TIMEOUT_CYCLES(250000)) enumerator(
    .clk_i(clk),.rst_ni(rst_n),.connected_i(connected),
    .ctrl_req_valid_o(cv),.ctrl_req_ready_i(cr),.ctrl_setup_o(setup),
    .ctrl_in_length_o(length),.ctrl_address_o(address),.ctrl_ep0_size_o(ep0),
    .ctrl_cancel_o(cc),.ctrl_data_i(data),.ctrl_data_valid_i(cdv),
    .ctrl_data_ready_o(cdr),.ctrl_done_i(done),.ctrl_error_i(err),
    .enumerated_o(enumerated),.enum_error_o(enum_error),.enum_error_code_o(enum_error_code),
    .configuration_o(configuration),.interface_o(intf),.alternate_setting_o(alt),
    .endpoint_o(endpoint),.max_packet_size_o(max_packet),.interval_o(interval),
    .channels_o(channels),.sample_bits_o(bits),.sample_rate_o(rate)
  );
  usb_control_transfer #(.CTRL_TIMEOUT_CYCLES(250000)) control(
    .clk_i(clk),.rst_ni(rst_n),.ctrl_req_valid_i(cv),.ctrl_req_ready_o(cr),
    .ctrl_setup_i(setup),.ctrl_in_length_i(length),.ctrl_address_i(address),
    .ctrl_ep0_size_i(ep0),.ctrl_cancel_i(cc),.ctrl_data_o(data),
    .ctrl_data_valid_o(cdv),.ctrl_data_ready_i(cdr),.ctrl_done_o(done),
    .ctrl_error_o(err),.ctrl_error_code_o(ctrl_error_code),
    .host_req_valid_o(hv),.host_req_ready_i(hr),.host_req_token_o(token),
    .host_req_addr_o(haddr),.host_req_wdata_o(wdata),.host_req_out_len_o(out_len),
    .host_req_toggle_valid_o(toggle_valid),.host_req_rcv_toggle_o(rcv_toggle),
    .host_req_snd_toggle_o(snd_toggle),.host_cancel_o(hcancel),
    .host_rsp_valid_i(rv),.host_rsp_ready_o(rr),.host_rsp_packet_i(packet),
    .host_rsp_len_i(packet_len),.host_rsp_error_i(result),
    .host_rsp_rcv_toggle_i(1'b0),.host_rsp_snd_toggle_i(1'b0)
  );

  function automatic logic [63:0] expected_setup(input int index);
    case(index)
      0: expected_setup=64'h0008_0000_0100_0680;
      1: expected_setup=64'h0012_0000_0100_0680;
      2: expected_setup=64'h0000_0000_0001_0500;
      3: expected_setup=64'h0009_0000_0200_0680;
      4: expected_setup=64'h04a7_0000_0200_0680;
      5: expected_setup=64'h0000_0000_0001_0900;
      6: expected_setup=64'h0000_0002_0001_0b01;
      default: expected_setup='1;
    endcase
  endfunction

  initial begin : peripheral
    int count;
    $readmemh("tb/usb/pcm2902_device.mem",dev);
    $readmemh("tb/usb/pcm2902_config.mem",cfg);
    wait(rst_n);
    forever begin
      do @(posedge clk); while(!hv || !hr);
      if(haddr!==peripheral_address) $fatal(1,"USB address mismatch: got %0d expected %0d",haddr,peripheral_address);
      transactions++;
      packet='0; packet_len=0; result=0;
      case(token)
        8'h10: begin
          if(out_len!=8 || wdata[63:0]!==expected_setup(requests))
            $fatal(1,"unexpected SETUP %016x at step %0d",wdata[63:0],requests);
          current_setup=wdata[63:0]; requests++; offset=0; first_data=1;
          expected_bytes=current_setup[63:48];
        end
        8'h00: begin
          if(!current_setup[7] || current_setup[15:8]!=6 || offset>=expected_bytes || out_len!=0)
            $fatal(1,"IN outside descriptor data stage");
          if(toggle_valid!==first_data || (first_data && !rcv_toggle))
            $fatal(1,"EP0 toggle reset or wrong first DATA PID");
          if(current_setup[31:16]==16'h0200 && inject_nak) begin
            result=4; naks++; inject_nak=0;
          end else begin
            count=expected_bytes-offset;
            if(count>8) count=8;
            packet_len=9'(count);
            for(int k=0;k<count;k++) begin
              if(current_setup[31:16]==16'h0100) packet[k*8+:8]=dev[offset+k];
              else packet[k*8+:8]=cfg[offset+k];
            end
            offset+=count;
            first_data=0;
          end
        end
        8'ha0: begin
          if(!current_setup[7] || offset!=expected_bytes || out_len!=0)
            $fatal(1,"descriptor status issued before full data transfer");
        end
        8'h80: begin
          if(current_setup[7] || expected_bytes!=0 || out_len!=0)
            $fatal(1,"invalid no-data status stage");
          case(current_setup[15:8])
            5: peripheral_address=7'd1;
            9: configured=1;
            11: begin
              if(!configured) $fatal(1,"SET_INTERFACE before configuration");
              capture_selected=1;
            end
            default: $fatal(1,"unexpected no-data request");
          endcase
        end
        default: $fatal(1,"unexpected token %02x",token);
      endcase
      @(negedge clk); hr=0;
      repeat(3) @(negedge clk);
      rv=1;
      do @(posedge clk); while(!rr);
      @(negedge clk); rv=0; hr=1;
    end
  end
  initial begin
    #10000000; $fatal(1,"enumeration integration watchdog");
  end
  initial begin
    repeat(5) @(negedge clk); rst_n=1; connected=1;
    wait(enumerated || enum_error);
    if(enum_error) $fatal(1,"enumerator error=%0d control=%0d",enum_error_code,ctrl_error_code);
    if(requests!=7 || !capture_selected || naks!=1 || configuration!=1 || intf!=2 ||
       alt!=1 || endpoint!=8'h84 || max_packet!=196 || rate!=48000 || channels!=2 || bits!=16)
      $fatal(1,"integrated enumeration metadata mismatch");
    $display("PASS enumeration path: SETUP=%0d transactions=%0d NAK retries=%0d actual config bytes=1191",requests,transactions,naks);
    $finish;
  end
endmodule
