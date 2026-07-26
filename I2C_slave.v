module Slave #(
    parameter [6:0] SLAVE_ADDR = 7'h50, // Address of the target slave
    parameter STRETCH_CYCLES = 20       // Number of clock cycles to stretch SCL before sending a read byte
)       (input clk,                 // System clock
         input arst_n,              // Asynchronous active-low reset

         // 
         output reg [7:0] rx_data,  // Last byte received from the master
         output reg rx_valid,       // 1-cycle pulse indicating rx_data has been updated
         input [7:0] tx_data,       // Data byte to send back to the master during a read
         output reg busy,           // High while the slave is actively addressed in a transaction

         // I2C bus (open-drain)
         inout scl,
         inout sda
         );

    // FSM states
    parameter IDLE = 4'd0,
              ADDR = 4'd1,
              ADDR_ACK_WAIT = 4'd2,
              ADDR_ACK_STRETCH = 4'd3,
              ADDR_ACK_RISE = 4'd4,
              WR_DATA = 4'd5,
              WR_ACK_WAIT = 4'd6,
              WR_ACK_RISE = 4'd7,
              RD_DATA = 4'd8,
              RD_ACK_WAIT = 4'd9,
              WAIT_STOP = 4'd10;

    reg [3:0] state;

    // 3-Stage Synchronizers
    reg [2:0] scl_sync;
    reg [2:0] sda_sync;
    always @(posedge clk or negedge  arst_n) begin
        if (! arst_n) begin
            scl_sync <= 3'b111;
            sda_sync <= 3'b111;
        end else begin
            scl_sync <= {scl_sync[1:0], scl};
            sda_sync <= {sda_sync[1:0], sda};
        end
    end
    // Sampled line levels after synchronization
    wire sda_curr = sda_sync[1];

    // Edge detectors for SCL line
    wire scl_rising = (scl_sync[2:1] == 2'b01);
    wire scl_falling = (scl_sync[2:1] == 2'b10);

    // START: SDA falls while SCL is stable high
    wire start_cond = (scl_sync[2:1] == 2'b11 && sda_sync[2:1] == 2'b10);
    // STOP: SDA rises while SCL stable high.
    wire stop_cond = (scl_sync[2:1] == 2'b11 && sda_sync[2:1] == 2'b01);

    // Open-drain bus driver control registers
    reg sda_oe;
    reg sda_out;
    reg scl_en; // 1 = Slave holds SCL low (clock stretching)

    // Open-drain control logic
    assign scl = scl_en ? 1'b0 : 1'bz;
    assign sda = sda_oe ? sda_out : 1'bz;

    reg [7:0] shift_reg;    // Shift register for serial-to-parallel / parallel-to-serial conversion (address/data)
    reg [3:0] bit_cnt;      // Bit counter tracking remaining bits to shift in/out for the current byte
    reg rw_latch;           // Latch storing the read/write direction flag from the address byte
    reg [15:0] stretch_cnt; // Counter managing clock stretching duration before transmitting read data

    // Main FSM
    always @(posedge clk or negedge  arst_n) begin
        if (!arst_n) begin
            state <= IDLE;
            sda_oe <= 1'b0;
            sda_out <= 1'b1;
            scl_en <= 1'b0;
            rx_data <= 8'h00;
            rx_valid <= 1'b0;
            busy <= 1'b0;
            shift_reg <= 8'h00;
            bit_cnt <= 4'b0;
            rw_latch <= 1'b0;
            stretch_cnt <= 16'b0;
        end else begin
            rx_valid <= 1'b0; // Default pulse signal to low

            // Stop has highest priority
            if (stop_cond) begin
                state <= IDLE;
                sda_oe <= 1'b0;
                scl_en <= 1'b0;
                busy <= 1'b0;
            end
            
            // Start resets the transaction to address capture
            else if (start_cond) begin
                state <= ADDR;
                bit_cnt <= 4'd7;
                sda_oe <= 1'b0;
                scl_en <= 1'b0;
                busy <= 1'b0;
            end
            else begin
                case (state)

                    IDLE: begin
                        sda_oe <= 1'b0;
                        scl_en <= 1'b0;
                    end

                    ADDR: begin
                        // Shift in 7-bit address and 1-bit R/W flag on every SCL rising edge
                        if (scl_rising) begin
                            shift_reg <= {shift_reg[6:0], sda_curr};
                            if (bit_cnt == 4'b0) begin
                                state <= ADDR_ACK_WAIT;
                            end
                            else begin
                                bit_cnt <= bit_cnt-1;
                            end
                        end
                    end

                    ADDR_ACK_WAIT: begin
                        // Wait for SCL falling edge before responding with an ACK or NACK
                        if (scl_falling) begin
                            if (shift_reg[7:1] == SLAVE_ADDR) begin
                                busy <= 1'b1;
                                rw_latch <= shift_reg[0];
                                sda_oe <= 1'b1;
                                sda_out <= 1'b0; // Send ACK
                                if (shift_reg[0] == 1'b1) begin
                                    // Read: stretch SCL to allow time to load data
                                    scl_en <= 1'b1;
                                    stretch_cnt <= 16'b0;
                                    state <= ADDR_ACK_STRETCH;
                                end
                                else begin
                                    // Write: Proceed directly to rise phase
                                    state <= ADDR_ACK_RISE;
                                end
                            end
                            // Address mismatch
                            else begin
                                sda_oe <= 1'b0; // Send NACK
                                state <= WAIT_STOP;
                            end
                        end
                    end

                    ADDR_ACK_STRETCH: begin
                        // Hold SCL low during clock stretching to prepare read data payload
                        if (stretch_cnt == STRETCH_CYCLES-1) begin
                            shift_reg <= tx_data; 
                            scl_en <= 1'b0;       // Release SCL after data is loaded
                            state <= ADDR_ACK_RISE;
                        end
                        else begin
                            stretch_cnt <= stretch_cnt+1;
                        end
                    end

                    ADDR_ACK_RISE: begin
                        // Wait for SCL falling edge after address ACK before transferring data bits
                        if (scl_falling) begin
                            if (rw_latch == 1'b0) begin
                                sda_oe <= 1'b0;
                                bit_cnt <= 4'd7;
                                state <= WR_DATA;
                            end
                            else begin
                                sda_out <= shift_reg[7];
                                bit_cnt <= 4'd7;
                                state <= RD_DATA;
                            end
                        end
                    end

                    WR_DATA: begin 
                        // Capture data byte sent by the master (MSB first) on SCL rising edges
                        if (scl_rising) begin
                            shift_reg <= {shift_reg[6:0], sda_curr};
                            if (bit_cnt == 4'b0) begin
                                state <= WR_ACK_WAIT;
                            end
                            else begin
                                bit_cnt <= bit_cnt-1;
                            end
                        end
                    end

                    WR_ACK_WAIT: begin
                        // Prepare to acknowledge the successfully received data byte
                        if (scl_falling) begin
                            rx_data <= shift_reg;
                            rx_valid <= 1'b1;
                            sda_oe <= 1'b1;
                            sda_out <= 1'b0; // Send ACK
                            state <= WR_ACK_RISE;
                        end
                    end

                    WR_ACK_RISE: begin
                        // Release SDA after write ACK phase and wait for transaction completion
                        if (scl_falling) begin
                            sda_oe <= 1'b0;
                            busy <= 1'b0;
                            state <= WAIT_STOP;
                        end
                    end

                    RD_DATA: begin
                        // Shift out data byte bits to the master on SCL falling edges
                        if (scl_falling) begin
                            if (bit_cnt == 0) begin
                                sda_oe <= 1'b0; // Release SDA to receive Master's ACK/NACK
                                state <= RD_ACK_WAIT;
                            end
                            else begin
                                shift_reg <= shift_reg << 1;
                                sda_out <= shift_reg[6];
                                bit_cnt <= bit_cnt-1;
                            end
                        end
                    end

                    RD_ACK_WAIT: begin
                        // Handle the final phase of a read transaction before stopping
                        if (scl_falling) begin
                            busy <= 1'b0;
                            state <= WAIT_STOP;
                        end
                    end

                    WAIT_STOP: begin
                        sda_oe <= 1'b0;
                        scl_en <= 1'b0;
                    end

                    default: state <= IDLE;
                endcase
            end
        end
    end

endmodule
