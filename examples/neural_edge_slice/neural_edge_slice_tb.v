`timescale 1ns/1ps

`include "sand_defs.vh"
`include "neural_edge_slice_config.vh"

module neural_edge_slice_tb;
    localparam integer Q_ONE  = (1 << `FRAC_W);
    localparam integer MAX_W  = `WIDTH;
    localparam integer MAX_H  = `HEIGHT;
    localparam integer Q_MAX  = (1 << (`DATA_W-1)) - 1;

    integer window_w          = NES_WINDOW_W_DEFAULT;
    integer window_h          = NES_WINDOW_H_DEFAULT;
    integer pattern_id        = NES_PATTERN_ID_DEFAULT;
    integer edge_gain_pct     = NES_EDGE_GAIN_PCT;
    integer raw_gain_pct      = NES_RAW_GAIN_PCT;
    integer bias_pct          = NES_BIAS_PCT;
    integer threshold_pct     = NES_THRESHOLD_PCT;

    integer base_img   [0:MAX_H-1][0:MAX_W-1];
    integer edge_map   [0:MAX_H-1][0:MAX_W-1];
    integer neuron_raw [0:MAX_H-1][0:MAX_W-1];
    integer neuron_relu[0:MAX_H-1][0:MAX_W-1];
    integer neuron_fire[0:MAX_H-1][0:MAX_W-1];

    // Shared combinational primitives sourced from rtl/circuits.
    reg  signed [`DATA_W-1:0] edge_center;
    reg  signed [`DATA_W-1:0] edge_north;
    reg  signed [`DATA_W-1:0] edge_south;
    reg  signed [`DATA_W-1:0] edge_east;
    reg  signed [`DATA_W-1:0] edge_west;
    wire signed [`DATA_W-1:0] edge_value;

    sand_circuit_edge_l1 edge_core (
        .center(edge_center),
        .north(edge_north),
        .south(edge_south),
        .east(edge_east),
        .west(edge_west),
        .edge(edge_value)
    );

    reg  signed [`DATA_W-1:0] neuron_edge_in;
    reg  signed [`DATA_W-1:0] neuron_raw_in;
    reg  signed [`DATA_W-1:0] neuron_edge_gain_q_reg;
    reg  signed [`DATA_W-1:0] neuron_raw_gain_q_reg;
    reg  signed [`DATA_W-1:0] neuron_bias_q_reg;
    reg  signed [`DATA_W-1:0] neuron_threshold_q_reg;

    wire signed [`DATA_W-1:0] neuron_raw_out_wire;
    wire signed [`DATA_W-1:0] neuron_relu_out_wire;
    wire                      neuron_fire_wire;

    sand_circuit_neuron_relu neuron_core (
        .edge_in(neuron_edge_in),
        .raw_in(neuron_raw_in),
        .edge_gain_q(neuron_edge_gain_q_reg),
        .raw_gain_q(neuron_raw_gain_q_reg),
        .bias_q(neuron_bias_q_reg),
        .threshold_q(neuron_threshold_q_reg),
        .raw_out(neuron_raw_out_wire),
        .relu_out(neuron_relu_out_wire),
        .fire(neuron_fire_wire)
    );

    integer edge_gain_q;
    integer raw_gain_q;
    integer bias_q;
    integer threshold_q;

    integer total_edge_energy;
    integer total_relu_activation;
    integer active_pixels;

    function integer pct_to_q;
        input integer pct;
        integer scaled;
        begin
            scaled = pct * Q_ONE;
            if (pct >= 0)
                pct_to_q = (scaled + 500) / 1000;
            else
                pct_to_q = (scaled - 500) / 1000;
        end
    endfunction

    task clear_buffers;
        integer y, x;
        begin
            for (y = 0; y < MAX_H; y = y + 1) begin
                for (x = 0; x < MAX_W; x = x + 1) begin
                    base_img[y][x]    = 0;
                    edge_map[y][x]    = 0;
                    neuron_raw[y][x]  = 0;
                    neuron_relu[y][x] = 0;
                    neuron_fire[y][x] = 0;
                end
            end
        end
    endtask

    task load_pattern;
        integer y, x;
        integer centre_x;
        integer centre_y;
        integer denom;
        integer val;
        begin
            centre_x = window_w >> 1;
            centre_y = window_h >> 1;
            denom    = (window_w + window_h > 2) ? (window_w + window_h - 2) : 1;

            case (pattern_id)
                0: begin
                    // Bright cross on dim background
                    for (y = 0; y < window_h; y = y + 1) begin
                        for (x = 0; x < window_w; x = x + 1) begin
                            val = Q_ONE >> 3; // background ~0.125
                            if ((x == centre_x) || (y == centre_y))
                                val = Q_ONE;
                            base_img[y][x] = val;
                        end
                    end
                end
                1: begin
                    // Smooth ramp from top-left (0.0) to bottom-right (~1.0)
                    for (y = 0; y < window_h; y = y + 1) begin
                        for (x = 0; x < window_w; x = x + 1) begin
                            val = ((x + y) * Q_ONE) / denom;
                            if (val > Q_MAX)
                                val = Q_MAX;
                            base_img[y][x] = val;
                        end
                    end
                end
                2: begin
                    // Checkerboard emphasises high-frequency edges
                    for (y = 0; y < window_h; y = y + 1) begin
                        for (x = 0; x < window_w; x = x + 1) begin
                            if (((x ^ y) & 1) == 0)
                                val = Q_ONE;
                            else
                                val = Q_ONE >> 4; // ~0.0625
                            base_img[y][x] = val;
                        end
                    end
                end
                default: begin
                    // Diagonal stripe fallback
                    for (y = 0; y < window_h; y = y + 1) begin
                        for (x = 0; x < window_w; x = x + 1) begin
                            val = (x == y) ? Q_ONE : (Q_ONE >> 2);
                            base_img[y][x] = val;
                        end
                    end
                end
            endcase
        end
    endtask

    task compute_edges;
        integer y, x;
        integer north, south, east, west, center;
        begin
            total_edge_energy = 0;
            for (y = 0; y < window_h; y = y + 1) begin
                for (x = 0; x < window_w; x = x + 1) begin
                    center = base_img[y][x];
                    north  = (y == 0) ? center : base_img[y-1][x];
                    south  = (y == window_h-1) ? center : base_img[y+1][x];
                    west   = (x == 0) ? center : base_img[y][x-1];
                    east   = (x == window_w-1) ? center : base_img[y][x+1];

                    edge_center = center;
                    edge_north  = north;
                    edge_south  = south;
                    edge_east   = east;
                    edge_west   = west;
                    #0;

                    edge_map[y][x] = edge_value;
                    total_edge_energy = total_edge_energy + edge_value;
                end
            end
        end
    endtask

    task run_neuron;
        integer y, x;
        begin
            total_relu_activation = 0;
            active_pixels = 0;

            neuron_edge_gain_q_reg = edge_gain_q;
            neuron_raw_gain_q_reg  = raw_gain_q;
            neuron_bias_q_reg      = bias_q;
            neuron_threshold_q_reg = threshold_q;

            for (y = 0; y < window_h; y = y + 1) begin
                for (x = 0; x < window_w; x = x + 1) begin
                    neuron_edge_in = edge_map[y][x];
                    neuron_raw_in  = base_img[y][x];
                    #0;

                    neuron_raw[y][x]  = neuron_raw_out_wire;
                    neuron_relu[y][x] = neuron_relu_out_wire;
                    neuron_fire[y][x] = neuron_fire_wire;

                    total_relu_activation = total_relu_activation + neuron_relu[y][x];
                    if (neuron_fire_wire) begin
                        active_pixels = active_pixels + 1;
                    end
                end
            end
        end
    endtask

    task dump_results;
        integer y, x;
        begin
            $display("NEURAL.window_w=%0d window_h=%0d pattern_id=%0d",
                     window_w, window_h, pattern_id);
            $display("NEURAL.config.edge_gain_q=%0d raw_gain_q=%0d bias_q=%0d threshold_q=%0d",
                     edge_gain_q, raw_gain_q, bias_q, threshold_q);

            for (y = 0; y < window_h; y = y + 1) begin
                for (x = 0; x < window_w; x = x + 1) begin
                    $display("EDGE.pixel[%0d,%0d]=%0d", y, x, edge_map[y][x]);
                end
            end

            for (y = 0; y < window_h; y = y + 1) begin
                for (x = 0; x < window_w; x = x + 1) begin
                    $display("NEURON.raw[%0d,%0d]=%0d", y, x, neuron_raw[y][x]);
                end
            end

            for (y = 0; y < window_h; y = y + 1) begin
                for (x = 0; x < window_w; x = x + 1) begin
                    $display("NEURON.relu[%0d,%0d]=%0d", y, x, neuron_relu[y][x]);
                end
            end

            for (y = 0; y < window_h; y = y + 1) begin
                for (x = 0; x < window_w; x = x + 1) begin
                    $display("NEURON.fire[%0d,%0d]=%0d", y, x, neuron_fire[y][x]);
                end
            end

            $display("NEURON.summary.total_edge=%0d active_pixels=%0d total_relu=%0d",
                     total_edge_energy, active_pixels, total_relu_activation);
        end
    endtask

    initial begin
        if ($value$plusargs("WINDOW_W=%d", window_w));
        if ($value$plusargs("WINDOW_H=%d", window_h));
        if ($value$plusargs("PATTERN_ID=%d", pattern_id));
        if ($value$plusargs("EDGE_GAIN=%d", edge_gain_pct));
        if ($value$plusargs("RAW_GAIN=%d", raw_gain_pct));
        if ($value$plusargs("BIAS_PCT=%d", bias_pct));
        if ($value$plusargs("THRESH_PCT=%d", threshold_pct));

        if (window_w < 2) window_w = 2;
        if (window_h < 2) window_h = 2;
        if (window_w > MAX_W) window_w = MAX_W;
        if (window_h > MAX_H) window_h = MAX_H;

        clear_buffers;
        load_pattern;

        edge_gain_q = pct_to_q(edge_gain_pct);
        raw_gain_q  = pct_to_q(raw_gain_pct);
        bias_q      = pct_to_q(bias_pct);
        threshold_q = pct_to_q(threshold_pct);

        compute_edges;
        run_neuron;
        dump_results;
        $finish;
    end
endmodule
