# Confirm one crash against the gem AS `gem install` DELIVERS IT, and decide whether the
# gem's own error handling catches it.  This is the question the direct harness cannot
# answer: the fuzzer crashes a C boundary with Ruby deleted, but a real user reaches that
# code through the gem's Ruby, which may validate the input first, rescue the native
# error, or convert it into its own exception class.  A finding a user can never
# trigger is not a finding.
#
#   PKG=/abs/oracle/gems/<gem>-<ver> [REQUIRE=<feature>] [EXT=/abs/out/asan/<name>.so] \
#     [EXT_MATCH=<regex> | EXT_MAP='<regex>=<path>;...'] [ENTRY=<name>] ruby confirm.rb <crash file>
#
# Verdict (printed as `verdict=...`, and the process exit code):
#   CLEAN    (0)  the call returned with no error at all.  Printed with `evidence=` --
#                 see "Do not believe a bare CLEAN" below.
#   CAUGHT  (10)  it raised a StandardError -- the `rescue => e` a careful caller writes
#                 stops it.  A careful user is safe.
#   UNCAUGHT(20)  it raised an Exception that is NOT a StandardError (NoMemoryError,
#                 SystemStackError, ScriptError, ...), so a plain `rescue => e` does not
#                 stop it; or it killed a Thread the gem started, which no rescue at the
#                 call site sees; or it ended the process through `fatal` / exit.
#   HANG    (25)  no answer within TIMEOUT_MS.  An algorithmic DoS no rescue can stop.
#                 (A C loop that never releases the GVL starves this watchdog too; then
#                 confirm.sh's CELL_TIMEOUT reports HANG(cell-timeout) instead.)
#   SKIPPED (30)  NoMemoryError in a column that runs under a sanitizer allocation cap
#                 (ALLOC_CEIL set by confirm.sh): the cap, not the gem, refused it, so
#                 this run proves nothing.  Re-run with the cap raised.
#   ERROR   (40)  no such ENTRY, PKG does not load, or `arm-wiring`: an arm used a name
#                 this file does not define (a helper not pasted).  (41) PKG is not PKG_VERSION
#                 (`version-mismatch=got!=want`): another release says nothing about this one.
#
# A NATIVE crash (SIGSEGV/SIGBUS/SIGABRT, or an ASAN report) is caught by Ruby's own
# signal handler only to print a `[BUG]` report and abort: no `rescue`, not even
# `rescue Exception`, runs.  confirm.sh detects it from the `[BUG]` line, the sanitizer
# report or the exit status, and it is the most severe verdict.

# Under preloaded ASAN, re-exec with use_sigaltstack=0: otherwise every Ruby THREAD EXIT
# dies in ASAN's "CHECK failed ... unable to unmmap" (it munmaps Ruby's own malloc'd
# signal stack as if it were its own; measured on Ruby 3.3 / clang 21 / aarch64), and a
# gem that starts a thread reads NATIVE-CRASH(CHECK) in both sanitized columns.  See the
# harness skill's real_harness.rb.
if !ENV["ASAN_OPTIONS"].to_s.include?("use_sigaltstack=0") &&
   (File.read("/proc/self/maps") rescue "").match?(/libclang_rt\.asan|libasan\.so/)
  ENV["ASAN_OPTIONS"] = [ENV["ASAN_OPTIONS"], "use_sigaltstack=0"].reject { |o| o.to_s.empty? }.join(":")
  exec(RbConfig.ruby, $0, *ARGV)
end

def die(why, code = 40)    # flush: exit! skips it, and a piped stdout is buffered
  $stdout.puts "verdict=ERROR #{why}"
  $stdout.flush
  exit! code
end

PKG = File.expand_path(ENV.fetch("PKG") { die("set PKG=/abs/oracle/gems/<gem>-<ver>") })
SPEC_FILE = File.join(PKG, "..", "..", "specifications", File.basename(PKG) + ".gemspec")
File.exist?(SPEC_FILE) or die("PKG-NOT-A-GEM: no #{File.expand_path(SPEC_FILE)}")
# the gem's dependencies resolve from the same install dir (plus Ruby's default gems)
Gem.paths = { "GEM_HOME" => File.expand_path("../..", PKG), "GEM_PATH" => File.expand_path("../..", PKG) } unless ENV["GEM_PATH"]

# ---- swap the ASAN extension under the gem's published Ruby, and PROVE it happened ----
# Same mechanism as the harness skill's real_harness.rb: intercept require and
# require_relative (a source build loads `x/x` from the extension dir on $LOAD_PATH, a
# precompiled gem uses require_relative), then believe /proc/self/maps, not the hook.
# A swap that silently did not happen makes the ASAN column a duplicate of the install
# column and hides exactly the memory bugs that column exists to find.
def real(p) = File.exist?(p) ? File.realpath(p) : die("EXT-MISSING: #{p}")
EXT = ENV["EXT"] && real(File.expand_path(ENV["EXT"]))
EXT_MATCH = ENV["EXT_MATCH"] ? Regexp.new(ENV["EXT_MATCH"]) : (EXT && /(\A|\/)#{Regexp.escape(File.basename(EXT))}\z/)
# A gem can load SEVERAL extensions; one EXT would then be swapped in for all of them.
# EXT_MAP handles that (`regex=path;regex=path`, first match wins), and a single EXT
# swapped into two distinct extensions reports swap=AMBIGUOUS instead of a verdict.
EXT_MAP = (ENV["EXT_MAP"] || "").split(";").reject(&:empty?).map do |e|
  re, to = e.split("=", 2)
  [Regexp.new(re), real(File.expand_path(to))]
end
SWAPPING = !!(EXT || !EXT_MAP.empty?)
SWAPPED_FROM = {}

module ExtSwap
  def self.target_for(so)
    m = EXT_MAP.find { |re, _| re.match?(so) }
    return m[1] if m
    return EXT if EXT && EXT_MATCH.match?(so) && so != EXT
    nil
  end

  def self.redirect(feature)
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

def swap_state
  return "absent" unless SWAPPING
  maps = mapped_sos
  wanted = ([EXT] + EXT_MAP.map(&:last)).compact
  return "NOT-SWAPPED" if maps.any? { |p| !wanted.include?(p) && ExtSwap.target_for(p) }
  return "NOT-SWAPPED" if SWAPPED_FROM.empty? || wanted.any? { |w| !maps.include?(w) }
  return "AMBIGUOUS-SWAP" if EXT_MAP.empty? && SWAPPED_FROM.keys.map { |p| File.basename(p) }.uniq.size > 1
  "swapped"
end
def loaded_exts = mapped_sos.select { |p| ExtSwap.target_for(p) || ([EXT] + EXT_MAP.map(&:last)).include?(p) }.map { |p| File.basename(p) }
# No swap requested: name the install's own extension (mapped from under the gem's dir or
# its extensions/ dir, both named <gem>-<ver>), so `loaded=` does not read like a failure.
def loaded_desc
  return loaded_exts.join(",").then { |s| s.empty? ? "none" : s } if SWAPPING
  own = mapped_sos.select { |p| p.include?("/#{File.basename(PKG)}/") }.map { |p| File.basename(p) }.uniq
  "#{own.empty? ? 'none' : own.join(',')} (no swap requested)"
end

# Exceptions that kill a Thread the gem started never reach the caller's rescue.
# Record them; Thread#join is NOT called for the gem (that would be adding a handler a
# user does not write).
THREAD_DEATHS = []
module ThreadWatch
  def initialize(*args, &blk)
    super(*args) do |*a|
      blk.call(*a)
    rescue Exception => e # rubocop:disable Lint/RescueException
      THREAD_DEATHS << e
      raise
    end
  end
end
Thread.prepend(ThreadWatch)
# Thread.start / Thread.fork do not call #initialize; wrap them too.  Threads created
# from C (rb_thread_create) are still not seen.
module ThreadWatchStart
  def start(*args, &blk)
    super(*args) do |*a|
      blk.call(*a)
    rescue Exception => e # rubocop:disable Lint/RescueException
      THREAD_DEATHS << e
      raise
    end
  end
  alias fork start
end
Thread.singleton_class.prepend(ThreadWatchStart)
Thread.report_on_exception = false

spec = Gem::Specification.load(SPEC_FILE) or die("PKG-NOT-A-GEM: #{SPEC_FILE} does not load")
# The version you harnessed (confirm.sh passes PKG_VERSION from fuzz.env): checked before
# the gem loads, so a stale or newer install cannot answer for it.
if (want = ENV["PKG_VERSION"].to_s) != "" && spec.version.to_s != want
  die("version-mismatch=#{spec.version}!=#{want}", 41)
end
begin
  spec.activate
  require ENV.fetch("REQUIRE", spec.name)
rescue LoadError, Gem::LoadError => e
  die("LOAD-FAILED #{e.class}: #{e.message.lines.first.to_s.strip.gsub(/\s+/, '_')[0, 120]}")
end

def tok(e) = (e.respond_to?(:code) && e.code.is_a?(Integer) ? e.code : (e.message.to_s.lines.first.to_s.strip.then { |m| m.empty? ? e.class.name : "#{e.class.name}:#{m}" })).to_s.gsub(/\s+/, "_")[0, 80]

# The input, as BINARY: the exact bytes.  Ruby Strings carry arbitrary bytes, so unlike a
# JS string nothing is lost on the way in -- unless an arm passes it through #encode or
# the extension takes it with StringValueCStr (cut at, or refusing, an embedded NUL).
# `nul=` and `utf8=` say which byte spaces this input is in, so a CLEAN row on a
# UTF-8-only or NUL-refusing entry point can be explained instead of guessed at.
# (Small Strings live inside GC slots, so ASAN cannot see an over-read of the INPUT
# itself here; see the harness skill's real_harness.rb.)
RAW = File.binread(ARGV[0] || die("usage: ruby confirm.rb <crash file>")).force_encoding(Encoding::BINARY)
NUL = RAW.include?("\0") ? 1 : 0
UTF8 = RAW.dup.force_encoding(Encoding::UTF_8).valid_encoding? ? 1 : 0

# The helpers real_harness.rb defines for its arms, same names and signatures, so a pasted
# arm or helper that calls one works here unchanged.
FNV_MASK = 0xffffffffffffffff
def fnv1a(bytes)
  h = 0xcbf29ce484222325
  bytes.each_byte { |c| h = ((h ^ c) * 0x100000001b3) & FNV_MASK }
  format("%016x", h)
end
ALLOC_CEIL = (ENV["ALLOC_CEIL"] || 0).to_i
def over_ceiling?(declared) = ALLOC_CEIL > 0 && declared > ALLOC_CEIL
WORK_CEIL = (ENV["WORK_CEIL"] || 0).to_i
def over_work?(units) = WORK_CEIL > 0 && units > WORK_CEIL
MODE = ENV["ENTRY"] || "default"   # real_harness.rb's MODE is the entry name

# Same signature as in real_harness.rb, so a pasted "file" arm works unchanged.
def as_file(b, ext = "")
  require "tmpdir"
  p = File.join(Dir.mktmpdir("confirm-"), "input" + ext)
  File.binwrite(p, b)
  p
end

$done = false
def finish(v, code, extra = "")
  return if $done
  $done = true
  $stdout.write("verdict=#{v} entry=#{ENV['ENTRY'] || 'default'} swap=#{swap_state} " \
                "loaded=#{loaded_desc} nul=#{NUL} utf8=#{UTF8}#{extra}\n")
  $stdout.flush
  exit! code
end

# Do not believe a bare CLEAN: a mis-wired call returns successfully while parsing
# nothing, and then every crash in the table reads CLEAN and gets dropped (on a Node
# binding, a JS harness exited 0 for 18 files that had all failed, because the getter it
# checked was hardcoded `return true`).  So every CLEAN carries evidence of what the call
# produced, and confirm.sh runs a known-good seed through each column first.
def describe(r)
  case r
  when nil then "type=nil"
  when String then "bytes=#{r.bytesize}"
  when Array, Hash then "#{r.class.name.downcase}=#{r.size}"
  else
    %i[to_s].each do |m|
      next unless r.respond_to?(m)
      s = r.public_send(m)
      return "#{r.class.name}.#{m}=#{s.bytesize}" if s.is_a?(String) && !s.start_with?("#<")
    end
    "class=#{r.class.name}"
  end
rescue StandardError
  "undescribable"
end

TIMEOUT_MS = (ENV["TIMEOUT_MS"] || 10_000).to_i
Thread.new do
  sleep TIMEOUT_MS / 1000.0
  finish("HANG", 25, " note=no-answer-in-#{TIMEOUT_MS}ms")
end

# An exception that leaves the main script any other way (fatal, exit from inside the
# gem) still gets a verdict line.
at_exit do
  next if $done
  e = $!
  if e.is_a?(SystemExit) then finish("UNCAUGHT", 20, " via=exit status=#{e.status}")
  elsif e then finish("UNCAUGHT", 20, " via=#{e.class.name} err=#{tok(e)}")
  end
end

# ---- THE CALLS INTO THE GEM ----------------------------------------------------------
# One arm per entry point the gem exposes over the same engine, selected by ENTRY.
# Harness EVERY one: a String argument, an IO and a file path can carry different byte
# spaces and reach different code (event callbacks vs a built tree, a push parser vs
# parse-in-one).  Each arm is exactly how a user calls the gem -- the same calls
# real_harness.rb made for the gate, keyed the same way, with NO options and NO rescue a
# user would not write.  Adding a `rescue` inside an arm manufactures a CAUGHT verdict.
#
# Arms return the result; a return value of nil is reported CLEAN with evidence=type=nil,
# which the liveness check then shows up as suspicious.  An arm whose gem delivers
# results through a block or handler object returns whatever the handler collected.
#
# PASTE real_harness.rb's ENTRIES hash here as is: each arm is a lambda called as
# arm.call(RAW) (the exact bytes, BINARY), and as_file(b, ext) is the same helper.  A lambda
# checks its arity, so an arm of another arity raises ArgumentError and reads CAUGHT.
# Paste ABOVE the hash every class, method and global the arms use (a handler subclass, a
# tree walker, `$H = Handler.new`).  One missing reads ERROR(arm-wiring), not CAUGHT.
ENTRIES = {
  "default" => ->(b) { raise NotImplementedError, "fill in ENTRIES with the gem's real call (as in real_harness.rb)" },
  # "file"  => ->(b) { MyGem.parse_file(as_file(b)) },        # the path entry point
  # "events" => ->(b) { h = MyHandler.new; MyGem::EventParser.new(h).parse(b); h.events },
}.freeze
# --------------------------------------------------------------------------------------

entry = ENV["ENTRY"] || "default"
call = ENTRIES[entry] or die("no-such-entry=#{entry}")

begin
  result = call.call(RAW)
  # a thread the gem started and that already died with an exception: the caller's rescue
  # never saw it (one that dies AFTER the call returned is not caught here)
  if (e = THREAD_DEATHS.first)
    finish("UNCAUGHT", 20, " via=thread err=#{tok(e)}")
  end
  finish("CLEAN", 0, " evidence=#{describe(result)}")
rescue NameError => e
  # A name missing from THIS file (a helper not pasted) is a wiring error, not the gem's:
  # raised on a line here that spells the name (a NameError raised inside the gem's C
  # also reports the arm's line, but that line does not name what was missing).
  at = e.backtrace_locations&.first
  top = at && File.expand_path(at.path.to_s) == File.expand_path(__FILE__) &&
        (File.readlines(__FILE__)[at.lineno - 1].to_s.include?(e.name.to_s) rescue false) &&
        (!e.is_a?(NoMethodError) || (e.receiver.equal?(TOPLEVEL_BINDING.receiver) rescue false))
  die("arm-wiring #{e.class.name}: #{e.message.lines.first.to_s.strip.gsub(/\s+/, '_')[0, 100]}") if top
  finish("CAUGHT", 10, " err=#{tok(e)}")
rescue StandardError => e       # the `rescue => e` a careful caller writes stops it
  finish("CAUGHT", 10, " err=#{tok(e)}")
rescue NoMemoryError => e
  if ENV["ALLOC_CEIL"].to_i > 0 then finish("SKIPPED", 30, " note=alloc-ceiling err=#{tok(e)}")
  else finish("UNCAUGHT", 20, " via=NoMemoryError err=#{tok(e)}")
  end
rescue Exception => e           # rubocop:disable Lint/RescueException -- SystemStackError,
  finish("UNCAUGHT", 20, " via=#{e.class.name} err=#{tok(e)}")   # ScriptError: not StandardError
end
