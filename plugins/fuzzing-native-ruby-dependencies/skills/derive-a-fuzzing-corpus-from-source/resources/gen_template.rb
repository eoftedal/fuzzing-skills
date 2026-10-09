#!/usr/bin/env ruby
# frozen_string_literal: true
# Skeleton for a corpus generator.  Copy it, fill in the record builder and the
# families, run it.  The scaffolding already does what every generator needs and
# what every hand-rolled one got wrong at least once:
#
#   * one output file per seed, named <family>-<nnn>-<name>, so validate.sh PREFIX=
#     can slice a family out and a broken family cannot hide among healthy ones;
#   * a MANIFEST written OUTSIDE the corpus directory (a manifest inside it is a seed),
#     mapping each file to the branch, bound or hazard that motivated it;
#   * every written integer CLAMPED to its field width, so a value derived from a
#     deliberately extreme one cannot make pack() wrap silently before the target sees it;
#   * the DECLARED value separated from the ACTUAL layout, so a length field can say
#     0xFFFFFFF0 while the buffer stays small;
#   * a default record that must parse to completion -- byte-diff it against the real
#     writer's output BEFORE writing families (`od -An -tx1` both; see SKILL.md);
#   * de-duplication of identical bytes across families.
#
#   ruby gen.rb OUT=./corpus-derived [MANIFEST=./corpus-derived.manifest.tsv] [ONLY=fam]
#
# Pure Ruby, no gems: it runs on the host's ruby as well as the target's.  If it must
# require the extension itself, point -I at a plain snapshot (ruby -I out/plain gen.rb);
# the in-tree <name>.so is whatever variant was built last.
require 'fileutils'

ARGS     = ARGV.map { |a| a.split('=', 2) }.select { |kv| kv.size == 2 }.to_h
OUT      = ARGS.fetch('OUT', './corpus-derived')
ONLY     = ARGS['ONLY']                            # emit one family, for iterating
# with ONLY the default manifest is <OUT>.manifest.<fam>.tsv, so iterating on one family
# does not overwrite the full manifest with that family's rows
MANIFEST = ARGS.fetch('MANIFEST', ONLY ? "#{OUT}.manifest.#{ONLY}.tsv" : "#{OUT}.manifest.tsv")
FileUtils.mkdir_p(OUT)

# ---- clamps: every value you WRITE goes through one of these -------------------
# pack('C'/'v'/'V'/'Q<') silently truncates an out-of-range Integer, which turns a
# deliberate boundary into a different, unintended value.  Clamp instead.
def clamp(v, lo, hi)
  f = v.is_a?(Integer) ? v : (Float(v) rescue 0.0)
  return 0.clamp(lo, hi) if f.is_a?(Float) && f.nan?
  return (f > 0 ? hi : lo) if f.is_a?(Float) && f.infinite?
  n = f.floor
  n < lo ? lo : (n > hi ? hi : n)
end
def u8(v);  clamp(v, 0, 0xff);                     end
def u16(v); clamp(v, 0, 0xffff);                   end
def u32(v); clamp(v, 0, 0xffffffff);               end
def i32(v); clamp(v, -0x80000000, 0x7fffffff);     end
# 64-bit fields (content sizes, offsets): Ruby Integers are arbitrary precision, so the
# clamp is the same; write with [u64(v)].pack('Q<').  Boundaries worth a seed each:
# 2**32, 2**53 (the largest exact Float, which a Ruby wrapper may sum sizes in), 2**63,
# 2**64-1.
U64_MAX = (1 << 64) - 1
def u64(v); clamp(v, 0, U64_MAX); end
# Check every size field's ENCODING against the real writer before deriving from it:
# one frame format stores (size - 256) under one flag value; one compressed container stores
# (n + 1) * 4 in a header length byte.  A wrong encoding rule kills a whole family while every seed "runs".

# ---- emit --------------------------------------------------------------------
$seen = {}
$manifest = []
$n = 0
$family = 'misc'
def fam(name); $family = name; end
def emit(name, bytes, why)
  return if ONLY && $family != ONLY
  buf = bytes.is_a?(Array) ? bytes.pack('C*') : bytes.to_s.b
  if $seen.key?(buf)
    $manifest << [$family, name, "DUP of #{$seen[buf]}", why]
    return
  end
  $n += 1
  file = format('%s-%03d-%s', $family, $n, name.to_s.gsub(/[^A-Za-z0-9._-]+/, '_'))
  File.binwrite(File.join(OUT, file), buf)
  $seen[buf] = file
  $manifest << [$family, file, "#{buf.bytesize}B", why]
end

# ---- 1. the record builder ----------------------------------------------------
# Defaults produce a record that parses TO COMPLETION.  Every dependent field is
# DERIVED from the code's own rule, never a plausible constant.  Each field can be
# overridden with a declared value that differs from the actual layout.
def mkrecord(o = {})
  version = o.fetch(:version, 1)
  payload = o.fetch(:payload, 'hello'.b)
  count   = o.fetch(:count, 1)
  # actual layout
  body    = payload.b
  # declared values (what we WRITE), defaulting to the truth
  decl_len = o.fetch(:declared_len, body.bytesize)
  hdr = 'MAGC'.b                                   # replace with the real signature
  hdr += [u8(version), u8(count), u16(decl_len)].pack('CCv')
  hdr + body
end

# ---- 2. families: one axis each, varied from the fully-parsing default ----------
fam 'default'
emit 'default', mkrecord, 'fully parsing record; byte-diff this against the real writer first'

fam 'sniff'
[0, 1, 2, 3, 4].each { |len| emit "len#{len}", mkrecord.byteslice(0, len), 'sub-minimum input reaching the sniffer' }

fam 'version'
[0, 1, 2, 0xff].each { |v| emit "v#{v}", mkrecord(version: v), 'every accepted value, one unlisted (default: arm)' }

fam 'len'
[0, 1, 4, 5, 6, 0xffff].each { |d| emit "decl#{d}", mkrecord(declared_len: d), 'declared length vs actual: both sides of the boundary' }

fam 'count'
[0, 1, 2, 50, 255].each { |c| emit "count#{c}", mkrecord(count: c), 'repetition count is an axis: 1 and ~50 differ' }

# ---- 3. manifest, outside the corpus directory ---------------------------------
File.write(MANIFEST, (["family\tfile\tsize\twhy"] + $manifest.map { |r| r.join("\t") }).join("\n") + "\n")
puts "#{$n} seeds -> #{OUT}  (#{$manifest.size - $n} duplicates dropped; manifest: #{MANIFEST}" +
     (ONLY ? ", family #{ONLY} only; the full manifest is left as it was)" : ")")
