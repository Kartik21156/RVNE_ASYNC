// RVNE-ASYNC — matched delay element. Contract: docs/rtl_module_spec.md §4.9.
// Realises D3 §5.2 (T1–T3).
//
// Simulation: d is an inertial delay of in_i by D (pulses shorter than D are
// absorbed). Reset comes from the OUTPUT gating, not from the delay node: d is
// not cleared by reset and may stay high or have a transition still scheduled
// while rst_ni = 0, but out_o is 0 for as long as rst_ni = 0.
// Synthesis: placeholder wire, pending DEC-10. It gives NO timing guarantee.
`timescale 1ns/1ps

module rvne_delay #(
  parameter realtime D = 1.0
) (
  input  logic rst_ni,
  input  logic in_i,
  output logic out_o
);

`ifndef SYNTHESIS
  // d MUST be a net: xsim 2022.1 applies a continuous-assignment delay to a
  // 'logic' variable as a transport delay (short pulses pass); only a net
  // gets the inertial semantics this contract requires (d6_impl_notes X-h).
  wire d;
  assign #(D) d = in_i;
  assign out_o = rst_ni & d;
`else
  assign out_o = rst_ni & in_i;
`endif

endmodule
