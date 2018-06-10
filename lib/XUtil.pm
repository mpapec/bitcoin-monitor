{
package XUtil;
    use strict;
    use warnings;

    use Exporter 'import';
    our @EXPORT_OK = qw( fasync fstop );

    sub fasync(&) {
      my ($worker) = @_;

      use POSIX ":sys_wait_h";
      my $pid = fork() // die "can't fork!";

      if (!$pid) {
        $worker->();
        exit(0);
      }

      return sub {
        my %arg = @_;
        return $pid if $arg{getpid};
        return kill($arg{kill}, $pid) if $arg{kill};
        return !waitpid($pid, $arg{wait} ? 0 : WNOHANG);
      }
    }

    sub fstop {
      my ($async, $repeat) = @_;
      $repeat ||= 1;

      for my $i (1 .. $repeat) {
        my $sent = $async->(kill => 15); sleep 1; $async->();
        if (!$sent or !$async->(kill => 0)) {
            return $sent ? "terminated" : "alreadyGone";
        }
      }
      $async->(kill => 9); sleep 1; $async->();
      return $async->(kill => 0) ? undef : "forced";
    }

}

1;
