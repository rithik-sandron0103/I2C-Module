`timescale 1ns/1ps

module testbench;

    reg clk;
    reg arst_n;

    // Pull-ups for open-drain I2C bus lines
    wire scl, sda;
    pullup(scl);
    pullup(sda);

    // Master control and status interface signals
    reg start;
    reg rw;
    reg [6:0] slave_addr;
    reg [7:0] data_in;
    wire [7:0] data_out;
    wire busy;
    wire done;
    wire nack_flag;
    wire timeout_error;

    // Slave backend data and status signals
    wire [7:0] rx_data;
    wire rx_valid;
    reg [7:0] tx_data;
    wire slave_busy;

    localparam CLK_FREQ = 1000000; // 1MHz simulation system clock
    localparam I2C_FREQ = 100000;  // 100kHz target I2C clock frequency

    // Master Instantiation
    Master #(
        .CLK_FREQ(CLK_FREQ),
        .I2C_FREQ(I2C_FREQ),
        .STRETCH_TIMEOUT(50000)
    ) master (
        .clk(clk),
        .arst_n( arst_n),
        .start(start),
        .rw(rw),
        .slave_addr(slave_addr),
        .data_in(data_in),
        .data_out(data_out),
        .busy(busy),
        .done(done),
        .nack_flag(nack_flag),
        .timeout_error(timeout_error),
        .scl(scl),
        .sda(sda)
    );

    // Slave Instantiation
    Slave #(
        .SLAVE_ADDR(7'h50),
        .STRETCH_CYCLES(20)
    ) slave (
        .clk(clk),
        . arst_n( arst_n),
        .scl(scl),
        .sda(sda),
        .rx_data(rx_data),
        .rx_valid(rx_valid),
        .tx_data(tx_data),
        .busy(slave_busy)
    );

    // System clock generation
    initial begin
        clk = 0;
    end 
    always begin
        #10 clk = ~clk;
    end

    // Waveform dumping
    initial begin
        $dumpfile("i2c.vcd");
        $dumpvars(0, testbench);
    end

    // Monitoring Master FSM state changes
    always @(master.state) begin
        $display("[%0t] MASTER state=%0d phase=%0d scl_en=%0d", 
                $time, master.state, master.bit_phase, master.scl_en);
    end

    // Monitoring Slave FSM state changes
    always @(slave.state) begin
        $display("[%0t] SLAVE  state=%0d scl_en=%0d sda_oe=%0d",
                $time, slave.state, slave.scl_en, slave.sda_oe);
    end

    // Main test sequence block
    initial begin

        // Initialisation
        arst_n = 1'b0;
        start = 1'b0;
        rw = 1'b0;
        slave_addr = 7'h50;
        data_in = 8'h00;
        tx_data = 8'hA5;

        // Releasing reset
        repeat (5) @(posedge clk);
        arst_n = 1'b1;
        repeat (5) @(posedge clk);

        // Write Test

        @(posedge clk);
        slave_addr = 7'h50; // Correct slave address
        rw = 1'b0;          // 0 for write
        data_in = 8'hC3;    // Master writes 8'hC3 to slave

        start = 1'b1;
        @(posedge clk);
        start = 1'b0;

        wait (done == 1'b1); // Wait for the master to complete the write transaction

        @(posedge clk);
        if (nack_flag) begin
            // Check if slave failed to acknowledge
            $display("FAIL: write got NACK");
        end
        else if (rx_data !== 8'hC3) begin
            // Check if received data does not match expected value
            $display("FAIL: slave rx_data=%h expected 0xC3", rx_data);
        end
        else begin
            // Confirm successful write transfer
            $display("PASS: write transaction, slave captured rx_data=%h", rx_data);
        end

        repeat (20) @(posedge clk);
        $display("[%0t] TB: about to start READ, busy=%0d done=%0d",
                 $time, busy, done);

        // Read Test
        tx_data = 8'h7E;    // Preset data that slave will return during read
        slave_addr = 7'h50;
        rw = 1'b1;          // 1 for read operation

        start = 1'b1;
        repeat (4) @(posedge clk);
        start = 1'b0;

        wait (done == 1'b1); // Wait for master to complete the read transaction
        
        @(posedge clk);
        if (nack_flag) begin
            // Check if master failed to acknowledge
            $display("FAIL: read got NACK on address");
        end
        else if (data_out !== 8'h7E) begin
            // Check if received data does not match expected value
            $display("FAIL: master data_out=%h expected 0x7E", data_out);
        end
        else begin
            // Confirm successful read transfer
            $display("PASS: read transaction, master data_out=%h", data_out);
        end

        repeat (20) @(posedge clk);

        // Address Mismatch Test (Verifying nack/ack behaviour)

        slave_addr = 7'h11; // Non-existent slave address
        rw = 1'b0;
        data_in = 8'hFF;

        start = 1'b1;
        repeat (4) @(posedge clk);
        start = 1'b0;

        wait (done == 1'b1);    // Wait for master to complete the write transaction

        @(posedge clk);
        if (nack_flag) begin
            // Confirm correct NACK response for non-existent address
            $display("PASS: mismatched address correctly NACKed");
        end
        else begin
            // Flag error if slave improperly acknowledged an invalid address
            $display("FAIL: expected NACK for mismatched address");
        end

        repeat (10) @(posedge clk);
        $display("SIM DONE");
        $finish;
    end

    // Safety timeout
    initial begin
        #2000000;
        $display("TIMEOUT: simulation did not finish in time");
        $finish;
    end

endmodule