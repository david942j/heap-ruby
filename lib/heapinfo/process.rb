# encoding: ascii-8bit
# frozen_string_literal: true

require 'heapinfo/dumper'
require 'heapinfo/helper'
require 'heapinfo/nil'
require 'heapinfo/process_info'

module HeapInfo
  # Main class of heapinfo.
  class Process
    # The default options of libraries,
    # use for matching glibc segments in +/proc/[pid]/maps+.
    DEFAULT_LIB = {
      libc: /bc[^a-z]*\.so/
    }.freeze
    # @return [Integer, nil] The pid of process, +nil+ if no such process found.
    attr_reader :pid

    # Instantiate a {HeapInfo::Process} object.
    # @param [String, Integer] prog Process name or pid, see {HeapInfo::heapinfo} for more information.
    # @param [Hash{Symbol => Regexp, String}] options
    #   Libraries' filename, see {HeapInfo::heapinfo} for more information.
    def initialize(prog, options = {})
      @prog = prog
      @options = DEFAULT_LIB.merge options
      @pid = nil
      # Transparent info's methods
      ProcessInfo::EXPORT.each do |m|
        define_singleton_method(m) do
          return Nil.instance if @pid.nil?

          @info.__send__(m)
        end
      end
      load!
    end

    # Reload a new process with same program name.
    #
    # @return [HeapInfo::Process] return +self+ so that this method is chainable.
    # @example
    #   puts h.reload!
    def reload!
      @pid = nil
      load!
      self
    end
    alias reload reload!

    # Use this method to wrapper all HeapInfo methods.
    #
    # Since {HeapInfo} is a tool(debugger) for local usage,
    # while exploiting remote service, all methods will not work properly.
    # So I suggest to wrapper all methods inside {#debug},
    # which will ignore the block while the victim process is not found.
    #
    # @example
    #   h = heapinfo('./victim') # such process doesn't exist
    #   libc_base = leak_libc_base_of_victim # normal exploit
    #   h.debug {
    #     # for local to check if exploit correct
    #     fail('libc_base') unless libc_base == h.libc.base
    #   }
    #   # block of #debug will not execute if can't found process
    def debug
      return unless load!

      yield if block_given?
    end

    # Dump the content of specific memory address.
    #
    # Note: This method require you have permission of attaching another process.
    # If not, a warning message will present.
    #
    # @param [Mixed] args Will be parsed into +[base, length]+, see Examples for more information.
    # @return [String, HeapInfo::Nil]
    #   The content needed. When the request address is not readable or the process not exists,
    #   instance of {HeapInfo::Nil} is returned.
    #
    # @example
    #   h = heapinfo('victim')
    #   h.dump(:heap) # heap[0, 8]
    #   h.dump(:heap, 64) # heap[0, 64]
    #   h.dump('heap+256', 64)  # heap[256, 64]
    #   h.dump('heap+0x100', 64) # heap[256, 64]
    #   h.dump('heap+0x100 * 2 + 0x300', 64) # heap[1024, 64]
    #   h.dump(<segment>, 8) # segment can be [heap, stack, (program|elf), libc, ld]
    #   h.dump(addr, 64) # addr[0, 64]
    #
    #   # Invalid usage
    #   dump(:meow) # no such segment
    def dump(*args)
      return Nil.instance unless load?

      dumper.dump(*args)
    end

    # Return the dump result as chunks.
    # see {HeapInfo::Dumper#dump_chunks} for more information.
    #
    # @return [HeapInfo::Chunks, HeapInfo::Nil] An array of chunk(s).
    # @param [Mixed] args Same as arguments of {#dump}.
    def dump_chunks(*args)
      return Nil.instance unless load?

      dumper.dump_chunks(*args)
    end

    # Show the offset in pretty way between the segment.
    # Very useful in pwn when leak some address,
    # see examples for more details.
    # @param [Integer] addr The leaked address.
    # @param [Symbol] sym
    #   The segment symbol to be calculated offset.
    #   If this parameter not given, will loop segments
    #   and find the most close one. See examples for more details.
    # @return [void] Offset will show to stdout.
    # @example
    #   h.offset(0x7f11f6ae1670, :libc)
    #   #=> 0xf6670 after libc
    #   h.offset(0x5559edc057a0, :heap)
    #   #=> 0x9637a0 after heap
    #   h.offset(0x7f11f6ae1670)
    #   #=> 0xf6670 after :libc
    #   h.offset(0x5559edc057a0)
    #   #=> 0x9637a0 after :heap
    def offset(addr, sym = nil)
      return unless load?

      segment = @info.to_segment(sym)
      if segment.nil?
        sym, segment = @info.segments
                            .select { |_, seg| seg.base <= addr }
                            .min_by { |_, seg| addr - seg }
      end
      return $stdout.puts("Invalid address #{Helper.color_hex(addr)}") if segment.nil?

      $stdout.puts(Helper.color_hex(addr - segment) + ' after ' + Helper.color(sym, sev: :sym))
    end
    alias off offset

    # GDB-style command
    #
    # Show dump results like gdb's command +x+.
    # While will auto detect the current elf class to decide using +gx+ or +wx+.
    #
    # The dump results wrapper with color codes and nice typesetting will output to +stdout+.
    # @param [Integer] count The number of result need to dump, see examples for more information.
    # @param [String, Symbol, Integer] address The base address to be dumped.
    #   Same format as {#dump}, see {#dump} for more information.
    # @return [void]
    # @example
    #   h.x 8, :heap
    #   # 0x1f0d000:      0x0000000000000000      0x0000000000002011
    #   # 0x1f0d010:      0x00007f892a9f87b8      0x00007f892a9f87b8
    #   # 0x1f0d020:      0x0000000000000000      0x0000000000000000
    #   # 0x1f0d030:      0x0000000000000000      0x0000000000000000
    # @example
    #   h.x 3, 0x400000
    #   # 0x400000:       0x00010102464c457f      0x0000000000000000
    #   # 0x400010:       0x00000001003e0002
    def x(count, address)
      return unless load?

      dumper.x(count, address)
    end

    # GDB-style command
    #
    # Dump a string until reach the null-byte.
    # @param [String, Symbol, Integer] address The base address to be dumped.
    #   See {#dump}.
    #
    # @return [String]
    #   The string *without* null-byte.
    def s(address)
      return Nil.instance unless load?

      dumper.cstring(address)
    end

    # GDB-style command.
    #
    # Search a specific value/string/regexp in memory.
    # @param [Integer, String, Regexp] pattern
    #   The desired search pattern, can be value(+Integer+), string, or regular expression.
    # @param [Integer, String, Symbol] from
    #   Start address for searching, can be segment(+Symbol+) or segments with offset.
    #   See examples for more information.
    # @param [Integer] length
    #   The search length limit, default is unlimited,
    #   which will search until pattern found or reach unreadable memory.
    # @param [Boolean] rel
    #   To show relative offset of +from+ or absolute address.
    # @return [Integer, nil] The first matched address, +nil+ is returned when no such pattern found.
    # @example
    #   h.find(0xdeadbeef, 'heap+0x10', 0x1000)
    #   #=> 6299664 # 0x602010
    #   h.find(/E.F/, 0x400000, 4)
    #   #=> 4194305 # 0x400001
    #   h.find(/E.F/, 0x400000, 3)
    #   #=> nil
    #   sh_offset = h.find('/bin/sh', :libc) - h.libc
    #   #=> 1559771 # 0x17ccdb
    #   h.find('/bin/sh', :libc, rel: true) == h.find('/bin/sh', :libc) - h.libc
    #   #=> true
    def find(pattern, from, length = :unlimited, rel: false)
      return Nil.instance unless load?

      dumper.find(pattern, from, length, rel)
    end
    alias search find

    # Find pattern in all segments with pretty output.
    #
    # The search result will be output to +$stdout+.
    #
    # @param [Integer, String, Regexp] pattern
    #   The desired search pattern, can be value(+Integer+), string, or regular expression.
    # @param [String, Symbol, Integer] from
    #   Instead of searching all mapped segments, find the pattern from this address.
    #   +from+ can be an address, symbol name of segments (+:ld/:libc/:heap+, etc.) or string with address calculation,
    #   see {#dump} or {Dumper#base_of} for examples of string annotation.
    # @param [String, Symbol, Integer] to
    #   End address for searching. In the same format as +from+.
    #
    # @return [void]
    #
    # @example
    #   h = heapinfo('victim')
    #   h.find_all(0xdeadbeef)
    #   # Searching 0xdeadbeef:
    #   # In [heap](0x563055f3c000-0x56305b82c000), permission=rw-
    #   #   0x563058076510
    #   #   0x563058253d50
    #   #=> nil
    # @example
    #   h = heapinfo('victim')
    #   h.find_all(h.canary)
    #   # Searching 0xc83db42feb3c0f00:
    #   # In (0x7ffff7fd3000-0x7ffff7ff7000), permission=rw-
    #   #   0x7ffff7ff5728
    #   # In [stack](0x7ffffffdd000-0x7ffffffff000), permission=rw-
    #   #   0x7fffffffda28
    #   #=> nil
    # @example
    #   h = heapinfo('victim')
    #   h.find_all(h.canary, :ld, :stack)
    #   # Searching 0xc83db42feb3c0f00:
    #   # In (0x7ffff7fd3000-0x7ffff7ff7000), permission=rw-
    #   #   0x7ffff7ff5728
    #   #=> nil
    def find_all(pattern, from = 0, to = 1 << 64)
      return Nil.instance unless load?

      from = dumper.base_of(from)
      to = dumper.base_of(to)
      result = []
      HeapInfo::Helper.parsed_maps(pid).each do |st, ed, perm, name|
        next if st >= to || ed < from || !perm.include?('r')

        start = [st, from].max
        len = [ed, to].min - start
        matches = dumper.scan(pattern, start, len).map { |v| v + start }
        result << [st, ed, perm, name, matches] if matches.any?
      end

      target = pattern.is_a?(Integer) ? Helper.hex(pattern) : pattern.inspect
      str = ["Searching #{Helper.color(target)}:"]
      str.concat(format_findall_result(result))
      $stdout.puts(str)
    end
    alias findall find_all

    # Pretty dump of bins' layouts.
    #
    # The request layouts will output to +stdout+.
    # @param [Array<Symbol>] args Bin type(s) you want to see.
    # @return [void]
    # @example
    #   h.layouts(:fast, :unsorted, :small)
    #   # ...
    #   h.layouts(:tcache)
    #   # ...
    #   h.layouts(:all) # show all bin(s), includes tcache
    def layouts(*args)
      return unless load?

      args << :all if args.empty?
      str = +''
      str << libc.tcache.layouts if libc.tcache? && (%w[all tcache] & args.map(&:to_s)).any?
      str << libc.main_arena.layouts(*args)
      $stdout.puts(str)
    end

    # Show simple information of target process.
    #
    # Contains program names, pid, and segments' info.
    #
    # @return [String]
    # @example
    #   puts h
    def to_s
      return 'Process not found' unless load?

      "Program: #{Helper.color(program.name)} PID: #{Helper.color(pid)}\n" +
        program.to_s +
        heap.to_s +
        stack.to_s +
        libc.to_s +
        ld.to_s +
        format("%-28s\tvalue: #{Helper.color(format('%#x', canary), sev: :sym)}", Helper.color('canary', sev: :sym))
    end

    # Get the value of stack guard.
    #
    # @return [Integer]
    # @example
    #   h.canary
    #   #=> 11342701118118205184 # 0x9d695e921adc9700
    def canary
      return Nil.instance unless load?

      addr = @info.auxv[:random]
      Helper.unpack(bits / 8, @dumper.dump(addr, bits / 8)) & 0xffffffffffffff00
    end

    # Make pry not so verbose.
    #
    # @return [String]
    def inspect
      format('#<HeapInfo::Process:0x%016x>', __id__)
    end

    private

    attr_accessor :dumper

    def load?
      @pid != nil
    end

    # try to load
    def load!
      return true if @pid

      @pid = fetch_pid
      return false if @pid.nil? # still can't load

      load_info!
      true
    end

    def fetch_pid
      pid = nil
      if @prog.is_a? String
        pid = Helper.pidof @prog
      elsif @prog.is_a? Integer
        pid = @prog
      end
      pid
    end

    def load_info!
      @info = ProcessInfo.new(self)
      @dumper = Dumper.new(mem_filename) do |sym|
        @info.__send__(sym) if @info.respond_to?(sym)
      end
    end

    def format_findall_result(result)
      result.map do |(st, ed, perm, name, ary)|
        seg_name, seg = @info.segments.find { |_k, v| v.name == name }
        sym = seg_name || name.split('/').last
        has_name = !name.empty?
        title = "In #{has_name ? Helper.color(name, sev: :bin) : ''}" \
                "(#{Helper.color_hex(st)}-#{Helper.color_hex(ed)}), permission=#{perm.delete('p')}\n"
        title + ary.map do |v|
          r = +"  #{Helper.color_hex(v)}"
          st = seg.base if seg
          r << " (#{Helper.color(sym, sev: :sym)}+#{Helper.color_hex(v - st)})" if has_name
          r
        end.join("\n")
      end
    end

    def mem_filename
      "/proc/#{pid}/mem"
    end
  end
end
