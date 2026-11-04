// Serializes one USB token transaction at a time through MAX3421E registers.
// It prepares endpoint/toggle/FIFO state, launches HXFR, drains received
// banks, interprets HIRQ/HRSL and returns a complete packet plus status. The
// controller lock prevents idle interrupt service from racing the transaction.
module usb_host_engine #(
  parameter int unsigned TRANSACTION_TIMEOUT_CYCLES=5_000_000
) (
  input logic clk_i,rst_ni,
  input logic init_done_i,connected_i,full_speed_i,fault_i,
  input logic host_req_valid_i,output logic host_req_ready_o,
  input logic [7:0] host_req_token_i,input logic [6:0] host_req_addr_i,
  input logic [511:0] host_req_wdata_i,input logic [6:0] host_req_out_len_i,
  input logic host_req_toggle_valid_i,host_req_rcv_toggle_i,host_req_snd_toggle_i,
  input logic host_cancel_i,
  output logic host_rsp_valid_o,input logic host_rsp_ready_i,
  output logic [2047:0] host_rsp_packet_o,output logic [8:0] host_rsp_len_o,
  output logic [3:0] host_rsp_error_o,output logic host_rsp_rcv_toggle_o,host_rsp_snd_toggle_o,
  output logic reg_lock_o,port_change_o,frame_tick_o,reinitialize_o,
  output logic reg_valid_o,input logic reg_ready_i,
  output logic reg_write_o,output logic [4:0] reg_addr_o,
  output logic [6:0] reg_len_o,output logic [511:0] reg_wdata_o,
  input logic reg_rsp_valid_i,output logic reg_rsp_ready_o,
  input logic [511:0] reg_rdata_i,input logic reg_error_i
);
  localparam logic [4:0] RCVFIFO=1,SNDFIFO=2,SUDFIFO=4,RCVBC=6,SNDBC=7,HIRQ=25,PERADDR=28,HCTL=29,HXFR=30,HRSL=31;
  typedef enum logic [4:0] {E_IDLE,E_ADDR,E_TOGGLE,E_SETUPFIFO,E_OUTFIFO,E_SNDBC,E_LAUNCH,E_IRQ,E_RCVBC,E_RCVFIFO,E_CLRRCV,E_CLRFRAME,E_CLRHXFR,E_CLRCHANGE,E_HRSL,E_RESP} state_t;
  state_t state_q;
  logic pending_q,is_in_q,cancel_q,frame_seen_q,bus_seen_q,hxfr_seen_q;
  logic [7:0] token_q;
  logic [6:0] addr_q,out_len_q,chunk_len_q;
  logic [511:0] wdata_q;
  logic [2047:0] packet_q;
  logic [8:0] packet_len_q;
  logic [3:0] error_q;
  logic rcv_toggle_q,snd_toggle_q;
  logic req_rcv_toggle_q,req_snd_toggle_q;
  localparam int unsigned TIMER_WIDTH = $clog2(TRANSACTION_TIMEOUT_CYCLES+1);
  localparam logic [TIMER_WIDTH-1:0] TRANSACTION_TIMEOUT_LIMIT = TIMER_WIDTH'(TRANSACTION_TIMEOUT_CYCLES);
  localparam logic [TIMER_WIDTH-1:0] TRANSACTION_TIMEOUT_LAST = TIMER_WIDTH'(TRANSACTION_TIMEOUT_CYCLES-1);
  logic [TIMER_WIDTH-1:0] transaction_timer_q;
  logic [4:0] reg_addr;
  logic [7:0] reg_write_data;
  logic active_transaction;

  assign host_req_ready_o=(state_q==E_IDLE)&&init_done_i&&connected_i&&full_speed_i&&!fault_i;
  assign host_rsp_valid_o=(state_q==E_RESP);
  assign host_rsp_packet_o=packet_q;
  assign host_rsp_len_o=packet_len_q;
  assign host_rsp_error_o=error_q;
  assign host_rsp_rcv_toggle_o=rcv_toggle_q;
  assign host_rsp_snd_toggle_o=snd_toggle_q;
  assign active_transaction=(state_q!=E_IDLE&&state_q!=E_RESP);
  // Advertise the lock combinationally with a request handshake so the
  // controller cannot launch idle HIRQ polling on that same clock edge.
  assign reg_lock_o=active_transaction||(host_req_valid_i&&host_req_ready_o);
  // Always drain late bridge responses after timeout/cancel. pending_q keeps
  // them from being mistaken for a later register operation.
  assign reg_rsp_ready_o=1'b1;
  assign reg_valid_o=active_transaction&&!pending_q;
  assign reg_write_o=(state_q==E_ADDR||state_q==E_TOGGLE||state_q==E_SETUPFIFO||state_q==E_OUTFIFO||state_q==E_SNDBC||state_q==E_LAUNCH||state_q==E_CLRRCV||state_q==E_CLRFRAME||state_q==E_CLRHXFR||state_q==E_CLRCHANGE);
  assign reg_len_o=(state_q==E_SETUPFIFO)?7'd8:(state_q==E_OUTFIFO)?out_len_q:(state_q==E_RCVFIFO)?chunk_len_q:7'd1;
  always_comb begin
    case(state_q)
      E_ADDR: reg_addr=PERADDR;
      E_TOGGLE: reg_addr=HCTL;
      E_SETUPFIFO: reg_addr=SUDFIFO;
      E_OUTFIFO: reg_addr=SNDFIFO;
      E_SNDBC: reg_addr=SNDBC;
      E_LAUNCH: reg_addr=HXFR;
      E_IRQ,E_CLRRCV,E_CLRFRAME,E_CLRHXFR,E_CLRCHANGE: reg_addr=HIRQ;
      E_RCVBC: reg_addr=RCVBC;
      E_RCVFIFO: reg_addr=RCVFIFO;
      default: reg_addr=HRSL;
    endcase
    reg_write_data=0;
    case(state_q)
      E_ADDR: reg_write_data={1'b0,addr_q};
      E_TOGGLE: if(is_in_q) reg_write_data={2'b0,req_rcv_toggle_q,~req_rcv_toggle_q,4'b0};
                else reg_write_data={req_snd_toggle_q,~req_snd_toggle_q,6'b0};
      E_SNDBC: reg_write_data={1'b0,out_len_q};
      E_LAUNCH: reg_write_data=token_q;
      E_CLRRCV: reg_write_data=8'h04|(frame_seen_q?8'h40:0)|(bus_seen_q?8'h20:0);
      E_CLRFRAME: reg_write_data=8'h40|(bus_seen_q?8'h20:0);
      E_CLRHXFR: reg_write_data=8'h80|(frame_seen_q?8'h40:0)|(bus_seen_q?8'h20:0);
      E_CLRCHANGE: reg_write_data=8'h20;
      default: reg_write_data=0;
    endcase
    reg_addr_o=reg_addr;
    reg_wdata_o=0;
    reg_wdata_o[7:0]=reg_write_data;
    if(state_q==E_SETUPFIFO||state_q==E_OUTFIFO) reg_wdata_o=wdata_q;
  end

  always_ff @(posedge clk_i) begin
    if(!rst_ni) begin
      state_q<=E_IDLE; pending_q<=0; is_in_q<=0; cancel_q<=0; frame_seen_q<=0; bus_seen_q<=0; hxfr_seen_q<=0;
      token_q<=0; addr_q<=0; out_len_q<=0; chunk_len_q<=0; wdata_q<=0; packet_q<=0; packet_len_q<=0;
      error_q<=0; rcv_toggle_q<=0; snd_toggle_q<=0; req_rcv_toggle_q<=0; req_snd_toggle_q<=0; port_change_o<=0; frame_tick_o<=0; reinitialize_o<=0; transaction_timer_q<=0;
    end else begin
      port_change_o<=0; frame_tick_o<=0; reinitialize_o<=0;
      if(active_transaction && transaction_timer_q<TRANSACTION_TIMEOUT_LIMIT) transaction_timer_q<=transaction_timer_q+1'b1;
      if(reg_valid_o&&reg_ready_i) pending_q<=1;
      if(reg_rsp_valid_i&&reg_rsp_ready_o&&pending_q) begin
        pending_q<=0;
        if(reg_error_i) begin error_q<=4'he; packet_q<=0; packet_len_q<=0; state_q<=E_RESP; end
        else case(state_q)
          E_ADDR: if(cancel_q) state_q<=E_RESP; else if(token_q[4]) state_q<=E_SETUPFIFO; else if(token_q[5]) state_q<=(out_len_q==0)?E_SNDBC:E_OUTFIFO; else state_q<=E_LAUNCH;
          E_TOGGLE: state_q<=E_ADDR;
          E_SETUPFIFO: state_q<=cancel_q?E_RESP:E_LAUNCH;
          E_OUTFIFO: state_q<=cancel_q?E_RESP:E_SNDBC;
          E_SNDBC: state_q<=cancel_q?E_RESP:E_LAUNCH;
          E_LAUNCH: state_q<=is_in_q?E_IRQ:E_IRQ;
          E_IRQ: begin
            // HIRQ.CONNIRQ signals either a connect or disconnect transition.
            // Let the MAX3421E controller inspect HRSL J/K state before the
            // top level decides whether this is an actual disconnect.
            if(reg_rdata_i[5]) begin bus_seen_q<=1; port_change_o<=1; end
            if(reg_rdata_i[6]) frame_seen_q<=1;
            if(reg_rdata_i[2]) begin if(reg_rdata_i[7]) hxfr_seen_q<=1; state_q<=E_RCVBC; end
            else if(reg_rdata_i[7]) begin hxfr_seen_q<=1; state_q<=E_CLRHXFR; end
            else if(reg_rdata_i[6]) state_q<=E_CLRFRAME;
            else if(reg_rdata_i[5]) state_q<=E_CLRCHANGE;
            else if(hxfr_seen_q) state_q<=E_HRSL;
            else if(cancel_q) begin packet_q<=0; packet_len_q<=0; state_q<=E_RESP; end
            else state_q<=E_IRQ;
          end
          E_RCVBC: begin
            if(reg_rdata_i[6:0]>64) begin error_q<=4'hd; chunk_len_q<=64; end
            else chunk_len_q<=reg_rdata_i[6:0];
            state_q<=(reg_rdata_i[6:0]==0)?E_CLRRCV:E_RCVFIFO;
          end
          E_RCVFIFO: begin
            // MAX3421E RCVFIFO is a 64-byte bank. A short chunk is the end of
            // the packet; reject any later bank after a partial fill. This
            // keeps each accepted bank aligned to one fixed 512-bit slice.
            if(packet_len_q[5:0]!=0) error_q<=4'hd;
            else if(packet_len_q+{2'b00,chunk_len_q}>9'd256 || packet_len_q>9'd192) error_q<=4'hd;
            else begin
              case(packet_len_q[7:6])
                2'd0: for(int n=0;n<64;n++) if(n<chunk_len_q) packet_q[n*8 +:8]<=reg_rdata_i[n*8 +:8];
                2'd1: for(int n=0;n<64;n++) if(n<chunk_len_q) packet_q[512+n*8 +:8]<=reg_rdata_i[n*8 +:8];
                2'd2: for(int n=0;n<64;n++) if(n<chunk_len_q) packet_q[1024+n*8 +:8]<=reg_rdata_i[n*8 +:8];
                2'd3: for(int n=0;n<64;n++) if(n<chunk_len_q) packet_q[1536+n*8 +:8]<=reg_rdata_i[n*8 +:8];
              endcase
              packet_len_q<=packet_len_q+{2'b00,chunk_len_q};
            end
            state_q<=E_CLRRCV;
          end
          E_CLRRCV: begin if(frame_seen_q) frame_tick_o<=1; frame_seen_q<=0; bus_seen_q<=0; state_q<=E_IRQ; end
          E_CLRFRAME: begin frame_tick_o<=1; frame_seen_q<=0; bus_seen_q<=0; state_q<=E_IRQ; end
          E_CLRHXFR: begin if(frame_seen_q) frame_tick_o<=1; frame_seen_q<=0; bus_seen_q<=0; state_q<=is_in_q?E_IRQ:E_HRSL; end
          E_CLRCHANGE: begin bus_seen_q<=0; state_q<=E_IRQ; end
          E_HRSL: begin
            rcv_toggle_q<=reg_rdata_i[4]; snd_toggle_q<=reg_rdata_i[5];
            if(error_q==0) error_q<=reg_rdata_i[3:0];
            if((error_q!=0)||(reg_rdata_i[3:0]!=0)) begin packet_q<=0; packet_len_q<=0; end
            state_q<=E_RESP;
          end
          default: state_q<=E_RESP;
        endcase
      end
      if(state_q==E_IDLE&&host_req_valid_i&&host_req_ready_o) begin
        token_q<=host_req_token_i; addr_q<=host_req_addr_i; out_len_q<=host_req_out_len_i; wdata_q<=host_req_wdata_i;
        req_rcv_toggle_q<=host_req_rcv_toggle_i; req_snd_toggle_q<=host_req_snd_toggle_i;
        // MAX3421E HXFR uses OUTNIN in bit 5 and SETUP in bit 4. SETUP
        // always sends host-to-device data, so it must follow the OUT
        // completion path even though OUTNIN is clear in TOKEN_SETUP (8'h10).
        is_in_q<=!host_req_token_i[5] && !host_req_token_i[4];
        packet_q<=0; packet_len_q<=0; error_q<=0;
        cancel_q<=0; frame_seen_q<=0; bus_seen_q<=0; hxfr_seen_q<=0; transaction_timer_q<=0;
        rcv_toggle_q<=0; snd_toggle_q<=0;
        state_q<=host_req_toggle_valid_i?E_TOGGLE:E_ADDR;
      end
      if(state_q==E_RESP&&host_rsp_ready_i) state_q<=E_IDLE;
      if(host_cancel_i&&active_transaction) begin
        state_q<=E_RESP; pending_q<=0; error_q<=4'hf; packet_q<=0; packet_len_q<=0; reinitialize_o<=1;
      end else if(active_transaction && transaction_timer_q>=TRANSACTION_TIMEOUT_LAST) begin
        state_q<=E_RESP; pending_q<=0; error_q<=4'he; packet_q<=0; packet_len_q<=0; reinitialize_o<=1;
      end
    end
  end
endmodule
