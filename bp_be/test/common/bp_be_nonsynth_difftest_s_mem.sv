`ifdef BP_DIFFTEST_S
`include "bp_common_defines.svh"
`include "bp_be_defines.svh"

// Private physical-source observations. SRAM drain is a candidate, not a GMO
// claim: the host must qualify publication against the selected protocol.
module bp_be_nonsynth_difftest_s_mem
 import bp_common_pkg::*;
 import bp_be_pkg::*;
 #(parameter bp_params_e bp_params_p = e_bp_default_cfg
   `declare_bp_proc_params(bp_params_p)
   )
  (input clk_i
   , input reset_i
   , input en_i
   , input [63:0] source_time_i
   );

  import "DPI-C" context function int bp_difftest_s_memory
    (input int unsigned hart, input longint unsigned epoch, input longint unsigned uid,
     input int unsigned attempt, input longint unsigned source_time, input int unsigned kind,
     input longint unsigned address, input longint unsigned aligned_data, input int unsigned mask,
     input longint unsigned array_time, input longint unsigned forwarding_time,
     input int unsigned forwarded_mask, input int unsigned flags);
  import "DPI-C" context function int bp_difftest_s_forward_byte
    (input int unsigned hart, input longint unsigned epoch, input longint unsigned uid,
     input int unsigned attempt, input int unsigned byte_index,
     input longint unsigned writer_epoch, input longint unsigned writer_uid);
  import "DPI-C" context function int bp_difftest_s_memory_idle
    (input int unsigned hart, input longint unsigned source_time, input int unsigned physically_idle);

  typedef struct packed {
    logic valid;
    logic [63:0] epoch;
    logic [63:0] uid;
    logic [31:0] attempt;
  } identity_s;

  // All shadow state follows real cache enables. None can stall the DUT.
  identity_s tl_identity_r, tv_identity_r, miss_identity_r;
  identity_s wbuf_identity0_r, wbuf_identity1_r;
  identity_s forwarding_identity_r [8];
  logic [63:0] tl_array_time_r, tv_array_time_r, tv_forwarding_time_r;
  logic [63:0] wbuf_address0_r, wbuf_address1_r;
  logic [31:0] wbuf_flags0_r, wbuf_flags1_r;
  identity_s request_identity;
  logic physically_idle_r = 0;

`define BP_DS_DC calculator.pipe_mem.dcache
  // This is a source fact at the upcoming physical edge, not a watermark.
  wire physical_idle = `BP_DS_DC.ordered_o && `BP_DS_DC.is_ready
    && (`BP_DS_DC.wbuf.num_els_r == 0) && !`BP_DS_DC.wbuf_v_li && !`BP_DS_DC.wbuf_v_lo
    && !`BP_DS_DC.wbuf_yumi_li && !`BP_DS_DC.safe_tl_we && !`BP_DS_DC.v_i
    && !`BP_DS_DC.v_tl_r && !`BP_DS_DC.v_tv_r && !`BP_DS_DC.tv_we
    && !`BP_DS_DC.blocking_sent && !`BP_DS_DC.nonblocking_sent
    && !`BP_DS_DC.cache_req_v_o && `BP_DS_DC.cache_req_credits_empty_i
    && !miss_identity_r.valid && !tl_identity_r.valid && !tv_identity_r.valid
    && !`BP_DS_DC.critical_recv && !`BP_DS_DC.complete_recv && !`BP_DS_DC.fill_restart_tv
    && !`BP_DS_DC.data_mem_pkt_v_i && !`BP_DS_DC.tag_mem_pkt_v_i && !`BP_DS_DC.stat_mem_pkt_v_i;

  always_comb begin
    request_identity.valid = difftest_s_probe.reservation_identity.valid;
    request_identity.epoch = difftest_s_probe.reservation_identity.epoch;
    request_identity.uid = difftest_s_probe.reservation_identity.uid;
    request_identity.attempt = difftest_s_probe.reservation_identity.attempt;
  end

  task automatic require_success(input int result);
    if (result != 0)
      $fatal(1, "Difftest-S memory host rejected source %0d (status %0d)", source_time_i, result);
  endtask

  // Deliberately separate atomic, MMIO/internal and FP paths from scalar facts.
  function automatic int unsigned memory_flags(input bit critical_fill);
    return (32'(`BP_DS_DC.decode_tv_r.amo_op || `BP_DS_DC.decode_tv_r.lr_op
                || `BP_DS_DC.decode_tv_r.sc_op))
      | (32'(`BP_DS_DC.uncached_tv_r) << 1)
      | (32'(`BP_DS_DC.decode_tv_r.ptw_op) << 2)
      | (32'(critical_fill) << 3)
      | (32'(`BP_DS_DC.decode_tv_r.float_op) << 4)
      | (32'(`BP_DS_DC.decode_tv_r.cache_op || `BP_DS_DC.decode_tv_r.block_op) << 5);
  endfunction

  // DCache clk is the inverted core clock. The testbench supplies the common
  // odd half-cycle tick; source_time is not the later DPI arrival time.
  always @(negedge clk_i) begin : observe_memory
    identity_s outgoing_identity;
    identity_s selected_writer;
    logic [63:0] incoming_address, outgoing_address;
    logic [7:0] load_mask, forwarded_mask;
    int unsigned flags, outgoing_flags;
    if (reset_i || !en_i) begin
      physically_idle_r <= 0;
      tl_identity_r <= '0;
      tv_identity_r <= '0;
      miss_identity_r <= '0;
      wbuf_identity0_r <= '0;
      wbuf_identity1_r <= '0;
      wbuf_address0_r <= '0;
      wbuf_address1_r <= '0;
      wbuf_flags0_r <= '0;
      wbuf_flags1_r <= '0;
      tl_array_time_r <= '0;
      tv_array_time_r <= '0;
      tv_forwarding_time_r <= '0;
      for (int i = 0; i < 8; i++)
        forwarding_identity_r[i] <= '0;
    end else begin
      if ($isunknown(source_time_i))
        $fatal(1, "Difftest-S memory source clock is unknown");

`ifdef BP_DIFFTEST_S_TERMINAL
      if (difftest_s_probe.terminal_closed_r && physical_idle !== 1'b1)
        $fatal(1, "Difftest-S memory source activity after terminal closure");
`endif
      incoming_address = 64'(`BP_DS_DC.paddr_tv_r) & ~64'h7;
      outgoing_identity = `BP_DS_DC.wbuf.mux1_sel ? wbuf_identity1_r : tv_identity_r;
      outgoing_address = `BP_DS_DC.wbuf.mux1_sel ? wbuf_address1_r : incoming_address;
      flags = memory_flags(`BP_DS_DC.snoop_tv_r);
      outgoing_flags = `BP_DS_DC.wbuf.mux1_sel ? wbuf_flags1_r : flags;

      if (`BP_DS_DC.wbuf_v_li) begin
        if (!tv_identity_r.valid && !`BP_DS_DC.decode_tv_r.ptw_op)
          $fatal(1, "Difftest-S cached store has no dynamic identity");
        require_success(bp_difftest_s_memory(32'(difftest_s_probe.hart_r),
          tv_identity_r.epoch, tv_identity_r.uid, tv_identity_r.attempt,
          source_time_i, 1, incoming_address, `BP_DS_DC.wbuf_entry_in.data,
          32'(`BP_DS_DC.wbuf_entry_in.mask), 0, 0, 0, flags));
      end

      // Queue identities move exactly as their data entries, including empty
      // input-and-drain in one edge and simultaneous dequeue/enqueue when full.
      if (`BP_DS_DC.wbuf.el0_enable) begin
        wbuf_identity0_r <= tv_identity_r;
        wbuf_address0_r <= incoming_address;
        wbuf_flags0_r <= flags;
      end
      if (`BP_DS_DC.wbuf.el1_enable) begin
        wbuf_identity1_r <= `BP_DS_DC.wbuf.mux0_sel ? wbuf_identity0_r : tv_identity_r;
        wbuf_address1_r <= `BP_DS_DC.wbuf.mux0_sel ? wbuf_address0_r : incoming_address;
        wbuf_flags1_r <= `BP_DS_DC.wbuf.mux0_sel ? wbuf_flags0_r : flags;
      end
      if (`BP_DS_DC.wbuf_yumi_li) begin
        if (!outgoing_identity.valid && !outgoing_flags[2])
          $fatal(1, "Difftest-S write-buffer drain lost its dynamic identity");
        require_success(bp_difftest_s_memory(32'(difftest_s_probe.hart_r),
          outgoing_identity.epoch, outgoing_identity.uid, outgoing_identity.attempt,
          source_time_i, 2, outgoing_address, `BP_DS_DC.wbuf_entry_out.data,
          32'(`BP_DS_DC.wbuf_entry_out.mask), 0, 0, 0, outgoing_flags));
      end

      if (`BP_DS_DC.v_o && `BP_DS_DC.decode_tv_r.load_op) begin
        if (!tv_identity_r.valid && !`BP_DS_DC.decode_tv_r.ptw_op)
          $fatal(1, "Difftest-S load sample has no dynamic identity");
        load_mask = '0;
        if (`BP_DS_DC.decode_tv_r.byte_op)
          load_mask = 8'h1;
        else if (`BP_DS_DC.decode_tv_r.half_op)
          load_mask = 8'h3;
        else if (`BP_DS_DC.decode_tv_r.word_op)
          load_mask = 8'hf;
        else if (`BP_DS_DC.decode_tv_r.double_op)
          load_mask = 8'hff;
        else
          $fatal(1, "Difftest-S load has no scalar byte width");
        load_mask = load_mask << `BP_DS_DC.paddr_tv_r[0+:3];
        forwarded_mask = load_mask & `BP_DS_DC.wbuf.bypass_mask_r;
        for (int i = 0; i < 8; i++) begin
          if (forwarded_mask[i]) begin
            require_success(bp_difftest_s_forward_byte(32'(difftest_s_probe.hart_r),
              tv_identity_r.epoch, tv_identity_r.uid, tv_identity_r.attempt, 32'(i),
              forwarding_identity_r[i].valid ? forwarding_identity_r[i].epoch : 0,
              forwarding_identity_r[i].valid ? forwarding_identity_r[i].uid : 0));
          end
        end
        require_success(bp_difftest_s_memory(32'(difftest_s_probe.hart_r),
          tv_identity_r.epoch, tv_identity_r.uid, tv_identity_r.attempt,
          source_time_i, 3, incoming_address, `BP_DS_DC.ld_data_dword_merged,
          32'(load_mask), tv_array_time_r, tv_forwarding_time_r, 32'(forwarded_mask), flags));
      end

      // Save source time at SRAM read, not at TV/response. The physical tag
      // qualifies it one edge later; invalid TL attempts never become samples.
      tl_identity_r <= `BP_DS_DC.tl_we ? request_identity : '0;
      if (`BP_DS_DC.data_mem_assoc_read)
        tl_array_time_r <= source_time_i;
      tv_identity_r <= '0;
      if (`BP_DS_DC.tv_we || `BP_DS_DC.fill_restart_tv) begin
        tv_identity_r <= `BP_DS_DC.snoop_v ? miss_identity_r : tl_identity_r;
        tv_array_time_r <= `BP_DS_DC.snoop_v ? source_time_i : tl_array_time_r;
        tv_forwarding_time_r <= source_time_i;
      end
      // A pipeline redirect (for example WFI) can flush younger work while
      // this miss belongs to an already committed instruction. Only real
      // UID/attempt cancellation can cancel that instruction; the bridge
      // validates those explicit records. Keep the physical MSHR until its
      // completion, using its old identity for a same-edge critical beat.
      if (`BP_DS_DC.complete_recv)
        miss_identity_r <= '0;
      if (`BP_DS_DC.blocking_sent)
        miss_identity_r <= tv_identity_r;

      // Mirror the actual byte priority: current TV store > el0 > el1.
      for (int i = 0; i < 8; i++) begin
        selected_writer = '0;
        if (`BP_DS_DC.wbuf.tag_hit2 && `BP_DS_DC.wbuf.wbuf_entry_cast_i.mask[i])
          selected_writer = tv_identity_r;
        else if (`BP_DS_DC.wbuf.tag_hit0 && `BP_DS_DC.wbuf.wbuf_entry_el0_r.mask[i])
          selected_writer = wbuf_identity0_r;
        else if (`BP_DS_DC.wbuf.tag_hit1 && `BP_DS_DC.wbuf.wbuf_entry_el1_r.mask[i])
          selected_writer = wbuf_identity1_r;
        forwarding_identity_r[i] <= selected_writer;
      end

      physically_idle_r <= physical_idle === 1'b1;
      require_success(bp_difftest_s_memory_idle(32'(difftest_s_probe.hart_r), source_time_i,
        32'(physical_idle === 1'b1)));
    end
  end
`undef BP_DS_DC
endmodule
`endif
