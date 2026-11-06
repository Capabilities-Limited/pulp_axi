// Copyright (c) 2026 Capabilities Limited.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"); you may not use this file except in
// compliance with the License.  You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.
//
// Authors:
// - Jonathan Woodruff <jonathan.woodruff@capabilitieslimited.co.uk>

`include "axi/typedef.svh"
`include "axi/assign.svh"

/// Testbench for `axi_hazard_filter`.
///
/// A random master issues reads, writes, and ATOPs to a small address space, so that many
/// transactions overlap.  A random slave answers them, with responses of different IDs reordered.
/// The testbench checks that:
/// - all beats on all channels pass the DUT unchanged and in order;
/// - at the master port of the DUT, no AW overlaps an in-flight read or write, and no AR overlaps
///   an in-flight write (the hazard invariant), using an independent reference model of the
///   address ranges of in-flight transactions;
/// - the DUT actually had to stall overlapping transactions, i.e., the stimuli exercised hazards.
module tb_axi_hazard_filter #(
  /// Number of write transactions issued by the random master.
  parameter int unsigned TbNumWrites   = 32'd5000,
  /// Number of read transactions issued by the random master.
  parameter int unsigned TbNumReads    = 32'd5000,
  /// Granularity of hazard detection of the DUT in bytes.
  parameter int unsigned TbRegionSize  = 32'd1,
  /// Maximum number of in-flight writes of the DUT.
  parameter int unsigned TbMaxWriteTxns = 32'd4,
  /// Maximum number of in-flight reads of the DUT.
  parameter int unsigned TbMaxReadTxns  = 32'd8
);
  // Random master
  localparam int unsigned MaxAW      = 32'd30;
  localparam int unsigned MaxAR      = 32'd30;
  localparam bit          EnAtop     = 1'b1;
  // timing parameters
  localparam time CyclTime = 10ns;
  localparam time ApplTime =  2ns;
  localparam time TestTime =  8ns;
  // AXI configuration
  localparam int unsigned AxiIdWidth   =  4;
  localparam int unsigned AxiAddrWidth =  32;    // Axi Address Width
  localparam int unsigned AxiDataWidth =  64;    // Axi Data Width
  localparam int unsigned AxiUserWidth =  5;
  // Sim print config, how many transactions
  localparam int unsigned PrintTxn = 500;

  typedef axi_test::axi_rand_master #(
    // AXI interface parameters
    .AW ( AxiAddrWidth ),
    .DW ( AxiDataWidth ),
    .IW ( AxiIdWidth   ),
    .UW ( AxiUserWidth ),
    // Stimuli application and test time
    .TA ( ApplTime ),
    .TT ( TestTime ),
    // Maximum number of read and write transactions in flight
    .MAX_READ_TXNS     ( MaxAR  ),
    .MAX_WRITE_TXNS    ( MaxAW  ),
    // Short bursts and few wait cycles keep many transactions in flight at the same time.
    .AX_MAX_WAIT_CYCLES( 5      ),
    .AXI_MAX_BURST_LEN ( 8      ),
    .AXI_ATOPS         ( EnAtop ),
    .AXI_BURST_FIXED   ( 1'b1   ),
    .AXI_BURST_INCR    ( 1'b1   ),
    .AXI_BURST_WRAP    ( 1'b1   )
  ) axi_rand_master_t;
  typedef axi_test::axi_rand_slave #(
    // AXI interface parameters
    .AW ( AxiAddrWidth ),
    .DW ( AxiDataWidth ),
    .IW ( AxiIdWidth   ),
    .UW ( AxiUserWidth ),
    // Stimuli application and test time
    .TA ( ApplTime ),
    .TT ( TestTime )
  ) axi_rand_slave_t;

  // -------------
  // DUT signals
  // -------------
  logic clk;
  logic rst_n;
  logic end_of_sim;

  // interfaces
  AXI_BUS #(
    .AXI_ADDR_WIDTH ( AxiAddrWidth ),
    .AXI_DATA_WIDTH ( AxiDataWidth ),
    .AXI_ID_WIDTH   ( AxiIdWidth   ),
    .AXI_USER_WIDTH ( AxiUserWidth )
  ) master ();
  AXI_BUS_DV #(
    .AXI_ADDR_WIDTH ( AxiAddrWidth ),
    .AXI_DATA_WIDTH ( AxiDataWidth ),
    .AXI_ID_WIDTH   ( AxiIdWidth   ),
    .AXI_USER_WIDTH ( AxiUserWidth )
  ) master_dv (clk);
  AXI_BUS #(
    .AXI_ADDR_WIDTH ( AxiAddrWidth ),
    .AXI_DATA_WIDTH ( AxiDataWidth ),
    .AXI_ID_WIDTH   ( AxiIdWidth   ),
    .AXI_USER_WIDTH ( AxiUserWidth )
  ) slave ();
  AXI_BUS_DV #(
    .AXI_ADDR_WIDTH ( AxiAddrWidth ),
    .AXI_DATA_WIDTH ( AxiDataWidth ),
    .AXI_ID_WIDTH   ( AxiIdWidth   ),
    .AXI_USER_WIDTH ( AxiUserWidth )
  ) slave_dv (clk);

  `AXI_ASSIGN(master, master_dv)
  `AXI_ASSIGN(slave_dv, slave)

  //-----------------------------------
  // Clock generator
  //-----------------------------------
  clk_rst_gen #(
    .ClkPeriod    ( CyclTime ),
    .RstClkCycles ( 5        )
  ) i_clk_gen (
    .clk_o (clk),
    .rst_no(rst_n)
  );

  //-----------------------------------
  // DUT
  //-----------------------------------
  axi_hazard_filter_intf #(
    .AXI_ID_WIDTH   ( AxiIdWidth     ),
    .AXI_ADDR_WIDTH ( AxiAddrWidth   ),
    .AXI_DATA_WIDTH ( AxiDataWidth   ),
    .AXI_USER_WIDTH ( AxiUserWidth   ),
    .MAX_READ_TXNS  ( TbMaxReadTxns  ),
    .MAX_WRITE_TXNS ( TbMaxWriteTxns ),
    .REGION_SIZE    ( TbRegionSize   )
  ) i_dut (
    .clk_i  ( clk    ),
    .rst_ni ( rst_n  ),
    .slv    ( master ),
    .mst    ( slave  )
  );

  initial begin : proc_axi_master
    automatic axi_rand_master_t axi_rand_master = new(master_dv);
    end_of_sim <= 1'b0;
    // A small, densely accessed region produces many overlapping transactions, a larger one
    // produces mostly independent transactions.
    axi_rand_master.add_memory_region(32'h0000_0000, 32'h0000_0400, axi_pkg::WBACK_RWALLOCATE);
    axi_rand_master.add_memory_region(32'h0001_0000, 32'h0002_0000, axi_pkg::DEVICE_NONBUFFERABLE);
    axi_rand_master.reset();
    @(posedge rst_n);
    axi_rand_master.run(TbNumReads, TbNumWrites);
    end_of_sim <= 1'b1;
    repeat (100) @(posedge clk);
    $stop();
  end

  initial begin : proc_axi_slave
    automatic axi_rand_slave_t  axi_rand_slave  = new(slave_dv);
    axi_rand_slave.reset();
    @(posedge rst_n);
    axi_rand_slave.run();
  end

  //-----------------------------------
  // Pass-through checker
  //-----------------------------------
  typedef logic [AxiIdWidth-1:0]     axi_id_t;
  typedef logic [AxiAddrWidth-1:0]   axi_addr_t;
  typedef logic [AxiDataWidth-1:0]   axi_data_t;
  typedef logic [AxiDataWidth/8-1:0] axi_strb_t;
  typedef logic [AxiUserWidth-1:0]   axi_user_t;
  `AXI_TYPEDEF_AW_CHAN_T(aw_chan_t, axi_addr_t,  axi_id_t,  axi_user_t)
  `AXI_TYPEDEF_W_CHAN_T(w_chan_t,  axi_data_t,  axi_strb_t,  axi_user_t)
  `AXI_TYPEDEF_B_CHAN_T(b_chan_t,  axi_id_t,  axi_user_t)
  `AXI_TYPEDEF_AR_CHAN_T(ar_chan_t,  axi_addr_t,  axi_id_t,  axi_user_t)
  `AXI_TYPEDEF_R_CHAN_T(r_chan_t,  axi_data_t,  axi_id_t,  axi_user_t)
  aw_chan_t aw_chan[$];
  w_chan_t   w_chan[$];
  b_chan_t   b_chan[$];
  ar_chan_t ar_chan[$];
  r_chan_t   r_chan[$];

  initial begin : proc_checker
    automatic aw_chan_t aw_exp; // expected AW
    automatic aw_chan_t aw_act; // actual AW
    automatic w_chan_t   w_exp; // expected W
    automatic w_chan_t   w_act; // actual W
    automatic b_chan_t   b_exp; // expected B
    automatic b_chan_t   b_act; // actual B
    automatic ar_chan_t ar_exp; // expected AR
    automatic ar_chan_t ar_act; // actual AR
    automatic r_chan_t   r_exp; // expected R
    automatic r_chan_t   r_act; // actual R
    forever begin
      @(posedge clk);
      #TestTime;
      // All FIFOs get populated if there is something to put in
      if (master.aw_valid && master.aw_ready) begin
        `AXI_SET_TO_AW(aw_exp, master)
        aw_chan.push_back(aw_exp);
      end
      if (master.w_valid && master.w_ready) begin
        `AXI_SET_TO_W(w_exp, master)
        w_chan.push_back(w_exp);
      end
      if (slave.b_valid && slave.b_ready) begin
        `AXI_SET_TO_B(b_exp, slave)
        b_chan.push_back(b_exp);
      end
      if (master.ar_valid && master.ar_ready) begin
        `AXI_SET_TO_AR(ar_exp, master)
        ar_chan.push_back(ar_exp);
      end
      if (slave.r_valid && slave.r_ready) begin
        `AXI_SET_TO_R(r_exp, slave)
        r_chan.push_back(r_exp);
      end
      // Check that all channels match the expected response
      if (slave.aw_valid && slave.aw_ready) begin
        aw_exp = aw_chan.pop_front();
        `AXI_SET_TO_AW(aw_act, slave)
        assert(aw_act == aw_exp) else $error("AW Measured: %h Expected: %h", aw_act, aw_exp);
      end
      if (slave.w_valid && slave.w_ready) begin
        w_exp = w_chan.pop_front();
        `AXI_SET_TO_W(w_act, slave)
        assert(w_act == w_exp) else $error("W Measured: %h Expected: %h", w_act, w_exp);
      end
      if (master.b_valid && master.b_ready) begin
        b_exp = b_chan.pop_front();
        `AXI_SET_TO_B(b_act, master)
        assert(b_act == b_exp) else $error("B Measured: %h Expected: %h", b_act, b_exp);
      end
      if (slave.ar_valid && slave.ar_ready) begin
        ar_exp = ar_chan.pop_front();
        `AXI_SET_TO_AR(ar_act, slave)
        assert(ar_act == ar_exp) else $error("AR Measured: %h Expected: %h", ar_act, ar_exp);
      end
      if (master.r_valid && master.r_ready) begin
        r_exp = r_chan.pop_front();
        `AXI_SET_TO_R(r_act, master)
        assert(r_act == r_exp) else $error("R Measured: %h Expected: %h", r_act, r_exp);
      end
    end
  end

  //-----------------------------------
  // Hazard checker
  //-----------------------------------
  // Reference model of the regions accessed by the transactions in flight at the master port of
  // the DUT.  The ranges are computed beat by beat with `axi_pkg::beat_addr()`, independently of
  // the range computation in the DUT.
  typedef struct {
    axi_addr_t first; // first region index
    axi_addr_t last;  // last region index
  } range_t;
  // In-flight transactions, per ID in order of issue.
  range_t wr_inflight[axi_id_t][$];
  range_t rd_inflight[axi_id_t][$];

  function automatic range_t burst_range(axi_addr_t addr, axi_pkg::size_t size,
                                         axi_pkg::len_t len, axi_pkg::burst_t burst);
    automatic axi_addr_t lo = '1;
    automatic axi_addr_t hi = '0;
    for (int unsigned i = 0; i <= len; i++) begin
      automatic axi_addr_t beat =
          axi_addr_t'(axi_pkg::aligned_addr(axi_pkg::beat_addr(addr, size, len, burst, i), size));
      if (beat < lo) lo = beat;
      if (beat + axi_pkg::num_bytes(size) - 1 > hi) hi = beat + axi_pkg::num_bytes(size) - 1;
    end
    return '{first: lo / TbRegionSize, last: hi / TbRegionSize};
  endfunction

  function automatic bit overlaps(range_t a, range_t b);
    return (a.first <= b.last) && (b.first <= a.last);
  endfunction

  function automatic bit overlaps_any(range_t r, range_t inflight[axi_id_t][$]);
    foreach (inflight[id]) begin
      foreach (inflight[id][i]) begin
        if (overlaps(r, inflight[id][i])) return 1'b1;
      end
    end
    return 1'b0;
  endfunction

  function automatic int unsigned num_inflight(range_t inflight[axi_id_t][$]);
    automatic int unsigned num = 0;
    foreach (inflight[id]) num += inflight[id].size();
    return num;
  endfunction

  // Coverage of the hazard filtering
  int unsigned num_aw_stall_cycles   = 0; // AW valid at slave port, but not at master port
  int unsigned num_ar_stall_cycles   = 0; // AR valid at slave port, but not at master port
  int unsigned max_wr_inflight       = 0;
  int unsigned max_rd_inflight       = 0;
  int unsigned num_rd_parallel       = 0; // ARs issued while overlapping reads were in flight
  int unsigned num_hazard_violations = 0;

  initial begin : proc_hazard_checker
    automatic range_t aw_range, ar_range;
    automatic bit     aw_hs, ar_hs, atop_r_resp;
    @(posedge rst_n);
    forever begin
      @(posedge clk);
      #TestTime;
      aw_hs = slave.aw_valid && slave.aw_ready;
      ar_hs = slave.ar_valid && slave.ar_ready;
      // Check new transactions against all transactions in flight *before* this cycle and against
      // each other.  Responses in this cycle do not release their regions before the next cycle.
      if (aw_hs) begin
        aw_range    = burst_range(slave.aw_addr, slave.aw_size, slave.aw_len, slave.aw_burst);
        atop_r_resp = slave.aw_atop[axi_pkg::ATOP_R_RESP];
        assert (!overlaps_any(aw_range, wr_inflight)) else begin
          num_hazard_violations++;
          $error("AW (ID %0h, addr %h) overlaps an in-flight write.", slave.aw_id, slave.aw_addr);
        end
        assert (!overlaps_any(aw_range, rd_inflight)) else begin
          num_hazard_violations++;
          $error("AW (ID %0h, addr %h) overlaps an in-flight read.", slave.aw_id, slave.aw_addr);
        end
      end
      if (ar_hs) begin
        ar_range = burst_range(slave.ar_addr, slave.ar_size, slave.ar_len, slave.ar_burst);
        assert (!overlaps_any(ar_range, wr_inflight)) else begin
          num_hazard_violations++;
          $error("AR (ID %0h, addr %h) overlaps an in-flight write.", slave.ar_id, slave.ar_addr);
        end
        if (overlaps_any(ar_range, rd_inflight)) num_rd_parallel++;
      end
      if (aw_hs && ar_hs) begin
        assert (!overlaps(aw_range, ar_range)) else begin
          num_hazard_violations++;
          $error("AW (ID %0h, addr %h) and AR (ID %0h, addr %h) overlap in the same cycle.",
              slave.aw_id, slave.aw_addr, slave.ar_id, slave.ar_addr);
        end
      end
      // Retire completed transactions (the oldest in-flight transaction of the response ID).
      if (slave.b_valid && slave.b_ready) begin
        assert (wr_inflight.exists(slave.b_id) && wr_inflight[slave.b_id].size() > 0)
          else $fatal(1, "B with ID %0h without in-flight write.", slave.b_id);
        void'(wr_inflight[slave.b_id].pop_front());
        if (wr_inflight[slave.b_id].size() == 0) wr_inflight.delete(slave.b_id);
      end
      if (slave.r_valid && slave.r_ready && slave.r_last) begin
        assert (rd_inflight.exists(slave.r_id) && rd_inflight[slave.r_id].size() > 0)
          else $fatal(1, "Last R with ID %0h without in-flight read.", slave.r_id);
        void'(rd_inflight[slave.r_id].pop_front());
        if (rd_inflight[slave.r_id].size() == 0) rd_inflight.delete(slave.r_id);
      end
      // Track new transactions.  An ATOP with R response is a write and a read.
      if (aw_hs) begin
        wr_inflight[slave.aw_id].push_back(aw_range);
        if (atop_r_resp) rd_inflight[slave.aw_id].push_back(aw_range);
      end
      if (ar_hs) begin
        rd_inflight[slave.ar_id].push_back(ar_range);
      end
      // The DUT must never exceed its capacity.
      if (num_inflight(wr_inflight) > max_wr_inflight) max_wr_inflight = num_inflight(wr_inflight);
      if (num_inflight(rd_inflight) > max_rd_inflight) max_rd_inflight = num_inflight(rd_inflight);
      assert (num_inflight(wr_inflight) <= TbMaxWriteTxns)
        else $error("More than %0d writes in flight.", TbMaxWriteTxns);
      assert (num_inflight(rd_inflight) <= TbMaxReadTxns)
        else $error("More than %0d reads in flight.", TbMaxReadTxns);
      // Stall coverage
      if (master.aw_valid && !slave.aw_valid) num_aw_stall_cycles++;
      if (master.ar_valid && !slave.ar_valid) num_ar_stall_cycles++;
    end
  end

  initial begin : proc_sim_progress
    automatic int unsigned aw         = 0;
    automatic int unsigned ar         = 0;
    automatic bit          aw_printed = 1'b0;
    automatic bit          ar_printed = 1'b0;

    @(posedge rst_n);

    forever begin
      @(posedge clk);
      #TestTime;
      if (master.aw_valid && master.aw_ready) begin
        aw++;
      end
      if (master.ar_valid && master.ar_ready) begin
        ar++;
      end

      if ((aw % PrintTxn == 0) && ! aw_printed) begin
        $display("%t> Transmit AW %d of %d.", $time(), aw, TbNumWrites);
        aw_printed = 1'b1;
      end
      if ((ar % PrintTxn == 0) && !ar_printed) begin
        $display("%t> Transmit AR %d of %d.", $time(), ar, TbNumReads);
        ar_printed = 1'b1;
      end

      if (aw % PrintTxn == 1) begin
        aw_printed = 1'b0;
      end
      if (ar % PrintTxn == 1) begin
        ar_printed = 1'b0;
      end

      if (end_of_sim) begin
        // Let the checkers process the last beats.
        repeat (10) @(posedge clk);
        $display("AW stall cycles:           %0d", num_aw_stall_cycles);
        $display("AR stall cycles:           %0d", num_ar_stall_cycles);
        $display("Overlapping parallel ARs:  %0d", num_rd_parallel);
        $display("Max in-flight writes:      %0d of %0d", max_wr_inflight, TbMaxWriteTxns);
        $display("Max in-flight reads:       %0d of %0d", max_rd_inflight, TbMaxReadTxns);
        assert (num_inflight(wr_inflight) == 0 && num_inflight(rd_inflight) == 0)
          else $error("Transactions still in flight at end of simulation.");
        assert (aw_chan.size() == 0 && w_chan.size() == 0 && b_chan.size() == 0 &&
                ar_chan.size() == 0 && r_chan.size() == 0)
          else $error("Beats still in flight at end of simulation.");
        // Make sure the stimuli actually exercised the hazard filtering.
        assert (num_aw_stall_cycles > 0) else $error("No AW was ever stalled.");
        assert (num_ar_stall_cycles > 0) else $error("No AR was ever stalled.");
        assert (num_rd_parallel > 0) else $error("Overlapping reads were never in flight together.");
        assert (num_hazard_violations == 0)
          else $error("%0d hazard violations detected.", num_hazard_violations);
        $info("All transactions completed.");
        break;
      end
    end
  end
endmodule
