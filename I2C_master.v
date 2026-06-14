module Master(input clk,
              input arst_n,

              // Producer Interface
              input start,
              input [6:0] addr,
              input rw,                 // 1 for read & 0 for write
              input [7:0] tx_data,
              output reg [7:0] rx_data,
              output reg ready,
              output reg done,
              output reg nack_flag,

              // I2C pins
              input wire SCL_in,
              output wire SCL_out,
              output wire nSCL_outen,
              input wire SDA_in,
              output wire SDA_out,
              output wire nSDA_outen);
    
    reg [6:0] clk_cnt;
    reg i2c_tick; //Once every 125 cycles

    // Clock tick generation
    always @(posedge clk or negedge arst_n) begin
        if (!arst_n) begin
            clk_cnt <= 7'b0;
            i2c_tick <= 0;
        end
        else begin
            if (clk_cnt == 7'd124) begin
                clk_cnt <= 7'd0;
                i2c_tick <= 1;
            end
            else begin
                clk_cnt <= clk_cnt+1;
                i2c_tick <= 0;
            end
        end
    end

    parameter IDLE = 0,
              START = 1, 
              ADDR = 2, 
              ACK_ADDR = 3, 
              WR_DATA = 4, 
              RD_DATA = 5, 
              ACK_DATA = 6, 
              STOP = 7;

    reg [2:0] state;

    parameter SETUP = 0,
              RISE = 1,
              SAMPLE = 2,
              FALL = 3;

    reg [1:0] bit_phase;

    reg [2:0] bit_cnt;
    reg [7:0] shift_reg;

    // Internal registers
    reg scl_out, sda_out;
    reg scl_outen, sda_outen;

    // FSM
    always @(posedge clk or negedge arst_n) begin
        if (!arst_n) begin
            state <= IDLE;
            bit_phase <= 2'b0;
            bit_cnt <= 3'b0;
            shift_reg <= 8'b0;
            rx_data <= 8'b0;
            ready <= 1;
            done <= 0;
            nack_flag <= 0;
            scl_out <= 1;
            sda_out <= 1;
            scl_outen <= 0;
            sda_outen <= 0;
        end
        else if (i2c_tick) begin
            case (state)
                IDLE: begin
                    bit_phase <= 2'b0;
                    ready <= 1;
                    done <= 0;
                    scl_out <= 1;
                    sda_out <= 1;
                    scl_outen <= 0;
                    sda_outen <= 0;

                    if (start) begin
                        state <= START;
                        shift_reg <= {addr, rw};
                        ready <= 0;
                        nack_flag <= 0;
                    end
                end

                START: begin
                    bit_phase <= bit_phase+1;
                    if (bit_phase == SETUP) begin
                        sda_out <= 1;
                        scl_out <= 1;
                        sda_outen <= 1;
                        scl_outen <= 1;
                    end
                    else if (bit_phase == RISE) sda_out <= 0;   // Start bit
                    else if (bit_phase == SAMPLE) scl_out <= 0; // Now, we can change SDA
                    else if (bit_phase == FALL) begin
                        state <= ADDR;
                        bit_phase <= SETUP;
                        bit_cnt <= 3'd7;
                    end
                end

                ADDR: begin
                    bit_phase <= bit_phase+1;
                    if (bit_phase == SETUP) begin
                        sda_outen <= 1;
                        sda_out <= shift_reg[bit_cnt]; // Start transmission from MSB
                    end
                    else if (bit_phase == RISE) scl_out <= 1; // SCL Rises
                    else if (bit_phase == FALL) begin
                        scl_out <= 0;                         // SCL Falls
                        if (bit_cnt == 3'b0) begin
                            state <= ACK_ADDR;
                            bit_phase <= SETUP;
                        end
                        else bit_cnt <= bit_cnt-1;
                    end
                end

                ACK_ADDR: begin
                    bit_phase <= bit_phase+1;
                    if (bit_phase == SETUP) sda_outen <= 0; // Let SLave respond with acknowlege bit
                    else if (bit_phase == RISE) scl_out <= 1;
                    else if (bit_phase == SAMPLE) begin
                        if (SDA_in == 1) nack_flag <= 1;
                    end
                    else if (bit_phase == FALL) begin
                        scl_out <= 0;
                        if (nack_flag) state <= STOP;
                        else if (rw) begin
                            state <= RD_DATA;
                            bit_phase <= SETUP;
                            bit_cnt <= 3'd7;
                        end
                        else if (!rw) begin
                            state <= WR_DATA;
                            bit_phase <= SETUP;
                            bit_cnt <= 3'd7;
                            shift_reg <= tx_data;
                        end
                    end
                end

                RD_DATA: begin
                    bit_phase <= bit_phase+1;
                    if (bit_phase == SETUP) sda_outen <= 0; // Let Slave write
                    else if (bit_phase == RISE) scl_out <= 1;
                    else if (bit_phase == SAMPLE) shift_reg[bit_cnt] <= SDA_in; // Sampling
                    else if (bit_phase == FALL) begin
                        scl_out <= 0;
                        if (bit_cnt == 3'b0) begin
                            rx_data <= {shift_reg[7:1], SDA_in};
                            state <= ACK_DATA;
                            bit_phase <= SETUP;
                        end
                        else bit_cnt <= bit_cnt-1;
                    end
                end

                WR_DATA: begin
                    bit_phase <= bit_phase+1;
                    if (bit_phase == SETUP) begin
                        sda_outen <= 1;
                        sda_out <= shift_reg[bit_cnt];
                    end
                    else if (bit_phase == RISE) scl_out <= 1;
                    else if (bit_phase == FALL) begin
                        scl_out <= 0;
                        if (bit_cnt == 3'b0)  begin
                            state <= ACK_DATA;
                            bit_phase <= SETUP;
                        end
                        else bit_cnt <= bit_cnt-1;
                    end
                end

                ACK_DATA: begin
                    bit_phase <= bit_phase+1;
                    if (bit_phase == SETUP) begin
                        if (rw) begin
                            sda_outen <= 1; // Enable to write to slave
                            sda_out <= 0;   // ACK bit sent from master
                        end
                        else sda_outen <= 0; // Disable to let slave write
                    end
                    else if (bit_phase == RISE) scl_out <= 1;
                    else if (bit_phase == SAMPLE) begin
                        if (rw == 0 && SDA_in == 1) nack_flag <= 1; 
                    end
                    else if (bit_phase == FALL) begin
                        scl_out <= 0;
                        state <= STOP;
                        bit_phase <= SETUP;
                    end
                end

                STOP: begin
                    bit_phase <= bit_phase+1;
                    if (bit_phase == SETUP) begin
                        sda_outen <= 1;
                        sda_out <= 0;
                    end
                    else if (bit_phase == RISE) scl_out <= 1;
                    else if (bit_phase == SAMPLE) sda_out <= 1; // Stop bit
                    else if (bit_phase == FALL) begin
                        done <= 1;
                        state <= IDLE;
                        bit_phase <= SETUP;
                    end 
                end
            endcase
        end
    end

    // Open Drain Pin Control
    assign SCL_out = 0;
    assign nSCL_outen = !scl_out || !scl_outen;

    assign SDA_out = 0;
    assign nSDA_outen = !sda_out || !sda_outen;
endmodule