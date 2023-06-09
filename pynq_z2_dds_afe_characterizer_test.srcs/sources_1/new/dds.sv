module dds #(
  parameter int PHASE_BITS = 24,
  parameter int OUTPUT_WIDTH = 18,
  parameter int QUANT_BITS = 8,
  parameter int PARALLEL_SAMPLES = 4
) (
  input wire clk, reset,
  Axis_If.Master_Simple cos_out,
  Axis_If.Slave_Simple phase_inc_in
);


localparam int LUT_ADDR_BITS = PHASE_BITS - QUANT_BITS;
localparam int LUT_DEPTH = 2**LUT_ADDR_BITS;

// generate LUT
localparam real PI = 3.14159265;
logic signed [OUTPUT_WIDTH-1:0] lut [LUT_DEPTH];
initial begin
  for (int i = 0; i < LUT_DEPTH; i = i + 1) begin
    lut[i] = signed'(int'($floor($cos(2*PI/(LUT_DEPTH)*i)*(2**(OUTPUT_WIDTH-1) - 0.5) - 0.5)));
  end
end

// update phases
logic [PARALLEL_SAMPLES-1:0][PHASE_BITS-1:0] phase_inc;
logic [PHASE_BITS-1:0] cycle_phase;
logic [PARALLEL_SAMPLES-1:0][PHASE_BITS-1:0] sample_phase;
assign phase_inc_in.ready = 1'b1;
always @(posedge clk) begin
  if (reset) begin
    phase_inc <= '0;
    cycle_phase <= '0;
    sample_phase <= '0;
  end else begin
    // load new phase_inc
    if (phase_inc_in.ready && phase_inc_in.valid) begin
      for (int i = 0; i < PARALLEL_SAMPLES; i = i + 1) begin
        phase_inc[i] <= phase_inc_in.data * (i + 1);
      end
    end
    if (cos_out.ready) begin
      cycle_phase <= cycle_phase + phase_inc[PARALLEL_SAMPLES-1];
      sample_phase[0] <= cycle_phase;
      for (int i = 1; i < PARALLEL_SAMPLES; i = i + 1) begin
        sample_phase[i] <= cycle_phase + phase_inc[i-1];
      end
    end
  end
end

// dither LFSR
logic [PARALLEL_SAMPLES-1:0][15:0] lfsr;
lfsr16_parallel #(.PARALLEL_SAMPLES(PARALLEL_SAMPLES)) lfsr_i (
  .clk,
  .reset,
  .enable(cos_out.ready),
  .data_out(lfsr)
);

logic [PARALLEL_SAMPLES-1:0][PHASE_BITS-1:0] phase_dithered;
logic [PARALLEL_SAMPLES-1:0][LUT_ADDR_BITS-1:0] phase_quant;
// delay data_valid to match phase increment + LUT latency
logic [2:0] data_valid;
assign cos_out.valid = data_valid[2];
genvar i;
generate
  for (i = 0; i < PARALLEL_SAMPLES; i = i + 1) begin
    if (QUANT_BITS > 16) begin
      assign phase_dithered[i] = {lfsr[i], {(QUANT_BITS - 16){1'b0}}} + sample_phase[i];
    end else begin
      assign phase_dithered[i] = lfsr[i][QUANT_BITS-1:0] + sample_phase[i];
    end
    always @(posedge clk) begin
      if (reset) begin
        data_valid <= '0;
        cos_out.data[OUTPUT_WIDTH*i+:OUTPUT_WIDTH] <= '0;
        phase_quant[i] <= '0;
      end else begin
        if (cos_out.ready) begin
          phase_quant[i] <= phase_dithered[i][PHASE_BITS-1:QUANT_BITS];
          data_valid[0] <= 1'b1;
          for (int j = 1; j < 3; j++) begin
            data_valid[j] <= data_valid[j-1];
          end
          cos_out.data[OUTPUT_WIDTH*i+:OUTPUT_WIDTH] <= lut[phase_quant[i]];
        end
      end
    end
  end
endgenerate

endmodule
