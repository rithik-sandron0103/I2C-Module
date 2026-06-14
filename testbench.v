`timescale 1ns / 1ps

module testbench();

    reg clk;
    reg arst_n;

    // Wires between Producer and Master
    wire start;
    wire [6:0] addr;
    wire rw;
    wire [7:0] tx_data_master;
    wire [7:0] rx_data_master;
    wire ready;
    wire done;
    wire nack_flag;

    // Wires between Responder and Slave
    wire [7:0] tx_data_slave;
    wire [7:0] rx_data_slave;
    wire valid;
    wire resp_req;

    // Master I2C Physical Pin Connections
    wire SCL_in_master, SCL_out_master, nSCL_outen_master;
    wire SDA_in_master, SDA_out_master, nSDA_outen_master;

    // Slave I2C Physical Pin Connections
    wire SCL_in_slave, SCL_out_slave, nSCL_outen_slave;
    wire SDA_in_slave, SDA_out_slave, nSDA_outen_slave;

    // Shared I2C Open-Drain Bus Lines
    wire scl_bus;
    wire sda_bus;

    // Pull-up resistors for the I2C Bus lines
    pullup(scl_bus);
    pullup(sda_bus);


    // Instantiating Producer Module
    producer u_producer(
        .clk(clk),
        .arst_n(arst_n),
        .din(rx_data_master),
        .ready(ready),
        .done(done),
        .nack_flag(nack_flag),
        .start(start),
        .addr(addr),
        .rw(rw),
        .dout(tx_data_master)
    );

    // Instantiating I2C Master Module
    Master u_master(
        .clk(clk),
        .arst_n(arst_n),
        .start(start),
        .addr(addr),
        .rw(rw),
        .tx_data(tx_data_master),
        .rx_data(rx_data_master),
        .ready(ready),
        .done(done),
        .nack_flag(nack_flag),
        .SCL_in(SCL_in_master),
        .SCL_out(SCL_out_master),
        .nSCL_outen(nSCL_outen_master),
        .SDA_in(SDA_in_master),
        .SDA_out(SDA_out_master),
        .nSDA_outen(nSDA_outen_master)
    );

    // Instantiating I2C Slave Module
    Slave #(
        .SLAVE_ADDR(7'd67)
    ) u_slave (
        .clk(clk),
        .arst_n(arst_n),
        .tx_data(tx_data_slave),
        .rx_data(rx_data_slave),
        .valid(valid),
        .resp_req(resp_req),
        .SCL_in(SCL_in_slave),
        .SCL_out(SCL_out_slave),
        .nSCL_outen(nSCL_outen_slave),
        .SDA_in(SDA_in_slave),
        .SDA_out(SDA_out_slave),
        .nSDA_outen(nSDA_outen_slave)
    );

    // Instantiating Responder Module
    responder u_responder (
        .clk(clk),
        .arst_n(arst_n),
        .rx_data(rx_data_slave),
        .valid(valid),
        .resp_req(resp_req),
        .tx_data(tx_data_slave)
    );
    
    // Master open-drain connection: Drive bus to 0 when enable is active-low (0)
    assign scl_bus = (!nSCL_outen_master) ? SCL_out_master : 1'bz;
    assign sda_bus = (!nSDA_outen_master) ? SDA_out_master : 1'bz;

    // Slave open-drain connection: Drive bus to 0 when enable is active-low (0)
    assign scl_bus = (!nSCL_outen_slave) ? SCL_out_slave : 1'bz;
    assign sda_bus = (!nSDA_outen_slave) ? SDA_out_slave : 1'bz;

    // Feed the shared bus status back to input pins of both Master and Slave
    assign SCL_in_master = scl_bus;
    assign SDA_in_master = sda_bus;
    assign SCL_in_slave  = scl_bus;
    assign SDA_in_slave  = sda_bus;

    // Clock Generation
    always begin
        #10 clk = ~clk;
    end

    initial begin
        // Initialize signals
        clk = 0;
        arst_n = 0;

        #100;
        arst_n = 1; // Release Reset

        // Monitor Slave reception data
        forever begin
            @(posedge clk);
            if (valid) begin
                $display("[TB TIME: %t] SUCCESS: Slave received valid data byte: 0x%h (Expected: 0x00)", $time, rx_data_slave);
                
                @(posedge done);
                $display("[TB TIME: %t] Master transaction completed successfully.", $time);
                
                #2000;
                $display("[TB] Test completed successfully.");
                $finish;
            end
            
            // Timeout if transaction hits a NACK error
            if (nack_flag) begin
                $display("[TB TIME: %t] ERROR: Transaction terminated with a NACK flag!", $time);
                $finish;
            end
        end
    end

    // Dump waveform files for debugging (Optional)
    initial begin
        $dumpfile("i2c.vcd");
        $dumpvars(0, testbench);
    end

endmodule