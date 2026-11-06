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

/// Testbench for `axi_throttle`.
///
/// A random master issues reads and writes, which a random slave answers.  The testbench checks
/// that:
/// - all beats on all channels pass the DUT unchanged and in order;
/// - at the master port of the DUT, the number of outstanding write and read transactions never
///   exceeds the write and read credit;
/// - if read beat limiting is enabled (`TbMaxNumRBeatsPending > 0`), the number of outstanding R
///   beats never exceeds the read beat credit, except for a single burst larger than the credit,
///   which may only be forwarded while no R beats are outstanding;
/// - the limits were actually reached, i.e., the stimuli exercised the throttling.
module tb_axi_throttle #(
  /// Number of write transactions issued by the random master.
  parameter int unsigned TbNumWrites           = 32'd5000,
  /// Number of read transactions issued by the random master.
  parameter int unsigned TbNumReads            = 32'd5000,
  /// Maximum number of outstanding write transactions of the DUT.
  parameter int unsigned TbMaxNumAwPending     = 32'd4,
  /// Maximum number of outstanding read transactions of the DUT.
  parameter int unsigned TbMaxNumArPending     = 32'd8,
  /// Maximum number of outstanding R beats of the DUT (0 disables read beat limiting).
  parameter int unsigned TbMaxNumRBeatsPending = 32'd16,
  /// Read beat credit applied at runtime, must be in [1, TbMaxNumRBeatsPending].
  parameter int unsigned TbRBeatCredit         = 32'd16
);
  // Random master
  localparam int unsigned MaxAW      = 32'd30;
  localparam int unsigned MaxAR      = 32'd30;
  localparam int unsigned MaxBurstLen = 32'd32;
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
  // DUT credit types
  localparam int unsigned WCntWidth     = cc_pkg::idx_width(TbMaxNumAwPending);
  localparam int unsigned RCntWidth     = cc_pkg::idx_width(TbMaxNumArPending);
  localparam int unsigned RBeatCntWidth = cc_pkg::cnt_width(TbMaxNumRBeatsPending);
  typedef logic [WCntWidth-1:0]     w_credit_t;
  typedef logic [RCntWidth-1:0]     r_credit_t;
  typedef logic [RBeatCntWidth-1:0] r_beat_credit_t;
  // Runtime credits: the largest representable transaction credits and the configured beat credit.
  localparam w_credit_t      WCredit     = '1;
  localparam r_credit_t      RCredit     = '1;
  localparam r_beat_credit_t RBeatCredit = r_beat_credit_t'(TbRBeatCredit);

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
    .MAX_READ_TXNS      ( MaxAR       ),
    .MAX_WRITE_TXNS     ( MaxAW       ),
    .AX_MAX_WAIT_CYCLES ( 5           ),
    .AXI_MAX_BURST_LEN  ( MaxBurstLen ),
    // ATOPs with R response are not supported by read beat limiting.
    .AXI_ATOPS          ( 1'b0        ),
    .AXI_BURST_FIXED    ( 1'b1        ),
    .AXI_BURST_INCR     ( 1'b1        ),
    .AXI_BURST_WRAP     ( 1'b1        )
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

  typedef logic [AxiIdWidth-1:0]     axi_id_t;
  typedef logic [AxiAddrWidth-1:0]   axi_addr_t;
  typedef logic [AxiDataWidth-1:0]   axi_data_t;
  typedef logic [AxiDataWidth/8-1:0] axi_strb_t;
  typedef logic [AxiUserWidth-1:0]   axi_user_t;
  `AXI_TYPEDEF_ALL(axi, axi_addr_t, axi_id_t, axi_data_t, axi_strb_t, axi_user_t)

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

  axi_req_t  slv_req,  mst_req;
  axi_resp_t slv_resp, mst_resp;
  `AXI_ASSIGN_TO_REQ(slv_req, master)
  `AXI_ASSIGN_FROM_RESP(master, slv_resp)
  `AXI_ASSIGN_FROM_REQ(slave, mst_req)
  `AXI_ASSIGN_TO_RESP(mst_resp, slave)

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
  axi_throttle #(
    .MaxNumAwPending     ( TbMaxNumAwPending     ),
    .MaxNumArPending     ( TbMaxNumArPending     ),
    .axi_req_t           ( axi_req_t             ),
    .axi_rsp_t           ( axi_resp_t            ),
    .MaxNumRBeatsPending ( TbMaxNumRBeatsPending )
  ) i_dut (
    .clk_i           ( clk         ),
    .rst_ni          ( rst_n       ),
    .req_i           ( slv_req     ),
    .rsp_o           ( slv_resp    ),
    .req_o           ( mst_req     ),
    .rsp_i           ( mst_resp    ),
    .w_credit_i      ( WCredit     ),
    .r_credit_i      ( RCredit     ),
    .r_beat_credit_i ( RBeatCredit )
  );

  initial begin : proc_axi_master
    automatic axi_rand_master_t axi_rand_master = new(master_dv);
    end_of_sim <= 1'b0;
    axi_rand_master.add_memory_region(32'h0000_0000, 32'h1000_0000, axi_pkg::DEVICE_NONBUFFERABLE);
    axi_rand_master.add_memory_region(32'h2000_0000, 32'h3000_0000, axi_pkg::WTHRU_NOALLOCATE);
    axi_rand_master.add_memory_region(32'h4000_0000, 32'h5000_0000, axi_pkg::WBACK_RWALLOCATE);
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
  axi_aw_chan_t aw_chan[$];
  axi_w_chan_t   w_chan[$];
  axi_b_chan_t   b_chan[$];
  axi_ar_chan_t ar_chan[$];
  axi_r_chan_t   r_chan[$];

  initial begin : proc_checker
    automatic axi_aw_chan_t aw_exp; // expected AW
    automatic axi_aw_chan_t aw_act; // actual AW
    automatic axi_w_chan_t   w_exp; // expected W
    automatic axi_w_chan_t   w_act; // actual W
    automatic axi_b_chan_t   b_exp; // expected B
    automatic axi_b_chan_t   b_act; // actual B
    automatic axi_ar_chan_t ar_exp; // expected AR
    automatic axi_ar_chan_t ar_act; // actual AR
    automatic axi_r_chan_t   r_exp; // expected R
    automatic axi_r_chan_t   r_act; // actual R
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
  // Throttling checker
  //-----------------------------------
  // Outstanding transactions and R beats at the master port of the DUT.
  int unsigned num_aw_pending      = 0;
  int unsigned num_ar_pending      = 0;
  int unsigned num_r_beats_pending = 0;
  // Coverage of the throttling
  int unsigned max_aw_pending      = 0;
  int unsigned max_ar_pending      = 0;
  int unsigned max_r_beats_pending = 0;
  int unsigned num_ar_stall_cycles = 0; // AR valid at slave port, but not at master port
  int unsigned num_oversized_ars   = 0; // ARs with more beats than the beat credit
  int unsigned num_violations      = 0;

  initial begin : proc_throttle_checker
    automatic int unsigned ar_beats;
    @(posedge rst_n);
    forever begin
      @(posedge clk);
      #TestTime;
      // New transactions are checked against the transactions outstanding *before* this cycle.
      if (slave.aw_valid && slave.aw_ready) begin
        num_aw_pending++;
      end
      if (slave.ar_valid && slave.ar_ready) begin
        ar_beats = slave.ar_len + 1;
        if (TbMaxNumRBeatsPending > 0) begin
          if (ar_beats > TbRBeatCredit) begin
            num_oversized_ars++;
            assert (num_r_beats_pending == 0) else begin
              num_violations++;
              $error("AR with %0d beats (more than the credit of %0d) forwarded while %0d R beats are outstanding.",
                  ar_beats, TbRBeatCredit, num_r_beats_pending);
            end
          end else begin
            assert (num_r_beats_pending + ar_beats <= TbRBeatCredit) else begin
              num_violations++;
              $error("AR with %0d beats exceeds the credit of %0d with %0d R beats outstanding.",
                  ar_beats, TbRBeatCredit, num_r_beats_pending);
            end
          end
        end
        num_ar_pending++;
        num_r_beats_pending += ar_beats;
      end
      if (slave.b_valid && slave.b_ready) begin
        num_aw_pending--;
      end
      if (slave.r_valid && slave.r_ready) begin
        assert (num_r_beats_pending > 0) else $fatal(1, "R beat without outstanding read.");
        num_r_beats_pending--;
        if (slave.r_last) begin
          num_ar_pending--;
        end
      end
      assert (num_aw_pending <= WCredit) else begin
        num_violations++;
        $error("%0d writes outstanding, credit is %0d.", num_aw_pending, WCredit);
      end
      assert (num_ar_pending <= RCredit) else begin
        num_violations++;
        $error("%0d reads outstanding, credit is %0d.", num_ar_pending, RCredit);
      end
      if (num_aw_pending      > max_aw_pending)      max_aw_pending      = num_aw_pending;
      if (num_ar_pending      > max_ar_pending)      max_ar_pending      = num_ar_pending;
      if (num_r_beats_pending > max_r_beats_pending) max_r_beats_pending = num_r_beats_pending;
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
        $display("Max outstanding writes:  %0d of %0d", max_aw_pending, WCredit);
        $display("Max outstanding reads:   %0d of %0d", max_ar_pending, RCredit);
        $display("Max outstanding R beats: %0d (credit %0d)", max_r_beats_pending, TbRBeatCredit);
        $display("Oversized ARs:           %0d", num_oversized_ars);
        $display("AR stall cycles:         %0d", num_ar_stall_cycles);
        assert (num_aw_pending == 0 && num_ar_pending == 0 && num_r_beats_pending == 0)
          else $error("Transactions still outstanding at end of simulation.");
        assert (aw_chan.size() == 0 && w_chan.size() == 0 && b_chan.size() == 0 &&
                ar_chan.size() == 0 && r_chan.size() == 0)
          else $error("Beats still in flight at end of simulation.");
        // Make sure the stimuli actually exercised the throttling.
        assert (max_aw_pending == WCredit) else $error("Write credit limit never reached.");
        assert (num_ar_stall_cycles > 0) else $error("No AR was ever stalled.");
        if (TbMaxNumRBeatsPending > 0) begin
          assert (max_r_beats_pending >= TbRBeatCredit)
            else $error("Read beat credit limit never reached.");
        end else begin
          assert (max_ar_pending == RCredit) else $error("Read credit limit never reached.");
        end
        assert (num_violations == 0) else $error("%0d throttling violations detected.", num_violations);
        $info("All transactions completed.");
        break;
      end
    end
  end
endmodule
