-- sprom with a write port (FPGA build; the sim uses sprom_wr in sprom.v).
-- The BASIC ROM: read on address, written by the OSD's Load ROM (ioctl index 0).
-- altsyncram simple dual port: port A writes, port B reads, init from init_file.
LIBRARY ieee;
USE ieee.std_logic_1164.all;

LIBRARY altera_mf;
USE altera_mf.all;

ENTITY sprom_wr IS
	GENERIC
	(
		init_file : string := "";
		widthad_a : natural;
		width_a   : natural := 8
	);
	PORT
	(
		clock      : IN  STD_LOGIC;
		address    : IN  STD_LOGIC_VECTOR (widthad_a-1 DOWNTO 0);
		q          : OUT STD_LOGIC_VECTOR (width_a-1 DOWNTO 0);
		wr         : IN  STD_LOGIC;
		wr_address : IN  STD_LOGIC_VECTOR (widthad_a-1 DOWNTO 0);
		wr_data    : IN  STD_LOGIC_VECTOR (width_a-1 DOWNTO 0)
	);
END sprom_wr;

ARCHITECTURE SYN OF sprom_wr IS

	COMPONENT altsyncram
	GENERIC (
		address_aclr_b         : STRING;
		address_reg_b          : STRING;
		clock_enable_input_a   : STRING;
		clock_enable_input_b   : STRING;
		clock_enable_output_b  : STRING;
		init_file              : STRING;
		intended_device_family : STRING;
		lpm_type               : STRING;
		numwords_a             : NATURAL;
		numwords_b             : NATURAL;
		operation_mode         : STRING;
		outdata_aclr_b         : STRING;
		outdata_reg_b          : STRING;
		power_up_uninitialized : STRING;
		read_during_write_mode_mixed_ports : STRING;
		widthad_a              : NATURAL;
		widthad_b              : NATURAL;
		width_a                : NATURAL;
		width_b                : NATURAL;
		width_byteena_a        : NATURAL
	);
	PORT (
		address_a : IN  STD_LOGIC_VECTOR (widthad_a-1 DOWNTO 0);
		clock0    : IN  STD_LOGIC;
		data_a    : IN  STD_LOGIC_VECTOR (width_a-1 DOWNTO 0);
		q_b       : OUT STD_LOGIC_VECTOR (width_a-1 DOWNTO 0);
		wren_a    : IN  STD_LOGIC;
		address_b : IN  STD_LOGIC_VECTOR (widthad_a-1 DOWNTO 0)
	);
	END COMPONENT;

BEGIN

	altsyncram_component : altsyncram
	GENERIC MAP (
		address_aclr_b         => "NONE",
		address_reg_b          => "CLOCK0",
		clock_enable_input_a   => "BYPASS",
		clock_enable_input_b   => "BYPASS",
		clock_enable_output_b  => "BYPASS",
		init_file              => init_file,
		intended_device_family => "Cyclone V",
		lpm_type               => "altsyncram",
		numwords_a             => 2**widthad_a,
		numwords_b             => 2**widthad_a,
		operation_mode         => "DUAL_PORT",
		outdata_aclr_b         => "NONE",
		outdata_reg_b          => "UNREGISTERED",
		power_up_uninitialized => "FALSE",
		read_during_write_mode_mixed_ports => "DONT_CARE",
		widthad_a              => widthad_a,
		widthad_b              => widthad_a,
		width_a                => width_a,
		width_b                => width_a,
		width_byteena_a        => 1
	)
	PORT MAP (
		address_a => wr_address,
		clock0    => clock,
		data_a    => wr_data,
		wren_a    => wr,
		address_b => address,
		q_b       => q
	);

END SYN;
