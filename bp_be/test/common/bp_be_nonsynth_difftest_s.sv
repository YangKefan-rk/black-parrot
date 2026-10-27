`ifdef BP_DIFFTEST_S
`include "bp_common_defines.svh"
`include "bp_be_defines.svh"

// DUT-private source monitor. The host converts these records to the public API.
module bp_be_nonsynth_difftest_s
 import bp_common_pkg::*;
 import bp_be_pkg::*;
 #(parameter bp_params_e bp_params_p = e_bp_default_cfg
   `declare_bp_proc_params(bp_params_p)
   , parameter int max_pending_p = 4096
   )
  (input clk_i
   , input reset_i
   , input en_i
   , input [63:0] source_time_i
   , input terminal_end_i = 1'b0
   );

  import "DPI-C" context function int bp_difftest_s_probe_init
    (input int unsigned hart, input int unsigned hart_count);
  import "DPI-C" context function int bp_difftest_s_allocate
    (input int unsigned hart, input longint unsigned epoch, input longint unsigned uid,
     input int unsigned attempt, input longint unsigned source_time, input longint unsigned pc,
     input int unsigned raw_instruction, input int unsigned instruction_bytes,
     input int unsigned expanded_instruction);
  import "DPI-C" context function int bp_difftest_s_retire
    (input int unsigned hart, input longint unsigned epoch, input longint unsigned uid,
     input int unsigned attempt, input longint unsigned source_time, input longint unsigned pc,
     input int unsigned raw_instruction, input int unsigned instruction_bytes,
     input int unsigned rd, input int unsigned write_enable, input int unsigned fp,
     input longint unsigned write_data);
  import "DPI-C" context function int bp_difftest_s_trap
    (input int unsigned hart, input longint unsigned epoch, input longint unsigned uid,
     input int unsigned attempt, input longint unsigned source_time, input longint unsigned pc,
     input longint unsigned cause, input int unsigned is_interrupt, input longint unsigned tval,
     input longint unsigned target_pc, input int unsigned privilege,
     input int unsigned target_privilege);
  import "DPI-C" context function int bp_difftest_s_cancel
    (input int unsigned hart, input longint unsigned epoch, input longint unsigned uid,
     input int unsigned attempt, input longint unsigned source_time, input int unsigned reason);
  import "DPI-C" context function int bp_difftest_s_heartbeat
    (input int unsigned hart, input longint unsigned source_time,
     input int unsigned pending_retirements);

`ifdef BP_DIFFTEST_S_TERMINAL
  import "DPI-C" context function int bp_difftest_s_terminal_state
    (input int unsigned hart, input longint unsigned source_time,
     input longint unsigned terminal_uid, input int unsigned stopped,
     input int unsigned pending_writebacks);
  import "DPI-C" context function int bp_difftest_s_close_hart
    (input int unsigned hart, input longint unsigned source_time,
     input longint unsigned terminal_uid);
`endif

  `declare_bp_be_if(vaddr_width_p, paddr_width_p, asid_width_p, branch_metadata_fwd_width_p, fetch_ptr_p, issue_ptr_p);

  localparam int issue_slot_width_lp = 1 + `BSG_SAFE_CLOG2(fe_queue_fifo_els_p) + fetch_sel_p;
  localparam int issue_slot_count_lp = 1 << issue_slot_width_lp;
  localparam int cancel_replay_lp = 1;
  localparam int cancel_squash_lp = 2;

  typedef struct packed {
    logic valid;
    logic ignored;
    logic [63:0] epoch;
    logic [63:0] uid;
    logic [31:0] attempt;
    logic [issue_slot_width_lp-1:0] slot;
    logic [63:0] pc;
    logic [31:0] raw_instruction;
    logic [31:0] instruction_bytes;
    logic [31:0] expanded_instruction;
  } identity_s;

  typedef struct packed {
    identity_s identity;
    logic [63:0] value;
  } writeback_s;

  typedef struct packed {
    identity_s identity;
    logic trap;
    logic terminal_wfi;
    logic [63:0] source_time;
    logic [63:0] pc;
    logic [4:0] rd;
    logic write_enable;
    logic [63:0] cause;
    logic is_interrupt;
    logic [63:0] tval;
    logic [63:0] target_pc;
    logic [1:0] privilege;
    logic [1:0] target_privilege;
  } completion_s;

  identity_s slot_identity [issue_slot_count_lp];
  identity_s pipeline_identity [5];
  identity_s pending_integer [rv64_rf_els_gp];
  writeback_s integer_writebacks [rv64_rf_els_gp][$];
  completion_s completions [$];

  longint unsigned epoch_r = 0;
  longint unsigned next_uid_r = 1;
  logic in_reset_r = 0;
  logic initialized_r = 0;
  logic started_r = 0;
  logic [31:0] raw_preissue_r = 0;
  int unsigned hart_r = 0;
`ifdef BP_DIFFTEST_S_TERMINAL
  longint unsigned terminal_uid_r = 0;
  bit terminal_closed_r = 0;
`endif

  wire bp_be_dispatch_pkt_s dispatch_packet = calculator.dispatch_pkt_cast_i;
  wire bp_be_commit_pkt_s commit_pkt = calculator.commit_pkt_o;
  wire bp_be_wb_pkt_s integer_writeback = calculator.iwb_pkt_o;
  wire bp_be_wb_pkt_s floating_writeback = calculator.fwb_pkt_o;
  wire bp_be_wb_pkt_s late_writeback = calculator.late_wb_pkt_o;
  wire bp_be_wb_pkt_s commit_completion = calculator.comp_stage_r[2];
  wire bp_be_decode_info_s decode_info = calculator.decode_info_o;
  wire bp_be_trans_info_s translation_info = calculator.trans_info_o;
  wire [issue_slot_width_lp-1:0] issue_slot = scheduler.issue_queue.rptr_r;
  wire is_real_dispatch = dispatch_packet.v & dispatch_packet.queue_v
    & ~scheduler.issue_pkt_cast_o.itlb_miss & ~scheduler.issue_pkt_cast_o.icache_miss
    & ~decode_info.debug_mode;
  wire raw_instruction_valid = scheduler.issue_pkt_cast_o.fetch
    | scheduler.issue_pkt_cast_o.illegal_instr;

  // These identities are intentionally visible to the separate memory monitor.
  identity_s dispatch_identity;
  wire identity_s reservation_identity = pipeline_identity[0];
  always_comb begin
    dispatch_identity = '0;
    dispatch_identity.ignored = dispatch_packet.v;
    if (is_real_dispatch) begin
      dispatch_identity = slot_identity[issue_slot];
      dispatch_identity.valid = 1'b1;
      dispatch_identity.ignored = 1'b0;
      dispatch_identity.epoch = epoch_r;
      dispatch_identity.uid = slot_identity[issue_slot].valid
        ? slot_identity[issue_slot].uid : next_uid_r;
      dispatch_identity.attempt = slot_identity[issue_slot].valid
        ? slot_identity[issue_slot].attempt + 1'b1 : 1;
      dispatch_identity.slot = issue_slot;
      dispatch_identity.pc = 64'($signed(dispatch_packet.pc));
      dispatch_identity.raw_instruction = '0;
      dispatch_identity.instruction_bytes = 0;
      if (raw_instruction_valid) begin
        // Illegal instructions carry a fetch-packet size, not decoded length.
        if (scheduler.issue_pkt_cast_o.illegal_instr)
          dispatch_identity.instruction_bytes = raw_preissue_r[1:0] == 2'b11 ? 4 : 2;
        else
          dispatch_identity.instruction_bytes = 32'(dispatch_packet.size << 1);
        dispatch_identity.raw_instruction = dispatch_identity.instruction_bytes == 2
          ? {16'b0, raw_preissue_r[0+:16]} : raw_preissue_r;
      end
      dispatch_identity.expanded_instruction = dispatch_packet.instr;
    end else if (scheduler.writeback_v) begin
      dispatch_identity = pending_integer[late_writeback.rd_addr];
    end
  end

  logic [int_rec_width_gp-1:0] integer_value;
  bp_be_int_unbox
   #(.bp_params_p(bp_params_p))
   integer_unbox
    (.reg_i(integer_writeback.rd_data)
     ,.tag_i(e_int_dword)
     ,.unsigned_i(1'b0)
     ,.val_o(integer_value)
     );

  task automatic require_success(input int result);
    if (result != 0)
      $fatal(1, "Difftest-S host rejected hart %0d source %0d (status %0d)", hart_r, source_time_i, result);
  endtask

  task automatic cancel_attempt(input identity_s identity, input int unsigned reason);
    if (identity.valid)
      require_success(bp_difftest_s_cancel(hart_r, identity.epoch, identity.uid,
        identity.attempt, source_time_i, reason));
  endtask

  task automatic emit_completed_prefix();
    completion_s head;
    writeback_s writeback;
    logic [63:0] value;
    bit ready;
    ready = 1'b1;
    while (completions.size() != 0 && ready) begin
      head = completions[0];
      value = '0;
      if (head.write_enable) begin
        ready = integer_writebacks[head.rd].size() != 0;
        if (ready) begin
          writeback = integer_writebacks[head.rd].pop_front();
          if (writeback.identity.uid != head.identity.uid
              || writeback.identity.epoch != head.identity.epoch
              || writeback.identity.attempt != head.identity.attempt)
            $fatal(1, "Difftest-S writeback identity mismatch on hart %0d x%0d", hart_r, head.rd);
          value = writeback.value;
        end
      end
      if (ready) begin
        head = completions.pop_front();
        if (head.trap)
          require_success(bp_difftest_s_trap(hart_r, head.identity.epoch, head.identity.uid,
            head.identity.attempt, head.source_time, head.pc, head.cause, 32'(head.is_interrupt),
            head.tval, head.target_pc, 32'(head.privilege), 32'(head.target_privilege)));
        else begin
          require_success(bp_difftest_s_retire(hart_r, head.identity.epoch, head.identity.uid,
            head.identity.attempt, head.source_time, head.pc, head.identity.raw_instruction,
            head.identity.instruction_bytes, 32'(head.rd), 32'(head.write_enable), 0, value));
`ifdef BP_DIFFTEST_S_TERMINAL
          if (head.terminal_wfi)
            terminal_uid_r = head.identity.uid;
`endif
        end
      end
    end
  endtask

`ifdef BP_DIFFTEST_S_TERMINAL
  function automatic int unsigned pending_terminal_resources();
    int unsigned pending_count;
    pending_count = 32'(completions.size());
    for (int i = 0; i < 5; i++)
      pending_count += 32'(pipeline_identity[i].valid);
    for (int i = 0; i < rv64_rf_els_gp; i++) begin
      pending_count += 32'(pending_integer[i].valid);
      pending_count += 32'(integer_writebacks[i].size());
    end
    return pending_count;
  endfunction

  function automatic bit terminal_source_stopped();
    return terminal_uid_r != 0 && director.is_wait && director.suppress_iss_o
      && !director.resume_o && !scheduler.irq_pending_i && !director.irq_waiting_i
      && !calculator.pipe_sys.csr.enter_debug && !decode_info.debug_mode
      && !calculator.pipe_sys.csr.interrupt_v_lo && !dispatch_packet.v
      && !commit_pkt.instret && !commit_pkt.exception && !commit_pkt.resume
      && !integer_writeback.ird_w_v && !floating_writeback.frd_w_v
      && !late_writeback.ird_w_v && !late_writeback.frd_w_v;
  endfunction

  task automatic close_terminal_source();
    if ($isunknown(source_time_i) || source_time_i[0])
      $fatal(1, "Difftest-S terminal boundary lacks a known core-edge source time");
    if (!initialized_r || !terminal_source_stopped() || pending_terminal_resources() !== 0
        || difftest_s_memory_probe.physically_idle_r !== 1'b1
        || difftest_s_memory_probe.physical_idle !== 1'b1)
      $fatal(1, "Difftest-S terminal boundary is not stopped and drained");
    // WFI rolled back these attempts but retained their issue slots. The
    // explicit global simulation end now permanently abandons those UIDs.
    for (int i = 0; i < issue_slot_count_lp; i++) begin
      cancel_attempt(slot_identity[i], cancel_squash_lp);
      slot_identity[i] = '0;
    end
    require_success(bp_difftest_s_terminal_state(hart_r, source_time_i, terminal_uid_r, 1, 0));
    require_success(bp_difftest_s_close_hart(hart_r, source_time_i, terminal_uid_r));
    terminal_closed_r = 1;
  endtask
`endif

  // Behavioral monitor queues are deliberate: they do not backpressure the DUT.
  // Overflow or host rejection terminates the run instead of losing an event.
  always @(posedge clk_i) begin : observe_core
    identity_s accepted_identity;
    completion_s completion;
    writeback_s writeback;
    if (reset_i) begin
`ifdef BP_DIFFTEST_S_TERMINAL
      if (terminal_closed_r)
        $fatal(1, "Difftest-S reset after terminal source closure");
      terminal_uid_r = 0;
`endif
      if (!in_reset_r)
        epoch_r = epoch_r + 1;
      in_reset_r = 1'b1;
      initialized_r = 1'b0;
      started_r = 1'b0;
      next_uid_r = 1;
      raw_preissue_r = '0;
      completions.delete();
      for (int i = 0; i < issue_slot_count_lp; i++)
        slot_identity[i] = '0;
      for (int i = 0; i < 5; i++)
        pipeline_identity[i] = '0;
      for (int i = 0; i < rv64_rf_els_gp; i++) begin
        pending_integer[i] = '0;
        integer_writebacks[i].delete();
      end
`ifdef BP_DIFFTEST_S_TERMINAL
    end else if (terminal_closed_r) begin
      if (!terminal_end_i || !terminal_source_stopped() || pending_terminal_resources() !== 0)
        $fatal(1, "Difftest-S source activity after terminal closure");
    end else if (terminal_end_i) begin
      close_terminal_source();
`endif
    end else if (en_i) begin
      in_reset_r = 1'b0;
      if ($isunknown(source_time_i))
        $fatal(1, "Difftest-S source clock is unknown");
      if (!initialized_r && !decode_info.debug_mode) begin
        hart_r = 32'(calculator.pipe_sys.csr.mhartid_lo);
        require_success(bp_difftest_s_probe_init(hart_r, num_core_p));
        initialized_r = 1'b1;
      end
      if (initialized_r) begin
`ifdef BP_DIFFTEST_S_TERMINAL
        // A resumed or newly dispatched instruction invalidates the old WFI
        // candidate. Only a later actually delivered WFI can establish a stop.
        if (terminal_uid_r != 0 && (director.resume_o || scheduler.irq_pending_i || director.irq_waiting_i
            || is_real_dispatch || commit_pkt.resume || calculator.pipe_sys.csr.enter_debug
            || decode_info.debug_mode || calculator.pipe_sys.csr.interrupt_v_lo))
          terminal_uid_r = 0;
`endif
        if (hart_r != 32'(calculator.pipe_sys.csr.mhartid_lo))
          $fatal(1, "Difftest-S hart identity changed during an active epoch");
        if (started_r && (calculator.pipe_sys.csr.enter_debug || decode_info.debug_mode))
          $fatal(1, "Difftest-S scalar probe does not support debug entry");
        if (is_real_dispatch && (dispatch_packet.decode.frf_w_v
            || dispatch_packet.decode.frs1_r_v || dispatch_packet.decode.frs2_r_v
            || dispatch_packet.decode.frs3_r_v))
          $fatal(1, "Difftest-S scalar probe does not support floating-point instructions");

        // Sample the old stage-3 value before advancing shadow stages.
        if (integer_writeback.ird_w_v) begin
          if (!pipeline_identity[3].valid && !pipeline_identity[3].ignored)
            $fatal(1, "Difftest-S integer writeback has no dynamic identity");
          if (pipeline_identity[3].valid) begin
            if (integer_writebacks[integer_writeback.rd_addr].size() >= max_pending_p)
              $fatal(1, "Difftest-S integer writeback queue overflow");
            writeback = '{identity: pipeline_identity[3], value: integer_value[0+:64]};
            integer_writebacks[integer_writeback.rd_addr].push_back(writeback);
          end
        end
        if (floating_writeback.frd_w_v && pipeline_identity[4].valid)
          $fatal(1, "Difftest-S scalar probe received floating-point writeback");

        if (commit_pkt.instret && !decode_info.debug_mode) begin
          if (!pipeline_identity[2].valid)
            $fatal(1, "Difftest-S retired instruction has no dynamic identity");
          completion = '0;
          completion.identity = pipeline_identity[2];
          completion.source_time = source_time_i;
`ifdef BP_DIFFTEST_S_TERMINAL
          completion.terminal_wfi = commit_pkt.wfi;
`endif
          completion.pc = 64'($signed(commit_pkt.pc));
          completion.rd = commit_completion.rd_addr;
          completion.write_enable = (commit_completion.ird_w_v | commit_pkt.iscore_v)
            & (commit_completion.rd_addr != '0);
          if (commit_completion.frd_w_v || commit_pkt.fscore_v)
            $fatal(1, "Difftest-S scalar probe cannot retire FP destination");
          if (commit_pkt.iscore_v) begin
            if (pending_integer[completion.rd].valid)
              $fatal(1, "Difftest-S scoreboard destination reused while pending");
            pending_integer[completion.rd] = completion.identity;
          end
          completions.push_back(completion);
          slot_identity[completion.identity.slot].valid = 1'b0;
        end

        if ((commit_pkt.exception || calculator.pipe_sys.csr.interrupt_v_lo)
            && !decode_info.debug_mode) begin
          completion = '0;
          completion.identity = pipeline_identity[2];
          completion.identity.epoch = epoch_r;
          completion.trap = 1'b1;
          completion.source_time = source_time_i;
          completion.pc = 64'($signed(commit_pkt.pc));
          completion.is_interrupt = calculator.pipe_sys.csr.interrupt_v_lo;
          completion.target_pc = 64'($signed(commit_pkt.npc));
          completion.privilege = translation_info.priv_mode;
          completion.target_privilege = commit_pkt.priv_n;
          if (commit_pkt.priv_n == `PRIV_MODE_S) begin
            completion.cause = 64'(calculator.pipe_sys.csr.scause_li);
            completion.tval = 64'(calculator.pipe_sys.csr.stval_li);
          end else begin
            completion.cause = 64'(calculator.pipe_sys.csr.mcause_li);
            completion.tval = 64'(calculator.pipe_sys.csr.mtval_li);
          end
          completions.push_back(completion);
          if (completion.identity.valid)
            slot_identity[completion.identity.slot].valid = 1'b0;
        end
        if (completions.size() > max_pending_p)
          $fatal(1, "Difftest-S retirement queue overflow");

        // Rollback cancels execution attempts, while retained issue slots keep UID.
        if (commit_pkt.npc_w_v) begin
          if (!calculator.exc_stage_n[1].v)
            cancel_attempt(pipeline_identity[0], cancel_replay_lp);
          if (!calculator.exc_stage_n[2].v)
            cancel_attempt(pipeline_identity[1], cancel_replay_lp);
          if (!commit_pkt.instret && !commit_pkt.exception
              && !calculator.pipe_sys.csr.interrupt_v_lo)
            cancel_attempt(pipeline_identity[2], cancel_replay_lp);
        end
        if (scheduler.clear_iss_i) begin
          for (int i = 0; i < issue_slot_count_lp; i++) begin
            cancel_attempt(slot_identity[i], cancel_squash_lp);
            slot_identity[i] = '0;
          end
        end

        accepted_identity = dispatch_identity;
        if (is_real_dispatch) begin
          if (slot_identity[issue_slot].valid
              && slot_identity[issue_slot].pc != accepted_identity.pc)
            $fatal(1, "Difftest-S issue slot reused without retirement or squash");
          started_r = 1'b1;
          if (!slot_identity[issue_slot].valid)
            next_uid_r = next_uid_r + 1;
          slot_identity[issue_slot] = accepted_identity;
          require_success(bp_difftest_s_allocate(hart_r, accepted_identity.epoch,
            accepted_identity.uid, accepted_identity.attempt, source_time_i,
            accepted_identity.pc, accepted_identity.raw_instruction,
            accepted_identity.instruction_bytes, accepted_identity.expanded_instruction));
        end else if (scheduler.writeback_v) begin
          if (!accepted_identity.valid || !late_writeback.ird_w_v)
            $fatal(1, "Difftest-S late integer writeback has no pending original UID");
          pending_integer[late_writeback.rd_addr] = '0;
        end

        for (int i = 4; i > 0; i--) begin
          pipeline_identity[i] = pipeline_identity[i-1];
          pipeline_identity[i].valid &= calculator.exc_stage_n[i].v;
        end
        pipeline_identity[0] = accepted_identity;
        pipeline_identity[0].valid &= calculator.exc_stage_n[0].v;
        emit_completed_prefix();
        require_success(bp_difftest_s_heartbeat(hart_r, source_time_i, completions.size()));
`ifdef BP_DIFFTEST_S_TERMINAL
        require_success(bp_difftest_s_terminal_state(hart_r, source_time_i, terminal_uid_r,
          32'(terminal_source_stopped() && pending_terminal_resources() == 0),
          pending_terminal_resources()));
`endif
      end

      // This raw shadow follows the real issue_reg enable; capture after dispatch use.
      if (scheduler.issue_queue.preissue_v)
        raw_preissue_r = scheduler.issue_queue.queue_instr_raw
          [scheduler.issue_queue.preissue_entry_sel +: 2];
    end
  end
endmodule
`endif
