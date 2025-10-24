`timescale 1ns/1ps

`include "sand_defs.vh"

module neural_edge_slice_tb;
    localparam integer Q_ONE  = (1 << `FRAC_W);
    localparam integer MAX_W  = `WIDTH;
    localparam integer MAX_H  = `HEIGHT;
    localparam integer Q_MAX  = (1 << (`DATA_W-1)) - 1;
    localparam integer Q_MIN  = -(1 << (`DATA_W-1));

    integer window_w          = 8;
    integer window_h          = 8;
    integer pattern_id        = 0;
    integer edge_gain_pct     = 700;   // thousandths (0.7x)
    integer raw_gain_pct      = 300;   // thousandths (0.3x)
    integer bias_pct          = -250;  // thousandths (-0.25)
    integer threshold_pct     = 500;   // thousandths (0.5)

    integer base_img   [0:MAX_H-1][0:MAX_W-1];
    integer edge_map   [0:MAX_H-1][0:MAX_W-1];
    integer neuron_raw [0:MAX_H-1][0:MAX_W-1];
    integer neuron_relu[0:MAX_H-1][0:MAX_W-1];
    integer neuron_fire[0:MAX_H-1][0:MAX_W-1];

    integer edge_gain_q;
    integer raw_gain_q;
    integer bias_q;
    integer threshold_q;

    integer total_edge_energy;
    integer total_relu_activation;
    integer active_pixels;

    function integer saturate_signed;
        input integer value;
        begin
            if (value > Q_MAX)
                saturate_signed = Q_MAX;
            else if (value < Q_MIN)
                saturate_signed = Q_MIN;
            else
                saturate_signed = value;
        end
    endfunction

    function integer saturate_positive;
        input integer value;
        begin
            if (value < 0)
                saturate_positive = 0;
            else if (value > Q_MAX)
                saturate_positive = Q_MAX;
            else
                saturate_positive = value;
        end
    endfunction

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
        integer dx, dy;
        begin
            total_edge_energy = 0;
            for (y = 0; y < window_h; y = y + 1) begin
                for (x = 0; x < window_w; x = x + 1) begin
                    center = base_img[y][x];
                    north  = (y == 0) ? center : base_img[y-1][x];
                    south  = (y == window_h-1) ? center : base_img[y+1][x];
                    west   = (x == 0) ? center : base_img[y][x-1];
                    east   = (x == window_w-1) ? center : base_img[y][x+1];

                    dx = east - west;
                    if (dx < 0) dx = -dx;
                    dy = south - north;
                    if (dy < 0) dy = -dy;

                    edge_map[y][x] = saturate_positive(dx + dy);
                    total_edge_energy = total_edge_energy + edge_map[y][x];
                end
            end
        end
    endtask

    task run_neuron;
        integer y, x;
        integer edge_term;
        integer raw_term;
        integer combined;
        begin
            total_relu_activation = 0;
            active_pixels = 0;

            for (y = 0; y < window_h; y = y + 1) begin
                for (x = 0; x < window_w; x = x + 1) begin
                    edge_term = (edge_gain_q * edge_map[y][x]) >>> `FRAC_W;
                    raw_term  = (raw_gain_q * base_img[y][x]) >>> `FRAC_W;
                    combined  = edge_term + raw_term + bias_q;

                    neuron_raw[y][x] = saturate_signed(combined);
                    if (combined > 0) begin
                        neuron_relu[y][x] = saturate_positive(combined);
                        total_relu_activation = total_relu_activation + neuron_relu[y][x];
                    end else begin
                        neuron_relu[y][x] = 0;
                    end

                    if (combined >= threshold_q) begin
                        neuron_fire[y][x] = 1;
                        active_pixels = active_pixels + 1;
                    end else begin
                        neuron_fire[y][x] = 0;
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

