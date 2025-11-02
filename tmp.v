module m;
  wire [7:0] csr;
  function automatic [7:0] clamp;
    input [7:0] x;
    clamp = x;
  endfunction
  wire [7:0] y = clamp(__SV_SEL_0(csr, 7, 0));
endmodule
