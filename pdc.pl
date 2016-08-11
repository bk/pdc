#!/usr/bin/env perl
# -*- mode: perl -*-

use strict;
use YAML qw/LoadFile Load/;
use File::Basename qw/fileparse/;
use File::Temp qw/tempfile/;

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
            katex-stylesheet / ],
);

my $conf_dir = "$ENV{HOME}/.config/pdc";
my $config_file = "$conf_dir/defaults.yaml";
die "config file $config_file does not exist" unless -f $config_file;

my $mdfile = shift or die "Need markdown file as parameter";
die "markdown file $mdfile does not exist" unless -f $mdfile;

#### CONFIG

# Meta section from md document (possibly following 'include' directive
# to fetch an external config file, which may chain on to others).
my $meta = get_meta($mdfile);
my $conf = load_config($config_file);
$conf = merge_conf($meta, $conf);

# If both 'pdf' and 'latex' are in formats,
# 'generate-pdf' in 'format-latex' would be superfluous.
if (grep {/pdf/} @{$conf->{formats}} && grep {/latex/} @{$conf->{formats}}) {
    $conf->{'format-latex'}->{'generate-pdf'} = 0;
}

#### MAIN SECTION

foreach my $format (@{ $conf->{formats} }) {
    my @cmds = get_command($format, $mdfile, $conf);
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

sub get_command {
    my ($format, $mdfile, $conf) = @_;
    my $iext = $1 if $mdfile=~/(\.\w+)$/;
    my ($mdfn, $mddir, $input_ext) = fileparse($mdfile, $iext);
    $mddir ||= './';
    $mddir .= '/' unless $mddir =~ /\/$/;
    my $fmt = $format eq 'pdf' ? 'latex' : $format;
    my @pre_cmd = ();
    my $core_cmd = ['pandoc', '-f', 'markdown'];
    my @post_cmd = ();
    # TODO: Preprocessor support; will affect @pre_cmd, @post_cmd.
    if ($format eq 'pdf') {
        push @$core_cmd, "-t", "latex";
    } else {
        push @$core_cmd, "-t", $format;
    }
    # Turn on if we need two-stage conversion to pdf
    # (in case of --biblatex/--natbib).
    my $two_stage = 0;
    my $ext = $format eq 'pdf' ? 'pdf' : conf_val($conf, 'extension', $fmt);
    $ext ||= $format;
    if ($format eq 'pdf' && (
            conf_val($conf, 'biblatex', $fmt) || conf_val($conf, 'natbib', $fmt))) {
        $ext = 'tmp.tex'; # so as not to conflict with possible separate latex doc
        $two_stage = 1;
    }
    # common switches
    foreach my $ss (@{$pandoc_args{simple_switches}}) {
        my $val = conf_val($conf, $ss, $fmt);
        push @$core_cmd, "--$ss" if $val;
    }
    foreach my $ma (@{$pandoc_args{mixed_args}}) {
        my $val = conf_val($conf, $ma, $fmt);
        if ($val =~ /[\.\/]/) {
            push @$core_cmd, "--$ma=$val";
        } elsif ($val) {
            push @$core_cmd, "--$ma";
        }
    }
    foreach my $param (@{$pandoc_args{params}}) {
        my $val = conf_val($conf, $param, $fmt);
        next unless $val;
        $val = [$val] unless ref $val eq 'ARRAY';
        foreach my $v (@$val) {
            push @$core_cmd, "--$param=$v";
        }
    }
    # filters, metadata, variables
    my $filters = conf_val($conf, 'filters', $fmt) || [];
    foreach my $filter (@$filters) {
        push @$core_cmd, "--filter=$filter";
    }
    my $metadata = conf_val($conf, 'metadata', $fmt) || {};
    foreach my $mk (keys %$metadata) {
        my $val = $metadata->{$mk};
        my $mval = defined $val && length($val) ? "$mk:$val" : $mk;
        push @$core_cmd, "--metadata=$mval";
    }
    my $variables = conf_val($conf, 'variables', $fmt) || {};
    foreach my $vk (keys %$variables) {
        my $val = $variables->{$vk};
        $val = undef if $val eq 'false';
        my $vval = defined $val && length($val) ? "$vk:$val" : undef;
        push @$core_cmd, "--variable=$vval" if $vval;
    }
    # template
    my $tpl = conf_val($conf, 'template', $fmt);
    unless ($tpl) {
        my $tpl_base = conf_val($conf, 'template-basename', $fmt);
        if ($tpl_base) {
            $tpl = "$tpl_base.$fmt";
            $tpl = undef unless -f "$ENV{HOME}/.pandoc/templates/$tpl";
        }
    }
    if ($tpl) {
        push @$core_cmd, "--template=$tpl";
    }
    # output files (and dir)
    my $output_file;
    if ($conf->{outputdir}) {
        my $outputdir = "$mddir$mdfn.pdc";
        unless (-d $outputdir) {
            mkdir $outputdir or die "Could not makedir $outputdir";
        }
        $output_file = "$outputdir/$mdfn.$ext";
    } else {
        $output_file = "$mddir/$mdfn.$ext";
        die "Refusing to overwrite $output_file when outputdir is false"
            if -f $output_file && !$conf->{overwrite};
    }
    push @$core_cmd, '-o', $output_file;
    # input file
    push @$core_cmd, $mdfile;
    if ($two_stage) {
        # This is triggered in case of --biblatex or --natbib
        my $latexmk = ['latexmk', '-cd', '-quiet', '-silent'];
        my $engine = conf_val($conf, 'latex-engine', $fmt);
        if ($engine) {
            push @$latexmk, ($engine eq 'pdflatex' ? '-pdf' : "-$engine");
        }
        push @$latexmk, $output_file;
        push @post_cmd, $latexmk;
        # clean up aux files, etc.
        push @post_cmd, ['latexmk', '-cd', '-c', '-quiet', '-silent', $output_file];
        my $nam = $output_file;
        $nam =~ s/\.tex$/\.pdf/;
        my $newnam = $nam;
        $newnam =~ s/\.tmp\.pdf$/\.pdf/;
        # rename pdf file (get rid of .tmp extension prefix)
        push @post_cmd, ['mv', $nam, $newnam];
    }
    return (@pre_cmd, $core_cmd, @post_cmd);
}

sub conf_val {
    my ($conf, $key, $fmt) = @_;
    my $val;
    my $try_key = "format-$fmt";
    while ($try_key) {
        if (exists $conf->{$try_key}->{$key}) {
            my $val = $conf->{$try_key}->{$key};
            $val = undef if $val eq 'false';
            return $val;
        }
        elsif ($try_key eq 'general') {
            last;
        }
        else {
            $try_key = $conf->{$try_key}->{inherit} || 'general';
        }
    }
    return;
}

sub load_config {
    my $conf_file = shift;
    $conf_file = "$conf_dir/$conf_file" unless -f $conf_file;
    return {} unless -f $conf_file;
    return LoadFile($conf_file);
}

sub get_meta {
    # Parses the YAML meta block and returns the 'pdc' key, if any.
    # If there is an 'include' subkey, try to load the referenced yaml
    # file, possibly recursively, and merge it with the values here
    # before returning.
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
    if ($meta_block) {
        my $meta = Load($meta_block) || {};
        my $pdc = $meta->{pdc} || {};
        $pdc->{general} ||= {};
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
        # special bibliography handling
        if (exists $meta->{bibliography}) {
            $pdc->{general}->{bibliography} = $meta->{bibliography}
                unless exists $pdc->{general}->{bibliography};
        }
        if ($pdc->{'no-bib'} && $pdc->{'no-bib'} ne 'false') {
            $pdc->{general}->{bibliography} = '';
            $pdc->{general}->{citeproc} = undef;
            $pdc->{general}->{csl} = '';
            $pdc->{"general-latex"}->{biblatex} = undef;
            $pdc->{"general-latex"}->{natbib} = undef;
        }
        return $pdc;
    } else {
        warn "WARNING: No meta block at start of document - using defaults only\n";
        return {general=>{}};
    }
}

sub merge_conf {
    my ($meta, $conf) = @_;
    foreach my $k (keys %$meta) {
        if (ref $meta->{$k} eq 'HASH') {
            $conf->{$k} ||= {};
            foreach my $sk (keys %{$meta->{$k}}) {
                $conf->{$k}->{$sk} = $meta->{$k}->{$sk};
            }
        } else {
            $conf->{$k} = $meta->{$k};
        }
    }
    return $conf;
}
