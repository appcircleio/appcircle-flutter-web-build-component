# frozen_string_literal: true

# ─── Coverage (must start before loading main.rb) ─────────────────────────────
unless defined?(Coverage) && Coverage.running?
  require 'coverage'
  Coverage.start
end

# ─── Dependencies ─────────────────────────────────────────────────────────────
require 'rspec'
require 'rspec/core/formatters/base_formatter'
require 'open3'
require 'fileutils'
require 'stringio'
require 'tmpdir'
require 'rbconfig'

MAIN_RB  = File.expand_path('../main.rb', __dir__)
RUBY_BIN = RbConfig.ruby

# ─── Subprocess coverage ──────────────────────────────────────────────────────
# Everything under `if __FILE__ == $PROGRAM_NAME` only runs when main.rb is
# executed as a script, which the ENV-validation and build-flow tests do in a
# subprocess. This boot file is pushed into those subprocesses through RUBYOPT
# so their coverage is measured too, and merged into the report at the end.
CHILD_COVERAGE_DIR     = Dir.mktmpdir('flutter_web_build_child_cov')
CHILD_COVERAGE_RESULTS = File.join(CHILD_COVERAGE_DIR, 'results')
CHILD_COVERAGE_BOOT    = File.join(CHILD_COVERAGE_DIR, 'coverage_boot.rb')
FileUtils.mkdir_p(CHILD_COVERAGE_RESULTS)
File.write(CHILD_COVERAGE_BOOT, <<~'BOOT')
  require 'coverage'
  Coverage.start
  at_exit do
    dir = ENV['AC_TEST_COVERAGE_RESULTS']
    unless dir.nil? || dir.empty?
      File.binwrite(
        File.join(dir, "cov-#{Process.pid}-#{rand(1 << 32)}.dump"),
        Marshal.dump(Coverage.result)
      )
    end
  end
BOOT

require MAIN_RB

# ─── Custom Formatter ─────────────────────────────────────────────────────────
class ReadableFormatter < RSpec::Core::Formatters::BaseFormatter
  RSpec::Core::Formatters.register(
    self,
    :example_group_started,
    :example_group_finished,
    :example_passed,
    :example_failed,
    :example_pending,
    :dump_summary
  )

  PASS  = "\e[32;1m[ PASS ]\e[0m"
  FAIL  = "\e[31;1m[ FAIL ]\e[0m"
  ERROR = "\e[31;1m[ERROR ]\e[0m"
  SKIP  = "\e[33;1m[ SKIP ]\e[0m"

  DIVIDER     = "\e[90m#{'─' * 72}\e[0m"
  DIVIDER_FAT = "\e[90m#{'═' * 72}\e[0m"

  # Top-level describe groups cycle through distinct colors
  GROUP_COLORS = [
    "\e[34;1m", # bold blue
    "\e[35;1m", # bold magenta
    "\e[36;1m", # bold cyan
    "\e[33;1m"  # bold yellow
  ].freeze

  def initialize(output)
    super
    @depth    = 0
    @failures = []
    @counts   = { passed: 0, failed: 0, pending: 0 }
  end

  def example_group_started(notification)
    group = notification.group
    if group.parent_groups.size <= 1
      output.puts if @depth.zero?
      color = GROUP_COLORS[@depth % GROUP_COLORS.size]
      output.puts "  #{color}#{group.description}\e[0m"
    else
      output.puts "    #{'  ' * (@depth - 1)}\e[90m▸ \e[0m\e[37m#{group.description}\e[0m"
    end
    @depth += 1
  end

  def example_group_finished(_notification)
    @depth -= 1 if @depth > 0
  end

  def example_passed(notification)
    @counts[:passed] += 1
    print_example(PASS, notification.example)
  end

  def example_failed(notification)
    @counts[:failed] += 1
    ex    = notification.example
    exc   = ex.execution_result.exception
    badge = exc.is_a?(RSpec::Expectations::ExpectationNotMetError) ? FAIL : ERROR
    print_example(badge, ex)
    @failures << notification
  end

  def example_pending(notification)
    @counts[:pending] += 1
    ex = notification.example
    output.puts "    #{'  ' * [0, @depth - 1].max}#{SKIP}  #{ex.description}"
  end

  def dump_summary(notification)
    output.puts
    output.puts DIVIDER_FAT

    unless @failures.empty?
      output.puts "\n  \e[1;31mFailures:\e[0m\n"
      @failures.each_with_index do |n, i|
        ex  = n.example
        exc = ex.execution_result.exception
        output.puts "  \e[1m#{i + 1}) #{ex.full_description}\e[0m"
        exc.message.lines.first(6).each do |line|
          output.puts "     \e[31m#{line.rstrip}\e[0m"
        end
        output.puts "     \e[90m# #{ex.location}\e[0m"
        output.puts
      end
      output.puts DIVIDER
    end

    total   = notification.examples.size
    passed  = @counts[:passed]
    failed  = @counts[:failed]
    pending = @counts[:pending]
    sec     = format('%.3fs', notification.duration)

    parts = ["\e[32m#{passed} passed\e[0m"]
    parts << "\e[31m#{failed} failed\e[0m"   if failed > 0
    parts << "\e[33m#{pending} pending\e[0m" if pending > 0

    overall = failed.zero? ? "\e[32;1m✔  All #{total} tests passed\e[0m" : "\e[31;1m✖  #{failed} of #{total} tests failed\e[0m"
    output.puts "\n  #{overall}"
    output.puts "  #{parts.join('  |  ')}  \e[90m(#{sec})\e[0m"
    output.puts DIVIDER_FAT
  end

  private

  def print_example(badge, example)
    indent = '  ' * [0, @depth - 1].max
    time   = format('%.3fs', example.execution_result.run_time)
    output.puts "    #{indent}#{badge}  #{example.description}  \e[90m(#{time})\e[0m"
  end
end

# ─── Helpers ──────────────────────────────────────────────────────────────────

# Capture everything written to $stdout while the block runs.
# SystemExit raised inside the block propagates after $stdout is restored.
def capture_stdout
  old = $stdout
  $stdout = StringIO.new
  yield
  $stdout.string
ensure
  captured = $stdout.string if $stdout.is_a?(StringIO)
  $stdout = old
  @last_stdout = captured
end

# Set $? to a chosen exit code without touching the shell or any external
# toolchain: only the already-running Ruby interpreter is spawned. run_command
# reads `$?.exitstatus` after a failed `system`, so the stub has to leave a
# realistic Process::Status behind.
def set_child_status(code)
  Process.wait(Process.spawn(RUBY_BIN, '-e', "exit #{code}"))
end

# Stub Kernel#system on the example so that no command is ever executed.
# Returns the array that collects the composed command strings.
def stub_system(success: true, exit_code: 0)
  captured = []
  allow(self).to receive(:system) do |cmd|
    captured << cmd
    set_child_status(exit_code) unless success
    success
  end
  captured
end

# Kernel#system(nil) raises TypeError before spawning anything; make the stub
# reproduce that so the nil-command test never reaches a shell either.
def stub_system_passthrough_nil
  allow(self).to receive(:system) do |cmd|
    raise TypeError, 'no implicit conversion of nil into String' if cmd.nil?

    true
  end
end

# Writes a stub `flutter` executable so the subprocess tests never invoke the
# real Flutter SDK. It records the arguments it was called with and the working
# directory it ran in — the latter is what proves the `cd` in the composed
# build command actually took effect. On `flutter build …` it writes a small
# fake `build/web` tree into its cwd, which is what main.rb copies afterwards.
# Failure modes are driven by test-only env vars:
#   AC_TEST_FLUTTER_FAIL_ON      sub-command (`config` / `build`) that fails
#   AC_TEST_FLUTTER_EXIT         exit status of that failure
#   AC_TEST_FLUTTER_STDERR       stderr printed on that failure
#   AC_TEST_FLUTTER_STDOUT       stdout printed on every call
#   AC_TEST_FLUTTER_SKIP_OUTPUT  build succeeds but writes no build/web
def build_fake_bin(dir)
  FileUtils.mkdir_p(dir)

  flutter = File.join(dir, 'flutter')
  File.write(flutter, <<~'SH')
    #!/bin/sh
    printf '%s\n' "$*" >> "$AC_TEST_FLUTTER_ARGS_FILE"
    pwd >> "$AC_TEST_FLUTTER_CWD_FILE"
    if [ -n "$AC_TEST_FLUTTER_STDOUT" ]; then
      printf '%s\n' "$AC_TEST_FLUTTER_STDOUT"
    fi
    if [ -n "$AC_TEST_FLUTTER_FAIL_ON" ] && [ "$1" = "$AC_TEST_FLUTTER_FAIL_ON" ]; then
      printf '%s\n' "${AC_TEST_FLUTTER_STDERR:-flutter $1 failed}" >&2
      exit "${AC_TEST_FLUTTER_EXIT:-1}"
    fi
    if [ "$1" = "build" ] && [ -z "$AC_TEST_FLUTTER_SKIP_OUTPUT" ]; then
      mkdir -p build/web/assets
      printf '%s\n' '<html>stub web build</html>' > build/web/index.html
      printf '%s\n' 'main.dart.js' > build/web/main.dart.js
      printf '%s\n' '{}' > build/web/assets/AssetManifest.json
    fi
    exit 0
  SH
  FileUtils.chmod(0o755, flutter)

  dir
end

# Runs main.rb in a subprocess. Every key main.rb reads starts out nil, so a
# "missing variable" case never inherits a value from the test runner.
def run_main(env = {}, chdir: nil, path: nil)
  spawn_env = {
    'AC_FLUTTER_PROJECT_DIR' => nil,
    'AC_OUTPUT_DIR'          => nil,
    'AC_ENV_FILE_PATH'       => nil
  }.merge(env)
  spawn_env['PATH'] = path if path
  spawn_env['AC_TEST_COVERAGE_RESULTS'] = CHILD_COVERAGE_RESULTS
  spawn_env['RUBYOPT'] = [ENV['RUBYOPT'], "-r#{CHILD_COVERAGE_BOOT}"].compact.join(' ').strip

  options = {}
  options[:chdir] = chdir if chdir
  Open3.capture3(spawn_env, RUBY_BIN, MAIN_RB, **options)
end

# A complete, valid step environment inside a tmpdir: a stub toolchain on
# PATH, a project directory, an existing output directory and an env file
# path. `invoke` runs the step from the tmpdir root — deliberately not the
# project directory, so a missing `cd` would show up as a wrong cwd.
RSpec.shared_context 'stubbed step' do
  let(:workdir)     { Dir.mktmpdir('flutter_web_build_run') }
  let(:bindir)      { File.join(workdir, 'fakebin') }
  let(:project_dir) { File.join(workdir, 'flutter_project') }
  let(:output_dir)  { File.join(workdir, 'output') }
  let(:env_file)    { File.join(workdir, 'ac_env_file') }
  let(:args_file)   { File.join(workdir, 'flutter_args.txt') }
  let(:cwd_file)    { File.join(workdir, 'flutter_cwd.txt') }
  let(:web_output)  { File.join(output_dir, 'web') }
  # The stub reports its cwd via the `pwd` shell builtin, which echoes back the
  # logical path `cd` was given. Both sides are resolved before comparing so
  # the assertion holds whether the shell reports the logical or the physical
  # path (on macOS /var is a symlink to /private/var).
  let(:project_realpath) { File.realpath(project_dir) }
  let(:workdir_realpath) { File.realpath(workdir) }

  before do
    build_fake_bin(bindir)
    FileUtils.mkdir_p([project_dir, output_dir])
    FileUtils.touch([args_file, cwd_file])
  end

  after { FileUtils.rm_rf(workdir) }

  def invoke(env = {}, path: "#{bindir}:/usr/bin:/bin")
    run_main(
      {
        'AC_FLUTTER_PROJECT_DIR'    => project_dir,
        'AC_OUTPUT_DIR'             => output_dir,
        'AC_ENV_FILE_PATH'          => env_file,
        'AC_TEST_FLUTTER_ARGS_FILE' => args_file,
        'AC_TEST_FLUTTER_CWD_FILE'  => cwd_file
      }.merge(env),
      chdir: workdir,
      path: path
    )
  end

  def flutter_calls
    File.readlines(args_file, chomp: true)
  end

  def flutter_cwds
    File.readlines(cwd_file, chomp: true).map { |dir| File.realpath(dir) }
  end
end

# ─── Tests ────────────────────────────────────────────────────────────────────

RSpec.describe 'Required libraries' do
  %w[yaml open3 pathname fileutils].each do |lib|
    it "loads '#{lib}'" do
      expect { require lib }.not_to raise_error
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe 'Requiring main.rb' do
  it 'defines get_env_variable and run_command without running the step' do
    expect(respond_to?(:get_env_variable, true)).to be(true)
    expect(respond_to?(:run_command, true)).to be(true)
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe '#get_env_variable' do
  around do |example|
    had_key = ENV.key?('_AC_TEST_VAR')
    old     = ENV['_AC_TEST_VAR']
    example.run
    had_key ? ENV['_AC_TEST_VAR'] = old : ENV.delete('_AC_TEST_VAR')
  end

  it 'returns the value when the key is set' do
    ENV['_AC_TEST_VAR'] = '/tmp/flutter_project'
    expect(get_env_variable('_AC_TEST_VAR')).to eq('/tmp/flutter_project')
  end

  it 'returns the value verbatim, without trimming it' do
    ENV['_AC_TEST_VAR'] = '  /tmp/output  '
    expect(get_env_variable('_AC_TEST_VAR')).to eq('  /tmp/output  ')
  end

  it 'keeps a whitespace-only value, which is not an empty string' do
    ENV['_AC_TEST_VAR'] = ' '
    expect(get_env_variable('_AC_TEST_VAR')).to eq(' ')
  end

  it 'returns nil when the key is missing' do
    ENV.delete('_AC_TEST_VAR')
    expect(get_env_variable('_AC_TEST_VAR')).to be_nil
  end

  it 'returns nil when the value is an empty string' do
    ENV['_AC_TEST_VAR'] = ''
    expect(get_env_variable('_AC_TEST_VAR')).to be_nil
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe '#run_command' do
  it 'passes the command string to system untouched' do
    captured = stub_system
    capture_stdout { run_command('flutter config --enable-web') }
    expect(captured).to eq(['flutter config --enable-web'])
  end

  it 'returns without raising when the command succeeds' do
    stub_system
    expect { capture_stdout { run_command('flutter build web') } }.not_to raise_error
  end

  it 'echoes the command it is about to run' do
    stub_system
    out = capture_stdout { run_command('cd /tmp/app && flutter build web') }
    expect(out).to eq("@@[command] cd /tmp/app && flutter build web\n")
  end

  it 'exits with the exit status of the failed command' do
    stub_system(success: false, exit_code: 65)
    expect { capture_stdout { run_command('flutter build web') } }
      .to raise_error(SystemExit) { |e| expect(e.status).to eq(65) }
  end

  it 'still echoes the command before exiting on failure' do
    stub_system(success: false, exit_code: 65)
    expect { capture_stdout { run_command('flutter build web') } }.to raise_error(SystemExit)
    expect(@last_stdout).to eq("@@[command] flutter build web\n")
  end

  it 'propagates a status of 127 when the command cannot be executed' do
    stub_system(success: false, exit_code: 127)
    expect { capture_stdout { run_command('ac_test_command_that_does_not_exist') } }
      .to raise_error(SystemExit) { |e| expect(e.status).to eq(127) }
  end

  it 'raises TypeError when the command is nil' do
    stub_system_passthrough_nil
    expect { capture_stdout { run_command(nil) } }.to raise_error(TypeError)
  end

  it 'echoes an empty command line when the command is an empty string' do
    stub_system
    out = capture_stdout { run_command('') }
    expect(out).to eq("@@[command] \n")
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe 'ENV validation' do
  # The aborts for the project and output directories happen before any
  # command is composed; a stub toolchain is still put on PATH where the test
  # proves flutter is never reached.
  context 'AC_FLUTTER_PROJECT_DIR' do
    include_context 'stubbed step'

    it 'aborts when the variable is missing' do
      _out, err, status = invoke({ 'AC_FLUTTER_PROJECT_DIR' => nil })
      expect(status.exitstatus).to eq(1)
      expect(err).to include('Missing Flutter project path.')
    end

    it 'aborts when the variable is an empty string' do
      _out, err, status = invoke({ 'AC_FLUTTER_PROJECT_DIR' => '' })
      expect(status.exitstatus).to eq(1)
      expect(err).to include('Missing Flutter project path.')
    end

    it 'never invokes flutter when the variable is missing' do
      _out, _err, status = invoke({ 'AC_FLUTTER_PROJECT_DIR' => nil })
      expect(status.exitstatus).to eq(1)
      expect(flutter_calls).to be_empty
    end
  end

  context 'AC_OUTPUT_DIR' do
    include_context 'stubbed step'

    it 'aborts when the variable is missing' do
      _out, err, status = invoke({ 'AC_OUTPUT_DIR' => nil })
      expect(status.exitstatus).to eq(1)
      expect(err).to include('Missing output folder.')
    end

    it 'aborts when the variable is an empty string' do
      _out, err, status = invoke({ 'AC_OUTPUT_DIR' => '' })
      expect(status.exitstatus).to eq(1)
      expect(err).to include('Missing output folder.')
    end

    it 'never invokes flutter when the variable is missing' do
      _out, _err, status = invoke({ 'AC_OUTPUT_DIR' => nil })
      expect(status.exitstatus).to eq(1)
      expect(flutter_calls).to be_empty
    end
  end

  context 'when every required variable is missing' do
    it 'reports only the project path, which is validated first' do
      Dir.mktmpdir('flutter_web_build_env') do |dir|
        _out, err, status = run_main({}, chdir: dir)
        expect(status.exitstatus).to eq(1)
        expect(err).to include('Missing Flutter project path.')
        expect(err).not_to include('Missing output folder.')
      end
    end
  end

  # AC_ENV_FILE_PATH is read straight from ENV (not through get_env_variable)
  # and only at the very end, so the step builds and copies before it fails.
  # These cases document that behaviour rather than endorse it.
  context 'AC_ENV_FILE_PATH' do
    include_context 'stubbed step'

    it 'fails with a TypeError when the variable is missing' do
      _out, err, status = invoke({ 'AC_ENV_FILE_PATH' => nil })
      expect(status.exitstatus).to eq(1)
      expect(err).to include('no implicit conversion of nil into String')
      expect(err).to include('TypeError')
    end

    it 'fails with ENOENT when the variable is an empty string' do
      _out, err, status = invoke({ 'AC_ENV_FILE_PATH' => '' })
      expect(status.exitstatus).to eq(1)
      expect(err).to include('No such file or directory')
      expect(err).to include('Errno::ENOENT')
    end

    it 'fails with ENOENT when the variable points into a missing directory' do
      _out, err, status = invoke({ 'AC_ENV_FILE_PATH' => File.join(workdir, 'no-such-dir', 'env') })
      expect(status.exitstatus).to eq(1)
      expect(err).to include('Errno::ENOENT')
    end

    it 'only fails after the build ran and the artifacts were copied' do
      _out, _err, status = invoke({ 'AC_ENV_FILE_PATH' => nil })
      expect(status.exitstatus).to eq(1)
      expect(flutter_calls).to eq(['config --enable-web', 'build web'])
      expect(File).to exist(File.join(web_output, 'index.html'))
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe 'Build flow (stubbed toolchain)' do
  include_context 'stubbed step'

  context 'happy path' do
    it 'exits 0' do
      _out, _err, status = invoke
      expect(status.exitstatus).to eq(0)
    end

    it 'echoes the exact composed commands in order' do
      out, _err, _status = invoke
      enable = out.index("@@[command] flutter config --enable-web\n")
      build  = out.index("@@[command] cd #{project_dir} && flutter build web\n")
      expect(enable).not_to be_nil
      expect(build).not_to be_nil
      expect(enable).to be < build
    end

    it 'enables web support and then builds, invoking flutter exactly twice' do
      invoke
      expect(flutter_calls).to eq(['config --enable-web', 'build web'])
    end

    it 'runs `flutter config` in the step cwd and `flutter build web` inside the project directory' do
      invoke
      expect(flutter_cwds).to eq([workdir_realpath, project_realpath])
    end

    it 'copies build/web into <AC_OUTPUT_DIR>/web' do
      invoke
      expect(File.read(File.join(web_output, 'index.html'))).to eq("<html>stub web build</html>\n")
      expect(File.read(File.join(web_output, 'main.dart.js'))).to eq("main.dart.js\n")
    end

    it 'copies nested directories of the web build' do
      invoke
      expect(File.read(File.join(web_output, 'assets', 'AssetManifest.json'))).to eq("{}\n")
    end

    it 'leaves the original build output in the project directory' do
      invoke
      expect(File).to exist(File.join(project_dir, 'build', 'web', 'index.html'))
    end

    it 'prints the copy and export messages' do
      out, _err, _status = invoke
      expect(out).to include("Copying artifacts to output folder...\n")
      expect(out).to include("Exporting AC_FLUTTER_WEB_PATH=#{web_output}\n")
    end

    it 'writes AC_FLUTTER_WEB_PATH to the env file' do
      invoke
      expect(File.read(env_file)).to eq("AC_FLUTTER_WEB_PATH=#{web_output}\n")
    end

    it 'appends to an existing env file without truncating it' do
      File.write(env_file, "AC_EXISTING_VAR=1\n")
      invoke
      expect(File.read(env_file)).to eq("AC_EXISTING_VAR=1\nAC_FLUTTER_WEB_PATH=#{web_output}\n")
    end

    it 'streams the output of flutter' do
      out, _err, _status = invoke({ 'AC_TEST_FLUTTER_STDOUT' => 'Compiling lib/main.dart for the Web...' })
      expect(out).to include('Compiling lib/main.dart for the Web...')
    end
  end

  context 'when the output web folder already exists' do
    it 'overwrites files of the same name and keeps unrelated ones' do
      FileUtils.mkdir_p(web_output)
      File.write(File.join(web_output, 'index.html'), "stale\n")
      File.write(File.join(web_output, 'leftover.txt'), "old\n")

      _out, _err, status = invoke
      expect(status.exitstatus).to eq(0)
      expect(File.read(File.join(web_output, 'index.html'))).to eq("<html>stub web build</html>\n")
      expect(File.read(File.join(web_output, 'leftover.txt'))).to eq("old\n")
    end
  end

  context 'when the project path has a trailing slash' do
    it 'still builds in the project directory and copies the output' do
      _out, _err, status = invoke({ 'AC_FLUTTER_PROJECT_DIR' => "#{project_dir}/" })
      expect(status.exitstatus).to eq(0)
      expect(flutter_cwds.last).to eq(project_realpath)
      expect(File).to exist(File.join(web_output, 'index.html'))
    end
  end

  context 'when `flutter config --enable-web` fails' do
    let(:failing) do
      { 'AC_TEST_FLUTTER_FAIL_ON' => 'config', 'AC_TEST_FLUTTER_EXIT' => '3',
        'AC_TEST_FLUTTER_STDERR' => 'Could not update flutter config.' }
    end

    it 'exits with the exit status of the flutter process' do
      _out, _err, status = invoke(failing)
      expect(status.exitstatus).to eq(3)
    end

    it 'surfaces the stderr of flutter' do
      _out, err, _status = invoke(failing)
      expect(err).to include('Could not update flutter config.')
    end

    it 'never runs the build, copies nothing and does not touch the env file' do
      invoke(failing)
      expect(flutter_calls).to eq(['config --enable-web'])
      expect(File).not_to exist(web_output)
      expect(File).not_to exist(env_file)
    end
  end

  context 'when `flutter build web` fails' do
    let(:failing) do
      { 'AC_TEST_FLUTTER_FAIL_ON' => 'build', 'AC_TEST_FLUTTER_EXIT' => '65',
        'AC_TEST_FLUTTER_STDERR' => 'Target dart2js failed.' }
    end

    it 'exits with the exit status of the flutter process' do
      _out, _err, status = invoke(failing)
      expect(status.exitstatus).to eq(65)
    end

    it 'surfaces the stderr of the build' do
      _out, err, _status = invoke(failing)
      expect(err).to include('Target dart2js failed.')
    end

    it 'does not copy artifacts or export AC_FLUTTER_WEB_PATH' do
      out, _err, _status = invoke(failing)
      expect(out).not_to include('Copying artifacts to output folder...')
      expect(File).not_to exist(web_output)
      expect(File).not_to exist(env_file)
    end
  end

  context 'when the build succeeds but produces no build/web folder' do
    it 'fails on the copy and never exports AC_FLUTTER_WEB_PATH' do
      out, err, status = invoke({ 'AC_TEST_FLUTTER_SKIP_OUTPUT' => '1' })
      expect(status.exitstatus).to eq(1)
      expect(out).to include('Copying artifacts to output folder...')
      expect(err).to include('Errno::ENOENT')
      expect(File).not_to exist(env_file)
    end
  end

  context 'when the parent of AC_OUTPUT_DIR does not exist' do
    it 'fails on the copy and never exports AC_FLUTTER_WEB_PATH' do
      missing_output = File.join(workdir, 'no-such-parent', 'output')
      _out, err, status = invoke({ 'AC_OUTPUT_DIR' => missing_output })
      expect(status.exitstatus).to eq(1)
      expect(err).to include('Errno::ENOENT')
      expect(File).not_to exist(env_file)
    end
  end

  context 'when the project path does not exist' do
    it 'fails because the cd fails, and never runs the build' do
      _out, err, status = invoke({ 'AC_FLUTTER_PROJECT_DIR' => File.join(workdir, 'no-such-project') })
      expect(status.exitstatus).not_to eq(0)
      expect(err).to include('No such file or directory')
      expect(flutter_calls).to eq(['config --enable-web'])
      expect(File).not_to exist(env_file)
    end
  end

  context 'when the project path is a file rather than a directory' do
    it 'fails because the cd fails, and never runs the build' do
      pubspec = File.join(workdir, 'pubspec.yaml')
      FileUtils.touch(pubspec)
      _out, err, status = invoke({ 'AC_FLUTTER_PROJECT_DIR' => pubspec })
      expect(status.exitstatus).not_to eq(0)
      expect(err).to include('Not a directory')
      expect(flutter_calls).to eq(['config --enable-web'])
    end
  end

  # `flutter config --enable-web` has no shell metacharacters, so Kernel#system
  # execs it directly instead of going through /bin/sh: a missing binary makes
  # `system` return nil with no shell error on stderr, and `$?` reports 127.
  context 'when flutter is not on PATH' do
    it 'exits 127 on the first flutter command and never reaches the build' do
      out, _err, status = invoke({}, path: '/usr/bin:/bin')
      expect(status.exitstatus).to eq(127)
      expect(out).to include("@@[command] flutter config --enable-web\n")
      expect(out).not_to include('flutter build web')
      expect(flutter_calls).to be_empty
      expect(File).not_to exist(env_file)
    end
  end

  # The path is interpolated into a shell command without quoting, so a space
  # in it splits into two words and the step fails instead of building. This
  # documents the current behaviour rather than endorsing it.
  context 'when the project path contains a space' do
    it 'fails because the unquoted path is split by the shell' do
      spaced = File.join(workdir, 'my project')
      FileUtils.mkdir_p(spaced)
      _out, _err, status = invoke({ 'AC_FLUTTER_PROJECT_DIR' => spaced })
      expect(status.exitstatus).not_to eq(0)
      expect(flutter_calls).to eq(['config --enable-web'])
      expect(File).not_to exist(env_file)
    end
  end
end

# ─── Coverage Report ──────────────────────────────────────────────────────────

# Merges the in-process result with every subprocess dump, so lines that only
# run under `if __FILE__ == $PROGRAM_NAME` are counted as the covered lines
# they are.
def merged_main_coverage
  results = []

  if defined?(Coverage) && Coverage.running?
    results << begin
      Coverage.result(stop: false, clear: false)
    rescue ArgumentError
      Coverage.result
    end
  end

  child_dumps = Dir.glob(File.join(CHILD_COVERAGE_RESULTS, '*.dump')).sort
  child_dumps.each do |file|
    results << Marshal.load(File.binread(file))
  rescue StandardError
    next
  end

  merged = nil
  results.each do |result|
    key = result.keys.find { |path| path&.end_with?('main.rb') }
    next unless key

    data = result[key]
    if merged.nil?
      merged = data.dup
    elsif merged.size == data.size
      data.each_with_index do |count, i|
        next if count.nil? || merged[i].nil?

        merged[i] += count
      end
    end
  end

  [merged, child_dumps.size]
end

def print_coverage_report
  merged, child_runs = merged_main_coverage
  return puts("\nCoverage: main.rb not found in results") if merged.nil?

  lines     = merged.each_with_index.reject { |count, _| count.nil? }
  total     = lines.size
  covered   = lines.count { |count, _| count.to_i > 0 }
  pct       = total.positive? ? (covered * 100.0 / total).round(1) : 100.0
  uncovered = lines.select { |count, _| count.to_i == 0 }.map { |_, i| i + 1 }

  color      = pct == 100 ? "\e[32;1m" : pct >= 80 ? "\e[33m" : "\e[31m"
  bar_filled = (pct / 5).round
  bar        = "\e[32m#{'█' * bar_filled}\e[90m#{'░' * (20 - bar_filled)}\e[0m"

  puts "\n\e[90m#{'═' * 72}\e[0m"
  puts '  Coverage Report'
  puts "\e[90m#{'─' * 72}\e[0m"
  puts "  main.rb  #{bar}  #{color}#{pct}%\e[0m  (#{covered}/#{total} lines)"
  puts "  \e[90mmerged from this process + #{child_runs} subprocess run(s)\e[0m"
  if uncovered.any? && uncovered.size <= 20
    puts "  Uncovered lines: \e[90m#{uncovered.join(', ')}\e[0m"
  elsif uncovered.any?
    puts "  Uncovered lines: \e[90m#{uncovered.first(15).join(', ')} … (+#{uncovered.size - 15} more)\e[0m"
  end
  puts "\e[90m#{'═' * 72}\e[0m"
end

# ─── Runner ───────────────────────────────────────────────────────────────────
if __FILE__ == $PROGRAM_NAME
  RSpec.configure do |config|
    config.add_formatter ReadableFormatter
    config.color = true
    config.order = :defined
  end

  exit_code = RSpec::Core::Runner.run(['--order', 'defined'])
  print_coverage_report
  FileUtils.rm_rf(CHILD_COVERAGE_DIR)
  exit exit_code
end
