package App::DuckPAN::Cmd::Query;
# ABSTRACT: Command line tool for testing queries and see triggered instant answers

use MooX;
with qw( App::DuckPAN::Cmd );

use MooX::Options protect_argv => 0;

sub run {
    my ($self, @args) = @_;

    $self->app->check_requirements;    # Will exit if missing

    require App::DuckPAN::Query;
    exit App::DuckPAN::Query->run($self->app, \@args);
}

1;
