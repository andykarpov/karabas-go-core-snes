-- The microcode tables of the 65C816 (MCode) and the SPC700 (SPC700_MCode) against the upstream
-- versions (ref/, entities renamed *_ref): the karabas change reads the table with a register
-- without reset (block RAM) and gives the reset / STATE 0 value with a flag. Random IR, STATE,
-- EN and resets, every output after every clock. Words of the table that are don't care ('X'
-- in upstream) are not compared.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

library work;

entity tb_eq_mcode is
end entity;

architecture sim of tb_eq_mcode is
	signal clk, rst_n, en : std_logic := '0';
	signal ir : std_logic_vector(7 downto 0) := (others => '0');
	signal state : unsigned(3 downto 0) := (others => '0');
	signal m_new, m_ref : work.P65816_pkg.MCode_r;
	signal s_new, s_ref : work.SPC700_pkg.MCode_r;
	signal done : boolean := false;

	function to_slv(m : work.P65816_pkg.MCode_r) return std_logic_vector is
	begin
		return m.ALU_CTRL.fstOp & m.ALU_CTRL.secOp & m.ALU_CTRL.fc & m.ALU_CTRL.w16 &
			m.STATE_CTRL & m.ADDR_BUS & m.ADDR_INC & m.IND_CTRL & m.ADDR_CTRL & m.LOAD_PC &
			m.LOAD_SP & m.LOAD_AXY & m.LOAD_P & m.LOAD_T & m.LOAD_DKB & m.BUS_CTRL &
			m.BYTE_SEL & m.OUT_BUS & m.VA;
	end function;

	function to_slv(m : work.SPC700_pkg.MCode_r) return std_logic_vector is
	begin
		return m.ALU_CTRL.fstOp & m.ALU_CTRL.secOp & m.ALU_CTRL.chgVO & m.ALU_CTRL.chgHO &
			m.ALU_CTRL.intC & m.ALU_CTRL.chgCO & m.ALU_CTRL.w &
			m.STATE_CTRL & m.ADDR_BUS & m.ADDR_CTRL & m.LOAD_PC & m.LOAD_SP & m.LOAD_AXY &
			m.LOAD_P & m.LOAD_T & m.BUS_CTRL & m.OUT_BUS;
	end function;

	-- equal where ref is a defined bit
	function same(a, ref : std_logic_vector) return boolean is
	begin
		for i in ref'range loop
			if (ref(i) = '0' or ref(i) = '1') and a(i) /= ref(i) then
				return false;
			end if;
		end loop;
		return true;
	end function;
begin
	cpu_new : entity work.MCode port map(clk, rst_n, en, ir, state, m_new);
	cpu_ref : entity work.MCode_ref port map(clk, rst_n, en, ir, state, m_ref);
	spc_new : entity work.SPC700_MCode port map(clk, rst_n, en, ir, state, s_new);
	spc_ref : entity work.SPC700_MCode_ref port map(clk, rst_n, en, ir, state, s_ref);

	clk <= not clk after 5 ns when not done;

	stim : process
		variable s1, s2 : positive := 7;
		variable r : real;
		variable errors, checks : natural := 0;
	begin
		for n in 0 to 200000 loop
			-- inputs change at the falling edge
			wait until falling_edge(clk);
			uniform(s1, s2, r); ir <= std_logic_vector(to_unsigned(integer(trunc(r * 256.0)), 8));
			uniform(s1, s2, r); state <= to_unsigned(integer(trunc(r * 16.0)), 4);
			uniform(s1, s2, r); if r < 0.7 then en <= '1'; else en <= '0'; end if;
			uniform(s1, s2, r); if n < 3 or r < 0.002 then rst_n <= '0'; else rst_n <= '1'; end if;
			wait until rising_edge(clk);
			wait for 1 ns;
			checks := checks + 1;
			if not same(to_slv(m_new), to_slv(m_ref)) then
				errors := errors + 1;
				if errors < 10 then report "MCode differs at check " & integer'image(checks) severity error; end if;
			end if;
			if not same(to_slv(s_new), to_slv(s_ref)) then
				errors := errors + 1;
				if errors < 10 then report "SPC700_MCode differs at check " & integer'image(checks) severity error; end if;
			end if;
		end loop;
		report "tb_eq_mcode: " & integer'image(errors) & " errors" severity note;
		done <= true;
		wait;
	end process;
end architecture;
