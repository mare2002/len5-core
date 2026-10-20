// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Included only by the simulation wrapper. u_sram.sram is the authoritative array.
function automatic void put_byte(logic [63:0] address, logic [7:0] value);
  if (memory_backend_pkg::in_region(address, 1, BASE_ADDR, 64'(SIZE_BYTES))) begin
    // Initialization precedes requests; each instance deposits only its own absolute addresses.
    /* verilator lint_off BLKSEQ */
    u_sram.sram[ADDR_WIDTH'((address-BASE_ADDR)/64'(WORD_BYTES))]
        [int'((address-BASE_ADDR)%64'(WORD_BYTES))*8+:8] = value;
    /* verilator lint_on BLKSEQ */
  end else if (!memory_backend_pkg::in_region(address, 1, OTHER_BASE_ADDR, 64'(OTHER_SIZE_BYTES))) begin
    $fatal(1, "Firmware byte at 0x%h is outside IMEM/DMEM", address);
  end
endfunction

// Tokenizer for byte-wide readmemh files, including both Verilog comment forms.
function automatic string hex_token(int fd);
  string token = "";
  int c, next_c, prev_c;
  while (1) begin
    c = $fgetc(fd);
    if (c == -1) return token;
    if (c == 32 || c == 9 || c == 10 || c == 13) begin
      if (token.len() != 0) return token;
    end else if (c == 47) begin
      next_c = $fgetc(fd);
      if (next_c == 47) begin
        do c = $fgetc(fd); while (c != -1 && c != 10);
      end else if (next_c == 42) begin
        prev_c = 0;
        do begin
          c = $fgetc(fd);
          if (c == -1) $fatal(1, "Unterminated firmware comment");
          if (prev_c == 42 && c == 47) break;
          prev_c = c;
        end while (1);
      end else $fatal(1, "Invalid '/' in firmware hex");
      if (token.len() != 0) return token;
    end else if (c != 95) token = {token, byte'(c)};
  end
  return token;
endfunction

function automatic logic [63:0] parse_hex(string token, int max_digits);
  logic [63:0] value;
  if (token.len() == 0 || token.len() > max_digits) $fatal(1, "Invalid firmware token '%s'", token);
  for (int i = 0; i < token.len(); i++) begin
    if (!((token[i] >= "0" && token[i] <= "9") || (token[i] >= "a" && token[i] <= "f") ||
          (token[i] >= "A" && token[i] <= "F")))
      $fatal(1, "Invalid firmware hex '%s'", token);
  end
  if ($sscanf(token, "%h", value) != 1) $fatal(1, "Invalid firmware hex '%s'", token);
  return value;
endfunction

function automatic void load_firmware();
  string path = "firmware.hex";
  string ext, token, line, addr_token, data_token;
  logic [63:0] address = 0;
  logic [63:0] value;
  int fd, c, fields;
  longint unsigned count = 0;
  bit exhausted = 0;
  void'($value$plusargs("firmware=%s", path));
  void'($value$plusargs("firmware_base=%h", address));
  ext = path.len() >= 3 ? path.substr(path.len() - 3, path.len() - 1) : "";
  fd  = $fopen(path, "rb");
  if (fd == 0) $fatal(1, "Cannot open TC_SRAM firmware '%s'", path);
  if (ext == "hex") begin
    token = hex_token(fd);
    while (token.len() != 0) begin
      if (token[0] == "@") begin
        address   = parse_hex(token.substr(1, token.len() - 1), 16);
        exhausted = 0;
      end else begin
        if (exhausted) $fatal(1, "Firmware byte address overflow");
        value = parse_hex(token, 2);
        put_byte(address, value[7:0]);
        exhausted = address == '1;
        address++;
        count++;
      end
      token = hex_token(fd);
    end
  end else if (ext == "txt") begin
    while ($fgets(
        line, fd
    ) != 0) begin
      fields = $sscanf(line, "%s %s", addr_token, data_token);
      if (fields == 0) continue;
      if (fields != 2) $fatal(1, "Expected address/word pair in '%s'", path);
      address = parse_hex(addr_token, 16);
      value   = parse_hex(data_token, 8);
      if (address > 64'hffff_ffff_ffff_fffc) $fatal(1, "Firmware word address overflow");
      for (int b = 0; b < 4; b++) put_byte(address + 64'(b), value[b*8+:8]);
      count += 4;
    end
  end else begin
    c = $fgetc(fd);
    while (c != -1) begin
      if (exhausted) $fatal(1, "Firmware byte address overflow");
      put_byte(address, 8'(c));
      exhausted = address == '1;
      address++;
      count++;
      c = $fgetc(fd);
    end
  end
  $fclose(fd);
  if (count == 0) $fatal(1, "Empty TC_SRAM firmware '%s'", path);
  $display("[TC_SRAM] Processed %0d firmware bytes for SRAM at 0x%h from %s", count, BASE_ADDR, path);
endfunction
