-- Crypto: SHA-256, HMAC-SHA256, PBKDF2-HMAC-SHA256, AES-256-GCM (encryption)
-- and Base64 in plain Lua 5.3, for the inverter login. The HC3 offers no
-- cryptographic functions, so everything is implemented here.

App.Crypto = {}
local Crypto = App.Crypto

local M32 = 0xffffffff
local spack, sunpack, schar, sbyte, srep = string.pack, string.unpack, string.char, string.byte, string.rep

-- SHA-256 -------------------------------------------------------------------

local K = {
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}
local H0 = { 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19 }

local W = {}

-- One compression: state h (8 words) and message words w (16) -> new state in out.
local function compress(h, w, out)
  for i = 1, 16 do W[i] = w[i] end
  for i = 17, 64 do
    local x, y = W[i - 15], W[i - 2]
    local s0 = ((x >> 7) | (x << 25)) ~ ((x >> 18) | (x << 14)) ~ (x >> 3)
    local s1 = ((y >> 17) | (y << 15)) ~ ((y >> 19) | (y << 13)) ~ (y >> 10)
    W[i] = (W[i - 16] + s0 + W[i - 7] + s1) & M32
  end
  local a, b, c, d, e, f, g, hh = h[1], h[2], h[3], h[4], h[5], h[6], h[7], h[8]
  for i = 1, 64 do
    local S1 = ((e >> 6) | (e << 26)) ~ ((e >> 11) | (e << 21)) ~ ((e >> 25) | (e << 7))
    local ch = (e & f) ~ (~e & g)
    local t1 = hh + (S1 & M32) + (ch & M32) + K[i] + W[i]
    local S0 = ((a >> 2) | (a << 30)) ~ ((a >> 13) | (a << 19)) ~ ((a >> 22) | (a << 10))
    local maj = (a & b) ~ (a & c) ~ (b & c)
    local t2 = (S0 & M32) + maj
    hh, g, f, e, d, c, b, a = g, f, e, (d + t1) & M32, c, b, a, (t1 + t2) & M32
  end
  out[1], out[2], out[3], out[4] = (h[1] + a) & M32, (h[2] + b) & M32, (h[3] + c) & M32, (h[4] + d) & M32
  out[5], out[6], out[7], out[8] = (h[5] + e) & M32, (h[6] + f) & M32, (h[7] + g) & M32, (h[8] + hh) & M32
  return out
end

local function wordsOf(s, pos)
  return { sunpack(">I4I4I4I4I4I4I4I4I4I4I4I4I4I4I4I4", s, pos) }
end

local function digestOf(h)
  return spack(">I4I4I4I4I4I4I4I4", h[1], h[2], h[3], h[4], h[5], h[6], h[7], h[8])
end

-- State after hashing `data` (length a multiple of 64) from `h`.
local function absorb(h, data)
  local state = { h[1], h[2], h[3], h[4], h[5], h[6], h[7], h[8] }
  for pos = 1, #data, 64 do compress(state, wordsOf(data, pos), state) end
  return state
end

-- Finish a hash whose first `prefixLen` bytes are already in `h`.
local function finish(h, tail, prefixLen)
  local total = prefixLen + #tail
  local padded = tail .. "\128" .. srep("\0", (55 - total) % 64) .. spack(">I8", total * 8)
  return digestOf(absorb(h, padded))
end

function Crypto.sha256(data)
  return finish(H0, data, 0)
end

-- HMAC-SHA256 ---------------------------------------------------------------

local function hmacStates(key)
  if #key > 64 then key = Crypto.sha256(key) end
  key = key .. srep("\0", 64 - #key)
  local ipad = key:gsub(".", function(ch) return schar(sbyte(ch) ~ 0x36) end)
  local opad = key:gsub(".", function(ch) return schar(sbyte(ch) ~ 0x5c) end)
  return absorb(H0, ipad), absorb(H0, opad)
end

function Crypto.hmac(key, message)
  local inner, outer = hmacStates(key)
  return finish(outer, finish(inner, message, 64), 64)
end

-- PBKDF2-HMAC-SHA256 for one 32-byte block, computed in slices:
-- `step(n)` runs up to n further rounds and returns the key once all are done.
function Crypto.pbkdf2Stepper(password, salt, rounds)
  local inner, outer = hmacStates(password)
  local u = { sunpack(">I4I4I4I4I4I4I4I4", Crypto.hmac(password, salt .. "\0\0\0\1")) }
  local t = { u[1], u[2], u[3], u[4], u[5], u[6], u[7], u[8] }
  -- A 32-byte message after a 64-byte key block: one padded block, length 768 bits.
  local block = { 0, 0, 0, 0, 0, 0, 0, 0, 0x80000000, 0, 0, 0, 0, 0, 0, 768 }
  local mid = {}
  local done = 1
  return function(n)
    local stop = math.min(done + n, rounds)
    for _ = done + 1, stop do
      for i = 1, 8 do block[i] = u[i] end
      compress(inner, block, mid)
      for i = 1, 8 do block[i] = mid[i] end
      compress(outer, block, u)
      for i = 1, 8 do t[i] = t[i] ~ u[i] end
    end
    done = stop
    if done >= rounds then return digestOf(t) end
    return nil
  end
end

function Crypto.pbkdf2(password, salt, rounds)
  return Crypto.pbkdf2Stepper(password, salt, rounds)(rounds)
end

-- AES-256 (encryption only) --------------------------------------------------

local SBOX = {}
do
  -- Generate the S-box from GF(2^8) inverses.
  local p, q = 1, 1
  repeat
    p = p ~ ((p << 1) & 0xff) ~ ((p & 0x80) ~= 0 and 0x1b or 0)
    q = q ~ (q << 1); q = q ~ (q << 2); q = q ~ (q << 4); q = q & 0xff
    if q & 0x80 ~= 0 then q = q ~ 0x09 end
    local x = q ~ ((q << 1) | (q >> 7)) ~ ((q << 2) | (q >> 6)) ~ ((q << 3) | (q >> 5)) ~ ((q << 4) | (q >> 4))
    SBOX[p] = (x ~ 0x63) & 0xff
  until p == 1
  SBOX[0] = 0x63
end

local function xtime(b) return ((b << 1) ~ ((b & 0x80) ~= 0 and 0x1b or 0)) & 0xff end

local function expandKey(key)
  local w = { sbyte(key, 1, 32) }
  local rcon = 1
  for i = 33, 240, 4 do
    local t1, t2, t3, t4 = w[i - 4], w[i - 3], w[i - 2], w[i - 1]
    local n = (i - 1) // 4
    if n % 8 == 0 then
      t1, t2, t3, t4 = SBOX[t2] ~ rcon, SBOX[t3], SBOX[t4], SBOX[t1]
      rcon = xtime(rcon)
    elseif n % 8 == 4 then
      t1, t2, t3, t4 = SBOX[t1], SBOX[t2], SBOX[t3], SBOX[t4]
    end
    w[i], w[i + 1], w[i + 2], w[i + 3] = w[i - 32] ~ t1, w[i - 31] ~ t2, w[i - 30] ~ t3, w[i - 29] ~ t4
  end
  return w
end

local function encryptBlock(rk, block)
  local s = { sbyte(block, 1, 16) }
  for i = 1, 16 do s[i] = s[i] ~ rk[i] end
  for round = 1, 14 do
    local t = {}
    for i = 1, 16 do t[i] = SBOX[s[i]] end
    -- ShiftRows (state is column-major: s[1..4] is column 0)
    s = { t[1], t[6], t[11], t[16], t[5], t[10], t[15], t[4], t[9], t[14], t[3], t[8], t[13], t[2], t[7], t[12] }
    if round < 14 then
      for c = 0, 3 do
        local a0, a1, a2, a3 = s[c * 4 + 1], s[c * 4 + 2], s[c * 4 + 3], s[c * 4 + 4]
        local all = a0 ~ a1 ~ a2 ~ a3
        s[c * 4 + 1] = a0 ~ all ~ xtime(a0 ~ a1)
        s[c * 4 + 2] = a1 ~ all ~ xtime(a1 ~ a2)
        s[c * 4 + 3] = a2 ~ all ~ xtime(a2 ~ a3)
        s[c * 4 + 4] = a3 ~ all ~ xtime(a3 ~ a0)
      end
    end
    local off = round * 16
    for i = 1, 16 do s[i] = s[i] ~ rk[off + i] end
  end
  return schar(table.unpack(s))
end

-- GCM -------------------------------------------------------------------------

-- Multiply two 128-bit values (hi, lo as 64-bit integers) in GF(2^128).
local function gmul(xh, xl, yh, yl)
  local zh, zl, vh, vl = 0, 0, yh, yl
  for i = 0, 127 do
    local bit = i < 64 and (xh >> (63 - i)) & 1 or (xl >> (127 - i)) & 1
    if bit == 1 then zh, zl = zh ~ vh, zl ~ vl end
    local lsb = vl & 1
    vl = (vl >> 1) | (vh << 63)
    vh = vh >> 1
    if lsb == 1 then vh = vh ~ (0xe1 << 56) end
  end
  return zh, zl
end

local function ghash(hh, hl, data)
  local yh, yl = 0, 0
  data = data .. srep("\0", (16 - #data % 16) % 16)
  for pos = 1, #data, 16 do
    local bh, bl = sunpack(">i8i8", data, pos)
    yh, yl = gmul(yh ~ bh, yl ~ bl, hh, hl)
  end
  return yh, yl
end

local function inc32(block)
  local prefix, counter = sunpack(">c12I4", block)
  return prefix .. spack(">I4", (counter + 1) & M32)
end

local function xorStrings(a, b)
  local out = {}
  for i = 1, #a do out[i] = schar(sbyte(a, i) ~ sbyte(b, i)) end
  return table.concat(out)
end

--- AES-256-GCM encryption without additional data. Returns ciphertext, tag.
function Crypto.aesGcmEncrypt(key, iv, plaintext)
  local rk = expandKey(key)
  local hh, hl = sunpack(">i8i8", encryptBlock(rk, srep("\0", 16)))
  local j0
  if #iv == 12 then
    j0 = iv .. "\0\0\0\1"
  else
    local lenBlock = spack(">i8i8", 0, #iv * 8)
    local jh, jl = ghash(hh, hl, iv .. srep("\0", (16 - #iv % 16) % 16) .. lenBlock)
    j0 = spack(">i8i8", jh, jl)
  end
  local counter, parts = j0, {}
  for pos = 1, #plaintext, 16 do
    counter = inc32(counter)
    local chunk = plaintext:sub(pos, pos + 15)
    parts[#parts + 1] = xorStrings(chunk, encryptBlock(rk, counter))
  end
  local ciphertext = table.concat(parts)
  local padded = ciphertext .. srep("\0", (16 - #ciphertext % 16) % 16)
  local sh, sl = ghash(hh, hl, padded .. spack(">i8i8", 0, #ciphertext * 8))
  local tag = xorStrings(spack(">i8i8", sh, sl), encryptBlock(rk, j0))
  return ciphertext, tag
end

-- Base64 ----------------------------------------------------------------------

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64INDEX = {}
for i = 1, 64 do B64INDEX[B64:sub(i, i)] = i - 1 end

function Crypto.b64encode(data)
  local out = {}
  for pos = 1, #data, 3 do
    local a, b, c = sbyte(data, pos, pos + 2)
    local n = (a << 16) | ((b or 0) << 8) | (c or 0)
    out[#out + 1] = B64:sub((n >> 18) + 1, (n >> 18) + 1) .. B64:sub(((n >> 12) & 63) + 1, ((n >> 12) & 63) + 1)
      .. (b and B64:sub(((n >> 6) & 63) + 1, ((n >> 6) & 63) + 1) or "=")
      .. (c and B64:sub((n & 63) + 1, (n & 63) + 1) or "=")
  end
  return table.concat(out)
end

function Crypto.b64decode(text)
  text = text:gsub("[^%w+/]", "")
  local out = {}
  for pos = 1, #text, 4 do
    local n, count = 0, 0
    for i = pos, pos + 3 do
      local v = B64INDEX[text:sub(i, i)]
      if v then n, count = (n << 6) | v, count + 1 else n = n << 6 end
    end
    local bytes = schar((n >> 16) & 255, (n >> 8) & 255, n & 255)
    out[#out + 1] = bytes:sub(1, count - 1)
  end
  return table.concat(out)
end

-- Random bytes ------------------------------------------------------------------
--
-- The HC3 has no cryptographic random source, and math.random returns the same
-- sequence after every start. Random bytes therefore come from a SHA-256 pool,
-- seeded from the time, the CPU clock and memory addresses (which differ on
-- every start), and stirred with every request and with data from outside,
-- such as the inverter's own random nonces (Crypto.addEntropy).

local pool    = nil
local counter = 0

local function stir(data)
  pool = Crypto.sha256(table.concat({ pool or "", tostring(data), tostring(os.time()),
    string.format("%.6f", os.clock()), tostring({}), tostring(function() end) }, "|"))
end

--- Mix data into the random pool, e.g. a nonce received from the inverter.
function Crypto.addEntropy(data)
  stir(data)
end

--- n random bytes from the pool.
function Crypto.randomBytes(n)
  stir(counter)
  local out, length = {}, 0
  while length < n do
    counter = counter + 1
    out[#out + 1] = Crypto.sha256(pool .. "|out|" .. counter)
    length = length + 32
  end
  return table.concat(out):sub(1, n)
end

function Crypto.hex(data)
  return (data:gsub(".", function(ch) return string.format("%02x", sbyte(ch)) end))
end

