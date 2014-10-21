package Git::PurePerl;
use Moose;
use MooseX::StrictConstructor;
use MooseX::Types::Path::Class;
use Compress::Zlib qw(uncompress);
use Data::Stream::Bulk;
use Data::Stream::Bulk::Array;
use Data::Stream::Bulk::Path::Class;
use Git::PurePerl::DirectoryEntry;
use Git::PurePerl::Loose;
use Git::PurePerl::Object;
use Git::PurePerl::Object::Blob;
use Git::PurePerl::Object::Commit;
use Git::PurePerl::Object::Tag;
use Git::PurePerl::Object::Tree;
use Git::PurePerl::Pack;
use Git::PurePerl::PackIndex;
use Git::PurePerl::PackIndex::Version1;
use Git::PurePerl::PackIndex::Version2;
use Path::Class;
our $VERSION = '0.38';

has 'directory' =>
    ( is => 'ro', isa => 'Path::Class::Dir', required => 1, coerce => 1 );

has 'loose' => (
    is         => 'rw',
    isa        => 'Git::PurePerl::Loose',
    required   => 0,
    lazy_build => 1,
);

has 'packs' => (
    is         => 'rw',
    isa        => 'ArrayRef[Git::PurePerl::Pack]',
    required   => 0,
    auto_deref => 1,
    lazy_build => 1,
);

__PACKAGE__->meta->make_immutable;

sub BUILD {
    my $self = shift;

    unless ( -d $self->directory ) {
        confess $self->directory . ' is not a directory';
    }
    my $git_dir = dir( $self->directory, '.git' );
    unless ( -d $git_dir ) {
        confess $self->directory . ' does not contain a .git directory';
    }
}

sub _build_loose {
    my $self = shift;
    my $loose_dir = dir( $self->directory, '.git', 'objects' );
    return Git::PurePerl::Loose->new( directory => $loose_dir );
}

sub _build_packs {
    my $self = shift;
    my $pack_dir = dir( $self->directory, '.git', 'objects', 'pack' );
    my @packs;
    foreach my $filename ( $pack_dir->children ) {
        next unless $filename =~ /\.pack$/;
        push @packs, Git::PurePerl::Pack->new( filename => $filename );
    }
    return \@packs;
}

sub master {
    my $self = shift;
    my $master = file( $self->directory, '.git', 'refs', 'heads', 'master' );
    my $sha1;
    if ( -f $master ) {
        $sha1 = $master->slurp || confess('Missing refs/heads/master');
        chomp $sha1;
    } else {
        my $packed_refs = file( $self->directory, '.git', 'packed-refs' );
        my $content = $packed_refs->slurp
            || confess('Missing refs/heads/master');
        foreach my $line ( split "\n", $content ) {
            next if $line =~ /^#/;
            ( $sha1, my $name ) = split ' ', $line;
            last if $name eq 'refs/heads/master';
        }
    }
    return $self->get_object($sha1);
}

sub get_object {
    my ( $self, $sha1 ) = @_;
    return $self->get_object_packed($sha1) || $self->get_object_loose($sha1);
}

sub get_object_packed {
    my ( $self, $sha1 ) = @_;

    foreach my $pack ( $self->packs ) {
        my ( $kind, $size, $content ) = $pack->get_object($sha1);
        if ( $kind && $size && $content ) {
            return $self->create_object( $sha1, $kind, $size, $content );
        }
    }
}

sub get_object_loose {
    my ( $self, $sha1 ) = @_;

    my ( $kind, $size, $content ) = $self->loose->get_object($sha1);
    if ( $kind && $size && $content ) {
        return $self->create_object( $sha1, $kind, $size, $content );
    }
}

sub create_object {
    my ( $self, $sha1, $kind, $size, $content ) = @_;
    if ( $kind eq 'commit' ) {
        return Git::PurePerl::Object::Commit->new(
            sha1    => $sha1,
            kind    => $kind,
            size    => $size,
            content => $content,
        );
    } elsif ( $kind eq 'tree' ) {
        return Git::PurePerl::Object::Tree->new(
            sha1    => $sha1,
            kind    => $kind,
            size    => $size,
            content => $content,
        );
    } elsif ( $kind eq 'blob' ) {
        return Git::PurePerl::Object::Blob->new(
            sha1    => $sha1,
            kind    => $kind,
            size    => $size,
            content => $content,
        );
    } elsif ( $kind eq 'tag' ) {
        return Git::PurePerl::Object::Tag->new(
            sha1    => $sha1,
            kind    => $kind,
            size    => $size,
            content => $content,
        );
    } else {
        confess "unknown kind $kind: $content";
    }
}

sub all_sha1s {
    my $self = shift;
    my $dir = dir( $self->directory, '.git', 'objects' );

    my @streams;
    push @streams, $self->loose->all_sha1s;

    foreach my $pack ( $self->packs ) {
        push @streams, $pack->all_sha1s;
    }

    return Data::Stream::Bulk::Cat->new( streams => \@streams, );
}

sub init {
    my ( $class, %arguments ) = @_;
    my $directory = $arguments{directory} || confess "No directory passed";
    my $git_dir = dir( $directory, '.git' );

    dir($directory)->mkpath;
    dir($git_dir)->mkpath;
    dir( $git_dir, 'refs',    'tags' )->mkpath;
    dir( $git_dir, 'objects', 'info' )->mkpath;
    dir( $git_dir, 'objects', 'pack' )->mkpath;
    dir( $git_dir, 'branches' )->mkpath;
    dir( $git_dir, 'hooks' )->mkpath;

    $class->_add_file(
        file( $git_dir, 'config' ),
        "[core]\n\trepositoryformatversion = 0\n\tfilemode = true\n\tbare = false\n\tlogallrefupdates = true\n"
    );
    $class->_add_file( file( $git_dir, 'description' ),
        "Unnamed repository; edit this file to name it for gitweb.\n" );
    $class->_add_file(
        file( $git_dir, 'hooks', 'applypatch-msg' ),
        "# add shell script and make executable to enable\n"
    );
    $class->_add_file( file( $git_dir, 'hooks', 'post-commit' ),
        "# add shell script and make executable to enable\n" );
    $class->_add_file(
        file( $git_dir, 'hooks', 'post-receive' ),
        "# add shell script and make executable to enable\n"
    );
    $class->_add_file( file( $git_dir, 'hooks', 'post-update' ),
        "# add shell script and make executable to enable\n" );
    $class->_add_file(
        file( $git_dir, 'hooks', 'pre-applypatch' ),
        "# add shell script and make executable to enable\n"
    );
    $class->_add_file( file( $git_dir, 'hooks', 'pre-commit' ),
        "# add shell script and make executable to enable\n" );
    $class->_add_file( file( $git_dir, 'hooks', 'pre-rebase' ),
        "# add shell script and make executable to enable\n" );
    $class->_add_file( file( $git_dir, 'hooks', 'update' ),
        "# add shell script and make executable to enable\n" );

    dir( $git_dir, 'info' )->mkpath;
    $class->_add_file( file( $git_dir, 'info', 'exclude' ),
        "# *.[oa]\n# *~\n" );

    return $class->new(%arguments);
}

sub _add_file {
    my ( $class, $filename, $contents ) = @_;
    my $fh = $filename->openw || confess "Error opening to $filename: $!";
    $fh->print($contents) || confess "Error writing to $filename: $!";
    $fh->close || confess "Error closing $filename: $!";
}

1;

__END__

=head1 NAME

Git::PurePerl - A Pure Perl interface to Git repositories

=head1 SYNOPSIS

    my $git = Git::PurePerl->new(
        directory => '/path/to/git/'
    );
    $git->master->committer;
    $git->master->comment;
    $git->get_object($git->master->tree);

=head1 DESCRIPTION

This module is a Pure Perl interface to Git repositories.

It was mostly based on Grit L<http://grit.rubyforge.org/>.

=head1 METHODS

=over 4

=item master

=item get_object

=item get_object_packed

=item get_object_loose

=item create_object

=item all_sha1s

=back

=head1 AUTHOR

Leon Brocard <acme@astray.com>

=head1 COPYRIGHT

Copyright (C) 2008, Leon Brocard.

=head1 LICENSE

This module is free software; you can redistribute it or 
modify it under the same terms as Perl itself.
