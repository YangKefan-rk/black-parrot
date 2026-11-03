`ifdef BP_SFUZZ_PRIVATE_PROBES
`include "bp_common_defines.svh"
`include "bp_me_defines.svh"

// The CCE does not expose an architectural store-publish event or a dynamic
// instruction UID. These source facts describe controller activity only.
module bp_me_nonsynth_sfuzz_cce
  import bp_common_pkg::*;
  import bp_me_pkg::*;
  #(parameter bp_params_e bp_params_p = e_bp_default_cfg
    `declare_bp_proc_params(bp_params_p)
    )
  (input logic clk_i
   , input logic reset_i
   , input logic en_i
   , input logic terminal_end_i
   , input logic [63:0] source_time_i
   , input logic [cce_id_width_p-1:0] cce_id_i
   , input logic pending_i
   , input logic [paddr_width_p-1:0] current_address_i
   , input logic [lce_id_width_p-1:0] requestor_i
   , input logic inv_sent_i
   , input logic [paddr_width_p-1:0] inv_address_i
   , input logic [lce_id_width_p-1:0] inv_destination_i
   , input logic inv_ack_i
   , input logic [paddr_width_p-1:0] ack_address_i
   , input logic [lce_id_width_p-1:0] ack_source_i
   , input logic owner_cmd_i
   , input logic [paddr_width_p-1:0] owner_line_i
   , input logic [lce_id_width_p-1:0] owner_lce_i
   , input bp_coh_states_e owner_state_i
   , input bp_coh_states_e proposed_state_i
   );

  import "DPI-C" context function void bp_sfuzz_cce_sample
    (input longint unsigned source_time
     , input int unsigned cce_id
     , input longint unsigned epoch
     , input int unsigned pending
     , input int unsigned inv_sent
     , input longint unsigned inv_line_addr
     , input int unsigned inv_dst_lce
     , input int unsigned requestor_lce
     , input int unsigned inv_ack
     , input longint unsigned ack_line_addr
     , input int unsigned ack_src_lce);

  import "DPI-C" context function void bp_sfuzz_owner_cmd
    (input longint unsigned source_time
     , input int unsigned cce_id
     , input longint unsigned epoch
     , input longint unsigned line_addr
     , input int unsigned owner_lce
     , input int unsigned requestor_lce
     , input int unsigned old_state
     , input int unsigned proposed_state);

  localparam int unsigned line_bytes_lp = bedrock_block_width_p / 8;
  logic [63:0] epoch_r = 0;
  bit in_reset_r = 0;
  bit started_r = 0;
  bit sealed_r = 0;
  logic [63:0] last_source_time_r = 0;

  initial if (bp_params_p != e_bp_multicore_4_cfg)
    $fatal(1, "SFUZZ CCE probes require BlackParrot's synchronous FSM four-hart profile");

  always @(posedge clk_i) begin
    if (reset_i) begin
      if (started_r || sealed_r)
        $fatal(1, "SFUZZ CCE reset after source sampling began");
      if (!in_reset_r)
        epoch_r = epoch_r + 1;
      in_reset_r = 1;
    end else if (terminal_end_i) begin
      sealed_r = started_r;
    end else if (!en_i) begin
      if (started_r)
        $fatal(1, "SFUZZ CCE source disabled before terminal closure");
      in_reset_r = 0;
    end else begin
      in_reset_r = 0;
      // The testbench starts before reset. Only the first positive post-reset
      // source position may open the continuous producer stream.
      if (!started_r && epoch_r > 0 && source_time_i > 0)
        started_r = 1;
      if (started_r) begin
        if (sealed_r || $isunknown({source_time_i, cce_id_i, pending_i,
                                    inv_sent_i, inv_ack_i}) || source_time_i[0]
            || (last_source_time_r != 0 && source_time_i != last_source_time_r + 2))
          $fatal(1, "SFUZZ CCE source has a gap, unknown identity or wrong clock phase");
        if ((inv_sent_i && $isunknown({inv_address_i, inv_destination_i, requestor_i}))
            || (inv_ack_i && $isunknown({ack_address_i, ack_source_i}))
            || (owner_cmd_i && $isunknown({owner_line_i, owner_lce_i,
                                         requestor_i, owner_state_i, proposed_state_i})))
          $fatal(1, "SFUZZ CCE event address or LCE identity is unknown");
        last_source_time_r = source_time_i;
        // Distinct send/ACK addresses are independent: ACKs may return while
        // another destination receives its first invalidation handshake.
        bp_sfuzz_cce_sample(source_time_i, 32'(cce_id_i), epoch_r,
          32'(pending_i), 32'(inv_sent_i),
          inv_sent_i ? 64'(inv_address_i) & ~(64'(line_bytes_lp) - 1) : 0,
          inv_sent_i ? 32'(inv_destination_i) : 0,
          inv_sent_i ? 32'(requestor_i) : 0,
          32'(inv_ack_i),
          inv_ack_i ? 64'(ack_address_i) & ~(64'(line_bytes_lp) - 1) : 0,
          inv_ack_i ? 32'(ack_source_i) : 0);
        if (owner_cmd_i)
          bp_sfuzz_owner_cmd(source_time_i, 32'(cce_id_i), epoch_r,
            64'(owner_line_i) & ~(64'(line_bytes_lp) - 1),
            32'(owner_lce_i), 32'(requestor_i),
            32'(owner_state_i), 32'(proposed_state_i));
      end
    end
  end
endmodule

// Only core D$ LCEs use the negative-edge memory phase. I$ LCEs run on the
// positive edge, and accelerator LCE IDs have different ownership semantics.
module bp_me_nonsynth_sfuzz_dcache_lce
  import bp_common_pkg::*;
  import bp_me_pkg::*;
  #(parameter bp_params_e bp_params_p = e_bp_default_cfg
    `declare_bp_proc_params(bp_params_p)
    , parameter int unsigned capacity_p = coh_noc_max_credits_p
    )
  (input logic clk_i
   , input logic reset_i
   , input logic en_i
   , input logic terminal_end_i
   , input logic [63:0] source_time_i
   , input logic [lce_id_width_p-1:0] lce_id_i
   , input logic [`BSG_WIDTH(capacity_p)-1:0] credit_count_i
   , input logic request_valid_i
   , input logic request_accepted_i
   , input logic credit_return_i
   );

  import "DPI-C" context function void bp_sfuzz_lce_sample
    (input longint unsigned source_time
     , input int unsigned lce_id
     , input longint unsigned epoch
     , input int unsigned credits
     , input int unsigned capacity
     , input int unsigned req_valid
     , input int unsigned req_accepted
     , input int unsigned credit_return);

  logic [63:0] epoch_r = 0;
  bit in_reset_r = 0;
  bit started_r = 0;
  bit sealed_r = 0;
  logic [63:0] last_source_time_r = 0;
  wire is_core_dcache = (lce_id_i < (2 * num_core_p)) && lce_id_i[0];

  initial if (bp_params_p != e_bp_multicore_4_cfg)
    $fatal(1, "SFUZZ LCE probes require BlackParrot's synchronous FSM four-hart profile");

  always @(posedge clk_i) begin
    if (reset_i) begin
      if (started_r || sealed_r)
        $fatal(1, "SFUZZ D$ LCE reset after source sampling began");
      if (!in_reset_r)
        epoch_r = epoch_r + 1;
      in_reset_r = 1;
    end else if (terminal_end_i) begin
      sealed_r = started_r;
    end else if (!en_i) begin
      if (started_r)
        $fatal(1, "SFUZZ D$ LCE source disabled before terminal closure");
      in_reset_r = 0;
    end else begin
      in_reset_r = 0;
      if (epoch_r > 0 && source_time_i > 0 && $isunknown(lce_id_i))
        $fatal(1, "SFUZZ LCE identity is unknown after reset");
      if (is_core_dcache) begin
        if (!started_r && epoch_r > 0 && source_time_i > 0)
          started_r = 1;
        if (started_r) begin
          if (sealed_r || !source_time_i[0]
              || (last_source_time_r != 0 && source_time_i != last_source_time_r + 2)
              || $isunknown({source_time_i, credit_count_i, request_valid_i,
                             request_accepted_i, credit_return_i}))
            $fatal(1, "SFUZZ D$ LCE source has a gap, unknown credit or wrong phase");
          if (credit_count_i > capacity_p || (request_accepted_i && !request_valid_i))
            $fatal(1, "SFUZZ D$ LCE credit or cache request handshake is inconsistent");
          last_source_time_r = source_time_i;
          bp_sfuzz_lce_sample(source_time_i, 32'(lce_id_i), epoch_r,
            32'(credit_count_i), capacity_p, 32'(request_valid_i),
            32'(request_accepted_i), 32'(credit_return_i));
        end
      end else if (started_r) begin
        $fatal(1, "SFUZZ D$ LCE source changed its core/hart identity");
      end
    end
  end
endmodule

bind bp_cce_fsm bp_me_nonsynth_sfuzz_cce
  #(.bp_params_p(bp_params_p)) sfuzz_cce_probe
  (.clk_i(clk_i), .reset_i(reset_i)
   ,.en_i(1'b1)
   ,.terminal_end_i(testbench.difftest_s_terminal_end)
   ,.source_time_i(testbench.difftest_s_core_time)
   ,.cce_id_i(cfg_bus_cast_i.cce_id)
   ,.pending_i(pending_r_v && pending_lo)
   ,.current_address_i(mshr_r.paddr)
   ,.requestor_i(mshr_r.lce_id)
   ,.inv_sent_i(fsm_cmd_v_lo && fsm_cmd_new_lo
     && fsm_cmd_header_lo.msg_type.cmd == e_bedrock_cmd_inv)
   ,.inv_address_i(fsm_cmd_header_lo.addr)
   ,.inv_destination_i(fsm_cmd_header_lo.payload.dst_id)
   ,.inv_ack_i(fsm_resp_v_li && fsm_resp_yumi_lo && fsm_resp_new_li
     && fsm_resp_header_li.msg_type.resp == e_bedrock_resp_inv_ack)
   ,.ack_address_i(fsm_resp_header_li.addr)
   ,.ack_source_i(fsm_resp_header_li.payload.src_id)
   ,.owner_cmd_i(state_r == e_transfer && fsm_cmd_v_lo && fsm_cmd_new_lo)
   ,.owner_line_i(fsm_cmd_header_lo.addr)
   ,.owner_lce_i(mshr_r.owner_lce_id)
   ,.owner_state_i(mshr_r.owner_coh_state)
   ,.proposed_state_i(fsm_cmd_header_lo.payload.state));

bind bp_lce_req bp_me_nonsynth_sfuzz_dcache_lce
  #(.bp_params_p(bp_params_p), .capacity_p(credits_p)) sfuzz_lce_probe
  (.clk_i(clk_i), .reset_i(reset_i)
   ,.en_i(1'b1)
   ,.terminal_end_i(testbench.difftest_s_terminal_end)
   ,.source_time_i(testbench.difftest_s_memory_time)
   ,.lce_id_i(lce_id_i)
   ,.credit_count_i(credit_count_lo)
   ,.request_valid_i(cache_req_v_i)
   ,.request_accepted_i(cache_req_yumi_o)
   ,.credit_return_i(credit_return_i));
`endif
