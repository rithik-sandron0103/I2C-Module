module responder(input clk,
                 input arst_n,

                 // Slave interface
                 input [7:0] rx_data,
                 input valid,
                 input resp_req,
                 output reg [7:0] tx_data);

    reg [7:0] tx_counter;

    // Track the previous resp_req to detect rising edge
    reg resp_req_prev;

    always @(posedge clk or negedge arst_n) begin
        if (!arst_n) begin
            tx_counter <= 8'h55;
            tx_data <= 8'h55;
            resp_req_prev <= 0;
        end
        else begin
            resp_req_prev <= resp_req;

            // On rising edge of resp_req, present current counter value and pre-increment for the next request
            if (resp_req && !resp_req_prev) begin
                tx_data <= tx_counter;
                tx_counter <= tx_counter+1;
            end
        end
    end
endmodule
