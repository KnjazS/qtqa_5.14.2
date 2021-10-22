#!/usr/bin/env perl
use 5.010;
use strict;
use warnings;
use utf8;

=head1 NAME

10-testrunner.t - basic test for testrunner.pl

=head1 SYNOPSIS

  perl ./10-testrunner.t

This test will run the testrunner.pl script with a few different
types of subprocesses and verify that behavior is as expected.

=cut

use Encode;
use English qw( -no_match_vars );
use File::Basename;
use File::Spec::Functions;
use File::chdir;
use FindBin;
use Readonly;
use Test::More;
use Capture::Tiny qw( capture );

use lib "$FindBin::Bin/../../lib/perl5";
use QtQA::Test::More qw( is_or_like );

# 1 if Windows
Readonly my $WINDOWS => ($OSNAME =~ m{win32}i);

# Directory containing some helper scripts
Readonly my $HELPER_DIR => catfile( $FindBin::Bin, 'helpers' );

# perl to print @ARGV unambiguously from a subprocess
# (not used directly)
Readonly my $TESTSCRIPT_BASE
    => q{use Data::Dumper; print Data::Dumper->new( \@ARGV )->Indent( 0 )->Dump( ); };

# perl to print @ARGV unambiguously and exit successfully
Readonly my $TESTSCRIPT_SUCCESS
    => $TESTSCRIPT_BASE . 'exit 0';

# perl to print @ARGV unambiguously and exit normally but unsuccessfully
Readonly my $TESTSCRIPT_FAIL
    => $TESTSCRIPT_BASE . 'exit 3';

# perl to print current working directory and exit normally
Readonly my $TESTSCRIPT_PRINT_CWD
    => q{use File::chdir; use File::Spec::Functions; say canonpath $CWD};

# Pattern matching --verbose 'begin' line, without trailing \n.
# 'label' is captured.
Readonly my $TESTRUNNER_VERBOSE_BEGIN
    => qr{\QQtQA::App::TestRunner: begin \E(?<label>.*?)\s\@.*?\Q: [perl]\E[^\n]*};

# Pattern matching --verbose 'end' line, without trailing \n.
# Ends with [^\n]*, so it can match or not match the exit status portion,
# as appropriate.
# 'label' is captured.
Readonly my $TESTRUNNER_VERBOSE_END
    => qr{\QQtQA::App::TestRunner: end \E(?<label>[^:]+)\Q: \E[^\n]*};

# expected STDERR when a process segfaults;
# note that we have no way to control if the system will create core dumps or not,
# so we will accept either case
Readonly my $TESTERROR_CRASH_VERBOSE
    => qr{\A $TESTRUNNER_VERBOSE_BEGIN \n}xms
      .(($WINDOWS)
          ? qr{
              \QQtQA::App::TestRunner: Process exited with exit code 0xC0000005 (STATUS_ACCESS_VIOLATION)\E\n
              $TESTRUNNER_VERBOSE_END\Q, exit code 3221225477\E\n
            \z}xms
          : qr{
              \QQtQA::App::TestRunner: Process exited due to signal 11\E(?:;\ dumped\ core)?\n
              $TESTRUNNER_VERBOSE_END\Q, signal 11\E\n
            \z}xms
      );

# expected STDERR when a process divides by zero
Readonly my $TESTERROR_DIVIDE_BY_ZERO
    => ($WINDOWS)
        ? "QtQA::App::TestRunner: Process exited with exit code 0xC0000094 (STATUS_INTEGER_DIVIDE_BY_ZERO)\n"
        : qr{\AQtQA::App::TestRunner: Process exited due to signal 8(?:; dumped core)?\n\z};

# perl to print @ARGV unambiguously and hang
Readonly my $TESTSCRIPT_HANG
    => $TESTSCRIPT_BASE . 'while (1) { sleep(1000) }';

# hardcoded value (seconds) for timeout test
Readonly my $TIMEOUT
    =>  2;

# perl to print @ARGV unambiguously and sleep for set period
Readonly my $TESTSCRIPT_TIMEOUT_WARNING
    => $TESTSCRIPT_BASE . 'sleep(4); exit 0';

# hardcoded value (seconds) for timeout warning test
Readonly my $TIMEOUT_WARNING
    =>  5;

# Message generated by killing a process when it times out;
# on Unix, we do this by SIGTERM, while on Windows, we expect
# no message because the process appears to exit normally
Readonly my $KILL_MESSAGE =>
    $WINDOWS ? q{}
  :            qr{QtQA::App::TestRunner: Process exited due to signal 15\n}
;

# expected STDERR when wrapping the above
Readonly my $TESTERROR_HANG => qr{
        QtQA::App::TestRunner:\ Timed\ out\ after\ \d+\ seconds?\n
        $KILL_MESSAGE
}xms;

# expect STDERR when timeout duration warning is issued
Readonly my $TESTSUCCESS_TIMEOUT_WARNING => qr{
        \QQtQA::App::TestRunner: warning: test duration (4 seconds) is dangerously close to maximum permitted time (5 seconds)\E\n
        \QQtQA::App::TestRunner: warning: Either modify the test to reduce its runtime, or use a higher timeout.\E\n
}xms;


# Various interesting sets of arguments, with their expected serialization from
# the subprocess.
#
# This dataset essentially aims to confirm that there is never any special munging
# of arguments, and arguments are always passed to the subprocess exactly as they
# were passed to the testrunner.
#
# Note that the right hand side of these assignments of course could be generated
# by using Data::Dumper in this test rather than writing it by hand, but this
# is deliberately avoided to reduce the risk of accidentally writing an identical
# bug into both this test script and the test subprocess.
Readonly my %TESTSCRIPT_ARGUMENTS => (

    'no args' => [
        [
        ] => q{},
    ],

    'trivial' => [
        [
            'hello',
        ] => q{$VAR1 = 'hello';},
    ],

    'whitespace' => [
        [
            'hello there',
            ' ',
        ] => q{$VAR1 = 'hello there';$VAR2 = ' ';},
    ],

    'posix sh metacharacters' => [
        [
            q{hello |there},
            q{how $are "you' !today},
        ] => q{$VAR1 = 'hello |there';$VAR2 = 'how $are "you\' !today';},
    ],

    'windows cmd metacharacters' => [
        [
            q{hello %there%},
            q{how ^are "you' today},
        ] => q{$VAR1 = 'hello %there%';$VAR2 = 'how ^are "you\' today';},
    ],

    'non-ascii' => [
        [
            q{早上好},
            q{你好马？},
        ] => encode_utf8( q{$VAR1 = '早上好';$VAR2 = '你好马？';} ),
    ],
);

# Do a single test of QtQA::App::TestRunner->run( ).
# Returns a hash of the actual output, error and status, in case additional
# testing is desired.
sub test_run
{
    my ($params_ref) = @_;

    my @args              = @{$params_ref->{ args }};
    my $expected_stdout   =   $params_ref->{ expected_stdout };
    my $expected_stderr   =   $params_ref->{ expected_stderr };
    my $expected_success  =   $params_ref->{ expected_success };
    my $testname          =   $params_ref->{ testname }          || q{};

    my $status;
    my ($output, $error) = capture {
        $status = system( 'perl', "$FindBin::Bin/../testrunner.pl", @args );
    };

    if ($expected_success) {
        is  ( $status, 0, "$testname exits zero" );
    }
    else {
        isnt( $status, 0, "$testname exits non-zero" );
    }

    is_or_like( $output, $expected_stdout, "$testname output looks correct" );
    is_or_like( $error,  $expected_stderr, "$testname error looks correct" );

    return (
        output => $output,
        error => $error,
        status => $status,
    );
}

sub test_success
{
    while (my ($testdata_name, $testdata_ref) = each %TESTSCRIPT_ARGUMENTS) {
        TODO: {
            if ($WINDOWS && $testdata_name =~ m{metacharacters}) {
                todo_skip( 'handling of shell metacharacters not yet defined on Windows', 1 );
            }

            test_run({
                args                =>  [ 'perl', '-e', $TESTSCRIPT_SUCCESS, @{$testdata_ref->[0]} ],
                expected_stdout     =>  $testdata_ref->[1],
                expected_stderr     =>  q{},
                expected_success    =>  1,
                testname            =>  "successful $testdata_name",
            });
        }
    }

    return;
}

# Basic test of --verbose with passing, failing or hanging test.
# Crashing with --verbose is tested in test_crashing
sub test_verbose
{
    my ($args_ref, $stdout) = @{ $TESTSCRIPT_ARGUMENTS{ 'trivial' } };
    my @args = @{ $args_ref };

    my $stderr_success = qr{
        \A
        $TESTRUNNER_VERBOSE_BEGIN\n
        $TESTRUNNER_VERBOSE_END\Q, exit code 0\E\n
        \z
    }xms;

    my $stderr_fail = qr{
        \A
        $TESTRUNNER_VERBOSE_BEGIN\n
        $TESTRUNNER_VERBOSE_END\Q, exit code 3\E\n
        \z
    }xms;

    my $stderr_hang = qr{
        \A
        $TESTRUNNER_VERBOSE_BEGIN\n
        $TESTERROR_HANG
        $TESTRUNNER_VERBOSE_END\n   # note, exit status is undefined (thus untested) on hang
    }xms;

    my $stderr_timeout_warning = qr{
        \A
        $TESTRUNNER_VERBOSE_BEGIN\n
        $TESTSUCCESS_TIMEOUT_WARNING
        $TESTRUNNER_VERBOSE_END\n
        \z
    }xms;

    my %result;

    %result = test_run({
        args                =>  [ '--verbose', '--', 'perl', '-e', $TESTSCRIPT_SUCCESS, @args ],
        expected_stdout     =>  $stdout,
        expected_stderr     =>  $stderr_success,
        expected_success    =>  1,
        testname            =>  "verbose success",
    });
    ok( $result{ error } =~ $TESTRUNNER_VERBOSE_BEGIN )
        && is( $+{ label }, 'perl', 'label defaults to command name (begin)' );
    ok( $result{ error } =~ $TESTRUNNER_VERBOSE_END )
        && is( $+{ label }, 'perl', 'label defaults to command name (end)' );

    %result = test_run({
        args                =>  [ '--verbose', '--label=failure test', '--', 'perl', '-e', $TESTSCRIPT_FAIL, @args ],
        expected_stdout     =>  $stdout,
        expected_stderr     =>  $stderr_fail,
        expected_success    =>  0,
        testname            =>  "verbose fail",
    });
    ok( $result{ error } =~ $TESTRUNNER_VERBOSE_BEGIN )
        && is( $+{ label }, 'failure test', 'explicitly setting label works as expected (begin)' );
    ok( $result{ error } =~ $TESTRUNNER_VERBOSE_END )
        && is( $+{ label }, 'failure test', 'explicitly setting label works as expected (end)' );

    %result = test_run({
        args                =>  [ '--verbose', '--label=mytestcase::mytestfunc', '--timeout', $TIMEOUT, '--', 'perl', '-e', $TESTSCRIPT_HANG, @args ],
        expected_stdout     =>  undef,  # output is undefined when killed from timeout
        expected_stderr     =>  $stderr_hang,
        expected_success    =>  0,
        testname            =>  "verbose hanging",
    });
    ok( $result{ error } =~ $TESTRUNNER_VERBOSE_BEGIN )
        && is( $+{ label }, 'mytestcase__mytestfunc', ': is stripped from label (begin)' );
    ok( $result{ error } =~ $TESTRUNNER_VERBOSE_END )
        && is( $+{ label }, 'mytestcase__mytestfunc', ': is stripped from label (end)' );

    test_run({
        args                =>  [ '--verbose', '--timeout', $TIMEOUT_WARNING, '--', 'perl', '-e', $TESTSCRIPT_TIMEOUT_WARNING, @args ],
        expected_stdout     =>  $stdout,
        expected_stderr     =>  $stderr_timeout_warning,
        expected_success    =>  1,
        testname            =>  "timeout warning",
    });

    return;
}

sub test_normal_nonzero_exitcode
{
    while (my ($testdata_name, $testdata_ref) = each %TESTSCRIPT_ARGUMENTS) {
        TODO: {
            if ($WINDOWS && $testdata_name =~ m{metacharacters}) {
                todo_skip( 'handling of shell metacharacters not yet defined on Windows', 1 );
            }

            test_run({
                args                =>  [ 'perl', '-e', $TESTSCRIPT_FAIL, @{$testdata_ref->[0]} ],
                expected_stdout     =>  $testdata_ref->[1],
                expected_stderr     =>  q{},
                expected_success    =>  0,
                testname            =>  "failure $testdata_name",
            });
        }
    }

    return;
}

sub test_crashing
{
    my $crash_script = catfile( $HELPER_DIR, 'dereference_bad_pointer.pl' );
    while (my ($testdata_name, $testdata_ref) = each %TESTSCRIPT_ARGUMENTS) {
        test_run({
            args                =>  [ '--verbose', '--', 'perl', $crash_script, @{$testdata_ref->[0]} ],
            expected_stdout     =>  undef,  # output is undefined when crashing
            expected_stderr     =>  qr{$TESTERROR_CRASH_VERBOSE},
            expected_success    =>  0,
            testname            =>  "crash $testdata_name",
        });
    }

    return;
}

sub test_divide_by_zero
{
    my $crash_script = catfile( $HELPER_DIR, 'divide_by_zero.pl' );
    while (my ($testdata_name, $testdata_ref) = each %TESTSCRIPT_ARGUMENTS) {
        test_run({
            args                =>  [ 'perl', $crash_script, @{$testdata_ref->[0]} ],
            expected_stdout     =>  undef,  # output is undefined when crashing
            expected_stderr     =>  $TESTERROR_DIVIDE_BY_ZERO,
            expected_success    =>  0,
            testname            =>  "divide by zero $testdata_name",
        });
    }

    return;
}

sub test_hanging
{
    while (my ($testdata_name, $testdata_ref) = each %TESTSCRIPT_ARGUMENTS) {
        my @args = (
            # timeout after some seconds
            '--timeout',
            $TIMEOUT,

            'perl',
            '-e',
            $TESTSCRIPT_HANG,
            @{$testdata_ref->[0]},
        );
        test_run({
            args                =>  \@args,
            expected_stdout     =>  undef,  # output is undefined when killed from timeout
            expected_stderr     =>  qr{\A$TESTERROR_HANG\z},
            expected_success    =>  0,
            testname            =>  "hanging $testdata_name",
        });
    }

    return;
}

# Test that testrunner.pl parses its own arguments OK and does not steal arguments
# from the child process
sub test_arg_parsing
{
    # basic test: testrunner.pl with no args will fail
    test_run({
        args                =>  [],
        expected_stdout     =>  q{},
        expected_stderr     =>  qr{not enough arguments},
        expected_success    =>  0,
        testname            =>  "fails with no args",
    });

    # basic test: testrunner.pl parses --help by itself, and stops
    test_run({
        args                =>  [ '--help', 'perl', '-e', 'print "Hello\n"' ],
        expected_stdout     =>  qr{\A Usage: \s}xms,
        expected_stderr     =>  q{},
        expected_success    =>  0,
        testname            =>  "--help parsed OK",
    });

    # test that testrunner.pl does not parse --help if it comes after --
    test_run({
        args                =>  [ '--', '--help' ],
        expected_stdout     =>  q{},
        expected_stderr     =>  (
            !$WINDOWS
                ? qr{--help: No such file or directory}
                : qr{'--help' is not recognized as }
        ),
        expected_success    =>  0,
        testname            =>  "-- stops argument processing",
    });

    return;
}

sub test_chdir
{
    my (undef, $parentdir) = fileparse( $CWD );
    $parentdir = canonpath $parentdir;

    my @cmd = ('perl', '-E', $TESTSCRIPT_PRINT_CWD);

    # Without chdir, CWD should be the same as parent process
    test_run({
        args                =>  [ '--', @cmd ],
        expected_stdout     => "$CWD\n",
        expected_stderr     => q{},
        expected_success    => 1,
        testname            => 'cwd as expected with no chdir',
    });

    test_run({
        args                =>  [ '--chdir', $parentdir, '--', @cmd ],
        expected_stdout     => "$parentdir\n",
        expected_stderr     => q{},
        expected_success    => 1,
        testname            => 'cwd as expected with --chdir',
    });

    test_run({
        args                =>  [ '-C', $parentdir, '--', @cmd ],
        expected_stdout     => "$parentdir\n",
        expected_stderr     => q{},
        expected_success    => 1,
        testname            => 'cwd as expected with -C',
    });

    return;
}

sub run
{
    test_arg_parsing;

    test_success;
    test_verbose;
    test_normal_nonzero_exitcode;
    test_crashing;
    SKIP: {
        skip( 'divide by zero is unpredictable on mac', 1 ) if ($OSNAME =~ m{darwin}i);
        test_divide_by_zero;
    }
    test_hanging;
    test_chdir;

    done_testing;

    return;
}

run if (!caller);
1;
