// MAX3421E register-access owner. Initializes the chip and USB port, tracks
// attach/speed state and SOF ticks, services idle interrupts, and arbitrates
// SPI register requests between maintenance and the USB host engine. It owns
// the physical SCK/MOSI/CS pins; D+/D- remain inside the MAX3421E transceiver.
module max3421e_controller #(
  parameter int unsigned CLK_HZ=50_000_000,
  parameter int unsigned DEBOUNCE_MS=100,
  parameter int unsigned BUS_RESET_MS=50,
  parameter int unsigned BUS_RESET_TIMEOUT_MS=100,
  parameter int unsigned OSC_TIMEOUT_MS=20
) (
  input logic clk_i,rst_ni,int_n_i,
  input logic reg_lock_i,port_change_i,engine_reinitialize_i,
  input logic reg_valid_i,output logic reg_ready_o,
  input logic reg_write_i,input logic [4:0] reg_addr_i,input logic [6:0] reg_len_i,
  input logic [511:0] reg_wdata_i,
  output logic reg_rsp_valid_o,input logic reg_rsp_ready_i,
  output logic [511:0] reg_rdata_o,output logic reg_error_o,
  output logic init_done_o,connected_o,full_speed_o,frame_tick_o,fault_o,
  output logic sck_o,mosi_o,input logic miso_i,output logic cs_n_o
);
  localparam int unsigned MS_CYCLES=CLK_HZ/1000;
  localparam int unsigned DB_CYCLES=MS_CYCLES*DEBOUNCE_MS;
  localparam int unsigned BR_CYCLES=MS_CYCLES*BUS_RESET_TIMEOUT_MS;
  localparam int unsigned OSC_CYCLES=MS_CYCLES*OSC_TIMEOUT_MS;
  localparam int unsigned DBR_MAX_CYCLES=(DB_CYCLES>BR_CYCLES)?DB_CYCLES:BR_CYCLES;
  localparam int unsigned MAX_WAIT_CYCLES=(DBR_MAX_CYCLES>OSC_CYCLES)?DBR_MAX_CYCLES:OSC_CYCLES;
  localparam int unsigned TW=$clog2(MAX_WAIT_CYCLES+1);
  localparam logic [TW-1:0] DB_LAST_CYCLE=TW'(DB_CYCLES-1);
  localparam logic [TW-1:0] BUS_RESET_TIMEOUT_LAST_CYCLE=TW'(BR_CYCLES-1);
  localparam logic [TW-1:0] OSC_TIMEOUT_LAST_CYCLE=TW'(OSC_CYCLES-1);
  typedef enum logic [5:0] {C_PIN,C_CHIPSET,C_CHIPCLR,C_OSCREQ,C_OSCWAIT,C_MODE,C_SAMPLE,C_DB,C_DBCHK,C_RSTREQ,C_BUSWAIT,C_BUSWAITRESP,C_RSTCLR,C_SOF,C_FRAMEREQ,C_FRAMEWAIT,C_FRAMECLR,C_CPUCTL,C_ENABLE,C_ENABLEWAIT,C_READY,C_IRQREQ,C_IRQWAIT,C_HRSLREQ,C_HRSLWAIT,C_IRQCLR,C_IRQCLRWAIT,C_FAULT} cstate_t;
  cstate_t state_q;
  logic [TW-1:0] timer_q;
  logic int_meta_q,int_sync_q,change_pending_q,reinit_pending_q,stable_check_q,initialized_q,client_pending_q;
  logic [31:0] idle_poll_q;
  logic [4:0] bridge_addr;
  logic [6:0] bridge_len;
  logic [511:0] bridge_wdata,bridge_rdata;
  logic bridge_valid,bridge_ready,bridge_write,bridge_rsp_valid,bridge_rsp_ready,bridge_error,bridge_busy,bridge_pending_q;
  logic [7:0] hrsl_sample_q,irq_sample_q;
  logic init_phase,client_phase;

  max3421e_spi_bridge u_bridge(
    .clk_i,.rst_ni,.req_valid_i(bridge_valid),.req_ready_o(bridge_ready),
    .req_write_i(bridge_write),.req_addr_i(bridge_addr),.req_len_i(bridge_len),.req_wdata_i(bridge_wdata),
    .rsp_valid_o(bridge_rsp_valid),.rsp_ready_i(bridge_rsp_ready),.rsp_rdata_o(bridge_rdata),.rsp_error_o(bridge_error),
    .busy_o(bridge_busy),.sck_o,.mosi_o,.miso_i,.cs_n_o);

  always_ff @(posedge clk_i) begin
    if(!rst_ni) begin int_meta_q<=1; int_sync_q<=1; end
    else begin int_meta_q<=int_n_i; int_sync_q<=int_meta_q; end
  end

  always_comb begin
    bridge_addr=0; bridge_len=1; bridge_wdata=0; bridge_write=0;
    case(state_q)
      C_PIN: begin bridge_addr=17; bridge_write=1; bridge_wdata[7:0]=8'h18; end
      C_CHIPSET: begin bridge_addr=15; bridge_write=1; bridge_wdata[7:0]=8'h20; end
      C_CHIPCLR: begin bridge_addr=15; bridge_write=1; bridge_wdata[7:0]=0; end
      C_OSCREQ: bridge_addr=13;
      C_MODE: begin bridge_addr=27; bridge_write=1; bridge_wdata[7:0]=8'hc1; end
      C_SAMPLE: begin bridge_addr=29; bridge_write=1; bridge_wdata[7:0]=8'h04; end
      C_DBCHK,C_HRSLREQ: bridge_addr=31;
      C_RSTREQ: begin bridge_addr=29; bridge_write=1; bridge_wdata[7:0]=8'h01; end
      C_BUSWAIT: bridge_addr=29;
      C_RSTCLR: begin bridge_addr=29; bridge_write=1; bridge_wdata[7:0]=0; end
      C_SOF: begin bridge_addr=27; bridge_write=1; bridge_wdata[7:0]=8'hc9; end
      C_FRAMEREQ,C_IRQREQ: bridge_addr=25;
      C_FRAMECLR: begin bridge_addr=25; bridge_write=1; bridge_wdata[7:0]=8'h40; end
      C_CPUCTL: begin bridge_addr=16; bridge_write=1; bridge_wdata[7:0]=8'h01; end
      C_ENABLE: begin bridge_addr=26; bridge_write=1; bridge_wdata[7:0]=8'h60; end
      C_HRSLWAIT: bridge_addr=31;
      C_IRQCLR: begin bridge_addr=25; bridge_write=1; bridge_wdata[7:0]=(irq_sample_q[5]?8'h20:0)|(irq_sample_q[6]?8'h40:0); end
      default: ;
    endcase
    init_phase=(state_q<C_READY) && (state_q!=C_DB);
    client_phase=(state_q==C_READY && reg_valid_i &&
                  (reg_lock_i || (!reinit_pending_q && !change_pending_q && !engine_reinitialize_i && !port_change_i)));
    bridge_valid=(init_phase && (state_q!=C_ENABLEWAIT && state_q!=C_OSCWAIT && state_q!=C_BUSWAITRESP && state_q!=C_FRAMEWAIT && state_q!=C_IRQWAIT && state_q!=C_HRSLWAIT && state_q!=C_IRQCLRWAIT))
      || client_phase || (state_q==C_IRQREQ) || (state_q==C_HRSLREQ) || (state_q==C_FRAMEREQ) || (state_q==C_IRQCLR);
    bridge_valid=bridge_valid&&!bridge_pending_q;
    if(client_phase) begin bridge_addr=reg_addr_i; bridge_len=reg_len_i; bridge_write=reg_write_i; bridge_wdata=reg_wdata_i; end
    reg_ready_o=(state_q==C_READY && bridge_ready &&
                 (reg_lock_i || (!reinit_pending_q && !change_pending_q && !engine_reinitialize_i && !port_change_i)));
    reg_rsp_valid_o=(state_q==C_READY && client_pending_q && bridge_rsp_valid);
    reg_rdata_o=bridge_rdata; reg_error_o=bridge_error;
    bridge_rsp_ready=(state_q!=C_READY) || (client_pending_q ? reg_rsp_ready_i : 1'b1);
  end
  // Keep initialization status stable during ordinary idle IRQ service, but
  // stop new host requests as soon as a disconnect or hardware reinit is pending.
  // A port-change interrupt requires an HRSL J/K check, but does not mean
  // the controller itself stopped being initialized. Keep enumeration alive
  // during that check; connected_o falling will report a confirmed detach.
  assign init_done_o=initialized_q && !fault_o && !reinit_pending_q && !engine_reinitialize_i;

  always_ff @(posedge clk_i) begin
    if(!rst_ni) begin
      state_q<=C_PIN; timer_q<=0; connected_o<=0; full_speed_o<=0; frame_tick_o<=0; fault_o<=0;
      change_pending_q<=0; reinit_pending_q<=0; stable_check_q<=0; initialized_q<=0; client_pending_q<=0; bridge_pending_q<=0; idle_poll_q<=0; hrsl_sample_q<=0; irq_sample_q<=0;
    end else begin
      frame_tick_o<=0;
      if(port_change_i) change_pending_q<=1;
      if(engine_reinitialize_i) reinit_pending_q<=1;
      if(state_q==C_READY && !reg_valid_i && !reg_lock_i) idle_poll_q<=idle_poll_q+1'b1;
      else idle_poll_q<=0;
      if(client_phase && bridge_ready) client_pending_q<=1;
      if(reg_rsp_valid_o && reg_rsp_ready_i) client_pending_q<=0;
      if(state_q!=C_READY && client_pending_q && bridge_rsp_valid && bridge_rsp_ready) client_pending_q<=0;
      if(bridge_valid&&bridge_ready) bridge_pending_q<=1;
      if(bridge_rsp_valid&&bridge_rsp_ready) bridge_pending_q<=0;
      if(state_q==C_DB) begin
        if(timer_q>=DB_LAST_CYCLE) begin timer_q<=0; state_q<=C_DBCHK; end
        else timer_q<=timer_q+1'b1;
      end
      if(state_q==C_BUSWAIT||state_q==C_BUSWAITRESP) begin
        if(timer_q>=BUS_RESET_TIMEOUT_LAST_CYCLE) begin fault_o<=1; state_q<=C_FAULT; end
        else timer_q<=timer_q+1'b1;
      end
      if(state_q==C_OSCWAIT || state_q==C_FRAMEWAIT) begin
        if(timer_q>=OSC_TIMEOUT_LAST_CYCLE) begin fault_o<=1; state_q<=C_FAULT; end
        else timer_q<=timer_q+1'b1;
      end
      if(bridge_rsp_valid && bridge_rsp_ready && bridge_error) begin fault_o<=1; state_q<=C_FAULT; end
      case(state_q)
        C_PIN: if(bridge_valid&&bridge_ready) state_q<=C_CHIPSET;
        C_CHIPSET: if(bridge_valid&&bridge_ready) state_q<=C_CHIPCLR;
        C_CHIPCLR: if(bridge_valid&&bridge_ready) begin timer_q<=0; state_q<=C_OSCREQ; end
        C_OSCREQ: if(bridge_valid&&bridge_ready) state_q<=C_OSCWAIT;
        C_OSCWAIT: if(bridge_rsp_valid&&bridge_rsp_ready) begin
          if(bridge_rdata[0]) state_q<=C_MODE;
          else state_q<=C_OSCREQ;
        end
        C_MODE: if(bridge_valid&&bridge_ready) state_q<=C_SAMPLE;
        C_SAMPLE: if(bridge_valid&&bridge_ready) state_q<=C_DBCHK;
        C_DBCHK: if(bridge_valid&&bridge_ready) state_q<=C_HRSLWAIT;
        C_HRSLREQ: if(bridge_valid&&bridge_ready) state_q<=C_HRSLWAIT;
        C_HRSLWAIT: if(bridge_rsp_valid&&bridge_rsp_ready) begin
          hrsl_sample_q<=bridge_rdata[7:0];
          if(bridge_rdata[7]||bridge_rdata[6]) begin
            full_speed_o<=bridge_rdata[7];
            if(stable_check_q) begin stable_check_q<=0; state_q<=C_RSTREQ; end
            // CONDETIRQ can remain pending after the initial attach has
            // already been debounced, reset, and enabled. If HRSL still
            // reports the same connected speed, accept that status check
            // immediately; another 100 ms debounce here can starve EP0 and
            // race the host transaction timeout while reading descriptors.
            else if(connected_o && full_speed_o==bridge_rdata[7]) begin
              change_pending_q<=0; state_q<=C_READY;
            end
            else begin timer_q<=0; state_q<=C_DB; end
          end
          else begin connected_o<=0; stable_check_q<=0; state_q<=C_SAMPLE; end
        end
        C_RSTREQ: if(bridge_valid&&bridge_ready) begin timer_q<=0; state_q<=C_BUSWAIT; end
        C_BUSWAIT: if(bridge_valid&&bridge_ready) state_q<=C_BUSWAITRESP;
        C_BUSWAITRESP: if(bridge_rsp_valid&&bridge_rsp_ready) begin
          if(!bridge_rdata[0]) begin timer_q<=0; state_q<=C_RSTCLR; end
          else state_q<=C_BUSWAIT;
        end
        C_RSTCLR: if(bridge_valid&&bridge_ready) state_q<=C_SOF;
        C_SOF: if(bridge_valid&&bridge_ready) begin timer_q<=0; state_q<=C_FRAMEREQ; end
        C_FRAMEREQ: if(bridge_valid&&bridge_ready) state_q<=C_FRAMEWAIT;
        C_FRAMEWAIT: if(bridge_rsp_valid&&bridge_rsp_ready) begin
          if(bridge_rdata[6]) state_q<=C_FRAMECLR;
          else state_q<=C_FRAMEREQ;
        end
        C_FRAMECLR: if(bridge_valid&&bridge_ready) begin frame_tick_o<=1; state_q<=C_CPUCTL; end
        C_CPUCTL: if(bridge_valid&&bridge_ready) state_q<=C_ENABLE;
        C_ENABLE: if(bridge_valid&&bridge_ready) state_q<=C_ENABLEWAIT;
        C_ENABLEWAIT: if(bridge_rsp_valid&&bridge_rsp_ready) begin
          connected_o<=1; initialized_q<=1; state_q<=C_READY; idle_poll_q<=0;
          change_pending_q<=0; reinit_pending_q<=0;
        end
        C_READY: begin
          if(!reg_lock_i && !client_pending_q && !bridge_pending_q && !bridge_busy && !bridge_rsp_valid &&
             (reinit_pending_q || engine_reinitialize_i)) begin
            state_q<=C_PIN; connected_o<=0; fault_o<=0; initialized_q<=0;
            reinit_pending_q<=0; change_pending_q<=0;
          end else if(!reg_lock_i && !client_pending_q && !bridge_pending_q && !bridge_busy && !bridge_rsp_valid &&
                      (change_pending_q || port_change_i)) begin
            state_q<=C_HRSLREQ; change_pending_q<=0;
          end else if(!reg_lock_i && !client_pending_q && !reg_valid_i &&
                      !reinit_pending_q && !change_pending_q && !engine_reinitialize_i && !port_change_i &&
                      (!int_sync_q || idle_poll_q>=5000)) state_q<=C_IRQREQ;
        end
        C_IRQREQ: if(bridge_valid&&bridge_ready) state_q<=C_IRQWAIT;
        C_IRQWAIT: if(bridge_rsp_valid&&bridge_rsp_ready) begin
          irq_sample_q<=bridge_rdata[7:0];
          if(bridge_rdata[5]) change_pending_q<=1;
          if(bridge_rdata[5]||bridge_rdata[6]) state_q<=C_IRQCLR;
          else state_q<=C_READY;
        end
        C_IRQCLR: if(bridge_valid&&bridge_ready) state_q<=C_IRQCLRWAIT;
        C_IRQCLRWAIT: if(bridge_rsp_valid&&bridge_rsp_ready) begin
          frame_tick_o<=irq_sample_q[6];
          // Return to the arbiter after W1C. An already accepted host
          // transaction may finish under the lock; then C_READY rechecks J/K.
          state_q<=C_READY;
        end
        C_FAULT: if(reinit_pending_q && !client_pending_q && !bridge_pending_q && !bridge_busy && !bridge_rsp_valid) begin
          state_q<=C_PIN; connected_o<=0; fault_o<=0; initialized_q<=0; reinit_pending_q<=0; change_pending_q<=0;
        end
        default: ;
      endcase
      if(state_q==C_DB && timer_q>=DB_LAST_CYCLE) begin timer_q<=0; stable_check_q<=1; state_q<=C_DBCHK; end
    end
  end
endmodule
