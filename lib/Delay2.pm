{

package Delay2;

    use Mojo::Base 'Mojo::IOLoop::Delay';

    has autodie => 1;

    sub _step {
      my ($self, $id, $offset, $len) = (shift, shift, shift, shift);

      $self->{args}[$id]
        = [@_ ? defined $len ? splice @_, $offset, $len : splice @_, $offset : ()];
      return $self if $self->{fail} || --$self->{pending} || $self->{lock};
      local $self->{lock} = 1;
      my @args = map {@$_} @{delete $self->{args}};

      $self->{counter} = 0;
      if (my $cb = shift @{$self->{steps}}) {
        my $err;
        my $i = 1;
        $err = join "; ", grep { ref($_) ne "Mojo::Transaction::HTTP" and $i++ %2 and $_ } @args
            if $self->autodie;

        unless (!$err && eval { $self->$cb(@args); 1 }) {
          # my $err = $@;
          $err ||= $@;
          @{$self}{qw(fail steps)} = (1, []);
          return $self->reject($err)->emit(error => $err);
        }
      }

      ($self->{steps} = []) and return $self->resolve(@args)->emit(finish => @args)
        unless $self->{counter};
      $self->ioloop->next_tick($self->begin) unless $self->{pending};
      return $self;
    }

    # sub _step {
      # my ($self, $id, $offset, $len) = (shift, shift, shift, shift);

      # $self->{args}[$id]
        # = [@_ ? defined $len ? splice @_, $offset, $len : splice @_, $offset : ()];
      # return $self if $self->{fail} || --$self->{pending} || $self->{lock};
      # local $self->{lock} = 1;
      # my @args = map {@$_} @{delete $self->{args}};

      # $self->{counter} = 0;
      # if (my $cb = shift @{$self->remaining}) {
        # my $err;
        # my $i = 1;
        # $err = join "; ", grep { ref($_) ne "Mojo::Transaction::HTTP" and $i++ %2 and $_ } @args if $self->autodie;
        # !$err && eval { $self->$cb(@args); 1 }
          # or (++$self->{fail} and return $self->remaining([])->emit(error => $err || $@));	  
      # }

      # return $self->remaining([])->emit(finish => @args) unless $self->{counter};
      # $self->ioloop->next_tick($self->begin) unless $self->{pending};
      # return $self;
    # }

}

1;
