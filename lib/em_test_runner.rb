#
# em_test_runner V0.1
# EventMachine savvy unit test harness.
# Written 2009 Bill Kelly
# Released into the public domain.
#

require 'eventmachine'

module TestEM

class TestError < RuntimeError ; end
class TestFailure < TestError ; end

class Runner
  def self.after_em_start(&block)
    @@one_time_init_blocks ||= []
    @@one_time_init_blocks << block
  end
  
  def initialize
    @@one_time_init_blocks ||= []
    @num_attempts = 0
    @num_failures = 0
    @num_errors = 0
    @failures = []
    @errors = []
    @out = $stderr
  end

  def run
    suites = find_test_suites
    suites = weed_out_testless_base_classes(suites)
    run_test_suites(suites)
  end
  
  def find_test_suites
    em_test_classes = []
    ObjectSpace.each_object do |o|
      if o.respond_to? :ancestors
        em_test_classes << o if o.ancestors[1..-1].include? TestEM::TestCase
      end
    end
    em_test_classes.sort {rand}
  end

  def weed_out_testless_base_classes(classes)
    classes.reject do |c|
      find_test_methods(c).empty?  &&  classes.any? {|o| o.ancestors[1..-1].include? c}
    end
  end

  def run_test_suites(suites)
    @suites_pending = suites
    @current_suite = nil
    EventMachine.run {
      @commence_test_run_proc = lambda do
        @suite_timer = EM.add_periodic_timer(0.01) {run_next_test_suite}
        run_next_test_suite
      end
      run_one_time_init_blocks
    }
  end

  def record_test_attempt(tc_instance)
    @num_attempts += 1
    @out.print "."
  end

  def record_test_failure(tc_instance, ex, usermsg="")
    @num_failures += 1
    @failures << [tc_instance.class, ex, usermsg]
    @out.print "F"
  end

  def record_test_error(tc_instance, ex, usermsg="")
    @num_errors += 1
    @errors << [tc_instance.class, ex, usermsg]
    @out.print "E"
  end
  
  def advance_to_next_test
    @current_test = nil
  end

  def current_test_name
    classname = @current_suite ? @current_suite.class.name : "UnknownClass"
    testname = @current_test || "unknown_method"
    "#{classname}##{testname}"
  end

  protected

  def find_test_methods(klass)
    klass.instance_methods.select {|m| m.to_s =~ /^test_/}.sort {rand}
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
          @commence_test_run_proc.call
        end
      end
      blocks.each do |initblock|
        @out.print "<"
        initblock.call(block_complete_cb)
      end
    end
  end  

  def run_next_test_suite
    if @current_init_block
    end
    unless @current_suite
      suite_class = @suites_pending.pop
      if suite_class
        @current_suite = suite_class.new(self)
        @pending_tests = find_test_methods(@current_suite.class)
        @current_test = nil
        if @pending_tests.empty?
          record_test_failure(@current_suite, TestFailure.new("No tests defined."))
        end
      else
        @suite_timer.cancel
        EventMachine.stop
        display_test_results
      end
    end
    if @current_suite
      run_next_test
    end
  end
  
  def run_next_test
    unless @current_test
      @current_test = @pending_tests.pop
      if @current_test
        initiate_test(@current_suite, @current_test)
      else
        @current_suite = nil
      end
    end
    if @current_test
      check_test_timeout
    end
  end
  
  def initiate_test(suite_instance, test_method)
    @test_start_time = Time.now
    completion_callback = lambda {advance_to_next_test}
    catch :failed do
      suite_instance.initiate_test(test_method, completion_callback)
    end
  end
  
  def check_test_timeout
    duration = @current_suite.current_timeout_secs
    tout = @test_start_time + duration
    if Time.now > tout
      record_test_error(@current_suite, TestError.new("TimeOut: #{current_test_name} duration exceeded #{duration} seconds"))
      @current_test = nil
    end
  end
  
  def display_test_results
    @out.puts
    @out.puts "#@num_attempts assertions, #@num_failures failures, #@num_errors errors."
    (@errors + @failures).each do |suite_class, ex|
      @out.puts
      display_failed_test(suite_class, ex)
    end
  end
  
  def display_failed_test(suite_class, ex)
    @out.puts "#{suite_class.name}: #{ex.class.name} - #{ex.message}"
    if (ex.class != TestFailure)  &&  (bt = ex.backtrace)
      bt.each do |line|
        @out.puts "        #{line}"
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
      fail("#{expected.inspect} expected, but was #{actual.inspect}") unless expected == actual
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

  def initialize(runner)
    @test_runner = runner
  end
  
  def setup
  end
  
  def teardown
  end

  def initiate_test(test_method, completion_callback)
    set_timeout(default_timeout_secs)
    try_exec do
      (method(test_method).arity == 1) or raise(TestError, "Test method #{self.class.name}##{test_method} is missing its completion_callback argument")
      setup
      cc = lambda { try_exec {teardown} ; completion_callback.call }
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


at_exit do
  r = TestEM::Runner.new
  r.run
end


if $0 == __FILE__

  class FooBase < TestEM::TestCase
    # no tests defined here, but should not produce an
    # error, because there are derived classes
  end
  
  class Foo < FooBase
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

  class Bar < TestEM::TestCase
    # no tests defined
  end

  class Baz < TestEM::TestCase
    def test_timeout(completed)
      set_timeout(1)
      # return without calling completed, expect timeout
    end
    
    def test_init_result(completed)
      assert_equal( "uno dos tres.", $initcb )
      completed.call
    end
    
    def test_failure(completed)
      assert_equal("Two plus two", "five")
      raise "Should Never Get Here"
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
  
  include TestEM::Assertions
  
  r = TestEM::Runner.new
  assert(true)
  assert_raises(TestEM::TestFailure) { assert(false) }
  suites = r.find_test_suites
  assert_equal( %w(Bar Baz Foo FooBase), suites.map{|tc| tc.name}.sort )
  suites = r.weed_out_testless_base_classes(suites)
  assert_equal( %w(Bar Baz Foo), suites.map{|tc| tc.name}.sort )
  
  puts <<ENDTXT
We are expecting:
5 assertions, 2 failures, 1 errors.

Baz: TestEM::TestError - TimeOut: Baz#test_timeout duration exceeded 1 seconds

Bar: TestEM::TestFailure - No tests defined.

Baz: TestEM::TestFailure - Baz#test_failure - "Two plus two" expected, but was "five"

ENDTXT
end

