# The real stack, for the fidelity gate and differential triage only -- never for
# fuzzing.  Prints the SAME key=value line the direct harness prints:
#   in_len= status= err= out_len= out_hash= lossy=
#
#   PKG=/abs/oracle/gems/<gem>-<ver> [REQUIRE=<feature>] [EXT=/abs/out/asan/<name>.so] \
#     [EXT_MATCH=<regex> | EXT_MAP='<regex>=<path>;...'] [ALLOC_CEIL=<bytes>] \
#     ruby real_harness.rb <input>
# By hand: `. ./fuzz.env && $REAL <file>` (REAL carries PKG=; plain `ruby real_harness.rb x` aborts).
# With EXT, run ruby with the sanitizer runtime preloaded (first in LD_PRELOAD):
#   LD_PRELOAD=$(resources/find_asan_rt.sh) ASAN_OPTIONS=detect_leaks=0 EXT=... ruby real_harness.rb <input>
# detect_leaks=0: the interpreter does not free everything at exit, so LeakSanitizer
# would report Ruby itself on every run.
#
# use_sigaltstack=0 is added below by re-exec when ASAN is loaded.  Ruby installs its own
# per-thread signal stack (malloc'd), and at every Ruby THREAD EXIT the preloaded ASAN
# runtime tries to munmap it as its own, fails (EINVAL: not page-aligned) and dies in
# "CHECK failed ... unable to unmmap" -- measured on Ruby 3.3 / clang 21 / aarch64 with
# `Thread.new{}.join`.  Every gem that starts a thread would read NATIVE-CRASH.  Ruby
# replaces ASAN's SIGSEGV handler with its own anyway, so ASAN's alternate stack buys
# nothing here; the option is NOT set globally, because the direct harness needs it to
# report stack overflows.
if !ENV["ASAN_OPTIONS"].to_s.include?("use_sigaltstack=0") &&
   (File.read("/proc/self/maps") rescue "").match?(/libclang_rt\.asan|libasan\.so/)
  ENV["ASAN_OPTIONS"] = [ENV["ASAN_OPTIONS"], "use_sigaltstack=0"].reject { |o| o.to_s.empty? }.join(":")
  exec(RbConfig.ruby, $0, *ARGV)   # ASAN reads its options only at process start
end

# 1. Load the gem as `gem install` delivers it, not your build tree -- build_ext.sh
#    rebuilds that per variant, and agreeing with an independently installed copy
#    (different build directory, possibly different compiler flags) is a far stronger
#    claim.  Install the oracle FROM SOURCE:
#      gem install --install-dir oracle --platform ruby <gem> -v <ver>
#    A precompiled platform gem (aarch64-linux-gnu, x86_64-linux) ships someone else's
#    build of the extension and of every vendored library: a different back end.
#    PKG is the installed gem directory, oracle/gems/<gem>-<ver>; its spec is activated
#    by path, and unless GEM_PATH is set, the gem path becomes that install dir, so its
#    dependencies resolve from oracle/ (plus Ruby's default gems).
PKG = File.expand_path(ENV.fetch("PKG") { abort "Error: set PKG=/abs/oracle/gems/<gem>-<ver>" })
SPEC_FILE = File.join(PKG, "..", "..", "specifications", File.basename(PKG) + ".gemspec")
File.exist?(SPEC_FILE) or abort("Error: PKG-NOT-A-GEM: no #{File.expand_path(SPEC_FILE)}; PKG must be <install-dir>/gems/<gem>-<ver>")
# the gem's dependencies resolve from the same install dir (plus Ruby's default gems)
Gem.paths = { "GEM_HOME" => File.expand_path("../..", PKG), "GEM_PATH" => File.expand_path("../..", PKG) } unless ENV["GEM_PATH"]

# 1b. To swap just the extension (an ASAN build) while keeping the gem's own published
#     Ruby, intercept the LOAD, then PROVE it from the process's own memory map.
#     A gem reaches its .so by `require "x/x"` (a source build: the .so sits in the
#     gem's extension_dir on $LOAD_PATH), by `require_relative "3.3/x"` (a precompiled
#     gem), or by a path it computes itself -- so both require and require_relative are
#     intercepted, and the proof does not trust either hook: after loading, the mapped
#     shared objects are read from /proc/self/maps.  A hook that silently missed a load
#     leaves the gem's own .so mapped and EXT unmapped, which is EXT-NOT-SWAPPED, never a
#     result line computed by the wrong build.
#       EXT        the .so to load instead.  Ruby calls Init_<basename>, so it must keep
#                  the original file name (build_ext.sh's snapshot does)
#       EXT_MATCH  regex on the resolved .so path to replace (default: same basename as
#                  EXT): set it when the gem loads SEVERAL extensions and only one is yours
#       EXT_MAP    `regex=path;regex=path`, first match wins: one replacement per extension
def die(why)            # stderr, "Error:" first so gate.sh / smoke.sh quote it; no result line
  $stderr.puts "Error: #{why}"
  exit! 4
end
# real paths throughout: /proc/self/maps names the resolved file, never a symlink
def real(p) = File.exist?(p) ? File.realpath(p) : die("EXT-MISSING: #{p} does not exist")
EXT = ENV["EXT"] && real(File.expand_path(ENV["EXT"]))
EXT_MATCH = ENV["EXT_MATCH"] ? Regexp.new(ENV["EXT_MATCH"]) : (EXT && /(\A|\/)#{Regexp.escape(File.basename(EXT))}\z/)
EXT_MAP = (ENV["EXT_MAP"] || "").split(";").reject(&:empty?).map do |e|
  re, to = e.split("=", 2)
  [Regexp.new(re), real(File.expand_path(to))]
end
SWAPPING = !!(EXT || !EXT_MAP.empty?)
SWAPPED_FROM = {}       # original .so path the gem asked for -> replacement

module ExtSwap
  def self.target_for(so)
    m = EXT_MAP.find { |re, _| re.match?(so) }
    return m[1] if m
    return EXT if EXT && EXT_MATCH.match?(so) && so != EXT
    nil
  end

  def self.redirect(feature)    # resolve like require would; nil unless it is a .so to swap
    kind, path = $LOAD_PATH.resolve_feature_path(feature)
    return nil unless kind == :so && path
    to = target_for(path) or return nil
    SWAPPED_FROM[path] = to
    to
  rescue LoadError
    nil
  end

  def require(feature)
    to = SWAPPING && ExtSwap.redirect(feature.to_s)
    to ? super(to) : super
  end

  def require_relative(feature)
    base = caller_locations(1, 1)[0].absolute_path or return super
    abs = File.expand_path(feature.to_s, File.dirname(base))
    to = SWAPPING && ExtSwap.redirect(abs)
    # require(abs) == require_relative(feature) from the caller's file; calling super
    # here would resolve relative to THIS file instead
    require(to || abs)
  end
end
Kernel.prepend(ExtSwap)

def mapped_sos
  File.readlines("/proc/self/maps").map { |l| l.split(" ", 6)[5].to_s.strip }
      .select { |p| p.end_with?(".so") || p.include?(".so.") }.uniq
rescue Errno::ENOENT
  []
end

# Called before the input runs AND before the result line: a gem that loads its
# extension lazily (autoload, first call) has not mapped it at the first check.
def check_swap(final)
  return unless SWAPPING
  maps = mapped_sos
  wanted = ([EXT] + EXT_MAP.map(&:last)).compact
  originals = maps.select { |p| !wanted.include?(p) && ExtSwap.target_for(p) }
  unless originals.empty?
    die("EXT-NOT-SWAPPED: the gem's own #{originals.join(', ')} is mapped; the load did not go " \
        "through require/require_relative.  Find how the gem loads it and set EXT_MATCH/EXT_MAP")
  end
  if SWAPPED_FROM.empty? && final
    die("EXT-NOT-SWAPPED: EXT is set but no extension load was redirected (mapped: " \
        "#{maps.map { |p| File.basename(p) }.grep(/\A(?!lib(c|m|ruby|pthread|dl|gcc|stdc)\b)/).join(',')}). " \
        "Check EXT_MATCH against the .so the gem loads, and that PKG is the gem that loads it")
  end
  if EXT_MAP.empty? && SWAPPED_FROM.keys.map { |p| File.basename(p) }.uniq.size > 1
    die("EXT-AMBIGUOUS: one EXT replaced #{SWAPPED_FROM.keys.join(' and ')}; use EXT_MATCH or EXT_MAP")
  end
  missing = wanted.reject { |w| maps.include?(w) }
  die("EXT-NOT-SWAPPED: #{missing.join(', ')} is not mapped after the load") if final && !missing.empty?
end

spec = Gem::Specification.load(SPEC_FILE) or die("PKG-NOT-A-GEM: #{SPEC_FILE} does not load")
spec.activate
require ENV.fetch("REQUIRE", spec.name)
check_swap(false)

FNV_MASK = 0xffffffffffffffff
def fnv1a(bytes)
  h = 0xcbf29ce484222325
  bytes.each_byte { |b| h = ((h ^ b) * 0x100000001b3) & FNV_MASK }
  format("%016x", h)
end
ZERO = "0" * 16

# 1c. Attacker-declared allocations (a decompressor's declared content size, an image
#     header's dimensions): NO cap by default.  The gem's own behaviour IS the oracle --
#     Ruby raises NoMemoryError when the allocator refuses (ArgumentError for a size the
#     C API cannot represent) -- and the fuzz run is bounded by the fuzzer's memory limit
#     (afl-fuzz -m, ASAN max_allocation_size_mb), not by a constant here.
#     OPT-IN only, and only at the attacker-declared site: with ALLOC_CEIL=<bytes> set
#     identically on both arms, read the size the gem will allocate from the input the
#     same way the direct harness does, and refuse BEFORE the call.
ALLOC_CEIL = (ENV["ALLOC_CEIL"] || 0).to_i            # 0 = off
def over_ceiling?(declared) = ALLOC_CEIL > 0 && declared > ALLOC_CEIL
# Same for attacker-chosen WORK (a cost/rounds field): WORK_CEIL=<units>, err=work-ceiling.
WORK_CEIL = (ENV["WORK_CEIL"] || 0).to_i              # 0 = off
def over_work?(units) = WORK_CEIL > 0 && units > WORK_CEIL
# def declared_size(b) = b.byteslice(OFFSET, 8).unpack1("Q<")   # the field the gem sizes by

# 2. The input, as a BINARY (ASCII-8BIT) String: the exact bytes, no transcoding.
#    ORACLE CEILING, measured on Ruby 3.3 / aarch64: a String shorter than ~616 bytes is
#    stored INSIDE its GC heap slot, not in a malloc block of its own, and every String
#    keeps a NUL terminator after its bytes.  So an over-read of a small input lands in a
#    neighbouring GC slot and ASAN on this side cannot see it -- unlike the direct harness,
#    which copies the input into an exactly sized malloc block.  Ruby offers no way to
#    hand a gem an exactly sized external buffer as a String; do not try to "fix" it here.
#    A crash that reproduces on the direct harness but is CLEAN here may be exactly that.
raw = File.binread(ARGV[0] || die("usage: ruby real_harness.rb <input>"))
input = raw.dup.force_encoding(Encoding::BINARY)

def emit(f, in_len)
  check_swap(true)
  $stdout.write("in_len=#{in_len} status=#{f[:status]} err=#{f[:err] || 0} " \
                "out_len=#{f[:out_len] || 0} out_hash=#{f[:out_hash] || ZERO} lossy=#{f[:lossy] || 0}\n")
  $stdout.flush
end

# `err` is ONE TOKEN identical to what the direct harness prints (ArgumentError for an
# embedded NUL through StringValueCStr, NoMemoryError when the allocator refused a legal
# size, a gem's own numeric #code, ...).  Never a hash of a message that embeds the input:
# that makes err unique per seed and useless for the corpus skill.
# Default token: the gem's numeric code if it has one, else the exception CLASS -- for
# Ruby's own errors and for the gem's own namespaced classes alike (MyGem::ParseError).
# NOT the message by default: gem messages usually embed the position ("... at line 1,
# column 15 [file.c:376]"; measured on two gems), which makes err unique per seed.  When
# the class is too coarse, take a STABLE field the gem's exception exposes (e.g.
# #problem) in ERR_FIELD below, and print the same on the direct side.  A message that
# embeds input is cut at the first ": " or " at line" before it serves as a token.
ERR_FIELD = nil   # e.g. ->(e) { e.respond_to?(:problem) ? e.problem : nil }
def err_token(e)
  code = e.respond_to?(:code) ? e.code : nil
  return code if code.is_a?(Integer)
  f = ERR_FIELD && ERR_FIELD.call(e)
  return f.to_s.gsub(/\s+/, "_")[0, 63] if f && !f.to_s.empty?
  e.class.name
end

# 3. THE CALLS INTO THE GEM, one arm per entry point, keyed by the harness's MODE value
#    ("default" when MODE is unset).  This hash is the chain's shared contract:
#      * the direct harness selects the same entry point from the same MODE value;
#      * the campaign skill records each mode's `entry` as this key (MODE=file -> file);
#      * the triage skill's confirm.rb ENTRIES is THIS hash, pasted unchanged.
#    So write the arm once, here, where the gate proves it matches the native call, and
#    name the mode after the entry point it reaches.  Call the gem the way a user does,
#    with NO options -- the gate compares your mirrored defaults against the real ones.
#    Pass `b` (BINARY) unless the API documents a String in another encoding; an arm that
#    forces UTF-8 is a different byte space (see lossy below).
#    Example:  default: ->(b) { d = MyGem.parse(b); d.to_s.b + "\0" + d.errors.map { |e| "#{e.code};" }.join }
#              events:  ->(b) { MyGem.sax(b, Recorder.new); COLLECTED }   # a callback arm
#    COLLECTED is the partial-output buffer.  A one-shot arm returns its result and leaves
#    COLLECTED empty.  A callback arm appends each serialised event to COLLECTED as it
#    arrives (COLLECTED << tag << bytes.b) and returns COLLECTED; when the gem raises
#    mid-stream, the rescue below still hashes the events delivered before the error
#    (out_len/out_hash; 0 and all-zero when none were).  The direct harness must hash the
#    same partial stream on error (harness_template.cc section 7), or every rejected seed
#    mismatches.
#              strict:  ->(b) { MyGem.parse(b, strict: true).to_s }   # a SECOND mode, not the default
#    A recovering parser (a default "recover" mode) rejects almost nothing (measured:
#    nearly every seed took the success arm).  So put what the recovery reported (its
#    errors list) into the artifact, and add the non-recovering option set as its own
#    MODE if the gate's arm check needs rejects -- never make the default arm stricter
#    than what a user gets.
#    Ask the RUNTIME for tables the gem consults, as well as for limits: a serializer that
#    calls Encoding.find(doc_encoding) raises ArgumentError for names a C library accepts
#    (UCS-4, ebcdic-us; measured), so the direct side needs Ruby's Encoding.name_list --
#    generate it at build time (gen_enc_table.rb), never type it in.
ENTRIES = {
  "default" => ->(b) { raise NotImplementedError, "fill in ENTRIES with the gem's real call" },
  # "file"   => ->(b) { MyGem.parse_file(as_file(b)) },   # the path entry point (raw bytes)
}.freeze
COLLECTED = String.new(encoding: Encoding::BINARY)   # callback arms append here; see above
def as_file(b, ext = "")
  require "tmpdir"
  p = File.join(Dir.mktmpdir("real-"), "input" + ext)
  File.binwrite(p, b)
  p
end
MODE = ENV["MODE"] || "default"
ENTRIES.key?(MODE) or die("no entry for MODE=#{MODE}")

begin
  # Opt-in allocation ceiling (1c), only when the input declares a size:
  #   if over_ceiling?(declared_size(input)) then emit({ status: 1, err: "alloc-ceiling" }, raw.bytesize); exit 1; end
  result = ENTRIES[MODE].call(input)
  #
  # CALLBACK-DRIVEN (event-handler) API: subclass the gem's handler class,
  # override EVERY callback it offers, serialise each event exactly as the direct harness
  # does (event tag, length-prefixed bytes, attribute pairs in order, nil/true/false, a
  # position trailer), append it to COLLECTED, and hash the concatenation.  The event
  # stream IS the artifact, on the error path too.
  #
  # Hash the DEEPEST artifact the API gives you, not a summary: a width and a height can
  # agree while every byte differs.
  # Hash BYTES: `.b` (a BINARY copy) on every string before you concatenate or hash it.
  # A result in a dummy encoding (a serializer returning UTF-16) raises
  # Encoding::CompatibilityError when concatenated with a UTF-8 literal (measured).
  out = (result.is_a?(String) ? result : result.to_s).b
  #
  # `lossy=1` marks the oracle's ceiling: set it when the gem cannot report the library's
  # bytes faithfully.  Ruby does not replace invalid bytes on its own -- a String carries
  # whatever bytes the extension put in -- so loss enters only where the gem or this arm
  # transcodes: #encode / #scrub / String#unicode_normalize, a UTF-8 String built with
  # rb_utf8_str_new from invalid input that a later step rejects, a Qtrue/Qfalse the
  # extension collapsed a richer value into.  Set it AT THAT STEP, from what that step did
  # (e.g. `lossy = 1 unless s.valid_encoding?` just before an #encode), never from the
  # output's content: a document that really contains U+FFFD is not lossy, and a "has
  # U+FFFD" test would hide real mismatches on it.  A substitution changes the LENGTH
  # too, so gate with SOFT_DROP="out_len out_hash".
  lossy = 0
  # success: hash even an empty output; all-zero out_hash is the error path's "nothing collected"
  emit({ status: 0, out_len: out.bytesize, out_hash: fnv1a(out), lossy: lossy }, raw.bytesize)
  exit 0
rescue Exception => e            # rubocop:disable Lint/RescueException -- NoMemoryError and
  raise if e.is_a?(SystemExit)   # SystemStackError are not StandardErrors, and both are results
  # the events a callback arm delivered before the error are part of the artifact
  part = COLLECTED.empty? ? {} : { out_len: COLLECTED.bytesize, out_hash: fnv1a(COLLECTED) }
  emit({ status: 1, err: err_token(e) }.merge(part), raw.bytesize)
  exit 1
end
