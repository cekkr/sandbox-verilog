`timescale 1ns/1ps

`include "sand_defs.vh"
`include "sand_math.vh"
`include "neural_activation_field_config.vh"

module neural_activation_field_tb;
    localparam integer Q_ONE  = (1 << `FRAC_W);
    localparam integer Q_MAX  = (1 << (`DATA_W-1)) - 1;
    localparam integer Q_MIN  = -(1 << (`DATA_W-1));
    localparam integer MAX_W  = `WIDTH;
    localparam integer MAX_H  = `HEIGHT;
    localparam integer MAX_D  = `DEPTH;

    integer window_w          = NAF_WINDOW_W_DEFAULT;
    integer window_h          = NAF_WINDOW_H_DEFAULT;
    integer window_d          = NAF_WINDOW_D_DEFAULT;
    integer pattern_id        = NAF_PATTERN_ID_DEFAULT;
    integer iterations        = NAF_ITERATIONS_DEFAULT;

    string image_file = "";

    integer self_gain_pct     = NAF_SELF_GAIN_PCT;
    integer planar_gain_pct   = NAF_PLANAR_GAIN_PCT;
    integer vertical_gain_pct = NAF_VERTICAL_GAIN_PCT;
    integer bias_pct          = NAF_BIAS_PCT;
    integer feedback_pct      = NAF_FEEDBACK_PCT;
    integer damp_pct          = NAF_DAMP_PCT;
    integer learning_pct      = NAF_LEARNING_PCT;
    integer target_pct        = NAF_TARGET_PCT;
    integer read_edge_pct     = NAF_READ_EDGE_PCT;
    integer read_raw_pct      = NAF_READ_RAW_PCT;
    integer read_bias_pct     = NAF_READ_BIAS_PCT;
    integer read_thresh_pct   = NAF_READ_THRESH_PCT;
    integer activation_passthrough = NAF_ACTIVATION_BYPASS;

    integer base_field       [0:MAX_D-1][0:MAX_H-1][0:MAX_W-1];
    integer state_field      [0:MAX_D-1][0:MAX_H-1][0:MAX_W-1];
    integer next_state       [0:MAX_D-1][0:MAX_H-1][0:MAX_W-1];
    integer mix_field        [0:MAX_D-1][0:MAX_H-1][0:MAX_W-1];
    integer activation_field [0:MAX_D-1][0:MAX_H-1][0:MAX_W-1];
    integer readout_raw      [0:MAX_H-1][0:MAX_W-1];
    integer readout_relu     [0:MAX_H-1][0:MAX_W-1];
    integer readout_fire     [0:MAX_H-1][0:MAX_W-1];
    integer image_buffer     [0:MAX_D*MAX_H*MAX_W-1];

    // Circuit glue
    reg  signed [`DATA_W-1:0] mix_self;
    reg  signed [`DATA_W-1:0] mix_north;
    reg  signed [`DATA_W-1:0] mix_south;
    reg  signed [`DATA_W-1:0] mix_east;
    reg  signed [`DATA_W-1:0] mix_west;
    reg  signed [`DATA_W-1:0] mix_above;
    reg  signed [`DATA_W-1:0] mix_below;
    reg  signed [`DATA_W-1:0] mix_self_gain_q_reg;
    reg  signed [`DATA_W-1:0] mix_planar_gain_q_reg;
    reg  signed [`DATA_W-1:0] mix_vertical_gain_q_reg;
    reg  signed [`DATA_W-1:0] mix_bias_q_reg;
    wire signed [`DATA_W-1:0] mix_value;

    sand_circuit_neighbor_mix neighbor_mix (
        .self(mix_self),
        .north(mix_north),
        .south(mix_south),
        .east(mix_east),
        .west(mix_west),
        .above(mix_above),
        .below(mix_below),
        .self_gain_q(mix_self_gain_q_reg),
        .planar_gain_q(mix_planar_gain_q_reg),
        .vertical_gain_q(mix_vertical_gain_q_reg),
        .bias_q(mix_bias_q_reg),
        .mix_out(mix_value)
    );

    reg  signed [`DATA_W-1:0] act_in;
    wire signed [`DATA_W-1:0] act_out;

    reg signed [`DATA_W-1:0] micro_lut [0:15];

    sand_circuit_activation_micro_lut micro_lut_core (
        .value_in(act_in),
        .micro_lut(micro_lut),
        .value_out(act_out)
    );

    reg  signed [`DATA_W-1:0] read_edge_in;
    reg  signed [`DATA_W-1:0] read_raw_in;
    reg  signed [`DATA_W-1:0] read_edge_gain_q_reg;
    reg  signed [`DATA_W-1:0] read_raw_gain_q_reg;
    reg  signed [`DATA_W-1:0] read_bias_q_reg;
    reg  signed [`DATA_W-1:0] read_threshold_q_reg;
    wire signed [`DATA_W-1:0] read_raw_out_wire;
    wire signed [`DATA_W-1:0] read_relu_out_wire;
    wire                      read_fire_wire;

    sand_circuit_neuron_relu readout_neuron (
        .edge_in(read_edge_in),
        .raw_in(read_raw_in),
        .edge_gain_q(read_edge_gain_q_reg),
        .raw_gain_q(read_raw_gain_q_reg),
        .bias_q(read_bias_q_reg),
        .threshold_q(read_threshold_q_reg),
        .raw_out(read_raw_out_wire),
        .relu_out(read_relu_out_wire),
        .fire(read_fire_wire)
    );

    integer self_gain_q;
    integer planar_gain_q;
    integer vertical_gain_q;
    integer bias_q;
    integer feedback_gain_q_per_layer [0:MAX_D-1];
    integer damp_gain_q;
    integer learning_q;
    integer target_q;
    integer read_edge_gain_q;
    integer read_raw_gain_q;
    integer read_bias_q;
    integer read_threshold_q;

    integer current_bias_q;
    integer mean_top_q;
    integer last_error_q;
    integer top_layer_sum_q;
    integer top_active_cells;
    integer readout_fire_cells;
    integer readout_sum_q;
    integer readout_mean_q;

    function integer clamp_q;
        input integer value;
        begin
            if (value > Q_MAX)
                clamp_q = Q_MAX;
            else if (value < Q_MIN)
                clamp_q = Q_MIN;
            else
                clamp_q = value;
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

    function integer fp_add;
        input integer a;
        input integer b;
        integer sum;
        begin
            sum = a + b;
            fp_add = clamp_q(sum);
        end
    endfunction

    function integer fp_sub;
        input integer a;
        input integer b;
        integer diff;
        begin
            diff = a - b;
            fp_sub = clamp_q(diff);
        end
    endfunction

    function integer fp_mul;
        input integer a;
        input integer b;
        integer prod;
        integer rounder;
        begin
            prod = a * b;
            if (`FRAC_W > 0) begin
                rounder = 1 << (`FRAC_W-1);
                if (prod >= 0)
                    prod = prod + rounder;
                else
                    prod = prod - rounder;
                prod = prod >>> `FRAC_W;
            end
            fp_mul = clamp_q(prod);
        end
    endfunction

    task init_micro_lut;
        integer sign;
        integer bucket;
        integer frac;
        integer idx;
        integer q_val;
        real sample_abs;
        real sample_val;
        real response;
        real scaled;
        begin
            // Populate the LUT with a softsign approximation in Q format.
            for (sign = 0; sign < 2; sign = sign + 1) begin
                for (bucket = 0; bucket < 4; bucket = bucket + 1) begin
                    for (frac = 0; frac < 2; frac = frac + 1) begin
                        idx = (sign << 3) | (bucket << 1) | frac;

                        case (bucket)
                            0: sample_abs = 0.25;
                            1: sample_abs = (frac == 0) ? 1.25 : 0.75;
                            2: sample_abs = 1.75;
                            default: sample_abs = (frac == 0) ? 2.25 : 4.5;
                        endcase

                        sample_val = sign ? -sample_abs : sample_abs;
                        response = sample_val / (1.0 + sample_abs);
                        scaled = response * Q_ONE;

                        if (scaled >= 0.0)
                            q_val = $rtoi(scaled + 0.5);
                        else
                            q_val = -$rtoi(-scaled + 0.5);

                        micro_lut[idx] = clamp_q(q_val);
                    end
                end
            end
        end
    endtask

    task clear_buffers;
        integer z, y, x;
        begin
            for (z = 0; z < MAX_D; z = z + 1) begin
                for (y = 0; y < MAX_H; y = y + 1) begin
                    for (x = 0; x < MAX_W; x = x + 1) begin
                        base_field[z][y][x]       = 0;
                        state_field[z][y][x]      = 0;
                        next_state[z][y][x]       = 0;
                        mix_field[z][y][x]        = 0;
                        activation_field[z][y][x] = 0;
                    end
                end
            end

            for (y = 0; y < MAX_H; y = y + 1) begin
                for (x = 0; x < MAX_W; x = x + 1) begin
                    readout_raw[y][x]  = 0;
                    readout_relu[y][x] = 0;
                    readout_fire[y][x] = 0;
                end
            end
        end
    endtask

    task load_image;
        integer total_cells;
        integer idx;
        integer z, y, x;
        begin
            total_cells = window_w * window_h * window_d;
            if (total_cells > MAX_D*MAX_H*MAX_W)
                total_cells = MAX_D*MAX_H*MAX_W;

            for (idx = 0; idx < MAX_D*MAX_H*MAX_W; idx = idx + 1)
                image_buffer[idx] = 0;

            $readmemh(image_file, image_buffer);

            idx = 0;
            for (z = 0; z < window_d; z = z + 1) begin
                for (y = 0; y < window_h; y = y + 1) begin
                    for (x = 0; x < window_w; x = x + 1) begin
                        if (idx < total_cells)
                            base_field[z][y][x] = clamp_q(image_buffer[idx]);
                        else
                            base_field[z][y][x] = 0;
                        state_field[z][y][x] = base_field[z][y][x];
                        idx = idx + 1;
                    end
                end
            end
        end
    endtask

    task load_pattern;
        integer z, y, x;
        integer centre_x;
        integer centre_y;
        integer centre_z;
        integer dx, dy, dz;
        integer radial;
        integer seed;
        integer value;
        begin
            if (image_file != "") begin
                load_image();
            end else begin
                centre_x = window_w >> 1;
                centre_y = window_h >> 1;
                centre_z = window_d >> 1;
                seed     = 32'h1ACE_1234;

                for (z = 0; z < window_d; z = z + 1) begin
                    for (y = 0; y < window_h; y = y + 1) begin
                        for (x = 0; x < window_w; x = x + 1) begin
                            dx = x - centre_x;
                            dy = y - centre_y;
                            dz = z - centre_z;

                            if (pattern_id == 0) begin
                                radial = dx*dx + dy*dy + (dz*dz << 1);
                                value = (Q_ONE << 3) / (radial + 5);
                                if (value > Q_ONE)
                                    value = Q_ONE;
                            end else if (pattern_id == 1) begin
                                radial = dx*dx + dy*dy;
                                if (((radial + (dz << 1)) % 6) < 3)
                                    value = Q_ONE;
                                else
                                    value = -(Q_ONE >> 1);
                            end else if (pattern_id == 2) begin
                                value = ((z * window_h + y) * Q_ONE) / (window_h * window_d + 1);
                                if ((x ^ y ^ z) & 1)
                                    value = value - (Q_ONE >> 2);
                            end else if (pattern_id == 3) begin
                                seed = (seed * 1664525) + 1013904223;
                                value = (seed >> 24) & 8'hFF;
                                value = value - 9'sd128;
                                value = (value * Q_ONE) / 64;
                            end else begin
                                value = (((x + y + z) & 1) == 0) ? (Q_ONE >> 1) : -(Q_ONE >> 2);
                            end

                            value = clamp_q(value);
                            base_field[z][y][x]  = value;
                            state_field[z][y][x] = value;
                        end
                    end
                end
            end
        end
    endtask

    task compute_neighbor_mix;
        integer z, y, x;
        integer self_val, n_val, s_val, e_val, w_val, above_val, below_val;
        begin
            mix_self_gain_q_reg     = self_gain_q;
            mix_planar_gain_q_reg   = planar_gain_q;
            mix_vertical_gain_q_reg = vertical_gain_q;

            for (z = 0; z < window_d; z = z + 1) begin
                for (y = 0; y < window_h; y = y + 1) begin
                    for (x = 0; x < window_w; x = x + 1) begin
                        self_val  = state_field[z][y][x];
                        n_val     = (y == 0) ? self_val : state_field[z][y-1][x];
                        s_val     = (y == window_h-1) ? self_val : state_field[z][y+1][x];
                        w_val     = (x == 0) ? self_val : state_field[z][y][x-1];
                        e_val     = (x == window_w-1) ? self_val : state_field[z][y][x+1];
                        below_val = (z == 0) ? self_val : state_field[z-1][y][x];
                        above_val = (z == window_d-1) ? self_val : state_field[z+1][y][x];

                        mix_self          = self_val;
                        mix_north         = n_val;
                        mix_south         = s_val;
                        mix_west          = w_val;
                        mix_east          = e_val;
                        mix_below         = below_val;
                        mix_above         = above_val;
                        mix_bias_q_reg    = current_bias_q;

                        #0;
                        mix_field[z][y][x] = mix_value;
                    end
                end
            end
        end
    endtask

    task apply_activation;
        integer z, y, x;
        begin
            for (z = 0; z < window_d; z = z + 1) begin
                for (y = 0; y < window_h; y = y + 1) begin
                    for (x = 0; x < window_w; x = x + 1) begin
                        act_in = mix_field[z][y][x];
                        if (activation_passthrough != 0) begin
                            activation_field[z][y][x] = act_in;
                        end else begin
                            #0;
                            activation_field[z][y][x] = act_out;
                        end
                    end
                end
            end
        end
    endtask

    task apply_feedback;
        integer z, y, x;
        integer feedback_term;
        integer damp_term;
        integer updated;
        begin
            for (z = 0; z < window_d; z = z + 1) begin
                for (y = 0; y < window_h; y = y + 1) begin
                    for (x = 0; x < window_w; x = x + 1) begin
                        next_state[z][y][x] = activation_field[z][y][x];
                    end
                end
            end

            for (z = 0; z < window_d; z = z + 1) begin
                for (y = 0; y < window_h; y = y + 1) begin
                    for (x = 0; x < window_w; x = x + 1) begin
                        feedback_term = fp_mul(activation_field[z][y][x], feedback_gain_q_per_layer[z]);
                        damp_term     = fp_mul(
                            fp_sub(state_field[z][y][x], base_field[z][y][x]),
                            damp_gain_q
                        );
                        updated = fp_add(base_field[z][y][x], feedback_term);
                        updated = fp_sub(updated, damp_term);
                        next_state[z][y][x] = clamp_q(updated);
                    end
                end
            end

            for (z = 0; z < window_d; z = z + 1) begin
                for (y = 0; y < window_h; y = y + 1) begin
                    for (x = 0; x < window_w; x = x + 1) begin
                        state_field[z][y][x] = next_state[z][y][x];
                    end
                end
            end
        end
    endtask

    task update_bias;
        integer y, x;
        integer cell_count;
        integer top_val;
        integer adjust_q;
        begin
            top_layer_sum_q = 0;
            top_active_cells = 0;
            cell_count = window_w * window_h;
            if (cell_count <= 0)
                cell_count = 1;

            for (y = 0; y < window_h; y = y + 1) begin
                for (x = 0; x < window_w; x = x + 1) begin
                    top_val = activation_field[window_d-1][y][x];
                    top_layer_sum_q = top_layer_sum_q + top_val;
                    if (top_val > 0)
                        top_active_cells = top_active_cells + 1;
                end
            end

            if (top_layer_sum_q >= 0)
                mean_top_q = (top_layer_sum_q + (cell_count >> 1)) / cell_count;
            else
                mean_top_q = (top_layer_sum_q - (cell_count >> 1)) / cell_count;

            last_error_q = fp_sub(mean_top_q, target_q);
            adjust_q = fp_mul(last_error_q, learning_q);
            current_bias_q = clamp_q(fp_sub(current_bias_q, adjust_q));
        end
    endtask

    task apply_readout;
        integer y, x, z;
        integer accum;
        begin
            read_edge_gain_q_reg = read_edge_gain_q;
            read_raw_gain_q_reg  = read_raw_gain_q;
            read_bias_q_reg      = read_bias_q;
            read_threshold_q_reg = read_threshold_q;

            readout_fire_cells = 0;
            readout_sum_q = 0;

            for (y = 0; y < window_h; y = y + 1) begin
                for (x = 0; x < window_w; x = x + 1) begin
                    accum = 0;
                    for (z = 0; z < window_d; z = z + 1) begin
                        accum = accum + activation_field[z][y][x];
                    end
                    if (window_d > 0)
                        accum = accum / window_d;

                    read_edge_in = accum;
                    read_raw_in  = base_field[0][y][x];
                    #0;

                    readout_raw[y][x]  = read_raw_out_wire;
                    readout_relu[y][x] = read_relu_out_wire;
                    readout_fire[y][x] = read_fire_wire ? 1 : 0;

                    if (read_fire_wire)
                        readout_fire_cells = readout_fire_cells + 1;
                    readout_sum_q = readout_sum_q + read_relu_out_wire;
                end
            end

            if (readout_fire_cells > 0)
                readout_mean_q = readout_sum_q / readout_fire_cells;
            else
                readout_mean_q = 0;
        end
    endtask

    task dump_results;
        integer z, y, x;
        begin
            $display("NAF.window_w=%0d window_h=%0d window_d=%0d pattern_id=%0d iterations=%0d",
                     window_w, window_h, window_d, pattern_id, iterations);
            $display("NAF.config.self_gain_q=%0d planar_gain_q=%0d vertical_gain_q=%0d bias_q=%0d",
                     self_gain_q, planar_gain_q, vertical_gain_q, bias_q);
            $display("NAF.config.feedback_q=%0d damp_q=%0d learning_q=%0d target_q=%0d",
                     feedback_gain_q_per_layer[0], damp_gain_q, learning_q, target_q);
            $display("NAF.readout.edge_gain_q=%0d raw_gain_q=%0d bias_q=%0d threshold_q=%0d",
                     read_edge_gain_q, read_raw_gain_q, read_bias_q, read_threshold_q);

            for (z = 0; z < window_d; z = z + 1) begin
                for (y = 0; y < window_h; y = y + 1) begin
                    for (x = 0; x < window_w; x = x + 1) begin
                        $display("NAF.act[z=%0d,y=%0d,x=%0d]=%0d",
                                 z, y, x, activation_field[z][y][x]);
                    end
                end
            end

            for (y = 0; y < window_h; y = y + 1) begin
                for (x = 0; x < window_w; x = x + 1) begin
                    $display("NAF.readout.raw[%0d,%0d]=%0d", y, x, readout_raw[y][x]);
                end
            end

            for (y = 0; y < window_h; y = y + 1) begin
                for (x = 0; x < window_w; x = x + 1) begin
                    $display("NAF.readout.relu[%0d,%0d]=%0d", y, x, readout_relu[y][x]);
                end
            end

            for (y = 0; y < window_h; y = y + 1) begin
                for (x = 0; x < window_w; x = x + 1) begin
                    $display("NAF.readout.fire[%0d,%0d]=%0d", y, x, readout_fire[y][x]);
                end
            end

            $display("NAF.summary.top_sum_q=%0d top_mean_q=%0d top_active=%0d",
                     top_layer_sum_q, mean_top_q, top_active_cells);
            $display("NAF.summary.readout_fire=%0d readout_mean_q=%0d final_bias_q=%0d error_q=%0d",
                     readout_fire_cells, readout_mean_q, current_bias_q, last_error_q);
        end
    endtask

    integer iter, z;

    initial begin
        if ($value$plusargs("WINDOW_W=%d", window_w));
        if ($value$plusargs("WINDOW_H=%d", window_h));
        if ($value$plusargs("WINDOW_D=%d", window_d));
        if ($value$plusargs("PATTERN_ID=%d", pattern_id));
        if ($value$plusargs("ITERATIONS=%d", iterations));
        if ($value$plusargs("IMAGE_FILE=%s", image_file));

        if ($value$plusargs("SELF_GAIN=%d", self_gain_pct));
        if ($value$plusargs("PLANAR_GAIN=%d", planar_gain_pct));
        if ($value$plusargs("VERT_GAIN=%d", vertical_gain_pct));
        if ($value$plusargs("BIAS_PCT=%d", bias_pct));
        if ($value$plusargs("DAMP_PCT=%d", damp_pct));
        if ($value$plusargs("LEARN_PCT=%d", learning_pct));
        if ($value$plusargs("TARGET_PCT=%d", target_pct));
        if ($value$plusargs("READ_EDGE_PCT=%d", read_edge_pct));
        if ($value$plusargs("READ_RAW_PCT=%d", read_raw_pct));
        if ($value$plusargs("READ_BIAS_PCT=%d", read_bias_pct));
        if ($value$plusargs("READ_THRESH_PCT=%d", read_thresh_pct));

        for (z = 0; z < MAX_D; z = z + 1) begin
            if ($value$plusargs($sformatf("FEEDBACK_L%0d_PCT=%d", z), feedback_pct));
            feedback_gain_q_per_layer[z] = pct_to_q(feedback_pct);
        end

        if (window_w < 2) window_w = 2;
        if (window_h < 2) window_h = 2;
        if (window_d < 1) window_d = 1;
        if (window_w > MAX_W) window_w = MAX_W;
        if (window_h > MAX_H) window_h = MAX_H;
        if (window_d > MAX_D) window_d = MAX_D;
        if (iterations < 1) iterations = 1;

        init_micro_lut;
        clear_buffers;
        load_pattern;

        self_gain_q     = pct_to_q(self_gain_pct);
        planar_gain_q   = pct_to_q(planar_gain_pct);
        vertical_gain_q = pct_to_q(vertical_gain_pct);
        bias_q          = pct_to_q(bias_pct);
        damp_gain_q     = pct_to_q(damp_pct);
        learning_q      = pct_to_q(learning_pct);
        target_q        = pct_to_q(target_pct);
        read_edge_gain_q = pct_to_q(read_edge_pct);
        read_raw_gain_q  = pct_to_q(read_raw_pct);
        read_bias_q      = pct_to_q(read_bias_pct);
        read_threshold_q = pct_to_q(read_thresh_pct);

        current_bias_q = bias_q;

        for (iter = 0; iter < iterations; iter = iter + 1) begin
            compute_neighbor_mix;
            apply_activation;
            apply_feedback;
            update_bias;
            $display("NAF.iter[%0d].bias_q=%0d mean_top_q=%0d error_q=%0d",
                     iter, current_bias_q, mean_top_q, last_error_q);
        end

        apply_readout;
        dump_results;
        $finish;
    end
endmodule
