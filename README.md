# Parameterized I2C Module Verilog Implementation

## Overview
This project implements a robust, fully parameterized, and synthesizable I2C (Inter-Integrated Circuit) communication system in Verilog. It features a modular master–slave architecture with open-drain bus drivers, multi-phase bit timing, clock-stretching support (with timeout), and clean start/stop condition handling.
The design demonstrates correct master–slave interaction through an automated testbench that exercises write transactions, read transactions (with slave-side stretching), and address-mismatch NACK behavior.

## Architecture & Design
The I2C system is organized around synchronous control logic, multi-stage synchronization, phase-accurate bit timing, and safe open-drain signaling:
- **Clock Generation & Scaling**: A parameterized divider (`CLK_FREQ / (I2C_FREQ * 4)`) produces four evenly spaced phases per SCL cycle, giving precise control over setup, rise, sample, and fall intervals.
- **Phase-Partitioned Bit Transfer**: Each bit period is split into four phases (`SETUP` -> `RISE` -> `SAMPLE` -> `FALL`). This makes it straightforward to obey the fundamental I2C rule that **SDA may change only while SCL is low and must be stable while SCL is high**. Data is driven in the `SETUP`/`FALL` windows and sampled in the SAMPLE window when SCL is high.
- **Clock Stretching**: The slave can hold SCL low after an address ACK (for reads) to gain extra cycles for loading transmit data. The master detects a stalled SCL (released by the master but still low), freezes its phase counter, and aborts with a `timeout_error` if the stretch exceeds `STRETCH_TIMEOUT` cycles.
- **Open-Drain Bus Logic**: Both SCL and SDA are driven only to logic-0 and are released to high-impedance (`1'bz`) otherwise. External pull-ups restore the high level. This permits any device to safely pull a line low and allows true multi-master/multi-slave sharing.
- **Clock-Domain Crossing (CDC)**: Synchronizers on SCL/SDA together with edge detectors guarantee metastability-safe sampling of the asynchronous bus.
- **FSM States**:
 - Master FSM - Advances on every i2c_tick:
   <p align="center">`IDLE` -> `START` -> `ADDR` -> `ADDR_ACK` -> (`WR_DATA` -> `WR_ACK` or `RD_DATA` -> `RD_ACK`) -> `STOP` -> `IDLE`</p>
  - `IDLE` releases the bus and a `start` pulse latches parameters and begins the transfer.
  - `START` forms the start condition and loads the address + R/W byte.
  - `ADDR` shifts the eight bits out.
  - `ADDR_ACK` samples the slave’s ACK/NACK and branches to write or read.
  - Write path shifts the data byte and samples its ACK whereas the read path samples eight bits then drives a NACK.
  - `STOP` forms the stop condition, clears `busy` and pulses `done`.
  - Stretch timeout can abort any non-idle state back to `IDLE`.
 - Slave FSM - Primarily edge-driven (Start/Stop detection + SCL edges):
   <p align="center">`IDLE` -> `ADDR` -> `ADDR_ACK_WAIT` -> (`ADDR_ACK_STRETCH` ->) `ADDR_ACK_RISE` -> (`WR_DATA` -> `WR_ACK_WAIT` -> `WR_ACK_RISE` or `RD_DATA` -> `RD_ACK_WAIT`) -> `WAIT_STOP` -> `IDLE`</p>
  - `IDLE` keeps the bus released. A start condition moves the FSM to `ADDR` and resets the bit counter.
  - `ADDR` shifts in the seven address bits plus the R/W bit on successive rising edges of SCL.
  - `ADDR_ACK_WAIT` waits for the falling edge of SCL after the last address bit, compares the received address with `SLAVE_ADDR`, and either prepares an ACK or a NACK.
  - On a matching read address, the slave enters `ADDR_ACK_STRETCH`, actively holds SCL low for `STRETCH_CYCLES` while it loads `tx_data` into the shift register, then releases SCL and proceeds to `ADDR_ACK_RISE`.
  - On a matching write address (or after stretch) `ADDR_ACK_RISE` waits for the next falling edge and branches to the appropriate data path.
  - Write path (`WR_DATA`/`WR_ACK_WAIT`/`WR_ACK_RISE`) captures the incoming byte on rising edges, asserts `rx_valid` for one cycle, drives an ACK, then releases SDA.
  - Read path (`RD_DATA`/`RD_ACK_WAIT`) shifts the pre-loaded byte out on falling edges of SCL. After the eighth bit it releases SDA so the master can drive its ACK/NACK.
  - Both paths end in `WAIT_STOP`, which holds the bus released until a stop condition returns the FSM to `IDLE`.
  - A stop condition has highest priority and forces an immediate return to `IDLE` from any state.
