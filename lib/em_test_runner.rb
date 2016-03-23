#
# em_test_runner V0.6.2
#
# EventMachine savvy unit test harness.
#
# Copyright (c) 2009 - 2016 Bill Kelly.  All Rights Reserved.
# 
# Redistribution and use in source and binary forms, with or without 
# modification, are permitted provided that the following conditions 
# are met: 
# 
# 1. Redistributions of source code must retain the above copyright 
# notice, this list of conditions and the following disclaimer.  
# 
# 2. Redistributions in binary form must reproduce the above 
# copyright notice, this list of conditions and the following 
# disclaimer in the documentation and/or other materials provided 
# with the distribution.  
# 
# 3. Neither the name of the copyright holder nor the names of its 
# contributors may be used to endorse or promote products derived 
# from this software without specific prior written permission.  
# 
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND 
# CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, 
# INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF 
# MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE 
# DISCLAIMED.  IN NO EVENT SHALL THE COPYRIGHT HOLDER OR 
# CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, 
# SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT 
# LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF 
# USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED 
# AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT 
# LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN 
# ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE 
# POSSIBILITY OF SUCH DAMAGE.
#

require 'pp'
require 'eventmachine'
if defined? Fiber
  require 'fiber'
end

module ANSI
  Reset   = "0"
  Bright  = "1"
  
  Black   = "30"
  Red     = "31"
  Green   = "32"
  Yellow  = "33"
  Blue    = "34"
  Magenta = "35"
  Cyan    = "36"
  White   = "37"
  
  BGBlack   = "40"
  BGRed     = "41"
  BGGreen   = "42"
  BGYellow  = "43"
  BGBlue    = "44"
  BGMagenta = "45"
  BGCyan    = "46"
  BGWhite   = "47"

  def color(*colors)
    "\033[#{colors.join(';')}m"
  end
  
  def colorize(str, start_color, end_color = Reset)
    start_color = start_color.join(";") if start_color.respond_to? :join
    end_color = end_color.join(";") if end_color.respond_to? :join
    "#{color(start_color)}#{str}#{color(end_color)}"
  end
  
  def red(str);     colorize(str, Red) end
  def green(str);   colorize(str, Green) end
  def yellow(str);  colorize(str, Yellow) end
  def blue(str);    colorize(str, Blue) end
  def magenta(str); colorize(str, Magenta) end
  def cyan(str);    colorize(str, Cyan) end
  def white(str);   colorize(str, White) end

  def bright_red(str);      colorize(str, [Bright, Red]) end
  def bright_green(str);    colorize(str, [Bright, Green]) end
  def bright_yellow(str);   colorize(str, [Bright, Yellow]) end
  def bright_blue(str);     colorize(str, [Bright, Blue]) end
  def bright_magenta(str);  colorize(str, [Bright, Magenta]) end
  def bright_cyan(str);     colorize(str, [Bright, Cyan]) end
  def bright_white(str);    colorize(str, [Bright, White]) end
  
  extend self
end # ANSI

module TestEM

class TestError < RuntimeError ; end
class TestFailure < TestError ; end

class Runner
  def self.after_em_start(&block)
    @@one_time_init_blocks ||= []
    @@one_time_init_blocks << block
  end
  
  def initialize(explicit_tests=[], out=$stderr, flags={randomize_test_order:true, enable_color:true})
    @@one_time_init_blocks ||= []
    @randomize_test_order = flags[:randomize_test_order]
    @enable_color = flags[:enable_color]
    @num_attempts = 0
    @num_failures = 0
    @num_errors = 0
    @failures = []
    @errors = []
    @out = out
    init_explicit_tests(explicit_tests)
  end

  def run
    suites = find_test_suites
    suites = weed_out_testless_base_classes(suites)
    run_test_suites(suites)
  end
  
  def find_test_suites
    suites = TestEM::TestCase.test_suites
    if @explicit_tests.empty?
      @randomize_test_order ? suites.sort_by {rand} : suites.sort_by {|k| k.name}
    else
      suites.select {|sc| find_test_methods(sc).length.nonzero?}
    end
  end

  def weed_out_testless_base_classes(classes)
    classes.reject do |c|
      find_test_methods(c).empty?  &&  (classes.any? {|o| o.ancestors[1..-1].include? c})
    end
  end

  def run_test_suites(suites)
    @suites_pending = suites
    @current_suite = nil
    begin
      EventMachine.run {
        @commence_test_run_proc = lambda do
          @suite_timer = EM.add_periodic_timer(0.01) {poll_run_next_test_suite}
          poll_run_next_test_suite
        end
        run_one_time_init_blocks
      }
    rescue Exception => ex
      @out.puts(colorize_error("\nWARNING: run_test_suites: exception: #{ex.message} - #{ex.backtrace.inspect}\n\n"))
      raise
    ensure
      all_completed = @suites_pending.empty?  &&  (@pending_tests.nil? || @pending_tests.empty?)
      @out.puts(colorize_error("\nWARNING: Someone stopped EventMachine before all tests were run...\n\n")) unless all_completed
      identify_missing_explicit_tests
      display_test_results
    end
  end

  def record_test_attempt(tc_instance)
    @num_attempts += 1
    @out.print colorize_progress(".")
  end

  def record_test_failure(tc_instance, ex, usermsg="")
    @num_failures += 1
    @failures << [tc_instance.class, ex, usermsg]
    @out.print colorize_fail("F")
  end

  def record_test_error(tc_instance, ex, usermsg="")
    @num_errors += 1
    @errors << [tc_instance.class, ex, usermsg]
    @out.print colorize_error("E")
  end
  
  def advance_to_next_test
    finalize_current_test
  end

  def current_test_name
    classname = @current_suite ? @current_suite.class.name : "UnknownClass"
    testname = @current_test || "unknown_method"
    "#{classname}##{testname}"
  end

  protected

  def colorize_progress(str);               @enable_color ? ANSI.yellow(str) : str; end
  def colorize_success(str);                @enable_color ? ANSI.bright_green(str) : str; end
  def colorize_fail(str);                   @enable_color ? ANSI.bright_red(str) : str; end
  def colorize_error(str);                  @enable_color ? ANSI.bright_red(str) : str; end
  def colorize_initiate(str);               @enable_color ? ANSI.yellow(str) : str; end
  def colorize_failed_test_reason(str);     @enable_color ? ANSI.bright_yellow(str) : str; end
  def colorize_failed_test_backtrace(str);  @enable_color ? ANSI.bright_yellow(str) : str; end
  
  def suite_name_from_test(tname)
    tname.sub(/\.[^.]+\z/, "")
  end

  def suite_names_from_explicit_tests
    @explicit_tests_list.map {|tname| suite_name_from_test(tname)}.uniq
  end
  
  def init_explicit_tests(args)
    @explicit_tests_list = args.map {|tname| tname.gsub(/#/,".")}
    @explicit_tests = Hash.new(0)
    @explicit_tests_list.each {|tname| @explicit_tests[tname] = 0}
  end
  
  def record_explicit_tests_encountered(suite_class, tests)
    tests.each do |m|
      xname = "#{suite_class.name}.#{m}"
      if (@explicit_tests.has_key?(xk=xname) || @explicit_tests.has_key?(xk=m.to_s))
        @explicit_tests[xk] += 1
      end
    end
  end

  def find_test_methods(klass)
    meths = klass.instance_methods.select {|m| m.to_s =~ /^test_/}
    if @explicit_tests.empty?
      @randomize_test_order ? meths.sort_by {rand} : meths.sort_by {|m| m.to_s}
    else
      @explicit_tests_list.map do |name|
        meths.find {|m| ("#{klass.name}.#{m}" == name) || (m.to_s == name)}
      end.compact
    end
  end

  def wrap_tests_with_setup_methods(test_methods)
    [:setup_suite] + test_methods.map {|m| [:setup, m, :teardown]}.flatten + [:teardown_suite]
  end

  def run_one_time_init_blocks
    blocks = @@one_time_init_blocks
    blocks_pending = blocks.length
    if blocks_pending.zero?
      @commence_test_run_proc.call
    else
      block_complete_cb = lambda do
        @out.print ">"
        blocks_pending -= 1
        if blocks_pending < 1
          @out.puts
          @commence_test_run_proc.call
        end
      end
      blocks.each do |initblock|
        @out.print "<"
        initblock.call(block_complete_cb)
      end
    end
  end  

  def poll_run_next_test_suite
# @out.print "#"
    unless @current_suite
      suite_class = @suites_pending.shift
      if suite_class
        @current_suite = suite_class.new(self)
        @pending_tests = find_test_methods(@current_suite.class)
        @current_test = nil
        if @pending_tests.empty?
          record_test_failure(@current_suite, TestFailure.new("No tests defined."))
        else
          record_explicit_tests_encountered(suite_class, @pending_tests)
          @pending_tests = wrap_tests_with_setup_methods(@pending_tests)
        end
      else
        @suite_timer.cancel
        EventMachine.stop
      end
    end
    if @current_suite
      poll_run_next_test
    end
  end
  
  def finalize_current_suite
    @current_suite = nil
  end
  
  def poll_run_next_test
    unless @current_test
      @current_test = @pending_tests.shift
      if @current_test
        initiate_test(@current_suite, @current_test)
      else
        finalize_current_suite
      end
    end
    if @current_test
      check_test_timeout
    end
  end
  
  def initiate_test(suite_instance, test_method)
    @test_start_time = Time.now
    completion_callback = lambda {advance_to_next_test}
    if defined? Fiber
      runner = Fiber.new do
$stderr.puts(colorize_initiate("\n[fib=#{Fiber.current.object_id}] ********** initiate_test: #{suite_instance.class.name}.#{test_method} **********")) unless test_method.to_s =~ /\A(setup|setup_suite|teardown|teardown_suite)\z/
        catch :failed do
          suite_instance.__initiate_test__(test_method, completion_callback)
        end
      end
      runner.transfer
    else
      catch :failed do
        suite_instance.__initiate_test__(test_method, completion_callback)
      end
    end
  end
  
  def finalize_current_test
    @current_test = nil
  end
  
  def check_test_timeout
    duration = @current_suite.current_timeout_secs
    tout = @test_start_time + duration
    if Time.now > tout
      record_test_error(@current_suite, TestError.new("TimeOut: #{current_test_name} duration exceeded #{duration} seconds"))
      finalize_current_test
    end
  end
  
  def identify_missing_explicit_tests
    missing = @explicit_tests.keys.select {|k| @explicit_tests[k].zero?}.sort
    missing.each {|name| record_test_error(self, TestError.new("Missing explicit test: #{name}"))}
  end
  
  def display_test_results
    color_proc = ((@errors + @failures).length.zero?) ? method(:colorize_success) : method(:colorize_fail)
    @out.puts
    @out.puts color_proc.call("#@num_attempts assertions, #@num_failures failures, #@num_errors errors.")
    (@errors + @failures).each do |suite_class, ex, usermsg|
      @out.puts
      display_failed_test(suite_class, ex, usermsg)
    end
  end
  
  def display_failed_test(suite_class, ex, usermsg)
    msg = "#{suite_class.name}: #{ex.class.name} - #{ex.message}"
    msg << " - #{usermsg}" unless usermsg.empty?
    @out.puts colorize_failed_test_reason(msg)
    # if (ex.class != TestFailure)  &&  (bt = ex.backtrace)
    if (bt = ex.backtrace)
      bt.each do |line|
        unless line =~ /em_test_runner.rb:/  ### mega kludge!!! (is there a reasonable way to know our filename?)
          @out.puts colorize_failed_test_backtrace("        #{line}")
        end
      end
    end
  end 
end

module Assertions
  protected
  
  def assert(x, message="")
    try_assert(message) { fail("#{x.inspect} is not true") unless x }
  end
  
  def assert_equal(expected, actual, message="")
    try_assert(message) do
      fail("\n#{expected.pretty_inspect}\nexpected, but was\n\n#{actual.pretty_inspect}") unless expected == actual
    end
  end

  def assert_match(regexp, string, message="")
    try_assert(message) do
      fail("#{regexp.inspect} expected to match #{string.inspect}") unless regexp =~ string
    end
  end

  def assert_no_match(regexp, string, message="")
    try_assert(message) do
      fail("#{regexp.inspect} expected NOT to match #{string.inspect}") if regexp =~ string
    end
  end

  def assert_raises(ex_class, message="", &block)
    try_assert(message) do
      caught = false
      begin
        block.call
      rescue ex_class
        caught = true
      end
      fail("expected to raise #{ex_class.name}") unless caught
    end
  end

  def fail(errmsg)
    if defined?(@test_runner) && @test_runner
      errmsg = "#{@test_runner.current_test_name} - #{errmsg}"
    end
    ex = TestFailure.new(errmsg)
    raise ex
  end
  
  def try_assert(message="")
    try_exec(message) do
      record_test_attempt
      yield
    end
  end

  def try_exec(message="")
    begin
      # Explictly enforcing String message type deemed to be the
      # lesser evil than silently succeeding when assert is used
      # instead of assert_equal in cases like: assert( 2, Foo.num_foos )
      raise("Non-string message argument") unless message.is_a? String
      yield
    rescue SignalException, SystemExit => ex
      raise
    rescue TestFailure => ex
      record_test_failure(ex, message)
      advance_to_next_test
      throw :failed
    rescue Exception => ex
      record_test_error(ex, message)
      advance_to_next_test
      throw :failed
    end
  end

  def advance_to_next_test
    if defined?(@test_runner) && @test_runner
      @test_runner.advance_to_next_test
    end
  end

  def record_test_attempt
    if defined?(@test_runner) && @test_runner
      @test_runner.record_test_attempt(self)
    end
  end
  
  def record_test_failure(ex, usermsg="")
    if defined?(@test_runner) && @test_runner
      @test_runner.record_test_failure(self, ex, usermsg)
    else
      raise ex
    end
  end

  def record_test_error(ex, usermsg="")
    if defined?(@test_runner) && @test_runner
      @test_runner.record_test_error(self, ex, usermsg)
    else
      raise ex
    end
  end
end

class TestCase
  include Assertions

  class << self
    @@test_suites = []
    def test_suites
      @@test_suites
    end
    def inherited(subclass)
      @@test_suites << subclass
    end
  end
  
  def initialize(runner)
    @test_runner = runner
  end
  
  def setup_suite(completion_callback)
    completion_callback.call
  end
  
  def teardown_suite(completion_callback)
    completion_callback.call
  end

  def setup(completion_callback)
    completion_callback.call
  end
  
  def teardown(completion_callback)
    completion_callback.call
  end
  
  def __initiate_test__(test_method, completion_callback)
    set_timeout(default_timeout_secs)
    try_exec do
      (method(test_method).arity == 1) or raise(TestError, "Test method #{self.class.name}##{test_method} is missing its completion_callback argument")
      cc = lambda { completion_callback.call }
      self.send(test_method, cc)
    end
  end

  def set_timeout(secs)
    @test_timeout_secs = secs
  end
  
  def current_timeout_secs
    @test_timeout_secs
  end

  def default_timeout_secs
    5
  end
end

end # TestEM


##############################################################################
##############################################################################
##############################################################################

if $0 != __FILE__

  # Normal case when not self-testing:
  # Run tests at program exit:
  at_exit do
    explicit_tests = ARGV
    r = TestEM::Runner.new(explicit_tests)
    r.run
  end

else

  # Perform self-tests

  class FooBase < TestEM::TestCase
    # no tests defined here, but should not produce an
    # error, because there are derived classes
  end
  
  class FooBase2 < FooBase
  end
  
  class Foo < FooBase2
    class << self
      attr_accessor :num_foos
    end
    
    @num_foos = 0
    
    def test_foo(completed)
      self.class.num_foos += 1
      assert(true)
      completed.call
    end
    
    def test_simple(completed)
      assert(true)
      completed.call
    end
    
    def test_deferred(completed)
      assert_equal("Humbert", "Humbert")
      EM.add_timer(0.25) do
        assert(true)
        completed.call
      end
    end
  end

  class Foo2 < FooBase2
    class << self
      attr_accessor :num_foos
    end
    
    @num_foos = 0
    
    def test_foo2(completed)
      self.class.num_foos += 1
      assert(true)
      completed.call
    end
  end
  
  class Bar < TestEM::TestCase
    # no tests defined
  end

  class Baz < TestEM::TestCase
    class << self
      attr_accessor :expected_setups, :setups, :teardowns, :suite_setups, :suite_teardowns, :setups_seq
    end
    
    @suite_setups = 0
    @suite_teardowns = 0
    @setups = 0
    @teardowns = 0
    @setups_seq = []
    
    def setup_suite(completed)
      self.class.suite_setups += 1
      self.class.setups_seq << "setup_suite"
      completed.call
    end
    
    def teardown_suite(completed)
      self.class.suite_teardowns += 1
      self.class.setups_seq << "teardown_suite"
      completed.call
    end

    def setup(completed)
      self.class.setups += 1
      self.class.setups_seq << "setup"
      completed.call
    end
    
    def teardown(completed)
      self.class.teardowns += 1
      self.class.setups_seq << "teardown"
      completed.call
    end
    
    def test_timeout(completed)
      self.class.setups_seq << "test"
      set_timeout(1)
      # return without calling completed, expect timeout
    end
    
    def test_init_result(completed)
      self.class.setups_seq << "test"
      assert_equal( "uno dos tres.", $initcb )
      completed.call
    end
    
    def test_failure(completed)
      self.class.setups_seq << "test"
      assert_equal("Two plus two", "five", "for very large quantities of two!")
      raise "Should Never Get Here"
    end
    
    @expected_setups = self.instance_methods.grep(/^test_/).length
  end

  class Qux < TestEM::TestCase
    class << self
      attr_accessor :num_quxes
    end
    
    @num_quxes = 0
    
    def test_qux(completed)
      self.class.num_quxes += 1
      assert(true)
      completed.call
    end
  end
  
  TestEM::Runner.after_em_start do |completed|
    $initcb = "uno "
    EM.add_timer(0.25) do
      $initcb << "tres."
      completed.call
    end
  end

  TestEM::Runner.after_em_start do |completed|
    $initcb << "dos "
    completed.call
  end

  ############################################################################
  
  require 'stringio'
  
  include TestEM::Assertions  # assertions can be used independently of test suites

  # a few basic assertions
  assert(true)
  assert_raises(TestEM::TestFailure) { assert(false) }
  assert_match( /sNiCkEr/i , "The vorpal blade went snicker-snack!" )
  assert_no_match( /sNiCkEr/ , "The vorpal blade went snicker-snack!" )

  out = StringIO.new

  ############################################################################
  # first try running only explicitly selected tests
  r = TestEM::Runner.new(%w(Qux.test_qux test_foo Bogus.test_nonexistent), out, randomize_test_order:false)

  # verify the runner locates suites properly:
  suites = r.find_test_suites
  assert_equal( %w(Foo Qux), suites.map{|tc| tc.name}.sort )
  
  r.run
  
  assert_equal( 1, Foo.num_foos )
  assert_equal( 0, Foo2.num_foos )
  assert_equal( 1, Qux.num_quxes )
  assert( Baz.expected_setups > 1 )
  assert_equal( 0, Baz.setups )
  assert_equal( 0, Baz.teardowns )
  assert_equal( 0, Baz.suite_setups )
  assert_equal( 0, Baz.suite_teardowns )

  
  ############################################################################
  # next try running all tests
  r = TestEM::Runner.new([], out, randomize_test_order:false)

  # verify the runner locates suites properly:
  suites = r.find_test_suites
  assert_equal( %w(Bar Baz Foo Foo2 FooBase FooBase2 Qux), suites.map{|tc| tc.name} )
  suites = r.weed_out_testless_base_classes(suites)
  assert_equal( %w(Bar Baz Foo Foo2 Qux), suites.map{|tc| tc.name} )
  
  r.run
  
  assert_equal( 2, Foo.num_foos )
  assert_equal( 1, Foo2.num_foos )
  assert_equal( 2, Qux.num_quxes )
  assert( Baz.expected_setups > 1 )
  assert_equal( Baz.expected_setups, Baz.setups )
  assert_equal( Baz.expected_setups, Baz.teardowns )
  assert_equal( 1, Baz.suite_setups )
  assert_equal( 1, Baz.suite_teardowns )
  assert_equal( "setup_suite setup test teardown setup test teardown setup test teardown teardown_suite",
                Baz.setups_seq.join(" ") )

  out_expected = (<<ENDTXT).strip
<<>>
..E
2 assertions, 0 failures, 1 errors.

TestEM::Runner: TestEM::TestError - Missing explicit test: Bogus.test_nonexistent
<<>>
F.F.E......
8 assertions, 2 failures, 1 errors.

Baz: TestEM::TestError - TimeOut: Baz#test_timeout duration exceeded 1 seconds

Bar: TestEM::TestFailure - No tests defined.

Baz: TestEM::TestFailure - Baz#test_failure -\x20
"Two plus two"

expected, but was

"five"
 - for very large quantities of two!
ENDTXT

  out.seek(0)
  out_actual = out.read.strip

  if out_expected == out_actual
    puts "Success!"
  else
    puts "EXPECTED OUTPUT FAIL:"
    puts "************************** expected:", out_expected
    puts "************************** actual:", out_actual
    puts "**************************"
  end
  
end # __FILE__

# TODO: display_failed_test is not printing the user message!
