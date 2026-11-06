# Bug log

Record every bug your tests find: what failed, the root cause, and the fix. Interviewers ask about this.
The first entries are from building this reference version; add your own below them.

| # | Found by | Symptom | Root cause | Fix |
| --- | --- | --- | --- | --- |
| 1 | cocotb `test_wstrb` | Partial write to A_BUF with WSTRB=0010 returned SLVERR | Decoder required `addr[1:0] == 0`; the AXI master put the byte offset in AWADDR for a 1-byte write | Decode on word address only; WSTRB selects byte lanes |
| 2 | cocotb `test_back_to_back` | Second run read C while still BUSY | STATUS.DONE from the first run stayed set, so polling for DONE returned immediately | Accepted START now clears DONE (documented in regmap) |
| 3 | cocotb `test_busy_access` | CTRL write "while busy" returned OKAY | Test bug: three earlier accesses took longer than the 13-cycle run, so the core was already idle | Test now issues one illegal access per run, directly after START |
| 4 | Yosys 0.33 | `syntax error, unexpected TOK_INT` | Yosys 0.33 does not parse `int'(...)` casts | Rewrote skew and decode logic without casts |
| | | | | |
