// ---------------------------------------------------------------------------
// accel_tb_pkg.sv - UVM verification environment for the systolic accelerator.
//
//   axil_item -> axil_sequencer -> axil_driver -> DUT
//                                  axil_monitor -> accel_scoreboard
//                                               -> accel_coverage
// ---------------------------------------------------------------------------
package accel_tb_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"

  // Must match the DUT parameter in tb_top
  localparam int N      = 4;
  localparam int ADDR_W = 12;

  // Register map
  localparam bit [ADDR_W-1:0] CTRL   = 'h000;
  localparam bit [ADDR_W-1:0] STATUS = 'h004;
  localparam bit [ADDR_W-1:0] DIM    = 'h008;
  localparam bit [ADDR_W-1:0] A_BASE = 'h100;
  localparam bit [ADDR_W-1:0] B_BASE = 'h200;
  localparam bit [ADDR_W-1:0] C_BASE = 'h300;
  localparam bit [1:0] OKAY = 2'b00, SLVERR = 2'b10;

  typedef enum {R_CTRL, R_STATUS, R_DIM, R_A, R_B, R_C, R_UNMAPPED} region_e;

  // Address decode shared by scoreboard and coverage (addr[1:0] ignored, like the DUT)
  function automatic region_e decode(input bit [ADDR_W-1:0] addr, output int idx);
    bit [ADDR_W-1:0] wa = {addr[ADDR_W-1:2], 2'b00};
    idx = 0;
    if (wa == CTRL)   return R_CTRL;
    if (wa == STATUS) return R_STATUS;
    if (wa == DIM)    return R_DIM;
    if (wa >= A_BASE && wa < A_BASE + 4*N)   begin idx = (wa - A_BASE) >> 2; return R_A; end
    if (wa >= B_BASE && wa < B_BASE + 4*N)   begin idx = (wa - B_BASE) >> 2; return R_B; end
    if (wa >= C_BASE && wa < C_BASE + 4*N*N) begin idx = (wa - C_BASE) >> 2; return R_C; end
    return R_UNMAPPED;
  endfunction

  typedef byte mat8_t [N][N];   // signed INT8 matrix
  typedef int  mat32_t[N][N];   // signed 32-bit matrix

  function automatic mat32_t ref_matmul(input mat8_t a, input mat8_t b);
    mat32_t c;
    foreach (c[i, j]) begin
      c[i][j] = 0;
      for (int k = 0; k < N; k++) c[i][j] += int'(a[i][k]) * int'(b[k][j]);
    end
    return c;
  endfunction

  // =========================================================================
  // Sequence item
  // =========================================================================
  class axil_item extends uvm_sequence_item;
    rand bit              is_write;
    rand bit [ADDR_W-1:0] addr;
    rand bit [31:0]       data;      // write data, or read data after the read
    rand bit [3:0]        strb;
    rand int unsigned     aw_delay;  // cycles before AWVALID
    rand int unsigned     w_delay;   // cycles before WVALID
    rand int unsigned     ready_delay; // cycles before BREADY/RREADY
    bit  [1:0]            resp;

    constraint c_delays {
      aw_delay    dist {0 := 6, [1:3] := 3, [4:8] := 1};
      w_delay     dist {0 := 6, [1:3] := 3, [4:8] := 1};
      ready_delay dist {0 := 7, [1:4] := 3};
    }
    constraint c_strb_default { soft strb == 4'hF; }

    `uvm_object_utils(axil_item)

    function new(string name = "axil_item");
      super.new(name);
    endfunction

    function string convert2string();
      return $sformatf("%s addr=%03h data=%08h strb=%b resp=%s",
                       is_write ? "WR" : "RD", addr, data, strb,
                       resp == OKAY ? "OKAY" : "SLVERR");
    endfunction

    function void do_copy(uvm_object rhs);
      axil_item t;
      super.do_copy(rhs);
      $cast(t, rhs);
      is_write = t.is_write; addr = t.addr; data = t.data; strb = t.strb; resp = t.resp;
    endfunction
  endclass

  typedef uvm_sequencer #(axil_item) axil_sequencer;

  // =========================================================================
  // Driver: drives AW and W independently (random order/delays), then B; or AR then R
  // =========================================================================
  class axil_driver extends uvm_driver #(axil_item);
    `uvm_component_utils(axil_driver)
    virtual axil_if vif;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(virtual axil_if)::get(this, "", "vif", vif))
        `uvm_fatal("NOVIF", "virtual axil_if not set")
    endfunction

    task reset_signals();
      vif.awvalid <= 0; vif.awaddr <= '0; vif.awprot <= '0;
      vif.wvalid  <= 0; vif.wdata  <= '0; vif.wstrb  <= '0;
      vif.bready  <= 0;
      vif.arvalid <= 0; vif.araddr <= '0; vif.arprot <= '0;
      vif.rready  <= 0;
    endtask

    task run_phase(uvm_phase phase);
      reset_signals();
      @(posedge vif.clk iff vif.rst_n);
      forever begin
        seq_item_port.get_next_item(req);
        if (req.is_write) drive_write(req);
        else              drive_read(req);
        `uvm_info("DRV", req.convert2string(), UVM_HIGH)
        seq_item_port.item_done();
      end
    endtask

    task drive_write(axil_item t);
      fork
        begin
          repeat (t.aw_delay) @(posedge vif.clk);
          vif.awaddr  <= t.addr;
          vif.awvalid <= 1;
          do @(posedge vif.clk); while (!vif.awready);
          vif.awvalid <= 0;
        end
        begin
          repeat (t.w_delay) @(posedge vif.clk);
          vif.wdata  <= t.data;
          vif.wstrb  <= t.strb;
          vif.wvalid <= 1;
          do @(posedge vif.clk); while (!vif.wready);
          vif.wvalid <= 0;
        end
      join
      repeat (t.ready_delay) @(posedge vif.clk);
      vif.bready <= 1;
      do @(posedge vif.clk); while (!vif.bvalid);
      t.resp = vif.bresp;
      vif.bready <= 0;
    endtask

    task drive_read(axil_item t);
      vif.araddr  <= t.addr;
      vif.arvalid <= 1;
      do @(posedge vif.clk); while (!vif.arready);
      vif.arvalid <= 0;
      repeat (t.ready_delay) @(posedge vif.clk);
      vif.rready <= 1;
      do @(posedge vif.clk); while (!vif.rvalid);
      t.data = vif.rdata;
      t.resp = vif.rresp;
      vif.rready <= 0;
    endtask
  endclass

  // =========================================================================
  // Monitor: rebuilds completed transactions purely from the bus
  // =========================================================================
  class axil_monitor extends uvm_monitor;
    `uvm_component_utils(axil_monitor)
    virtual axil_if vif;
    uvm_analysis_port #(axil_item) ap;

    function new(string name, uvm_component parent);
      super.new(name, parent);
      ap = new("ap", this);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(virtual axil_if)::get(this, "", "vif", vif))
        `uvm_fatal("NOVIF", "virtual axil_if not set")
    endfunction

    task run_phase(uvm_phase phase);
      bit [ADDR_W-1:0] aw_q[$], ar_q[$];
      bit [35:0]       w_q[$];   // {strb, data}
      forever begin
        @(posedge vif.clk);
        if (!vif.rst_n) begin
          aw_q.delete(); w_q.delete(); ar_q.delete();
          continue;
        end
        if (vif.awvalid && vif.awready) aw_q.push_back(vif.awaddr);
        if (vif.wvalid  && vif.wready)  w_q.push_back({vif.wstrb, vif.wdata});
        if (vif.arvalid && vif.arready) ar_q.push_back(vif.araddr);

        if (vif.bvalid && vif.bready) begin
          axil_item t = axil_item::type_id::create("mon_wr");
          bit [35:0] w;
          if (aw_q.size() == 0 || w_q.size() == 0)
            `uvm_error("MON", "B handshake with no AW/W captured")
          else begin
            w = w_q.pop_front();
            t.is_write = 1;
            t.addr     = aw_q.pop_front();
            t.data     = w[31:0];
            t.strb     = w[35:32];
            t.resp     = vif.bresp;
            ap.write(t);
          end
        end

        if (vif.rvalid && vif.rready) begin
          axil_item t = axil_item::type_id::create("mon_rd");
          if (ar_q.size() == 0)
            `uvm_error("MON", "R handshake with no AR captured")
          else begin
            t.is_write = 0;
            t.addr     = ar_q.pop_front();
            t.data     = vif.rdata;
            t.strb     = 4'h0;
            t.resp     = vif.rresp;
            ap.write(t);
          end
        end
      end
    endtask
  endclass

  // =========================================================================
  // Agent
  // =========================================================================
  class axil_agent extends uvm_agent;
    `uvm_component_utils(axil_agent)
    axil_sequencer sqr;
    axil_driver    drv;
    axil_monitor   mon;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      mon = axil_monitor::type_id::create("mon", this);
      if (get_is_active() == UVM_ACTIVE) begin
        sqr = axil_sequencer::type_id::create("sqr", this);
        drv = axil_driver::type_id::create("drv", this);
      end
    endfunction

    function void connect_phase(uvm_phase phase);
      if (get_is_active() == UVM_ACTIVE)
        drv.seq_item_port.connect(sqr.seq_item_export);
    endfunction
  endclass

  // =========================================================================
  // Scoreboard: register mirror + reference model
  // =========================================================================
  class accel_scoreboard extends uvm_scoreboard;
    `uvm_component_utils(accel_scoreboard)
    uvm_analysis_imp #(axil_item, accel_scoreboard) imp;

    mat8_t  a_mirror, b_mirror;
    mat32_t c_expected;
    bit     irq_en;

    int unsigned n_matmuls, n_c_checked, n_c_errors, n_busy_rejects, n_err_checked, n_errors;

    function new(string name, uvm_component parent);
      super.new(name, parent);
      imp = new("imp", this);
      foreach (c_expected[i, j]) begin
        c_expected[i][j] = 0; a_mirror[i][j] = 0; b_mirror[i][j] = 0;
      end
    endfunction

    function void fail(string msg);
      n_errors++;
      `uvm_error("SCB", msg)
    endfunction

    function void expect_resp(axil_item t, bit [1:0] exp);
      n_err_checked++;
      if (t.resp !== exp)
        fail($sformatf("Wrong response: %s (expected %s)", t.convert2string(),
                       exp == OKAY ? "OKAY" : "SLVERR"));
    endfunction

    function bit [31:0] pack_row(input mat8_t m, input int row);
      bit [31:0] w = '0;
      for (int k = 0; k < N; k++) w[k*8 +: 8] = m[row][k];
      return w;
    endfunction

    function void write(axil_item t);
      int idx;
      region_e r = decode(t.addr, idx);
      `uvm_info("SCB", t.convert2string(), UVM_HIGH)

      if (t.is_write) begin
        case (r)
          R_CTRL: begin
            if (t.resp == SLVERR) n_busy_rejects++;   // only legal reason: BUSY
            else if (t.strb[0]) begin
              irq_en = t.data[2];
              if (t.data[0]) begin
                c_expected = ref_matmul(a_mirror, b_mirror);
                n_matmuls++;
              end else if (t.data[1]) begin
                foreach (c_expected[i, j]) c_expected[i][j] = 0;
              end
            end
          end
          R_STATUS: expect_resp(t, OKAY);
          R_A, R_B: begin
            if (t.resp == SLVERR) n_busy_rejects++;
            else
              for (int k = 0; k < N; k++)
                if (t.strb[k]) begin
                  if (r == R_A) a_mirror[idx][k] = t.data[k*8 +: 8];
                  else          b_mirror[idx][k] = t.data[k*8 +: 8];
                end
          end
          default: expect_resp(t, SLVERR);   // DIM, C (read-only) and unmapped
        endcase
      end else begin
        case (r)
          R_CTRL: begin
            expect_resp(t, OKAY);
            if (t.data !== {29'b0, irq_en, 2'b00})
              fail($sformatf("CTRL read %08h, expected IRQ_EN=%0b", t.data, irq_en));
          end
          R_STATUS: expect_resp(t, OKAY);
          R_DIM: begin
            expect_resp(t, OKAY);
            if (t.data != N) fail($sformatf("DIM read %0d, expected %0d", t.data, N));
          end
          R_A, R_B: begin
            bit [31:0] exp = (r == R_A) ? pack_row(a_mirror, idx) : pack_row(b_mirror, idx);
            expect_resp(t, OKAY);
            if (t.data !== exp)
              fail($sformatf("%s row %0d read %08h, expected %08h", r.name(), idx, t.data, exp));
          end
          R_C: begin
            if (t.resp == SLVERR) n_busy_rejects++;
            else begin
              int i = idx / N, j = idx % N;
              n_c_checked++;
              if ($signed(t.data) != c_expected[i][j]) begin
                n_c_errors++;
                fail($sformatf("C[%0d][%0d] = %0d, expected %0d", i, j,
                               $signed(t.data), c_expected[i][j]));
              end
            end
          end
          default: expect_resp(t, SLVERR);
        endcase
      end
    endfunction

    function void report_phase(uvm_phase phase);
      `uvm_info("SCB", $sformatf({"\n---- Scoreboard summary ----",
        "\n  matmuls started      : %0d",
        "\n  C elements checked   : %0d (mismatches %0d)",
        "\n  responses checked    : %0d",
        "\n  BUSY rejections seen : %0d",
        "\n  total errors         : %0d"},
        n_matmuls, n_c_checked, n_c_errors, n_err_checked, n_busy_rejects, n_errors), UVM_NONE)
      if (n_c_checked == 0 && n_matmuls > 0)
        `uvm_warning("SCB", "Matmuls were started but no C results were checked")
    endfunction
  endclass

  // =========================================================================
  // Functional coverage
  // =========================================================================
  class accel_coverage extends uvm_subscriber #(axil_item);
    `uvm_component_utils(accel_coverage)

    region_e  region;
    bit       is_write;
    bit [1:0] resp;
    bit [3:0] strb;
    byte      operand;

    covergroup cg_bus;
      option.per_instance = 1;
      cp_region: coverpoint region;
      cp_dir:    coverpoint is_write { bins read = {0}; bins write = {1}; }
      cp_resp:   coverpoint resp { bins okay = {OKAY}; bins slverr = {SLVERR}; }
      x_region_dir: cross cp_region, cp_dir;
      // Busy rejections and illegal-address errors, per region
      x_region_resp: cross cp_region, cp_resp {
        ignore_bins status_err = binsof(cp_region) intersect {R_STATUS} && binsof(cp_resp.slverr);
        ignore_bins unmapped_ok = binsof(cp_region) intersect {R_UNMAPPED} && binsof(cp_resp.okay);
      }
    endgroup

    covergroup cg_strb;
      option.per_instance = 1;
      cp_strb: coverpoint strb {
        bins full = {4'hF};
        bins single[] = {4'h1, 4'h2, 4'h4, 4'h8};
        bins partial = {4'h3, 4'h5, 4'h6, 4'h7, 4'h9, 4'hA, 4'hB, 4'hC, 4'hD, 4'hE};
      }
    endgroup

    covergroup cg_operand;
      option.per_instance = 1;
      cp_val: coverpoint operand {
        bins min  = {-128};
        bins neg  = {[-127:-1]};
        bins zero = {0};
        bins pos  = {[1:126]};
        bins max  = {127};
      }
    endgroup

    function new(string name, uvm_component parent);
      super.new(name, parent);
      cg_bus     = new();
      cg_strb    = new();
      cg_operand = new();
    endfunction

    function void write(axil_item t);
      int idx;
      region   = decode(t.addr, idx);
      is_write = t.is_write;
      resp     = t.resp;
      cg_bus.sample();
      if (t.is_write && (region == R_A || region == R_B) && t.resp == OKAY) begin
        strb = t.strb;
        cg_strb.sample();
        for (int k = 0; k < N; k++)
          if (t.strb[k]) begin
            operand = t.data[k*8 +: 8];
            cg_operand.sample();
          end
      end
    endfunction

    function void report_phase(uvm_phase phase);
      `uvm_info("COV", $sformatf({"\n---- Functional coverage ----",
        "\n  bus/register : %0.1f%%",
        "\n  byte strobes : %0.1f%%",
        "\n  operands     : %0.1f%%"},
        cg_bus.get_inst_coverage(), cg_strb.get_inst_coverage(),
        cg_operand.get_inst_coverage()), UVM_NONE)
    endfunction
  endclass

  // =========================================================================
  // Environment
  // =========================================================================
  class accel_env extends uvm_env;
    `uvm_component_utils(accel_env)
    axil_agent       agent;
    accel_scoreboard scb;
    accel_coverage   cov;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      agent = axil_agent::type_id::create("agent", this);
      scb   = accel_scoreboard::type_id::create("scb", this);
      cov   = accel_coverage::type_id::create("cov", this);
    endfunction

    function void connect_phase(uvm_phase phase);
      agent.mon.ap.connect(scb.imp);
      agent.mon.ap.connect(cov.analysis_export);
    endfunction
  endclass

  // =========================================================================
  // Sequences
  // =========================================================================
  typedef enum {M_RANDOM, M_ZERO, M_IDENTITY, M_ALL_MIN, M_ALL_MAX, M_MIN_MAX, M_SMALL} mat_mode_e;

  class accel_base_seq extends uvm_sequence #(axil_item);
    `uvm_object_utils(accel_base_seq)

    function new(string name = "accel_base_seq");
      super.new(name);
    endfunction

    task wr(input bit [ADDR_W-1:0] wa, input bit [31:0] wd,
            output bit [1:0] wresp, input bit [3:0] ws = 4'hF);
      axil_item t = axil_item::type_id::create("wr");
      start_item(t);
      if (!t.randomize() with { is_write == 1; addr == wa; data == wd; strb == ws; })
        `uvm_fatal("RAND", "write item randomization failed")
      finish_item(t);   // returns after the driver has completed the transfer
      wresp = t.resp;
    endtask

    task rd(input bit [ADDR_W-1:0] ra, output bit [31:0] rdata, output bit [1:0] rresp);
      axil_item t = axil_item::type_id::create("rd");
      start_item(t);
      if (!t.randomize() with { is_write == 0; addr == ra; })
        `uvm_fatal("RAND", "read item randomization failed")
      finish_item(t);
      rdata = t.data;
      rresp = t.resp;
    endtask

    function automatic mat8_t make_matrix(mat_mode_e mode);
      mat8_t m;
      foreach (m[i, j]) begin
        case (mode)
          M_ZERO:     m[i][j] = 0;
          M_IDENTITY: m[i][j] = (i == j);
          M_ALL_MIN:  m[i][j] = -128;
          M_ALL_MAX:  m[i][j] = 127;
          M_MIN_MAX:  m[i][j] = $urandom_range(1) ? 8'sd127 : -8'sd128;
          M_SMALL:    m[i][j] = $urandom_range(6) - 3;
          default:    m[i][j] = $urandom_range(255);
        endcase
      end
      return m;
    endfunction

    task load(mat8_t a, mat8_t b);
      bit [1:0] resp;
      for (int i = 0; i < N; i++) begin
        bit [31:0] wa = '0, wb = '0;
        for (int k = 0; k < N; k++) begin
          wa[k*8 +: 8] = a[i][k];
          wb[k*8 +: 8] = b[i][k];
        end
        wr(A_BASE + 4*i, wa, resp);
        wr(B_BASE + 4*i, wb, resp);
      end
    endtask

    task start_run(bit irq_en = 0);
      bit [1:0] resp;
      wr(CTRL, {29'b0, irq_en, 2'b01}, resp);
    endtask

    task wait_done(int max_polls = 100);
      bit [31:0] status;
      bit [1:0]  resp;
      repeat (max_polls) begin
        rd(STATUS, status, resp);
        if (status[1]) begin
          wr(STATUS, 32'h2, resp);   // clear DONE (W1C)
          return;
        end
      end
      `uvm_error("SEQ", "Timed out waiting for STATUS.DONE")
    endtask

    task read_c();
      bit [31:0] d;
      bit [1:0]  resp;
      for (int e = 0; e < N*N; e++) rd(C_BASE + 4*e, d, resp);   // scoreboard checks
    endtask
  endclass

  // One full matrix multiply: load, start, wait, read back
  class matmul_seq extends accel_base_seq;
    `uvm_object_utils(matmul_seq)
    rand mat_mode_e mode_a, mode_b;
    rand bit        irq_en;

    function new(string name = "matmul_seq");
      super.new(name);
    endfunction

    task body();
      load(make_matrix(mode_a), make_matrix(mode_b));
      start_run(irq_en);
      wait_done();
      read_c();
    endtask
  endclass

  // START again as soon as DONE is seen, without clearing DONE or reloading
  class back2back_seq extends accel_base_seq;
    `uvm_object_utils(back2back_seq)
    function new(string name = "back2back_seq");
      super.new(name);
    endfunction

    task body();
      bit [31:0] status;
      bit [1:0]  resp;
      load(make_matrix(M_RANDOM), make_matrix(M_RANDOM));
      start_run();
      do rd(STATUS, status, resp); while (!status[1]);
      start_run();            // must be accepted; START also clears DONE
      wait_done();
      read_c();
    endtask
  endclass

  // One illegal access right after START: must be rejected with SLVERR
  class busy_access_seq extends accel_base_seq;
    `uvm_object_utils(busy_access_seq)
    rand int unsigned which;
    constraint c_which { which inside {[0:3]}; }

    function new(string name = "busy_access_seq");
      super.new(name);
    endfunction

    task body();
      bit [31:0] d;
      bit [1:0]  resp;
      load(make_matrix(M_RANDOM), make_matrix(M_RANDOM));
      start_run();
      case (which)
        0: wr(A_BASE + 4*$urandom_range(N-1), $urandom, resp);
        1: wr(B_BASE + 4*$urandom_range(N-1), $urandom, resp);
        2: wr(CTRL, 32'h1, resp);
        default: begin rd(C_BASE + 4*$urandom_range(N*N-1), d, resp); end
      endcase
      if (resp != SLVERR)
        `uvm_error("SEQ", $sformatf("Access %0d while BUSY was not rejected", which))
      wait_done();
      read_c();   // scoreboard confirms the rejected access changed nothing
    endtask
  endclass

  // Unmapped addresses, read-only writes, partial (WSTRB) writes, register readback
  class error_seq extends accel_base_seq;
    `uvm_object_utils(error_seq)
    rand int unsigned n_accesses;
    constraint c_n { n_accesses inside {[20:40]}; }

    function new(string name = "error_seq");
      super.new(name);
    endfunction

    task body();
      bit [31:0] d;
      bit [1:0]  resp;
      bit [ADDR_W-1:0] bad [] = '{'h00C, 'h0FC, A_BASE + 4*N, B_BASE + 4*N,
                                   C_BASE + 4*N*N, 'h400, 'h800, 'hFFC};
      foreach (bad[i]) begin
        wr(bad[i], $urandom, resp);
        rd(bad[i], d, resp);
      end
      wr(DIM, 32'h7, resp);
      wr(C_BASE + 4*$urandom_range(N*N-1), $urandom, resp);
      // Partial writes and readback of A/B
      repeat (n_accesses) begin
        bit [ADDR_W-1:0] a = ($urandom_range(1) ? A_BASE : B_BASE) + 4*$urandom_range(N-1);
        wr(a, $urandom, resp, 4'($urandom_range(1, 15)));
        rd(a, d, resp);
      end
      rd(CTRL, d, resp);
      rd(DIM, d, resp);
    endtask
  endclass

  // =========================================================================
  // Tests
  // =========================================================================
  class base_test extends uvm_test;
    `uvm_component_utils(base_test)
    accel_env env;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      env = accel_env::type_id::create("env", this);
    endfunction

    function void end_of_elaboration_phase(uvm_phase phase);
      uvm_top.print_topology();
    endfunction

    virtual task run_seqs();
    endtask

    task run_phase(uvm_phase phase);
      phase.raise_objection(this);
      run_seqs();
      #100ns;
      phase.drop_objection(this);
    endtask

    function int iters(int dflt);
      int n;
      if ($value$plusargs("NUM_ITERS=%d", n)) return n;
      return dflt;
    endfunction
  endclass

  class smoke_test extends base_test;
    `uvm_component_utils(smoke_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_seqs();
      matmul_seq s = matmul_seq::type_id::create("s");
      if (!s.randomize() with { mode_a == M_RANDOM; mode_b == M_IDENTITY; })
        `uvm_fatal("RAND", "randomize failed")
      s.start(env.agent.sqr);
    endtask
  endclass

  class random_test extends base_test;
    `uvm_component_utils(random_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_seqs();
      repeat (iters(100)) begin
        matmul_seq s = matmul_seq::type_id::create("s");
        if (!s.randomize() with { mode_a == M_RANDOM; mode_b == M_RANDOM; })
          `uvm_fatal("RAND", "randomize failed")
        s.start(env.agent.sqr);
      end
    endtask
  endclass

  class corner_test extends base_test;
    `uvm_component_utils(corner_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_seqs();
      mat_mode_e pairs[][2] = '{'{M_ZERO, M_RANDOM},     '{M_IDENTITY, M_RANDOM},
                                '{M_RANDOM, M_IDENTITY}, '{M_ALL_MIN, M_ALL_MIN},
                                '{M_ALL_MAX, M_ALL_MIN}, '{M_ALL_MAX, M_ALL_MAX},
                                '{M_MIN_MAX, M_MIN_MAX}, '{M_SMALL, M_SMALL}};
      foreach (pairs[p]) begin
        matmul_seq s = matmul_seq::type_id::create("s");
        if (!s.randomize() with { mode_a == pairs[p][0]; mode_b == pairs[p][1]; })
          `uvm_fatal("RAND", "randomize failed")
        s.start(env.agent.sqr);
      end
    endtask
  endclass

  class back2back_test extends base_test;
    `uvm_component_utils(back2back_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_seqs();
      repeat (iters(10)) begin
        back2back_seq s = back2back_seq::type_id::create("s");
        s.start(env.agent.sqr);
      end
    endtask
  endclass

  class busy_access_test extends base_test;
    `uvm_component_utils(busy_access_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_seqs();
      repeat (iters(20)) begin
        busy_access_seq s = busy_access_seq::type_id::create("s");
        if (!s.randomize()) `uvm_fatal("RAND", "randomize failed")
        s.start(env.agent.sqr);
      end
    endtask
  endclass

  class error_test extends base_test;
    `uvm_component_utils(error_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_seqs();
      error_seq s = error_seq::type_id::create("s");
      if (!s.randomize()) `uvm_fatal("RAND", "randomize failed")
      s.start(env.agent.sqr);
    endtask
  endclass

  // Everything in one run: best for collecting coverage on EDA Playground
  class full_regression_test extends base_test;
    `uvm_component_utils(full_regression_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_seqs();
      error_seq       e = error_seq::type_id::create("e");
      if (!e.randomize()) `uvm_fatal("RAND", "randomize failed")
      e.start(env.agent.sqr);
      repeat (iters(60)) begin
        randcase
          6: begin
               matmul_seq s = matmul_seq::type_id::create("s");
               if (!s.randomize()) `uvm_fatal("RAND", "randomize failed")
               s.start(env.agent.sqr);
             end
          2: begin
               busy_access_seq s = busy_access_seq::type_id::create("s");
               if (!s.randomize()) `uvm_fatal("RAND", "randomize failed")
               s.start(env.agent.sqr);
             end
          1: begin
               back2back_seq s = back2back_seq::type_id::create("s");
               s.start(env.agent.sqr);
             end
        endcase
      end
    endtask
  endclass
endpackage
