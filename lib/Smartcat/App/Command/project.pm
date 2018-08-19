# ABSTRACT: get project details
use strict;
use warnings;

package Smartcat::App::Command::project;
use Smartcat::App -command;

sub opt_spec {
    my ($self) = @_;

    my @opts = $self->SUPER::opt_spec;
    push @opts, $self->project_id_opt_spec;

    return @opts;
}

sub validate_args {
    my ( $self, $opt, $args ) = @_;

    $self->SUPER::validate_args( $opt, $args );
    $self->validate_project_id( $opt, $args );
}

sub execute {
    my ( $self, $opt, $args ) = @_;

    my $api     = $self->app->project_api;
    my $project = $api->get_project;

    print "Project:\n\t" . $project->name . "\n";
    print "Documents:\n";
    print "\t"
      . $_->name
      . "\n\t\tid: $_->{id}\n\t\tstatus: "
      . $_->status
      . "\n\t\tlanguage: "
      . $_->target_language . "\n"
      for @{ $project->documents };
    print "Target languages:\n";
    print "\t" . join( ' ', @{ $project->target_languages } ) . "\n";
    print "Status:\n\t" . $project->status . "\n";
    print "\n";
}

1;
