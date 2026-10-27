`ifdef BP_DIFFTEST_S
`include "bp_common_defines.svh"
`include "bp_be_defines.svh"

// Profile-specific proof supplement for physical store drains. This monitor
// supplies ownership facts; retirement and public event ordering remain host work.
module bp_be_nonsynth_difftest_s_coherence
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

  import "DPI-C" context function int bp_difftest_s_coherent_drain
    (input int unsigned hart, input longint unsigned epoch, input longint unsigned uid,
     input int unsigned attempt, input longint unsigned source_time,
     input longint unsigned aligned_address, input int unsigned cache_set,
     input int unsigned cache_way, input int unsigned coherence_state,
     input longint unsigned grant_time, input int unsigned proof_flags,
     input int unsigned bank_select, input int unsigned physical_sram_index);

  localparam int bank_width_lp = dcache_block_width_p / dcache_assoc_p;
  localparam int bank_offset_width_lp = `BSG_SAFE_CLOG2(bank_width_lp / 8);
  localparam int way_width_lp = `BSG_SAFE_CLOG2(dcache_assoc_p);
  localparam int set_width_lp = `BSG_SAFE_CLOG2(dcache_sets_p);
  localparam int block_offset_width_lp = `BSG_SAFE_CLOG2(dcache_block_width_p / 8);
  `declare_bp_cache_tag_info_s(dcache_tag_width_p, difftest_shadow);
  `declare_bp_be_dcache_wbuf_entry_s(caddr_width_p, dcache_assoc_p);

  bp_difftest_shadow_tag_info_s tag_shadow_r [dcache_sets_p][dcache_assoc_p];
  bp_difftest_shadow_tag_info_s tag_known_r [dcache_sets_p][dcache_assoc_p];
  logic [63:0] grant_time_r [dcache_sets_p][dcache_assoc_p];

`define BP_DS_OWN_DC calculator.pipe_mem.dcache
`define BP_DS_OWN_MEM difftest_s_memory_probe

  initial begin
    if (bp_params_p != e_bp_multicore_4_cfg || cce_type_p != e_cce_fsm
        || !dcache_features_p[e_cfg_coherent] || !dcache_features_p[e_cfg_writeback]
        || async_coh_clk_p != 0 || async_mem_clk_p != 0 || async_dma_clk_p != 0
        || dcache_data_width_p != 64 || dcache_sets_p != 64 || dcache_assoc_p != 8
        || dcache_block_width_p != 512)
      $fatal(1, "Difftest-S coherent drain proof requires the synchronous four-hart FSM profile");
  end

  function automatic bit ordinary_scalar(input logic [31:0] flags);
    return (flags & ~32'h8) === 32'h0;
  endfunction

  function automatic logic [way_width_lp-1:0] physical_way
    (input bp_be_dcache_wbuf_entry_s entry);
    logic [way_width_lp-1:0] bank_offset;
    logic [way_width_lp-1:0] result;
    bank_offset = entry.caddr[bank_offset_width_lp+:way_width_lp];
    result = '0;
    for (int bank = 0; bank < dcache_assoc_p; bank++)
      if (entry.bank_sel[bank])
        result = way_width_lp'(bank) - bank_offset;
    return result;
  endfunction

  // Check all physical queue entries while they exist. In particular this does
  // not trust wbuf.snoop_match_o, whose el0 snoop qualifier uses the TV entry.
  task automatic require_exclusive_entry
    (input bp_be_dcache_wbuf_entry_s entry, input bit valid);
    logic [set_width_lp-1:0] set_index;
    logic [way_width_lp-1:0] way;
    logic [dcache_tag_width_p-1:0] tag;
    bp_difftest_shadow_tag_info_s next_tag;
    if (valid) begin
      set_index = entry.caddr[block_offset_width_lp+:set_width_lp];
      way = physical_way(entry);
      tag = entry.caddr[block_offset_width_lp+set_width_lp+:dcache_tag_width_p];
      if ($isunknown(entry) || $isunknown(tag_shadow_r[set_index][way])
          || !$onehot(entry.bank_sel)
          || tag_known_r[set_index][way] !== bp_difftest_shadow_tag_info_s'('1)
          || tag_shadow_r[set_index][way].tag != tag
          || !(tag_shadow_r[set_index][way].state inside {e_COH_M, e_COH_E}))
        $fatal(1, "Difftest-S pending store lacks a matching observed M/E grant");

      if (`BP_DS_OWN_DC.data_mem_pkt_yumi_o
          && `BP_DS_OWN_DC.data_mem_pkt_cast_i.opcode == e_cache_data_mem_read
          && `BP_DS_OWN_DC.data_mem_pkt_cast_i.index == set_index
          && `BP_DS_OWN_DC.data_mem_pkt_cast_i.way_id == way)
        $fatal(1, "Difftest-S coherence read accepted while matching store is buffered");

      if (`BP_DS_OWN_DC.tag_mem_v_li && `BP_DS_OWN_DC.tag_mem_w_li
          && `BP_DS_OWN_DC.tag_mem_addr_li == set_index) begin
        next_tag = (tag_shadow_r[set_index][way] & ~`BP_DS_OWN_DC.tag_mem_mask_li[way])
          | (`BP_DS_OWN_DC.tag_mem_data_li[way] & `BP_DS_OWN_DC.tag_mem_mask_li[way]);
        if ($isunknown(next_tag) || next_tag.tag != tag || !(next_tag.state inside {e_COH_M, e_COH_E}))
          $fatal(1, "Difftest-S store ownership lost before its physical drain");
      end
    end
  endtask

  always @(negedge clk_i) begin : observe_ownership
    bp_difftest_shadow_tag_info_s write_mask;
    bp_difftest_shadow_tag_info_s next_tag;
    bp_be_dcache_wbuf_entry_s outgoing_entry;
    logic [set_width_lp-1:0] set_index;
    logic [way_width_lp-1:0] way;
    logic [63:0] epoch, uid, address;
    logic [31:0] attempt, memory_flags, proof_flags;
    logic [set_width_lp+way_width_lp-1:0] physical_sram_index;
    logic physical_write_matches;
    int result;

    if (reset_i) begin
      for (int cache_set = 0; cache_set < dcache_sets_p; cache_set++)
        for (int cache_way = 0; cache_way < dcache_assoc_p; cache_way++) begin
          tag_shadow_r[cache_set][cache_way] <= '0;
          tag_known_r[cache_set][cache_way] <= '0;
          grant_time_r[cache_set][cache_way] <= '0;
        end
    end else begin
      // Observe initialization writes even before the core observation epoch is
      // enabled. The tag SRAM itself is initialized by LCE set-clear packets.
      if (`BP_DS_OWN_DC.tag_mem_v_li && `BP_DS_OWN_DC.tag_mem_w_li) begin
        for (int cache_way = 0; cache_way < dcache_assoc_p; cache_way++) begin
          write_mask = `BP_DS_OWN_DC.tag_mem_mask_li[cache_way];
          set_index = `BP_DS_OWN_DC.tag_mem_addr_li;
          next_tag = (tag_shadow_r[set_index][cache_way] & ~write_mask)
            | (`BP_DS_OWN_DC.tag_mem_data_li[cache_way] & write_mask);
          tag_shadow_r[set_index][cache_way] <= next_tag;
          tag_known_r[set_index][cache_way] <= tag_known_r[set_index][cache_way] | write_mask;
          if ((&write_mask.state) && next_tag.state inside {e_COH_M, e_COH_E})
            grant_time_r[set_index][cache_way] <= source_time_i;
        end
      end

      if (en_i) begin
        if ($isunknown(source_time_i) || !source_time_i[0])
          $fatal(1, "Difftest-S coherence source requires a known odd half-cycle tick");
        require_exclusive_entry(`BP_DS_OWN_DC.wbuf.wbuf_entry_el0_r,
          `BP_DS_OWN_DC.wbuf.el0_valid && ordinary_scalar(`BP_DS_OWN_MEM.wbuf_flags0_r));
        require_exclusive_entry(`BP_DS_OWN_DC.wbuf.wbuf_entry_el1_r,
          `BP_DS_OWN_DC.wbuf.el1_valid && ordinary_scalar(`BP_DS_OWN_MEM.wbuf_flags1_r));
        require_exclusive_entry(`BP_DS_OWN_DC.wbuf_entry_in,
          `BP_DS_OWN_DC.wbuf_v_li
            && ordinary_scalar(`BP_DS_OWN_MEM.memory_flags(`BP_DS_OWN_DC.snoop_tv_r)));

        if (`BP_DS_OWN_DC.wbuf_yumi_li) begin
          outgoing_entry = `BP_DS_OWN_DC.wbuf_entry_out;
          set_index = outgoing_entry.caddr[block_offset_width_lp+:set_width_lp];
          way = physical_way(outgoing_entry);
          if (`BP_DS_OWN_DC.wbuf.mux1_sel) begin
            epoch = `BP_DS_OWN_MEM.wbuf_identity1_r.epoch;
            uid = `BP_DS_OWN_MEM.wbuf_identity1_r.uid;
            attempt = `BP_DS_OWN_MEM.wbuf_identity1_r.attempt;
            address = `BP_DS_OWN_MEM.wbuf_address1_r;
            memory_flags = `BP_DS_OWN_MEM.wbuf_flags1_r;
          end else begin
            epoch = `BP_DS_OWN_MEM.tv_identity_r.epoch;
            uid = `BP_DS_OWN_MEM.tv_identity_r.uid;
            attempt = `BP_DS_OWN_MEM.tv_identity_r.attempt;
            address = 64'(`BP_DS_OWN_DC.paddr_tv_r) & ~64'h7;
            memory_flags = `BP_DS_OWN_MEM.memory_flags(`BP_DS_OWN_DC.snoop_tv_r);
          end

          physical_write_matches = (`BP_DS_OWN_DC.data_mem_fast_write === outgoing_entry.bank_sel)
            && (address === (64'(outgoing_entry.caddr) & ~64'h7));
          physical_sram_index = '0;
          for (int bank = 0; bank < dcache_assoc_p; bank++)
            if (outgoing_entry.bank_sel[bank]) begin
              physical_sram_index = `BP_DS_OWN_DC.data_mem_addr_li[bank];
              physical_write_matches &= `BP_DS_OWN_DC.data_mem_fast_write[bank]
                && `BP_DS_OWN_DC.data_mem_v_li[bank] && `BP_DS_OWN_DC.data_mem_w_li[bank]
                && `BP_DS_OWN_DC.data_mem_mask_li[bank] == `BP_DS_OWN_DC.wbuf_data_mem_mask
                && `BP_DS_OWN_DC.data_mem_addr_li[bank]
                  == {set_index, outgoing_entry.caddr[bank_offset_width_lp+:way_width_lp]}
                && `BP_DS_OWN_DC.data_mem_data_li[bank] == {bank_width_lp/64{outgoing_entry.data}};
            end

          // Bits state independently observed facts, not a cross-hart phase or rank.
          proof_flags = '0;
          proof_flags[0] = ordinary_scalar(memory_flags);
          proof_flags[1] = (&tag_known_r[set_index][way])
            && tag_shadow_r[set_index][way].tag
              == outgoing_entry.caddr[block_offset_width_lp+set_width_lp+:dcache_tag_width_p];
          proof_flags[2] = (tag_shadow_r[set_index][way].state inside {e_COH_M, e_COH_E})
            && grant_time_r[set_index][way] != 0 && grant_time_r[set_index][way] < source_time_i;
          proof_flags[3] = physical_write_matches && $onehot(outgoing_entry.bank_sel);
          // Unsupported kinds are retained as unqualified facts. Their entries
          // are excluded from this ordinary-scalar permission proof.
          proof_flags[4] = proof_flags[0];
          if (proof_flags[0] && proof_flags !== 32'h1f)
            $fatal(1, "Difftest-S coherent drain lacks all five profile proof facts");
          result = bp_difftest_s_coherent_drain(32'(difftest_s_probe.hart_r), epoch, uid,
            attempt, source_time_i, address, 32'(set_index), 32'(way),
            32'(tag_shadow_r[set_index][way].state), grant_time_r[set_index][way], proof_flags,
            32'(outgoing_entry.bank_sel), 32'(physical_sram_index));
          if (result != 0)
            $fatal(1, "Difftest-S host rejected coherent drain proof (status %0d)", result);
        end
      end
    end
  end
`undef BP_DS_OWN_MEM
`undef BP_DS_OWN_DC
endmodule
`endif
