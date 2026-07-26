module Master #(
    parameter CLK_FREQ = 50000000, // system clock frequency (Hz)
    parameter I2C_FREQ = 100000,    // desired SCL frequency (Hz)
    parameter STRETCH_TIMEOUT = 100000     // max clk cycles to wait for a stretched SCL before aborting
)           (input clk,
             input arst_n,

             // Control Interface
             input start,        // pulse 1 clk to begin a transaction
             input rw,           // 0 = write, 1 = read
             input [6:0] slave_addr,
             input [7:0] data_in,      // byte to write
             output reg [7:0] data_out,     // byte read from slave
             output reg busy,         // high while a transaction is in progress
             output reg done,         // pulses high for 1 clk when finished
             output reg nack_flag,    // high if slave did not ACK
             output reg timeout_error,// high if a stretch timeout aborted the xfer

             // I2C Bus (Open-Drain)
             inout scl,
             inout sda
);

    // Clock divider for 4 phases per SCL cycle
    localparam DIVIDER = CLK_FREQ / (I2C_FREQ * 4);

    // Main FSM states
    parameter IDLE = 4'd0,
              START = 4'd1,
              ADDR = 4'd2,
              ADDR_ACK = 4'd3,
              WR_DATA = 4'd4,
              WR_ACK = 4'd5,
              RD_DATA = 4'd6,
              RD_ACK = 4'd7,
              STOP = 4'd8;

    // Phase states within a single bit period
    parameter SETUP = 2'd0,
              RISE = 2'd1,
              SAMPLE = 2'd2,
              FALL = 2'd3;

    reg [3:0] state;
    reg [1:0] bit_phase;
    reg [15:0] clk_cnt;
    reg i2c_tick;       // 1-cycle pulse, advances FSM once per phase

    reg scl_en;     // 1 = drive SCL low, 0 = release
    reg sda_oe;     // 1 = master drives SDA, 0 = release
    reg sda_out;    // Value driven on SDA when sda_oe = 1

    reg [7:0] shift_reg;  // Address+rw or data byte being shifted out/in
    reg [3:0] bit_cnt;
    reg rw_latch;
    reg [6:0] addr_latch;
    reg [7:0] data_latch;

    // Open-drain bus drivers
    assign scl = scl_en ? 1'b0 : 1'bz;
    assign sda = sda_oe ? sda_out : 1'bz;

    // Asynchronous sampling of SDA line
    wire sda_in = sda;

    // 2-stage Synchroniser
    reg [1:0] scl_sync;
    always @(posedge clk or negedge arst_n) begin
        if (!arst_n) begin
            scl_sync <= 2'b11;
        end
        else begin
            scl_sync <= {scl_sync[0], scl};
        end
    end
    wire scl_curr = scl_sync[1];

    // Clock stretching detection
    wire scl_stalled = (state != IDLE) && (!scl_en) && (!scl_curr);

    reg [31:0] stretch_cnt;
    wire stretch_timeout_hit = scl_stalled && (stretch_cnt == STRETCH_TIMEOUT-1);

    // Phase and i2c_tick generator with clock stretching support
    always @(posedge clk or negedge arst_n) begin
        if (!arst_n) begin            
            bit_phase <= SETUP;
            clk_cnt <= 16'b0;
            i2c_tick <= 1'b0;
            stretch_cnt <= 32'b0;
        end
        else if (scl_stalled) begin
            // Freeze timing progression while waiting for slave to release SCL
            i2c_tick <= 1'b0;
            // Timeout behaviour
            if (stretch_cnt == STRETCH_TIMEOUT-1) begin
                stretch_cnt <= 32'b0;
            end
            else stretch_cnt <= stretch_cnt+1;
        end
        else begin
            stretch_cnt <= 32'b0;
            if (clk_cnt == DIVIDER-1) begin
                clk_cnt <= 16'b0;
                i2c_tick <= 1'b1;
                bit_phase <= bit_phase+1;
            end
            else begin
                clk_cnt <= clk_cnt+1;
                i2c_tick <= 1'b0;
            end
        end
    end

    // Main FSM
    always @(posedge clk or negedge arst_n) begin
        if (!arst_n) begin
            state <= IDLE;
            scl_en <= 1'b0;
            sda_oe <= 1'b1;
            sda_out <= 1'b1;
            bit_cnt <= 4'b0;
            busy <= 1'b0;
            done <= 1'b0;
            nack_flag <= 1'b0;
            timeout_error <= 1'b0;
            data_out <= 8'h00;
        end
        else begin
            done <= 1'b0; // Default pulse signal to low

            if (stretch_timeout_hit) begin
                // Abort transaction if clock stretching exceeds the timeout limit
                state <= IDLE;
                scl_en <= 1'b0;
                sda_oe <= 1'b1;
                sda_out <= 1'b1;
                busy <= 1'b0;
                done <= 1'b1;
                timeout_error <= 1'b1;
            end
            else if (i2c_tick) begin
                timeout_error <= 1'b0; // Clear once a normal tick occurs
                case (state)

                    IDLE: begin
                        scl_en <= 1'b0;   // SCL released (idle high)
                        sda_oe <= 1'b1;
                        sda_out <= 1'b1;   // SDA idle high
                        if (start) begin
                            state <= START;
                            busy <= 1'b1;
                            nack_flag <= 1'b0;
                            rw_latch <= rw;
                            addr_latch <= slave_addr;
                            data_latch <= data_in;
                            bit_phase <= 2'b0;
                        end
                    end

                    START: begin
                        // SDA falls while SCL is high
                        case (bit_phase)
                            SETUP: begin 
                                sda_oe <= 1'b1; 
                                sda_out <= 1'b1; 
                                scl_en <= 1'b0; 
                            end
                            RISE: begin 
                                sda_out <= 1'b1; 
                                scl_en <= 1'b0; 
                            end
                            SAMPLE: begin 
                                sda_out <= 1'b0;
                                scl_en <= 1'b0;
                            end
                            FALL: begin
                                scl_en <= 1'b1;     // Begin toggling (SCL low)
                                shift_reg <= {addr_latch, rw_latch};
                                bit_cnt <= 4'd7;
                                state <= ADDR;
                            end
                        endcase
                    end

                    ADDR: begin
                        // Shift out 7-bit slave address and 1-bit R/W flag (MSB first)
                        case (bit_phase)
                            SETUP: begin
                                scl_en <= 1'b1;
                                sda_oe <= 1'b1;
                                sda_out <= shift_reg[7];
                            end
                            RISE: scl_en <= 1'b0;
                            SAMPLE: scl_en <= 1'b0; // SCL high: slave samples bit
                            FALL: begin
                                scl_en <= 1'b1; // SCL falls
                                if (bit_cnt == 0) begin
                                    state <= ADDR_ACK;
                                end
                                else begin
                                    shift_reg <= shift_reg << 1;
                                    bit_cnt <= bit_cnt-1;
                                end
                            end
                        endcase
                    end

                    ADDR_ACK: begin
                        // Receive acknowledgment bit from slave after address phase
                        case (bit_phase)
                            SETUP: begin 
                                scl_en <= 1'b1;
                                sda_oe <= 1'b0;
                            end
                            RISE: scl_en <= 1'b0;
                            SAMPLE: begin
                                scl_en <= 1'b0;
                                nack_flag <= sda_in;
                            end
                            FALL: begin
                                scl_en <= 1'b1;
                                if (rw_latch == 1'b0) begin
                                    shift_reg <= data_latch;
                                    bit_cnt <= 4'd7;
                                    state <= WR_DATA;
                                end
                                else begin
                                    bit_cnt <= 4'd7;
                                    state <= RD_DATA;
                                end
                            end
                        endcase
                    end

                    WR_DATA: begin
                        // Shift out data byte to write to the slave (MSB first)
                        case (bit_phase)
                            SETUP: begin
                                scl_en <= 1'b1;
                                sda_oe <= 1'b1;
                                sda_out <= shift_reg[7];
                            end
                            RISE: scl_en <= 1'b0;
                            SAMPLE: scl_en <= 1'b0;
                            FALL: begin
                                scl_en <= 1'b1;
                                if (bit_cnt == 4'b0) begin
                                    state <= WR_ACK;
                                end else begin
                                    shift_reg <= shift_reg << 1;
                                    bit_cnt <= bit_cnt-1;
                                end
                            end
                        endcase
                    end

                    WR_ACK: begin
                        // Receive acknowledgment bit from slave after write data phase
                        case (bit_phase)
                            SETUP: begin
                                scl_en <= 1'b1;
                                sda_oe <= 1'b0;
                            end
                            RISE: scl_en <= 1'b0;
                            SAMPLE: begin
                                scl_en <= 1'b0;
                                nack_flag <= sda_in;
                            end
                            FALL: begin
                                scl_en <= 1'b1;
                                state <= STOP;
                            end
                        endcase
                    end

                    RD_DATA: begin
                        // Shift in data byte read from the slave (MSB first)
                        case (bit_phase)
                            SETUP: begin
                                scl_en <= 1'b1;
                                sda_oe <= 1'b0;
                            end
                            RISE: scl_en <= 1'b0;
                            SAMPLE: begin
                                scl_en <= 1'b0;
                                shift_reg <= {shift_reg[6:0], sda_in};
                            end
                            FALL: begin
                                scl_en <= 1'b1;
                                if (bit_cnt == 4'b0) begin
                                    data_out <= shift_reg;
                                    state <= RD_ACK;
                                end 
                                else begin
                                    bit_cnt <= bit_cnt-1;
                                end
                            end
                        endcase
                    end

                    RD_ACK: begin
                        // Send NACK to terminate single-byte read operation
                        case (bit_phase)
                            SETUP: begin
                                scl_en <= 1'b1;
                                sda_oe <= 1'b1;
                                sda_out <= 1'b1; // NACK
                            end
                            RISE: scl_en <= 1'b0;
                            SAMPLE: scl_en <= 1'b0;
                            FALL: begin
                                scl_en <= 1'b1;
                                state <= STOP;
                            end
                        endcase
                    end

                    STOP: begin
                        // SDA rises while SCL is high
                        case (bit_phase)
                            SETUP: begin
                                sda_oe <= 1'b1;
                                sda_out <= 1'b0;
                                scl_en <= 1'b1;
                            end
                            RISE: scl_en <= 1'b0;
                            SAMPLE: begin 
                                sda_out <= 1'b1; 
                                scl_en <= 1'b0; 
                            end
                            FALL: begin
                                state <= IDLE;
                                busy <= 1'b0;
                                done <= 1'b1;
                            end
                    endcase
                end

                    default: state <= IDLE;
                    
                endcase
            end
        end
    end

endmodule
