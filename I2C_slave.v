module Slave(input clk,
             input arst_n,
             
             // Responder interface
             input [7:0] tx_data,
             output reg [7:0] rx_data,
             output reg valid,
             output reg resp_req,

             // I2C interface
             input wire SCL_in,
             output wire SCL_out,
             output wire nSCL_outen,
             input wire SDA_in,
             output wire SDA_out,
             output wire nSDA_outen);

    // Device Address
    parameter SLAVE_ADDR = 7'd67;
    
    reg [2:0] scl_sync;
    reg [2:0] sda_sync;

    // Synchronization
    always @(posedge clk or negedge arst_n) begin
        if (!arst_n) begin
            scl_sync <= 3'b111;
            sda_sync <= 3'b111;
        end
        else begin
            scl_sync <= {scl_sync[2:1], SCL_in};
            sda_sync <= {sda_sync[2:1], SDA_in};
        end
    end

    // Current values
    wire scl_curr = scl_sync[1];
    wire sda_curr = sda_sync[1];

    // Detecting changes
    wire scl_posedge = (scl_sync[2:1] == 2'b01);
    wire scl_negedge = (scl_sync[2:1] == 2'b10);
    wire sda_rising = (sda_sync[2:1] == 2'b01);
    wire sda_falling = (sda_sync[2:1] == 2'b10);

    // Start and stop conditions
    wire start_cond = (scl_curr && sda_rising);
    wire stop_cond = (scl_curr && sda_falling);

    // States
    parameter IDLE = 0,
              ADDR = 1, 
              ACK_ADDR = 2, 
              WR_DATA = 3, 
              RD_DATA = 4, 
              ACK_DATA = 5;

    reg [2:0] state;
    reg [2:0] bit_cnt;
    reg [7:0] shift_reg;
    reg rw;

    // Internal wires
    reg sda_out;
    reg sda_outen;

    // FSM
    always @(posedge clk or negedge arst_n) begin
        if (!arst_n) begin
            state <= IDLE;
            bit_cnt <= 3'b0;
            shift_reg <= 8'b0;
            rx_data <= 8'b0;
            rw <= 0;
            valid <= 0;
            resp_req <= 0;
            sda_out <= 1;
            sda_outen <= 0;
        end
        else begin
            if (start_cond) begin
                state <= ADDR;
                bit_cnt <= 3'd7;
                sda_outen <= 0;
                resp_req <= 0;
            end
            else if (stop_cond) begin
                state <= IDLE;
                sda_outen <= 0;
                resp_req <= 0;
            end
            else begin
                case(state)
                    IDLE: begin
                        sda_outen <= 0;
                        sda_out <= 1;
                        resp_req <= 0;
                        valid <= 0;
                    end

                    ADDR: begin
                        if (scl_posedge) shift_reg[bit_cnt] <= sda_curr;
                        else if (scl_negedge) begin
                            if (bit_cnt == 3'b0) begin
                                if (shift_reg[7:1] == SLAVE_ADDR) begin
                                    state <= ACK_ADDR;
                                    rw <= shift_reg[0];
                                    if (shift_reg[0] == 1) resp_req <= 1;
                                end
                                else state <= IDLE;
                            end
                            else bit_cnt <= bit_cnt-1;
                        end
                    end

                    ACK_ADDR: begin
                        if (scl_negedge) begin
                            if (rw) begin
                                state <= RD_DATA;
                                bit_cnt <= 3'd7;
                                shift_reg <= tx_data;
                                sda_out <= tx_data[7];
                                sda_outen <= 1;
                            end
                            else begin
                                state <= WR_DATA;
                                bit_cnt <= 3'd7
                                sda_outen <= 0;
                            end
                        end
                        else begin
                            sda_out <= 0;
                            sda_outen <= 1;
                        end
                    end

                    RD_DATA: begin
                        if (scl_negedge) begin
                            if (bit_cnt == 3'b0) begin
                                state <= ACK_DATA;
                                sda_outen <= 0;
                                resp_req <= 0;
                            end
                            else begin
                                sda_out <= shift_reg[bit_cnt-1];
                                sda_outen <= 1;
                                bit_cnt <= bit_cnt-1;
                            end
                        end
                    end

                    WR_DATA: begin
                        if (scl_posedge) shift_reg[bit_cnt] <= sda_curr;
                        else if (scl_negedge) begin
                            if (bit_cnt == 3'b0) begin
                                state <= ACK_DATA;
                                rx_data <= shift_reg;
                                valid <= 1;
                            end
                            else bit_cnt <= bit_cnt-1;
                        end
                    end

                    ACK_DATA: begin
                        if (rw) begin
                            if (scl_posedge) begin
                                if (sda_curr == 1) state <= IDLE
                            end
                            if (scl_negedge) sda_outen <= 0;
                        end
                        else begin
                            sda_outen <= 1;
                            sda_out <= 0;
                            if (scl_negedge) begin
                                state <= IDLE;
                                sda_outen <= 0;
                                valid <= 0;
                            end
                        end
                    end

                    default: state <= IDLE;
                endcase
            end
        end
    end

    // Slave deosn't drive SCL
    assign SCL_out = 0;
    assign nSCL_outen = 1;

    // Open drain pin control
    assign SDA_out = 0;
    assign nSDA_outen = !sda_out || !sda_outen;
endmodule