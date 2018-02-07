#!/usr/bin/env perl
# -*- mode: perl -*-

use strict;
use YAML qw/LoadFile Load/;
use File::Basename qw/fileparse/;
use Getopt::Long;

my $VERSION = '0.2';

#### PRELIMINARIES

my %pandoc_args = (
    # These are either turned on or off
    'simple_switches' => [
        qw/ parse-raw smart old-dashes normalize preserve-tabs file-scope
            standalone toc no-highlight self-contained html-q-tags ascii
            reference-links atx-headers chapters number-sections
            no-tex-ligatures listings incremental section-divs natbib biblatex
            gladtex / ],

    # These may be used as booleans but can also take an URL argument
    'mixed_args' => [
        qw/ latexmathml asciimathml mathml mimetex webtex jsmath
            mathjax katex / ],

    # These take a parameter in all cases (filter, metadata, variable
    # are all handled specially)
    'params' => [
        qw/ data-dir base-header-level indented-code-classes tab-stop
            track-changes extract-media template dpi wrap columns toc-depth
            highlight-style include-in-header include-before-body
            include-after-body number-offset slide-level
            default-image-extension email-obfuscation id-prefix title-prefix
            css reference-odt reference-docx epub-stylesheet epub-cover-image
            epub-metadata epub-embed-font epub-chapter-level latex-engine
            latex-engine-opt bibliography csl citation-abbreviations
            katex-stylesheet pdf-engine pdf-engine-opt / ],
);

# If present in meta (outside the pdc section), these override all 'variables'
# settings from defaults.yaml.
my @pandoc_variables = qw/
  title author date subtitle institute abstract keywords header-includes toc
  toc-title include-before include-after body meta-json lang otherlangs dir
  slidy-url slideous-url s5-url revealjs-url theme colortheme fonttheme
  innertheme navigation section-titles papersize fontsize documentclass
  classoption geometry margin-left margin-right margin-top linestretch
  fontfamily fontfamilyoptions mainfont sansfont monofont CJKmainfont
  mainfontoptions sansfontoptions monofontoptions mathfontoptions CJKoptions
  fontenc colorlinks linkcolor citecolor urlcolor toccolor links-as-notes
  indent subparagraph thanks toc toc-depth secnumdepth lof lot bibliography
  biblio-style biblatexoptions layout contrastcolor linkstyle indenting
  whitespace interlinespace headertext footertext pagenumbering section
  header footer adjusting hyphenate
/;
# keeps track of variables specified in the meta block (see above)
my %vars_in_meta = ();

my $conf_dir = "$ENV{HOME}/.config/pdc";
my $config_file = "$conf_dir/defaults.yaml";
die "config file $config_file does not exist" unless -f $config_file;
my @css_search_path = ($conf_dir, "$ENV{HOME}/.pandoc/css", "$ENV{HOME}/.pandoc");

# Global options
my (@formats, $output_dir, $include_yaml, $target_name, $help);
GetOptions ("to|formats|t:s" => \@formats,
            "output-dir|d:s" => \$output_dir,
            "include-yaml|i:s" => \$include_yaml,
            "target-name|n:s" => \$target_name,
            "help|h" => \$help);
die usage() if $help;
@formats = split(/,/, join(',',@formats));
check_options();

my @mdfiles = @ARGV or die "ERROR: Need at least one markdown file as parameter\n";
for my $mdf (@mdfiles) {
    die "ERROR: markdown file $mdf does not exist\n" unless -f $mdf;
}

#### CONFIG

# Meta section from md document (possibly following 'include' directive
# to fetch an external config file, which may chain on to others).
my $meta = get_meta($mdfiles[0]);
my $conf = load_config($config_file);
$conf = merge_conf($meta, $conf);
$conf->{formats} = \@formats if @formats;

# If both 'pdf' and 'latex' are in formats,
# 'generate-pdf' in 'format-latex' would be superfluous.
if (join('::', sort @{$conf->{formats}}) =~ /latex:.*:pdf/) {
    $conf->{'format-latex'}->{'generate-pdf'} = 0;
}

#### MAIN SECTION

foreach my $format (@{ $conf->{formats} }) {
    my @cmds = get_commands($format, $conf, @mdfiles);
    foreach my $cmd (@cmds) {
        if (ref $cmd eq 'CODE') {
            print "[CLEANUP/PREP $format]\n";
            $cmd->();
        }
        elsif (ref $cmd eq 'ARRAY') {
            print "[CMD $format]: ", join(' ', @$cmd), "\n";
            system(@$cmd) == 0
                or warn "ERROR: Command returned non-zero exit code: $?";
        }
    }
}


#### SUBS BELOW

sub get_commands {
    my ($format, $conf, @mdfiles) = @_;
    my $iext = $1 if $mdfiles[0] =~ /(\.\w+)$/;
    my ($mdfn, $mddir, $input_ext) = fileparse($mdfiles[0], $iext);
    $mddir ||= './';
    $mddir .= '/' unless $mddir =~ /\/$/;
    my $fmt = $format eq 'pdf' ? 'latex' : $format;
    my @pre_cmd = ();
    # TODO: maybe make it possible to set list of markdown extensions, or
    # markdown base variant + extensions?
    my @version_info = qx/pandoc --version/ or die "error running pandoc: $!";
    my $version = $1 if @version_info && $version_info[0] =~ /^pandoc\s+([\d\.]+)/;
    $version ||= '0';
    my $major_version = $1 if $version =~ /^\D*(\d)/;
    my $core_cmd = ['pandoc', '-f', 'markdown'];
    my @post_cmd = ();
    if ($format eq 'pdf') {
        push @$core_cmd, "-t", "latex";
    } else {
        push @$core_cmd, "-t", $format;
    }
    my $c = new Conf (format=>$fmt, conf=>$conf,
                      version=>$major_version, full_version=>$version);

    my ($ext, $pdfext, $two_stage) = get_file_extensions($c, $format);

    # Get output file (and possibly create output dir).
    my $output_file = get_output_file($c, $core_cmd, $conf, $mddir, $mdfn, $ext);

    # Options directly corresponding to pandoc command-line args
    get_basic_pandoc_args($c, $core_cmd, $mddir);

    # filters, metadata, variables
    get_filters_etc($c, $core_cmd);

    # template
    get_template($c, $core_cmd, $fmt);

    # possibly override target filename
    my $trg = ($target_name || $conf->{target_name} || '');
    $mdfn = $trg if $trg;

    # preprocess + add input file(s) to core_cmd
    get_input_files_and_preprocess(
        $c, $core_cmd, \@pre_cmd, \@post_cmd, $format, $mddir);

    # User-configured postprocessing
    get_postprocessing($c, \@post_cmd, $output_file);

    # Two-stage pdf production in virtue of biblatex/natbib
    # (when 'pdf' is in formats). Note that this should run after postprocessing
    # so that filters, if present, will work.
    if ($two_stage) {
        maybe_biblatex_natbib($c, \@post_cmd, $output_file);
    }
    # Two-stage pdf production when 'pdf' is not in formats or does
    # not apply to this format.
    get_generate_pdf($c, \@post_cmd, $fmt, $output_file, $ext, $pdfext);

    return (@pre_cmd, $core_cmd, @post_cmd);
}

sub get_file_extensions {
    my ($c, $format) = @_;
    # $two_stage is true if we need two-stage conversion to pdf
    # because of --biblatex/--natbib.
    my $two_stage = 0;
    my $ext = $format eq 'pdf' ? 'pdf' : $c->val('extension');
    my $pdfext = $c->val('pdf-extension') || 'pdf';
    $ext ||= $format;
    if ($format eq 'pdf' && ($c->val('biblatex') || $c->val('natbib'))) {
        $ext = 'tmp.tex'; # so as not to conflict with possible separate latex doc
        $two_stage = 1;
    }
    return ($ext, $pdfext, $two_stage);
}

sub get_output_file {
    # Adds the output file to core_cmd.
    # Also makes sure the $output_dir global is set to the correct value.
    my ($c, $core_cmd, $conf, $mddir, $mdfn, $ext) = @_;
    # output files (and dir)
    my $output_file;
    if ($output_dir || ($conf->{'output-dir'} && $conf->{'output-dir'} ne 'false')) {
        my $outputdir = $output_dir || $conf->{'output-dir'};
        $outputdir = "$mddir$mdfn.pdc" if $outputdir eq 'auto';
        unless (-d $outputdir) {
            mkdir $outputdir or die "ERROR: Could not mkdir $outputdir: $!\n";
        }
        $output_file = "$outputdir/$mdfn.$ext";
        $output_dir = $outputdir;
    } else {
        $output_file = "$mddir/$mdfn.$ext";
        die "ERROR: Refusing to overwrite existing $output_file when outputdir has not been specified\n"
            if -f $output_file && !$conf->{overwrite};
        $output_dir = $mddir;
    }
    push @$core_cmd, '-o', $output_file;
    return $output_file;
}

sub get_basic_pandoc_args {
    # Assembles the arguments directly corresponding to pandoc command-line switches.
    # Called by get_commands.
    my ($c, $core_cmd, $mddir) = @_;
    my %only_v1_switches = qw/normalize 1 smart 1/;
    my %v1_to_v2_repl = qw/latex- pdf-/;

    # common switches
    foreach my $ss (@{$pandoc_args{simple_switches}}) {
        my $val = $c->val($ss);
        if ($val) {
            push @$core_cmd, "--$ss" unless $only_v1_switches{$ss} && $c->is_v2;
        }
    }
    foreach my $ma (@{$pandoc_args{mixed_args}}) {
        my $val = $c->val($ma);
        if ($val =~ /[\.\/]/) {
            push @$core_cmd, "--$ma=$val";
        } elsif ($val) {
            push @$core_cmd, "--$ma";
        }
    }
    foreach my $param (@{$pandoc_args{params}}) {
        my $val = $c->val($param);
        my $param_name = $param;
        if ($param_name =~ /^latex-/ && $c->is_v2) {
            $param_name =~ s/^latex/pdf/;
        }
        next unless $val;
        if ($param_name eq 'css' && $c->val('self-contained')) {
            $val = expand_css_path($val, $mddir);
        }
        $val = [$val] unless ref $val eq 'ARRAY';
        foreach my $v (@$val) {
            push @$core_cmd, "--$param_name=$v";
        }
    }
}

sub expand_css_path {
    my ($css, $input_dir) = @_;
    # Don't search for the file unless it contains no directory spec
    return $css if $css =~ /\//;
    # Don't alter the path if the file is found in $input_dir
    return $css if -f $input_dir . $css;
    foreach my $dir (@css_search_path) {
        return "$dir/$css" if -f "$dir/$css";
    }
    # Give up and let pandoc deal with the mess. (Hint: it won't).
    return $css;
}

sub get_filters_etc {
    # Process filters, metadata and variables and add to core_cmd.
    my ($c, $core_cmd) = @_;
    my $filters = $c->val('filters') || [];
    foreach my $filter (@$filters) {
        push @$core_cmd, "--filter=$filter";
    }
    if ($c->val('citeproc')) {
        push @$filters, "pandoc-citeproc"
            unless grep {/pandoc-citeproc/} @$filters;
    }
    my $metadata = $c->val('metadata', merge=>1) || {};
    foreach my $mk (keys %$metadata) {
        my $val = $metadata->{$mk};
        my $mval = defined $val && length($val) ? "$mk:$val" : $mk;
        push @$core_cmd, "--metadata=$mval";
    }
    my $variables = $c->val('variables', merge=>1) || {};
    foreach my $vk (keys %$variables) {
        # Whatever is defined in the meta section of the current document has
        # precedence, even if it was defined outside the pdc section.
        # Even the pdc section only has precedence for individual formats,
        # so the normal attribute inheritance does not apply to variables
        # defined there.
        if (exists $vars_in_meta{$vk}) {
            my $fmt = "format-" . $c->{format};
            next unless $meta->{$fmt} && exists $meta->{$fmt}->{$vk};
        }
        my $val = $variables->{$vk};
        $val = undef if $val eq 'false';
        my $vval = defined $val && length($val) ? "$vk:$val" : undef;
        push @$core_cmd, "--variable=$vval" if $vval;
    }
}

sub get_template {
    # Get template (if applicable) and add to core_cmd.
    my ($c, $core_cmd, $fmt) = @_;
    # template
    my $tpl = $c->val('template');
    unless ($tpl) {
        my $tpl_base = $c->val('template-basename');
        if ($tpl_base) {
            $tpl = "$tpl_base.$fmt";
            $tpl = undef unless -f "$ENV{HOME}/.pandoc/templates/$tpl";
        }
    }
    if ($tpl) {
        push @$core_cmd, "--template=$tpl";
    }
}

sub get_input_files_and_preprocess {
    # Adds input files to core_cmd, perhaps after a pre-processing stage.
    my ($c, $core_cmd, $pre_cmd, $post_cmd, $format, $mddir) = @_;
    my $preprocess = $c->val('preprocess-command');
    my $preprocess_args = $c->val('preprocess-args') || '';
    if ($preprocess) {
        # Note that we need to create the temporary file in the same directory as
        # the original markdown file, in case that it references external resources.
        my $tempfile = "${mddir}_pdctmp.".time.".".$$.".$format.md";
        die "Temp file $tempfile exists!\n" if -f $tempfile;
        # The sed filter removes any leading whitespace from the result;
        # gpp is especially bad about leaving whitespace when you include a macro
        # file from the command line.
        my $sed_clean = q(sed -e :a -e '/[^[:blank:]]/,$!d; /^[[:space:]]*$/{ $d; N; ba' -e '}');
        my $fnstr = join(' ', map { shellescape_filename($_) } @mdfiles);
        my $cmd = "cat $fnstr | $preprocess $preprocess_args | $sed_clean > $tempfile";
        push @$pre_cmd, sub {
            warn "  --> preprocess: $cmd\n";
            system($cmd)==0 or die "ERROR: preprocess failed!\n";
        };
        push @$post_cmd, sub {
            warn "  --> preprocess cleanup: unlink $tempfile\n";
            unlink $tempfile or warn "WARNING: could not unlink $tempfile\n";
        };
        push @$core_cmd, $tempfile;
    }
    else {
        push @$core_cmd, @mdfiles;
    }
}

sub maybe_biblatex_natbib {
    my ($c, $post_cmd, $output_file) = @_;
    # This is triggered in case of --biblatex or --natbib
    my $latexmk = ['latexmk', '-cd', '-quiet', '-silent'];
    my $engine = $c->val('latex-engine');
    if ($engine) {
        push @$latexmk, ($engine eq 'pdflatex' ? '-pdf' : "-$engine");
    }
    push @$latexmk, $output_file;
    push @$post_cmd, $latexmk;
    # clean up aux files, etc.
    push @$post_cmd, ['latexmk', '-cd', '-c', '-quiet', '-silent', $output_file];
    my $nam = $output_file;
    $nam =~ s/\.tex$/\.pdf/;
    my $newnam = $nam;
    $newnam =~ s/\.tmp\.pdf$/\.pdf/;
    # rename pdf file (get rid of .tmp extension prefix)
    push @$post_cmd, ['mv', $nam, $newnam];
}

sub get_postprocessing {
    my ($c, $post_cmd, $output_file) = @_;
    my $postprocess = $c->val('postprocess');
    $postprocess = [$postprocess] if $postprocess && !ref $postprocess;
    foreach my $cmd (@$postprocess) {
        my $fnarg = shellescape_filename($output_file);
        push @$post_cmd, sub {
            warn "  --> post-process: $cmd $fnarg\n";
            system("$cmd $fnarg") == 0 or warn "WARNING: postprocessing command failed: $!\n";
        };
    }
}

sub get_generate_pdf {
    # generate-pdf config option
    my ($c, $post_cmd, $fmt, $output_file, $ext, $pdfext) = @_;
    my $generate_pdf = $c->val('generate-pdf');
    if ($generate_pdf && $fmt =~ /^(?:latex|beamer|context|html5?)$/ && $ext !~ /pdf/) {
        my $pdf_output_file = $output_file;
        $pdf_output_file =~ s/$ext$/$pdfext/;
        my (@cmd, @cleanup);
        if ($fmt =~ /html/) {
            my $vars = $c->val('variables') || {};
            my @opts = ();
            foreach my $side (qw/top right bottom left/) {
                my $k = "margin-$side";
                push(@opts, "--$k", $vars->{$k}) if $vars->{$k};
            }
            push(@opts, '--page-size', $vars->{papersize}) if $vars->{papersize};
            @cmd = ('wkhtmltopdf', @opts, $output_file, $pdf_output_file);
        }
        elsif ($fmt eq 'context') {
            push @cmd, qw/context --batchmode --purge --result/;
            push @cmd, $pdf_output_file, $output_file;
        }
        else {
            push @cmd, qw/latexmk -cd -silent/;
            my $eng = $c->val('latex-engine') || 'xelatex';
            $eng = 'pdf' if $eng eq 'pdflatex';
            # TODO: handle latex-engine-opt
            push @cmd, "-$eng";
            push @cmd, $output_file;
            @cleanup = (qw/latexmk -cd -c/, $output_file);
        }
        push @$post_cmd, \@cmd;
        push @$post_cmd, \@cleanup if @cleanup;
    }
    elsif ($generate_pdf) {
        warn "WARNING: generate-pdf option not supported for format $fmt -- skipping\n";
    }
}

sub load_config {
    my $conf_file = shift;
    $conf_file = "$conf_dir/$conf_file" unless -f $conf_file;
    return {} unless -f $conf_file;
    return LoadFile($conf_file);
}

sub get_meta {
    # Parses the YAML meta block and returns the 'pdc' key, if any. If there
    # is an 'include' subkey or an '--include-yaml' command line switch, try
    # to load the referenced yaml file, possibly recursively, and merge it
    # with the values here before returning.
    my $mdfile = shift;
    my $meta_block = '';
    my $seen_start = 0;
    open IN, "<:encoding(UTF-8)", $mdfile or die "Could not open $mdfile for reading";
    while (my $ln = <IN>) {
        if ($seen_start && $ln =~ /^[\-\.]{3}\s*$/) {
            last;
        } elsif ($ln =~ /^---\s*$/) {
            $seen_start = 1;
        } elsif ($ln =~ /^\s*$/) {
            next;
        } elsif ($seen_start) {
            $meta_block .= $ln;
        } else {
            last;
        }
    }
    close IN;
    if ($meta_block || $include_yaml) {
        my $meta = Load($meta_block) || {};
        foreach my $var (@pandoc_variables) {
            $vars_in_meta{$var} = $meta->{$var} if exists $meta->{$var};
            $vars_in_meta{$var} = undef if $meta->{$var} eq 'false';
        }
        my $pdc = $meta->{pdc} || {};
        if ($include_yaml) {
            $pdc->{include} ||= $include_yaml;
        }
        # follow potential chain of includes.
        my %loaded = ();
        while ($pdc->{include}) {
            my $inc = $pdc->{include};
            last if $loaded{$inc}++;
            delete $pdc->{include};
            $pdc->{_include} ||= [];
            push @{ $pdc->{_include} }, $inc;
            my $iconf = load_config($inc);
            $pdc = merge_conf($pdc, $iconf);
        }
        return $pdc;
    } else {
        warn "WARNING: No meta block at start of document - using defaults only\n";
        return {};
    }
}

sub merge_conf {
    my ($meta, $conf) = @_;
    # For backwards compatibility with pre-v0.1:
    if (exists $meta->{general}) {
        foreach my $k (keys %{ $meta->{general} }) {
            $meta->{$k} = $meta->{general}->{$k} unless exists $meta->{$k};
        }
        delete $meta->{general};
    }
    foreach my $k (keys %$meta) {
        if (ref $meta->{$k} eq 'HASH') {
            $conf->{$k} ||= {};
            foreach my $sk (keys %{$meta->{$k}}) {
                # necessary for merging 'variables' and 'metadata' properly
                if (ref $meta->{$k}->{$sk} eq 'HASH') {
                    $conf->{$k}->{$sk} ||= {};
                    foreach my $sk2 (keys %{ $meta->{$k}->{$sk} }) {
                        $conf->{$k}->{$sk}->{$sk2} = $meta->{$k}->{$sk}->{$sk2};
                    }
                } else {
                    $conf->{$k}->{$sk} = $meta->{$k}->{$sk};
                }
            }
        } else {
            $conf->{$k} = $meta->{$k};
        }
    }
    return $conf;
}

sub check_options {
    # @formats are not checked
    if ($output_dir) {
        die "ERROR: output dir $output_dir (or its parent_directory) does not exist\n"
            unless output_dir_ok($output_dir);
    }
    if ($include_yaml) {
        die "ERROR: YAML file $include_yaml does not exist\n"
            unless -f $include_yaml;
    }
    if ($target_name && $target_name =~ /\//) {
        die "ERROR: target_name must be bare, without directory\n";
    }
}

sub output_dir_ok {
    # Either the output dir or its parent must exist.
    my $dir = shift;
    return 1 if -d $dir;
    return 1 if $dir =~ /^[^\/]+$/;
    $dir =~ s/\/+$//;
    my $parent_dir = $1 if $dir =~ /(.*)\//;
    return 1 if -d $parent_dir;
    return 0;
}

sub shellescape_filename {
    my $fn = shift;
    $fn =~ s{'}{'\\''}g;
    return "'$fn'";
}

sub usage {
    my $prog_name = $0;
    $prog_name =~ s/.*\///;
    return qq{$prog_name [v$VERSION] - Pandoc wrapper script

Usage: $prog_name [OPTIONS] FILES

Options:

  -t FORMAT or --to=FORMAT or --formats=FORMAT

    Output format override. May be repeated, e.g. '--to pdf --to html',
    or specified as a single comma-separated string, e.g '-t pdf,html'.

  -i YAML_FILE or --include-yaml=YAML_FILE

    Read extra config file and merge with settings in document.
    Corresponds to 'include' key in 'pdc' section of document meta.

  -d DIRNAME or --output-dir=DIRNAME

    Output files to this directory.

  -n TARGETNAME or --target-name=TARGETNAME

    Name (without directory or extension) of output files.

  -h or --help

     This help message.
};
}

package Conf;

sub new {
    my ($pk, %opt) = @_;
    my $self = \%opt;
    bless($self, (ref($pk) || $pk));
    die "need both conf and format"
        unless $self->{conf} && $self->{format};
    return $self;
}

sub val {
    # Gets the value of the given key.
    #
    # If the 'merge' option is true, assume that the value is intended to be a
    # hashref and collect keys into it while following the inheritance chain
    # all the way up.
    my ($self, $key, %opt) = @_;
    my $merge = $opt{merge} || 0;
    my $ret = $merge ? {} : undef;
    my $conf = $self->{conf};
    my $fmt = $self->{format};
    my $val;
    my $try_key = "format-$fmt";
    while ($try_key) {
        if (exists $conf->{$try_key}->{$key}) {
            my $val = $conf->{$try_key}->{$key};
            $val = undef if $val eq 'false';
            if ($merge && ref $val eq 'HASH') {
                foreach my $k (keys %$val) {
                    $ret->{$k} = $val->{$k} unless exists $ret->{$k};
                }
                $try_key = $conf->{$try_key}->{inherit};
            }
            else {
                return $val;
            }
        }
        else {
            $try_key = $conf->{$try_key}->{inherit};
        }
    }
    if ($merge) {
        # check toplevel:
        if (ref $conf->{$key} eq 'HASH') {
            foreach my $k (keys %{ $conf->{$key} }) {
                next if exists $ret->{$k};
                my $val = $conf->{$key}->{$k};
                $val = undef if $val eq 'false';
                $ret->{$k} = $val;
            }
        }
        # cleanup
        foreach my $k (keys %$ret) {
            $ret->{$k} = undef if $ret->{$k} eq 'false';
        }
        return $ret;
    }
    elsif ($conf->{$key} && $conf->{$key} ne 'false') {
        return $conf->{$key};
    }
    return;
}

sub version {
    my ($self, $full) = @_;
    return $full ? $self->{full_version} : $self->{version}
}

sub is_v2 { shift->version == 2 }

1;
