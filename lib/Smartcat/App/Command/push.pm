# ABSTRACT: push translation files to Smartcat
use strict;
use warnings;

package Smartcat::App::Command::push;
use Smartcat::App -command;

use File::Basename;
use File::Spec::Functions qw(catfile catdir);
use File::Find qw(find);
use List::Util qw(first);

use Smartcat::App::Constants qw(
  TOTAL_WAIT_TIMEOUT
  ITERATION_WAIT_TIMEOUT
  DOCUMENT_DISASSEMBLING_SUCCESS_STATUS
);
use Smartcat::App::Utils;

use Carp;
use Log::Any qw($log);

sub opt_spec {
    my ($self) = @_;

    my @opts = $self->SUPER::opt_spec();

    push @opts,
      [ 'disassemble-algorithm-name:s' =>
          'Optional disassemble file algorithm' ],
      $self->project_id_opt_spec,
      $self->project_workdir_opt_spec,
      $self->file_params_opt_spec,
      ;

    return @opts;
}

sub validate_args {
    my ( $self, $opt, $args ) = @_;

    $self->SUPER::validate_args( $opt, $args );
    $self->validate_project_id( $opt, $args );
    $self->validate_project_workdir( $opt, $args );
    $self->validate_file_params( $opt, $args );

    $self->app->{rundata}->{disassemble_algorithm_name} =
      $opt->{disassemble_algorithm_name}
      if defined $opt->{disassemble_algorithm_name};
}

sub execute {
    my ( $self, $opt, $args ) = @_;

    my $app     = $self->app;
    my $rundata = $app->{rundata};
    $log->info(
        sprintf(
"Running 'push' command for project '%s' and translation files from '%s'...",
            $rundata->{project_id},
            $rundata->{project_workdir}
        )
    );

    my $project = $app->project_api->get_project;
    my %documents;
    for ( @{ $project->documents } ) {
        my $key =
            $rundata->{language_file_tree}
          ? $_->name
          : &get_document_key( $_->name, $_->target_language );
        $documents{$key} = [] unless defined $documents{$key};
        push @{ $documents{$key} }, $_;
    }

    my %ts_files;
    find(
        sub {
            if (   -f $File::Find::name
                && $_ !~ m/^\./
                && m/$rundata->{filetype}$/ )
            {
                s/$rundata->{filetype}$//;
                my $name = catfile( dirname($File::Find::name), $_ );
                my $key =
                  $rundata->{language_file_tree} ? $_ : &get_ts_file_key($name);
                $ts_files{$key} = [] unless defined $ts_files{$key};
                push @{ $ts_files{$key} }, $File::Find::name;
            }

        },
        $rundata->{project_workdir}
    );

    my %stats;
    $stats{$_}++ for ( keys %documents, keys %ts_files );

    #print Dumper \%stats;
    my ( @upload, @obsolete, @update );
    push @{
        defined $documents{$_}
        ? ( $stats{$_} > 1 ? \@update : \@obsolete )
        : \@upload
      },
      $_
      for ( keys %stats );

    $log->info(
        sprintf(
"State:\n  Upload count: %d\n  Update count: %d\n  Obsolete count: %d\n",
            scalar @upload,
            scalar @update,
            scalar @obsolete
        )
    );
    $self->upload( $project, $ts_files{$_} ) for @upload;

    #p @update;
    $self->update( $project, $documents{$_}, $ts_files{$_} ) for @update;

    #todo: obsolete
    $log->info(
        sprintf(
"Finished 'push' command for project '%s' and translation files from '%s'.",
            $rundata->{project_id},
            $rundata->{project_workdir}
        )
    );
}

sub update {
    my ( $self, $project, $documents, $ts_files ) = @_;

    my $api = $self->app->document_api;
    my @target_languages =
      map { &get_language_from_ts_filepath($_) } @$ts_files;
    my @project_target_languages = @{ $project->target_languages };
    my %lang_pairs;
    my @files_without_documents;

    #print Dumper $ts_files;
    for (@$ts_files) {

        #print $_."\n";
        my $lang = get_language_from_ts_filepath($_);
        my $doc = first { $_->target_language eq $lang } @$documents;

        #p $doc;
        if ( defined $doc ) {
            $lang_pairs{$lang} = [ $_, $doc->id ];
        }
        else {
            push @files_without_documents, $_;
        }
    }
    my @documents_without_files =
      grep { !exists $lang_pairs{ $_->target_language } } @$documents;

    $log->warn(
        "No files for documents:"
          . join( ', ',
            map { $_->name . '(' . $_->target_language . ') [' . $_->id . ']' }
              @documents_without_files )
    ) if @documents_without_files;

    $log->warn(
        "No documents for files:" . join( ', ', @files_without_documents ) )
      if @files_without_documents;

    $api->update_document( @{ $lang_pairs{$_} } ) for ( keys %lang_pairs );
}

sub _upload_to_tree {
    my ( $self, $ts_files, $target_languages ) = @_;

    #my $path = $ts_files->[0];
    my $path = shift @$ts_files;
    my $documents =
      $self->app->project_api->upload_file( $path, basename($path),
        $target_languages );

    $log->info( "Created documents ids:\n  "
          . join( ', ', map { $_->id } @$documents ) );

    my $document_api = $self->app->document_api;
    for (@$ts_files) {
        sleep ITERATION_WAIT_TIMEOUT * 2;
        my $lang    = get_language_from_ts_filepath($_);
        my $doc     = first { $_->target_language eq $lang } @$documents;
        my $counter = 0;
        while ( $counter < TOTAL_WAIT_TIMEOUT ) {

#my $d = $counter == 0 ? $project_documents{$doc->id} : $document_api->get_document($doc->id);
            my $d = $document_api->get_document( $doc->id );
            last
              if $d->document_disassembling_status eq
              DOCUMENT_DISASSEMBLING_SUCCESS_STATUS;
            $log->info(
                sprintf(
"Document '%s' is not disassembled (disassemblingStatus='%s').",
                    $doc->id, $d->document_disassembling_status
                )
            );
            $counter++;
            sleep ITERATION_WAIT_TIMEOUT * 2;
        }
        die $log->error( sprintf( "Cannot update document %s.", $doc->id ) )
          if $counter == TOTAL_WAIT_TIMEOUT;
        $document_api->update_document( $_, $doc->id );
    }
}

sub upload {
    my ( $self, $project, $ts_files ) = @_;

    my $rundata = $self->app->{rundata};
    my @target_languages =
      map { &get_language_from_ts_filepath($_) } @$ts_files;
    my @project_target_languages = @{ $project->target_languages };

    if ( $rundata->{language_file_tree} ) {
        $log->warn(
            sprintf(
"Project target languages do not match translation files.\n  files: %s\n  project: %s",
                join( ', ', @target_languages ),
                join( ', ', @project_target_languages )
            )
        ) unless @target_languages == @project_target_languages;
        $self->_upload_to_tree( $ts_files, \@target_languages );
    }
    else {
        croak("Conflict: one target language to one file expected.")
          unless @$ts_files == 1 && @target_languages == 1;
        my $path     = shift @$ts_files;
        my $filename = prepare_document_name( $path, $rundata->{filetype},
            $target_languages[0] );
        my $documents = $self->app->project_api->upload_file( $path, $filename,
            \@target_languages );
        $log->info( "Created documents ids:\n  "
              . join( ', ', map { $_->id } @$documents ) );
    }
}

1;
