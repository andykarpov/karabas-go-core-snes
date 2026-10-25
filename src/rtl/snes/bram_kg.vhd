-- karabas: replacement of bram.vhd of SNES_MiSTer (altsyncram of Altera) with memories that XST
-- infers as block RAM. The entities, generics and ports are those of bram.vhd, so the upstream
-- sources instantiate them unchanged.
--
-- Behaviour of the altsyncram configuration of bram.vhd:
--   address and write data registered, read data not registered (one clock of latency);
--   a port reads the new data while it writes (NEW_DATA_NO_NBE_READ: write first);
--   enable_* is the clock enable of the port, cs_* gates its write and drives its read data to
--   all ones when low; the memory starts at zero (power_up_uninitialized FALSE) unless
--   mem_init_file names a file.
-- mem_init_file: a text file read by XST (std.textio, one word per line in binary, MSB first,
-- path relative to the directory XST runs in), " " for none. The .mif files of upstream are
-- converted to it (tools/mif2bin.py).
-- dpram_dif with different widths: only data_width_b = 2 * data_width_a and
-- addr_width_b = addr_width_a - 1 (the OAM of the PPU). Word n of port b is the words 2n (low
-- half) and 2n + 1 (high half) of port a, as altsyncram orders them.
-- dpram_difclk of bram.vhd is not used by the sources of this core and not provided.

--------------------------------------------------------------
-- Single port RAM of numwords words (a ROM with mem_init_file)
--------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity spram_sz is
	generic (
		addr_width    : integer := 8;
		data_width    : integer := 8;
		numwords      : integer := 2**8;
		mem_init_file : string := " ";
		mem_name      : string := "MEM"
	);
	port
	(
		clock   : in  std_logic;
		address : in  std_logic_vector(addr_width-1 downto 0);
		data    : in  std_logic_vector(data_width-1 downto 0) := (others => '0');
		enable  : in  std_logic := '1';
		wren    : in  std_logic := '0';
		q       : out std_logic_vector(data_width-1 downto 0);
		cs      : in  std_logic := '1'
	);
end entity;

architecture rtl of spram_sz is
	type ram_t is array (0 to numwords-1) of std_logic_vector(data_width-1 downto 0);

	impure function ram_init(name : string) return ram_t is
		file f : text;
		variable l : line;
		variable w : bit_vector(data_width-1 downto 0);
		variable r : ram_t := (others => (others => '0'));
	begin
		if name /= " " then
			file_open(f, name, read_mode);
			for i in 0 to numwords-1 loop
				exit when endfile(f);
				readline(f, l);
				read(l, w);
				r(i) := to_stdlogicvector(w);
			end loop;
			file_close(f);
		end if;
		return r;
	end function;

	signal ram : ram_t := ram_init(mem_init_file);
	signal q0 : std_logic_vector(data_width-1 downto 0) := (others => '0');
begin
	q <= q0 when cs = '1' else (others => '1');

	process (clock)
		variable a : integer range 0 to 2**addr_width-1;
	begin
		if rising_edge(clock) then
			if enable = '1' then
				a := to_integer(unsigned(address));
				if a < numwords then
					if wren = '1' and cs = '1' then
						ram(a) <= data;
						q0 <= data;
					else
						q0 <= ram(a);
					end if;
				end if;
			end if;
		end if;
	end process;
end architecture;

--------------------------------------------------------------
-- Single port RAM, 2**addr_width words
--------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;

entity spram is
	generic (
		addr_width    : integer := 8;
		data_width    : integer := 8;
		mem_init_file : string := " ";
		mem_name      : string := "MEM"
	);
	port
	(
		clock   : in  std_logic;
		address : in  std_logic_vector(addr_width-1 downto 0);
		data    : in  std_logic_vector(data_width-1 downto 0) := (others => '0');
		enable  : in  std_logic := '1';
		wren    : in  std_logic := '0';
		q       : out std_logic_vector(data_width-1 downto 0);
		cs      : in  std_logic := '1'
	);
end entity;

architecture rtl of spram is
begin
	ram : entity work.spram_sz
	generic map(addr_width, data_width, 2**addr_width, mem_init_file, mem_name)
	port map(clock, address, data, enable, wren, q, cs);
end architecture;

--------------------------------------------------------------
-- True dual port RAM, one clock, the same width on both ports
--------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity kg_bram_tdp is
	generic (
		addr_width : integer := 8;
		data_width : integer := 8
	);
	port
	(
		clock     : in  std_logic;
		address_a : in  std_logic_vector(addr_width-1 downto 0);
		data_a    : in  std_logic_vector(data_width-1 downto 0);
		enable_a  : in  std_logic;
		wren_a    : in  std_logic;
		q_a       : out std_logic_vector(data_width-1 downto 0);
		address_b : in  std_logic_vector(addr_width-1 downto 0);
		data_b    : in  std_logic_vector(data_width-1 downto 0);
		enable_b  : in  std_logic;
		wren_b    : in  std_logic;
		q_b       : out std_logic_vector(data_width-1 downto 0)
	);
end entity;

architecture rtl of kg_bram_tdp is
	type ram_t is array (0 to 2**addr_width-1) of std_logic_vector(data_width-1 downto 0);
	shared variable ram : ram_t := (others => (others => '0'));
	signal qa, qb : std_logic_vector(data_width-1 downto 0) := (others => '0');
begin
	q_a <= qa;
	q_b <= qb;

	process (clock)
	begin
		if rising_edge(clock) then
			if enable_a = '1' then
				if wren_a = '1' then
					ram(to_integer(unsigned(address_a))) := data_a;
				end if;
				qa <= ram(to_integer(unsigned(address_a)));
			end if;
		end if;
	end process;

	process (clock)
	begin
		if rising_edge(clock) then
			if enable_b = '1' then
				if wren_b = '1' then
					ram(to_integer(unsigned(address_b))) := data_b;
				end if;
				qb <= ram(to_integer(unsigned(address_b)));
			end if;
		end if;
	end process;
end architecture;

--------------------------------------------------------------
-- Dual port RAM, different widths on the ports
--------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;

entity dpram_dif is
	generic (
		addr_width_a  : integer := 8;
		data_width_a  : integer := 8;
		addr_width_b  : integer := 8;
		data_width_b  : integer := 8;
		mem_init_file : string := " "
	);
	port
	(
		clock     : in  std_logic;

		address_a : in  std_logic_vector(addr_width_a-1 downto 0);
		data_a    : in  std_logic_vector(data_width_a-1 downto 0) := (others => '0');
		enable_a  : in  std_logic := '1';
		wren_a    : in  std_logic := '0';
		q_a       : out std_logic_vector(data_width_a-1 downto 0);
		cs_a      : in  std_logic := '1';

		address_b : in  std_logic_vector(addr_width_b-1 downto 0) := (others => '0');
		data_b    : in  std_logic_vector(data_width_b-1 downto 0) := (others => '0');
		enable_b  : in  std_logic := '1';
		wren_b    : in  std_logic := '0';
		q_b       : out std_logic_vector(data_width_b-1 downto 0);
		cs_b      : in  std_logic := '1'
	);
end entity;

architecture rtl of dpram_dif is
	signal q0 : std_logic_vector(data_width_a-1 downto 0);
	signal q1 : std_logic_vector(data_width_b-1 downto 0);
	signal we_a, we_b : std_logic;
begin
	q_a <= q0 when cs_a = '1' else (others => '1');
	q_b <= q1 when cs_b = '1' else (others => '1');
	we_a <= wren_a and cs_a;
	we_b <= wren_b and cs_b;

	same : if data_width_a = data_width_b generate
		ram : entity work.kg_bram_tdp
		generic map(addr_width_a, data_width_a)
		port map(clock, address_a, data_a, enable_a, we_a, q0, address_b, data_b, enable_b, we_b, q1);
	end generate;

	-- two banks of port a words: bank 0 the even addresses (low half of a port b word)
	dif : if data_width_a /= data_width_b generate
		signal sel_a : std_logic := '0';
		signal we0_a, we1_a : std_logic;
		signal q0_0, q0_1 : std_logic_vector(data_width_a-1 downto 0);
	begin
		assert data_width_b = 2 * data_width_a and addr_width_b = addr_width_a - 1
			report "dpram_dif: only data_width_b = 2 * data_width_a is supported" severity failure;

		we0_a <= we_a and not address_a(0);
		we1_a <= we_a and address_a(0);

		process (clock)
		begin
			if rising_edge(clock) then
				if enable_a = '1' then
					sel_a <= address_a(0);
				end if;
			end if;
		end process;
		q0 <= q0_1 when sel_a = '1' else q0_0;

		bank0 : entity work.kg_bram_tdp
		generic map(addr_width_b, data_width_a)
		port map(clock, address_a(addr_width_a-1 downto 1), data_a, enable_a, we0_a, q0_0,
			address_b, data_b(data_width_a-1 downto 0), enable_b, we_b, q1(data_width_a-1 downto 0));

		bank1 : entity work.kg_bram_tdp
		generic map(addr_width_b, data_width_a)
		port map(clock, address_a(addr_width_a-1 downto 1), data_a, enable_a, we1_a, q0_1,
			address_b, data_b(data_width_b-1 downto data_width_a), enable_b, we_b, q1(data_width_b-1 downto data_width_a));
	end generate;
end architecture;

--------------------------------------------------------------
-- Dual port RAM, the same width on both ports
--------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;

entity dpram is
	generic (
		addr_width    : integer := 8;
		data_width    : integer := 8;
		mem_init_file : string := " "
	);
	port
	(
		clock     : in  std_logic;

		address_a : in  std_logic_vector(addr_width-1 downto 0);
		data_a    : in  std_logic_vector(data_width-1 downto 0) := (others => '0');
		enable_a  : in  std_logic := '1';
		wren_a    : in  std_logic := '0';
		q_a       : out std_logic_vector(data_width-1 downto 0);
		cs_a      : in  std_logic := '1';

		address_b : in  std_logic_vector(addr_width-1 downto 0) := (others => '0');
		data_b    : in  std_logic_vector(data_width-1 downto 0) := (others => '0');
		enable_b  : in  std_logic := '1';
		wren_b    : in  std_logic := '0';
		q_b       : out std_logic_vector(data_width-1 downto 0);
		cs_b      : in  std_logic := '1'
	);
end entity;

architecture rtl of dpram is
begin
	ram : entity work.dpram_dif
	generic map(addr_width, data_width, addr_width, data_width, mem_init_file)
	port map(clock, address_a, data_a, enable_a, wren_a, q_a, cs_a, address_b, data_b, enable_b, wren_b, q_b, cs_b);
end architecture;
