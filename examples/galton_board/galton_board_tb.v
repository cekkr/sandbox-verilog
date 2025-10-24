`timescale 1ns/1ps

`include "sand_defs.vh"

module galton_board_tb;
    localparam integer Q_ONE = (1 << `FRAC_W);
    localparam integer MAX_W = `WIDTH;
    localparam integer MAX_H = `HEIGHT;

    // Configurable parameters via plusargs (thousandths of 1.0)
    integer left_pct  = 500;
    integer right_pct = -1;
    integer board_w   = 15;
    integer board_h   = 16;

    // Internal derived values
    integer left_q;
    integer right_q;
    integer straight_q;
    integer steps_to_run;
    integer total_mass;

    // Weight storage per peg (rows 0..board_h-2)
    integer weight_left  [0:MAX_H-2][0:MAX_W-1];
    integer weight_right [0:MAX_H-2][0:MAX_W-1];

    // Mass buffers for current and next row
    integer row_curr [0:MAX_W-1];
    integer row_next [0:MAX_W-1];

    function integer mul_fraction;
        input integer value;
        input integer weight;
        integer product;
        begin
            product = value * weight;
            mul_fraction = product >> `FRAC_W;
        end
    endfunction

    task initialise_weights;
        integer y, x;
        begin
            for (y = 0; y < MAX_H-1; y = y + 1) begin
                for (x = 0; x < MAX_W; x = x + 1) begin
                    if (x >= board_w) begin
                        weight_left[y][x]  = 0;
                        weight_right[y][x] = 0;
                    end else begin
                        weight_left[y][x]  = (x == 0) ? 0 : left_q;
                        weight_right[y][x] = (x == (board_w-1)) ? 0 : right_q;
                    end
                end
            end
        end
    endtask

    task propagate_board;
        integer step, x;
        integer idx;
        integer left_flow;
        integer right_flow;
        integer straight_flow;
        integer lr_sum;
        begin
            for (idx = 0; idx < MAX_W; idx = idx + 1) begin
                row_curr[idx] = 0;
                row_next[idx] = 0;
            end
            row_curr[board_w/2] = Q_ONE[`DATA_W-1:0];

            for (step = 0; step < steps_to_run; step = step + 1) begin
                for (idx = 0; idx < MAX_W; idx = idx + 1) begin
                    row_next[idx] = 0;
                end
                for (x = 0; x < board_w; x = x + 1) begin
                    integer mass_now;
                    mass_now = row_curr[x];
                    if (mass_now != 0) begin
                        left_flow  = mul_fraction(mass_now, weight_left[step][x]);
                        right_flow = mul_fraction(mass_now, weight_right[step][x]);
                        lr_sum     = left_flow + right_flow;
                        if (lr_sum > mass_now) begin
                            integer excess;
                            excess = lr_sum - mass_now;
                            if (left_flow >= excess) begin
                                left_flow = left_flow - excess;
                            end else begin
                                excess = excess - left_flow;
                                left_flow = 0;
                                if (right_flow >= excess)
                                    right_flow = right_flow - excess;
                                else
                                    right_flow = 0;
                            end
                            straight_flow = 0;
                        end else begin
                            straight_flow = mass_now - lr_sum;
                        end

                        row_next[x] = row_next[x] + straight_flow;
                        if (x > 0)
                            row_next[x-1] = row_next[x-1] + left_flow;
                        else
                            row_next[x] = row_next[x] + left_flow;

                        if (x < (board_w-1))
                            row_next[x+1] = row_next[x+1] + right_flow;
                        else
                            row_next[x] = row_next[x] + right_flow;
                    end
                end

                for (x = 0; x < board_w; x = x + 1) begin
                    row_curr[x] = row_next[x];
                end
            end
        end
    endtask

    task dump_results;
        integer x;
        begin
            total_mass = 0;
            for (x = 0; x < board_w; x = x + 1) begin
                total_mass = total_mass + row_curr[x];
            end

            $display("GALTON.width=%0d height=%0d board_w=%0d board_h=%0d steps=%0d",
                     `WIDTH, `HEIGHT, board_w, board_h, steps_to_run);
            $display("GALTON.weights.left_q=%0d right_q=%0d straight_q=%0d total_mass=%0d",
                     left_q, right_q, straight_q, total_mass);

            for (x = 0; x < board_w; x = x + 1) begin
                $display("GALTON.bin[%0d]=%0d", x, row_curr[x]);
            end
        end
    endtask

    initial begin
        if ($value$plusargs("LEFT_PCT=%d", left_pct));
        if ($value$plusargs("RIGHT_PCT=%d", right_pct));
        if ($value$plusargs("BOARD_W=%d", board_w));
        if ($value$plusargs("BOARD_H=%d", board_h));

        if (board_w < 3) board_w = 3;
        if (board_w > MAX_W) board_w = MAX_W;
        if (board_h < 2) board_h = 2;
        if (board_h > MAX_H) board_h = MAX_H;

        if (right_pct < 0) right_pct = 1000 - left_pct;
        if (left_pct < 0) left_pct = 0;
        if (right_pct < 0) right_pct = 0;
        if (left_pct + right_pct > 1000) begin
            if (right_pct > left_pct)
                right_pct = 1000 - left_pct;
            else
                left_pct = 1000 - right_pct;
        end

        left_q  = (left_pct  * Q_ONE) / 1000;
        right_q = (right_pct * Q_ONE) / 1000;
        straight_q = Q_ONE - left_q - right_q;
        if (straight_q < 0) straight_q = 0;

        steps_to_run = board_h - 1;

        initialise_weights;
        propagate_board;
        dump_results;
        $finish;
    end
endmodule
