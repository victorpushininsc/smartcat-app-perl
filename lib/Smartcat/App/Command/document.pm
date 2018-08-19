# ABSTRACT: get document details
use strict;
use warnings;

package Smartcat::App::Command::document;
use Smartcat::App -command;

sub opt_spec {
    my ($self) = @_;

    my @opts = $self->SUPER::opt_spec();

    push @opts, [ 'document-id:s' => 'Document Id' ],;

    return @opts;
}

sub validate_args {
    my ( $self, $opt, $args ) = @_;

    $self->SUPER::validate_args( $opt, $args );
    $self->usage_error("'document_id' is required")
      unless defined $opt->{document_id};
}

sub execute {
    my ( $self, $opt, $args ) = @_;

    my $document =
      $self->app->document_api->get_document( $opt->{document_id} );

    printf(
"Document Details\n  Name: '%s'\n  Id: '%s'\n  Status: '%s'\n  DisassemblingStatus: '%s'\n",
        $document->name, $document->id, $document->status,
        $document->document_disassembling_status );
}

1;
