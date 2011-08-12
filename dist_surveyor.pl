#!/bin/env perl

=head1 NAME

=head1 TODO

* For installed modules get the file modification time (last commit time)
    and use it to eliminate candidate dists that were released after that time.

* Add partial ordering so dependencies are listed first, in install order.
    When used with --remnants should yield the same dir tree.

=cut

use strict;
use warnings;
use version;
use Carp;
use Config;
use Data::Dumper::Concise;
use DBI qw(looks_like_number);
use Digest::SHA qw(sha1_base64);
use ExtUtils::Perllocal::Parser;
use Fcntl qw(:DEFAULT :flock);
use File::Fetch;
use File::Find;
use File::Slurp;
use File::Spec;
use File::Spec::Unix;
use Getopt::Long;
use List::Util qw(max sum);
use Memoize;
use MetaCPAN::API 0.32;
use DB_File;
use MLDBM qw(DB_File Storable);
use Module::CoreList;
use Module::Metadata;
use Storable qw(nfreeze);
use Try::Tiny;

use constant ON_WIN32 => $^O eq 'MSWin32';
use constant ON_VMS   => $^O eq 'VMS';

$| = 1;
$Storable::canonical = 1;

GetOptions(
    'match=s' => \my $opt_match,
    'v|verbose!' => \my $opt_verbose,
    'd|debug!' => \my $opt_debug,
    # target perl version, re core modules
    'perlver=s' => \my $opt_perlver,
    # include old dists that have remnant/orphaned modules installed
    'remnants!' => \my $opt_remnants,
    # don't use a persistent cache
    'uncached!' => \my $opt_uncached,
    # e.g., mcpani needs: download_url author modvers
    'output=s' => \(my $opt_output ||= 'url'),
    # e.g., 'mcpani --add --file %s --authorid %s --module %s
    'format=s' => \my $opt_format,
) or exit 1;

$opt_perlver = version->parse($opt_perlver || $])->numify;

$opt_verbose++ if $opt_debug;

my $metacpan_size = 999; # don't make too large, hurts the server
my $metacpan_calls = 0;
my $metacpan_api ||= MetaCPAN::API->new(
    ua_args => [ agent => $0 ],
);


# caching via persistent memoize

my $memoize_file = "intuit_distros_cache.db";
my %memoize_cache;
if (not $opt_uncached) {
    my $db = tie %memoize_cache => 'MLDBM', $memoize_file, O_CREAT|O_RDWR, 0640
        or die "Unable to use persistent cache: $!";
    # this locking is flawed but good enough for my needs
    # http://search.cpan.org/~pmqs/DB_File-1.824/DB_File.pm#HINTS_AND_TIPS
    my $fd = $db->fd;
    open(DB_FH, "+<&=$fd") || die "dup $!";
    flock (DB_FH, LOCK_EX) || die "flock: $!";
}
my %memoize_subs = (
    get_candidate_cpan_dist_releases => { generation => 10 },
    get_module_versions_in_release   => { generation => 11 },
    dist_fraction_installed          => { generation => 10 },
);
for my $subname (keys %memoize_subs) {
    my %memoize_args = %{$memoize_subs{$subname}};
    my $generation = delete $memoize_args{generation} || 1;
    $memoize_args{SCALAR_CACHE} = [ HASH => \%memoize_cache ];
    $memoize_args{LIST_CACHE} = 'MERGE';
    $memoize_args{NORMALIZER} = sub {
        $Storable::canonical = 1;
        sha1_base64(nfreeze([ $subname, $generation, wantarray, @_ ]))
    };
    memoize($subname, %memoize_args);
}



# for distros with names that don't match the principle module name
# yet the principle module version always matches the distro
# Used for perllocal.pod lookups
# # XXX should be automated lookup rather than hardcoded
my %distro_key_mod_names = (
    'PathTools' => 'File::Spec',
    'Template-Toolkit' => 'Template',
    'TermReadKey' => 'Term::ReadKey',
    'libwww-perl' => 'LWP',
);


# give only top-level lib dir, the archlib will be added automatically
my @libdir = shift;
die "$libdir[0] isn't a directory\n" unless -d $libdir[0];
unshift @libdir, "$libdir[0]/$Config{archname}"
    if -d "$libdir[0]/$Config{archname}";

my @installed_releases = determine_installed_releases(@libdir);

my @fields = split ' ', $opt_output;
my $format = $opt_format ? $opt_format : join("\t", ('%s') x @fields);
for my $release_data (@installed_releases) {
    my @values = map {
        exists $release_data->{$_} ? $release_data->{$_} : "$_?"
    } @fields;
    printf $format, @values;
    print "\n";
}

warn sprintf "Completed in %.1f minutes using %d metacpan calls.\n",
    (time-$^T)/60, $metacpan_calls;

exit 0;




sub determine_installed_releases {
    my (@search_dirs) = @_;

    warn "Searching @search_dirs\n" if $opt_verbose;

    my %installed_mod_info;

    warn "Finding modules in @search_dirs\n";
    my ($installed_mod_files, $installed_meta) = find_installed_modules(@search_dirs);

    # get the installed version of each installed module and related info
    warn "Finding candidate releases for the ".keys(%$installed_mod_files)." installed modules\n";
    foreach my $module ( sort keys %$installed_mod_files ) {
        my $mod_file = $installed_mod_files->{$module};

        if ($opt_match) {
            if ($module !~ m/$opt_match/o) {
                delete $installed_mod_files->{$module};
                next;
            }
        }

        module_progress_indicator($module) unless $opt_verbose;

        my $mod_version = do {
            # silence warnings about duplicate VERSION declarations
            # eg Catalyst::Controller::DBIC::API* 2.002001
            local $SIG{__WARN__} = sub { warn @_ if $_[0] !~ /already declared with version/ };
            my $mm = Module::Metadata->new_from_file($mod_file);
            $mm->version; # only one version for one package in file
        };
        $mod_version ||= 0; # XXX
        my $mod_file_size = -s $mod_file;

        # Eliminate modules that will be supplied by the target perl version
        if ( my $cv = $Module::CoreList::version{ $opt_perlver }->{$module} ) {
            $cv =~ s/ //g;
            if (version->parse($cv) >= version->parse($mod_version)) {
                warn "$module $mod_version is core in perl $opt_perlver (as v$cv) - skipped\n";
                next;
            }
        }

        my $mi = $installed_mod_info{$module} = {
            file => $mod_file,
            module => $module,
            version => $mod_version,
            version_obj => version->parse($mod_version),
            size => $mod_file_size,
        };

        # XXX could also consider file mtime: releases newer than the mtime
        # of the module file can't be the origin of that module file.
        # (assuming clocks and file times haven't been messed with)

        try {
            my $ccdr = get_candidate_cpan_dist_releases($module, $mod_version, $mod_file_size);
            if (not %$ccdr) {
                $ccdr = get_candidate_cpan_dist_releases($module, $mod_version, 0);
                if (%$ccdr) {
                    # probably either a local change/patch or installed direct from repo
                    # but with a version number that matches a release
                    warn "$module $mod_version on CPAN but with different file size (not $mod_file_size)\n"
                        if $mod_version or $opt_verbose;
                    $mi->{file_size_mismatch}++;
                }
                else {
                    $mi->{version_not_on_cpan}++;
                    # Possibly a local change/patch or installed direct from repo
                    # with a version number that was never released.
                    # Also possibly a private module never released on cpan.
                    warn "$module $mod_version not found on CPAN\n"
                        if $mi->{version} # no version implies uninteresting
                        or $opt_verbose;
                    # XXX could try finding the module with *any* version on cpan
                    # to help with later advice. ie could select as candidates
                    # the version above and the version below the number we have,
                    # and set a flag to inform later logic.
                }
            }
            $mi->{candidate_cpan_dist_releases} = $ccdr if %$ccdr;
        }
        catch {
            warn "Failed get_candidate_cpan_dist_releases($module, $mod_version, $mod_file_size): $_";
        }

    }


    # Map modules to dists using the accumulated %installed_mod_info info

    warn "*** Mapping modules to releases\n";

    my %best_dist;
    foreach my $mod ( sort keys %installed_mod_info ) {
        my $mi = $installed_mod_info{$mod};

        module_progress_indicator($mod) unless $opt_verbose;

        # find best match among the cpan releases that included this module
        my $ccdr = $installed_mod_info{$mod}{candidate_cpan_dist_releases}
            or next; # no candidates, warned about above (for mods with a version)

        my $best_dist_cache_key = join " ", sort keys %$ccdr;
        our %best_dist_cache;
        my $best = $best_dist_cache{$best_dist_cache_key}
            ||= pick_best_cpan_dist_release($ccdr, \%installed_mod_info);

        my $note = "";
        if (@$best > 1) { # try using perllocal.pod to narrow the options
            my @in_perllocal = grep {
                my $distname = $_->{distribution};
                my ($v, $dist_mod_name) = perllocal_distro_mod_version($distname, $installed_meta->{perllocalpod});
                warn "$dist_mod_name in perllocal.pod: ".($v ? "YES" : "NO")."\n"
                    if $opt_debug;
                $v;
            } @$best;
            if (@in_perllocal && @in_perllocal < @$best) {
                $note = sprintf "narrowed from %d via perllocal", scalar @$best;
                $best = \@in_perllocal;
            }
        }

        if (@$best > 1 or $note) { # note the poor match for this module
            # but not if there's no version (as that's common)
            my $best_desc = join " or ", map { $_->{release} } @$best;
            my $pct = sprintf "%.2f%%", $best->[0]{fraction_installed} * 100;
            warn "$mod $mi->{version} odd best match: $best_desc $note ($best->[0]{fraction_installed})\n"
                if $note or $opt_verbose or ($mi->{version} and $best->[0]{fraction_installed} < 0.3);
            # if the module has no version and multiple best matches
            # then it's unlikely make a useful contribution, so ignore it
            # XXX there's a risk that we'd ignore all the modules of a release
            # where none of the modules has a version, but that seems unlikely.
            next if not $mi->{version};
        }

        for my $dist (@$best) {
            # two level hash to make it easier to handle versions
            my $di = $best_dist{ $dist->{distribution} }{ $dist->{release} } ||= { dist => $dist };
            push @{ $di->{modules} }, $mi;
            $di->{or}{$_->{release}}++ for grep { $_ != $dist } @$best;
        }

    }

    warn "*** Refining releases\n";

    # $best_dist{ Foo }{ Foo-1.23 }{ dist=>$dist_struct, modules=>, or=>{ Foo-1.22 => $dist_struct } }

    my @installed_releases;    # Dist-Name => { ... }

    for my $distname ( sort keys %best_dist ) {
        my $releases = $best_dist{$distname};

        my @dist_by_version  = sort {
            $a->{dist}{version_obj}        <=> $b->{dist}{version_obj} or
            $a->{dist}{fraction_installed} <=> $b->{dist}{fraction_installed}
        } values %$releases;
        my @dist_by_fraction = sort {
            $a->{dist}{fraction_installed} <=> $b->{dist}{fraction_installed} or
            $a->{dist}{version_obj}        <=> $b->{dist}{version_obj}
        } values %$releases;
        
        my @remnant_dists  = @dist_by_version;
        my $installed_dist = pop @remnant_dists;

        # is the most recent candidate dist version also the one with the
        # highest fraction_installed?
        if ($dist_by_version[-1] == $dist_by_fraction[-1]) {
            # this is the common case: we'll assume that's installed and the
            # rest are remnants of earlier versions
        }
        else {
            # else grumble so the user knows to ponder the possibilities
            warn "\tCan't determine which $distname is installed from among @{[ keys %$releases ]}\n";
            warn Dumper([ \@dist_by_version, \@dist_by_fraction ]);
            warn "\tSelecting based on latest version\n";
        }

        if (@remnant_dists or $opt_debug) {
            warn "@{[ map { $_->{dist}{release} } @dist_by_fraction ]}:\n"; 
            for ($installed_dist, @remnant_dists) {
                my $fi = $_->{dist}{fraction_installed};
                my $modules = $_->{modules};
                my $mv_desc = join(", ", map { "$_->{module} $_->{version}" } @$modules);
                warn sprintf "\t%s\t%s%% installed: %s\n",
                    $_->{dist}{release},
                    $_->{dist}{percent_installed},
                    (@$modules > 4 ? "(".@$modules." modules)" : $mv_desc),
            }
        }

        # note ordering: remnants first
        for (($opt_remnants ? @remnant_dists : ()), $installed_dist) {
            my ($author, $distribution, $release)
                = @{$_->{dist}}{qw(author distribution release)};

            $metacpan_calls++;
            my $release_data = $metacpan_api->release( author => $author, release => $release );
            if (!$release_data) {
                warn "Can't find release details for $author/$release - SKIPPED!\n";
                next; # XXX could fake some of $release_data instead
            }

            my $mods_in_rel = get_module_versions_in_release($author, $release);

            # shortcuts
            (my $url = $release_data->{download_url}) =~ s{ .*? \b authors/ }{authors/}x;

            push @installed_releases, {
                %$release_data,
                # handy shortcuts
                url => $url,
                modvers => join(";", map { $_->{name}."=".($_->{version}||0) } values %$mods_in_rel),
                # raw data structures
                dist_data => $_->{dist},
                mods_in_rel => $mods_in_rel,
            };
        }
        #die Dumper(\@installed_releases);
    }

    # sorting into dependency order could be added later, maybe

    return @installed_releases;
}


# pick_best_cpan_dist_release - memoized
# for each %$ccdr adds a fraction_installed based on %$installed_mod_info
# returns ref to array of %$ccdr values that have the max fraction_installed

sub pick_best_cpan_dist_release {
    my ($ccdr, $installed_mod_info) = @_;

    for my $release (sort keys %$ccdr) {
        my $release_info = $ccdr->{$release};
        $release_info->{fraction_installed}
            = dist_fraction_installed($release_info->{author}, $release, $installed_mod_info);
        $release_info->{percent_installed} # for informal use
            = sprintf "%.2f", $release_info->{fraction_installed} * 100;
    }

    my $max_fraction_installed = max( map { $_->{fraction_installed} } values %$ccdr );
    my @best = grep { $_->{fraction_installed} == $max_fraction_installed } values %$ccdr;

    return \@best;
}


# returns a number from 0 to 1 representing the fraction of the modules
# in a particular release match the coresponding modules in %$installed_mod_info
sub dist_fraction_installed {
    my ($author, $release, $installed_mod_info) = @_;

    my $tag = "$author/$release";
    my $mods_in_rel = get_module_versions_in_release($author, $release);
    my $mods_in_rel_count = keys %$mods_in_rel;
    my $mods_inst_count = sum( map {
        my $mi = $installed_mod_info->{ $_->{name} };
        my $hit = ($mi && $mi->{version_obj} == $_->{version_obj}) ? 1 : 0;
        # XXX demote to a low-scoring partial match if the file size differs
        $hit = 0.1 if $mi && $mi->{size} != $_->{size};
        warn sprintf "%s %s %s %s: %s\n", $tag, $_->{name}, $_->{version_obj}, $_->{size},
                ($hit == 1) ? "matches"
                    : ($mi) ? "differs ($mi->{version_obj}, $mi->{size})"
                    : "not installed",
            if $opt_debug;
        $hit;
    } values %$mods_in_rel) || 0;

    my $fraction_installed = ($mods_in_rel_count) ? $mods_inst_count/$mods_in_rel_count : 0;
    warn "$author/$release:\tfraction_installed $fraction_installed ($mods_inst_count/$mods_in_rel_count)\n"
        if $opt_verbose or !$mods_in_rel_count;

    return $fraction_installed;
}


sub get_candidate_cpan_dist_releases {
    my ($module, $version, $file_size) = @_;

    $version = 0 if not defined $version; # XXX

    # timbunce: So, the current situation is that: version_numified is a float
    # holding version->parse($raw_version)->numify, and version is a string
    # also holding version->parse($raw_version)->numify at the moment, and
    # that'll change to ->stringify at some point. Is that right now? 
    # mo: yes, I already patched the indexer, so new releases are already
    # indexed ok, but for older ones I need to reindex cpan
    my $v = (ref $version && $version->isa('version')) ? $version : version->parse($version);
    my %v = map { $_ => 1 } "$version", $v->stringify, $v->numify;
    my @version_qual;
    push @version_qual, { term => { "file.module.version" => $_ } }
        for keys %v;
    push @version_qual, { term => { "file.module.version_numified" => $_ }}
        for grep { looks_like_number($_) } keys %v;

    my @and_quals = (
        {"term" => {"file.module.name" => $module }},
        (@version_qual > 1 ? { "or" => \@version_qual } : $version_qual[0]),
    );
    push @and_quals, {"term" => {"file.stat.size" => $file_size }}
        if $file_size;

    # XXX doesn't cope with odd cases like 
    # http://explorer.metacpan.org/?url=/module/MLEHMANN/common-sense-3.4/sense.pm.PL
    $metacpan_calls++;
    my $results = $metacpan_api->post("file", {
        "size" => $metacpan_size,
        "query" =>  { "filtered" => {
            "filter" => {"and" => \@and_quals },
            "query" => {"match_all" => {}},
        }},
        "fields" => [qw(release _parent author version version_numified file.module.version file.module.version_numified date stat.mtime distribution)]
    });

    my $hits = $results->{hits}{hits};
    die "get_candidate_cpan_dist_releases($module, $version, $file_size): too many results (>$metacpan_size)"
        if @$hits >= $metacpan_size;
    warn "get_candidate_cpan_dist_releases($module, $version, $file_size): ".Dumper($results)
        if grep { not $_->{fields}{release} } @$hits; # XXX temp, seen once but not since

    # filter out perl-like releases
    @$hits = grep {
        $_->{fields}{release} !~ /^(perl|ponie|parrot|kurila|SiePerl-5.6.1-)/;
    } @$hits;

    for my $hit (@$hits) {
        $hit->{release_id} = delete $hit->{_parent};
        # add version_obj for convenience
        $hit->{fields}{version_obj} = eval { version->parse($hit->{version}) };
        die "get_candidate_cpan_dist_releases($module, $version, $file_size): error parsing $hit->{path} $hit->{version}: $@" if $@;
    }

    # we'll return { "Dist-Name-Version" => { details }, ... }
    my %dists = map { $_->{fields}{release} => $_->{fields} } @$hits;
    warn "get_candidate_cpan_dist_releases($module, $version, $file_size): @{[ sort keys %dists ]}\n"
        if $opt_verbose;

    return \%dists;
}


# this can be called for all sorts of releases that are only vague possibilities
# and aren't actually installed, so generally it's quiet
sub get_module_versions_in_release {
    my ($author, $release) = @_;

    $metacpan_calls++;
    my $results = eval { $metacpan_api->post("file", {
        "size" => $metacpan_size,
        "query" =>  { "filtered" => {
            "filter" => {"and" => [
                {"term" => {"release" => $release }},
                {"term" => {"author" => $author }},
                {"term" => {"mime" => "text/x-script.perl-module"}},
            ]},
            "query" => {"match_all" => {}},
        }},
        "fields" => ["path","name","_source.module", "_source.stat.size"],
    }) };
    if (not $results) {
        warn "Failed get_module_versions_in_release for $author/$release: $@";
        return {};
    }
    my $hits = $results->{hits}{hits};
    die "get_module_versions_in_release($author, $release): too many results"
        if @$hits >= $metacpan_size;

    my %modules_in_release;
    for my $hit (@$hits) {
        my $path = $hit->{fields}{path};

        # XXX try to ignore files that won't get installed
        # XXX should use META noindex!
        if ($path =~ m!^(?:t|xt|tests?|inc|samples?|ex|examples?|bak)\b!) {
            warn "$author/$release: ignored non-installed module $path\n"
                if $opt_debug;
            next;
        }

        my $size = $hit->{fields}{"_source.stat.size"};
        # files can contain more than one package ('module')
        my $rel_mods = $hit->{fields}{"_source.module"} || [];
        for my $mod (@$rel_mods) { # actually packages in the file

            # Some files may contain multiple packages. We want to ignore
            # all except the one that matches the name of the file.
            # We use a fairly loose (but still very effective) test because we
            # can't rely on $path including the full package name.
            (my $filebasename = $hit->{fields}{name}) =~ s/\.pm$//;
            if ($mod->{name} !~ m/\b$filebasename$/) {
                warn "$author/$release: ignored $mod->{name} in $path\n"
                    if $opt_debug;
                next;
            }

            # add version_obj to simplify later version checks
            my $version_obj = eval { version->parse($mod->{version}) };
            die "$author/$release: $mod $mod->{version}: $@" if $@;

            # warn if package previously seen in this release
            # with a different version or file size
            if (my $prev = $modules_in_release{$mod->{name}}) {
                # XXX could add a show-only-once cache here
                my $msg = "$mod->{name} $version_obj ($size) seen in $path after $prev->{path} $prev->{version_obj} ($prev->{size})";
                warn "$release: $msg\n"
                    if $opt_verbose and ($version_obj != $prev->{version_obj}
                        or $size != $prev->{size});
            }

            $modules_in_release{$mod->{name}} = {
                name => $mod->{name},
                path => $path,
                version => $mod->{version},
                version_obj => $version_obj,
                size => $size,
            };
        }
    }

    warn "\n$author/$release contains: @{[ map { qq($_->{name} $_->{version_obj}) } values %modules_in_release ]}\n"
        if $opt_debug;

    return \%modules_in_release;
}


sub get_file_mtime {
    my ($file) = @_;
    # try to find the time the file was 'installed'
    # by looking for the commit date in svn or git
    # else fallback to the file modification time
    return (stat($file))[9];
}


sub find_installed_modules {
    my (@dirs) = @_;

    ### File::Find uses follow_skip => 1 by default, which doesn't die
    ### on duplicates, unless they are directories or symlinks.
    ### Ticket #29796 shows this code dying on Alien::WxWidgets,
    ### which uses symlinks.
    ### File::Find doc says to use follow_skip => 2 to ignore duplicates
    ### so this will stop it from dying.
    my %find_args = ( follow_skip => 2 );

    ### File::Find uses lstat, which quietly becomes stat on win32
    ### it then uses -l _ which is not allowed by the statbuffer because
    ### you did a stat, not an lstat (duh!). so don't tell win32 to
    ### follow symlinks, as that will break badly
    # XXX disabled because we want the postprocess hook to work
    #$find_args{'follow_fast'} = 1 unless ON_WIN32;

    ### never use the @INC hooks to find installed versions of
    ### modules -- they're just there in case they're not on the
    ### perl install, but the user shouldn't trust them for *other*
    ### modules!
    ### XXX CPANPLUS::inc is now obsolete, remove the calls
    #local @INC = CPANPLUS::inc->original_inc;

    # sort @dirs to put longest first to make it easy to handle
    # elements that are within other elements (e.g., an archdir)
    my @dirs_ordered = sort { length $b <=> length $a } @dirs;

    my %seen_mod;
    my %dir_done;
    my %meta; # return metadata about the search
    for my $dir (@dirs_ordered) {
        next if $dir eq '.';

        ### not a directory after all
        ### may be coderef or some such
        next unless -d $dir;

        ### make sure to clean up the directories just in case,
        ### as we're making assumptions about the length
        ### This solves rt.cpan issue #19738

        ### John M. notes: On VMS cannonpath can not currently handle
        ### the $dir values that are in UNIX format.
        $dir = File::Spec->canonpath($dir) unless ON_VMS;

        ### have to use F::S::Unix on VMS, or things will break
        my $file_spec = ON_VMS ? 'File::Spec::Unix' : 'File::Spec';

        ### XXX in some cases File::Find can actually die!
        ### so be safe and wrap it in an eval.
        eval {
            File::Find::find(
                {   %find_args,
                    postprocess => sub {
                        $dir_done{$File::Find::dir}++;
                    },
                    wanted => sub {

                        unless (/\.pm$/i) {
                            # skip all dot-dirs (eg .git .svn)
                            $File::Find::prune = 1
                                if -d $File::Find::name and /^\.\w/;
                            # don't reenter a dir we've already done
                            $File::Find::prune = 1
                                if $dir_done{$File::Find::name};
                            # remember perllocal.pod if we see it
                            push @{$meta{perllocalpod}}, $File::Find::name
                                if $_ eq 'perllocal.pod';
                            return;
                        }
                        my $mod = $File::Find::name;

                        ### make sure it's in Unix format, as it
                        ### may be in VMS format on VMS;
                        $mod = VMS::Filespec::unixify($mod) if ON_VMS;

                        $mod = substr( $mod, length($dir) + 1, -3 );
                        $mod = join '::', $file_spec->splitdir($mod);

                        return if $seen_mod{$mod};
                        $seen_mod{$mod} = $File::Find::name;

                        ### ignore files that don't contain a matching package declaration
                        ### warn about those that do contain some kind of package declaration
                        #my $content = read_file($File::Find::name);
                        #unless ( $content =~ m/^ \s* package \s+ (\#.*\n\s*)? $mod \b/xm ) {
                        #warn "No 'package $mod' seen in $File::Find::name\n"
                        #if $opt_verbose && $content =~ /\b package \b/x;
                        #return;
                        #}

                    },
                },
                $dir
            );
            1;
        }
            or die "File::Find died: $@";

    }

    return (\%seen_mod, \%meta);
}


sub perllocal_distro_mod_version {
    my ($distname, $perllocalpod) = @_;

    ( my $dist_mod_name = $distname ) =~ s/-/::/g;
    my $key_mod_name = $distro_key_mod_names{$distname} || $dist_mod_name;

    our $perllocal_distro_mod_version;
    if (not $perllocal_distro_mod_version) { # initial setup
        warn "Only first perllocal.pod file will be processed: @$perllocalpod\n"
            if @$perllocalpod > 1;

        # extract data from perllocal.pod
        if (my $plp = shift @$perllocalpod) {
            # The VERSION is that of the 'main module' not the distro
            my $p = ExtUtils::Perllocal::Parser->new;
            $perllocal_distro_mod_version = { map {
                $_->name => $_->{data}{VERSION}
            } $p->parse_from_file($plp) };
            warn "Details of ".keys(%$perllocal_distro_mod_version)." distributions found in $plp\n";
        }
        else {
            warn "No perllocal.pod found to aid disambiguation\n";
            $perllocal_distro_mod_version = {};
        }
    }

    return $perllocal_distro_mod_version->{$key_mod_name};
}


sub module_progress_indicator {
    my ($module) = @_;
    my $crnt = (split /::/, $module)[0];
    our $last ||= '';
    if ($last ne $crnt) {
        warn "\t$crnt...\n";
        $last = $crnt;
    }
}
