module producer(input clk,
                input arst_n,
                
                // Master interface
                input [7:0] din,
                input ready,
                input done,
                input nack_flag,
                output reg start,
                output reg [6:0] addr,
                output reg rw,
                output reg [7:0] dout);

    reg [7:0] tx_counter;

    parameter IDLE = 2'd0,
              SEND = 2'd1,
              WAIT = 2'd2;

    reg [1:0] state;

    always @(posedge clk or negedge arst_n) begin
        if (!arst_n) begin
            state <= IDLE;
            start <= 0;
            addr <= 7'd0;
            rw <= 0;
            dout <= 8'd0;
            tx_counter <= 8'd0;
        end
        else begin
            case (state)
                // Wait until master is ready, then start writing
                IDLE: begin
                    start <= 0;
                    if (ready) begin
                        addr <= 7'd67; // Target slave address
                        rw <= 1'b0; // Write
                        dout <= tx_counter;
                        start <= 1'b1;
                        state <= SEND;
                    end
                end

                // Hold start high for one cycle, then wait for completion
                SEND: begin
                    start <= 0;
                    state <= WAIT;
                end

                // Wait for the master to signal done, then advance the counter
                WAIT: begin
                    if (done) begin
                        tx_counter <= tx_counter + 8'd1;
                        state <= IDLE;
                    end
                end
                default: state <= IDLE;
            endcase
        end
    end
endmodule
