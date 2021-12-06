# ABSTRACT: push translation files to Smartcat
use strict;
use warnings;

use utf8;
no utf8;

package Smartcat::App::Command::push;
use Smartcat::App -command;

use File::Basename;
use File::Spec::Functions qw(catfile catdir);
use File::Find qw(find);
use List::Util qw(first);

use Smartcat::App::Constants qw(
  MAX_ITERATION_WAIT_TIMEOUT
  ITERATION_WAIT_TIMEOUT
  DOCUMENT_DISASSEMBLING_SUCCESS_STATUS
);
use Smartcat::App::Utils;

use Carp;
use Log::Any qw($log);
use JSON qw/encode_json/;

# How many documents to delete at a time
# (there's a limitation on the number of the document due to
# the fact that all document IDs are specified in a URL,
# and URLs itself have length limitations).
my $DELETE_BATCH_SIZE = 20;

sub opt_spec {
    my ($self) = @_;

    my @opts = $self->SUPER::opt_spec();

    push @opts,
      [ 'disassemble-algorithm-name:s' =>
          'Optional disassemble file algorithm' ],
      [ 'preset-disassemble-algorithm:s' =>
          'Optional disassemble algorithm preset' ],
      [ 'delete-not-existing' => 'Delete not existing documents' ],
      $self->project_id_opt_spec,
      $self->project_workdir_opt_spec,
      $self->file_params_opt_spec,
      $self->extract_id_from_name_opt_spec,
      $self->external_tag_opt_spec,
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
    $self->app->{rundata}->{preset_disassemble_algorithm} =
      $opt->{preset_disassemble_algorithm}
      if defined $opt->{preset_disassemble_algorithm};
    $self->app->{rundata}->{delete_not_existing} =
      defined $opt->{delete_not_existing} ? $opt->{delete_not_existing} : 0;
    $self->app->{rundata}->{extract_id_from_name} =
      defined $opt->{extract_id_from_name} ? $opt->{extract_id_from_name} : 0;
    $self->app->{rundata}->{external_tag} =
      defined $opt->{external_tag} ? $opt->{external_tag} : "source:Serge";
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
    $app->project_api->update_project_external_tag( $project, $rundata->{external_tag} ) if ($#{ $project->documents } >= 0);
    my %documents;

    for ( @{ $project->documents } ) {
            my $key = &get_document_key( 
                $_->full_path,
                $_->target_language,
                $rundata->{extract_id_from_name} );
            $documents{$key} = [] unless defined $documents{$key};
            push @{ $documents{$key} }, $_;
    }

    my %ts_files;
    find(
        sub {
            my $name = $File::Find::name;
            if ($^O !~ /MSWin32/) { # assume we are on Unix if not on Windows
                utf8::decode($name); # assume UTF8 filenames
                utf8::decode($_);
            }

            if (   -f $name
                && !m/^\.$/
                && m/$rundata->{filetype}$/ )
            {
                s/$rundata->{filetype}$//;
                my $path = catfile( dirname($name), $_ );

                my $key = &get_ts_file_key(
                    $rundata->{project_workdir},
                    $path, 
                    $rundata->{extract_id_from_name} );

                utf8::decode($key);
                $ts_files{$key} = [] unless defined $ts_files{$key};
                push @{ $ts_files{$key} }, $name;
            }
        },
        $rundata->{project_workdir}
    );

    my %stats;
    $stats{$_}++ for ( keys %documents, keys %ts_files );

    my ( @upload, @obsolete, @update, @skip );
    push @{
        exists $ts_files{$_} && !$self->_check_if_files_are_empty( $ts_files{$_} )
        ? defined $documents{$_} ? \@update : \@upload
        : defined $documents{$_} ? \@obsolete : \@skip
      },
      $_
      for ( keys %stats );

    $log->info(
        sprintf(
"State:\n  Upload [%d]\n    %s\n  Update [%d]\n    %s\n  Obsolete [%d]\n    %s\n  Skip [%d]\n    %s\n",
            scalar @upload,
            join( ', ', map { "'$_'" } @upload ),
            scalar @update,
            join( ', ', map { "'$_'" } @update ),
            scalar @obsolete,
            join( ', ', map { "'$_'" } @obsolete ),
            scalar @skip,
            join( ', ', map { "'$_'" } @skip )
        )
    );

    $self->upload( $project, $ts_files{$_} ) for @upload;
    $self->update( $project, $documents{$_}, $ts_files{$_} ) for @update;

    if ($rundata->{delete_not_existing}) {
        my @document_ids;
        push( @document_ids, map { $_->id } @{ $documents{$_} } ) for @obsolete;

        # work in batches
        while (scalar(@document_ids) > 0) {
            my @batch = splice(@document_ids, 0, $DELETE_BATCH_SIZE);
            $self->delete( \@batch );
        }
    }

    $log->info(
        sprintf(
"Finished 'push' command for project '%s' and translation files from '%s'.",
            $rundata->{project_id},
            $rundata->{project_workdir}
        )
    );
}

sub delete {
    my ( $self, $document_ids ) = @_;

    $self->app->document_api->delete_documents($document_ids);
}

sub update {
    my ( $self, $project, $documents, $ts_files ) = @_;

    my $app     = $self->app;
    my $api     = $app->document_api;
    my $rundata = $app->{rundata};

    my @target_languages =
      map { &get_language_from_ts_filepath($rundata->{project_workdir}, $_) } @$ts_files;
    my %doc_and_path_by_lang;
    my @files_without_documents;

    #print Dumper $ts_files;
    for (@$ts_files) {

        my $lang = get_language_from_ts_filepath($rundata->{project_workdir}, $_);
        my $doc = first { $_->target_language eq $lang } @$documents;

        # p $doc;
        if ( defined $doc ) {
            $doc_and_path_by_lang{$lang} = { path => $_, doc => $doc };
        }
        else {
            push @files_without_documents, $_;
        }
    }
    my @documents_without_files =
      grep { !exists $doc_and_path_by_lang{ $_->target_language } } @$documents;

    $log->warn(
        "No files for documents:"
          . join( ', ',
            map { $_->name . '(' . $_->target_language . ') [' . $_->id . ']' }
              @documents_without_files )
    ) if @documents_without_files;

    $log->warn(
        "No documents for files:" . join( ', ', @files_without_documents ) )
      if @files_without_documents;

    for ( keys %doc_and_path_by_lang ) {
        my $doc_and_path = $doc_and_path_by_lang{$_};
        
        $api->update_document( $doc_and_path->{path}, $doc_and_path->{doc}->id );
        
        if ( $rundata->{extract_id_from_name} ) {
            my $file_name = get_file_name(
                $doc_and_path->{path},
                $rundata->{filetype},
                $target_languages[0]);
            my $document_name = $doc_and_path->{doc}->name;

            if ($file_name ne $document_name) {
                $log->info(
                    sprintf(
                        "Renaming document '%s' from '%s' to '%s'.",
                        $doc_and_path->{doc}->id,
                        $document_name,
                        $file_name
                    )
                );
                $api->rename_document( $doc_and_path->{doc}->id, $file_name );  
            }
        }
    }
}

sub _check_if_files_are_empty {
    my ($self, $filepaths) = @_;

    my $rundata = $self->app->{rundata};

    if ($rundata->{filetype} eq ".po") {
        return are_po_files_empty($filepaths);
    }

    return 0;
}

sub upload {
    my ( $self, $project, $ts_files ) = @_;

    my $rundata = $self->app->{rundata};
    my @target_languages =
      map { &get_language_from_ts_filepath($rundata->{project_workdir}, $_) } @$ts_files;
    my @project_target_languages = @{ $project->target_languages };

    croak("Conflict: one target language to one file expected.")
      unless @$ts_files == 1 && @target_languages == 1;
    my $path     = shift @$ts_files;

    my $filename = prepare_document_name( $rundata->{project_workdir}, $path, $rundata->{filetype},
        $target_languages[0] );

    my $meta_info;
    if ( $rundata->{extract_id_from_name}){
        my $file_id = &get_file_id( $path );
        $meta_info = encode_json( { file_id => $file_id } );
    }

    my $documents = $self->app->project_api->upload_file( $path, $filename, undef, $meta_info,
        \@target_languages );
    $log->info( "Created documents ids:\n  "
          . join( ', ', map { $_->id } @$documents ) );
}

1;
