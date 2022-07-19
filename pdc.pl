#!/usr/bin/env perl
# -*- mode: perl -*-

use strict;
use YAML qw/LoadFile Load/;
use File::Basename qw/fileparse/;
use File::Path qw/rmtree/;
use File::Copy qw/copy/;
use Cwd qw/getcwd/;
use Getopt::Long;

my $VERSION = '0.4';

#### PRELIMINARIES

my %pandoc_args = (
    # These are either turned on or off
    'simple_switches' => [
        qw/
            file-scope sandbox standalone ascii toc table-of-contents
            number-sections no-highlight preserve-tabs self-contained
            no-check-certificate strip-empty-paragraphs strip-comments
            reference-links atx-headers listings incremental section-divs
            html-q-tags citeproc natbib biblatex mathml gladtex trace
            dump-args ignore-args verbose quiet fail-if-warnings
          / ],

    # These may be used as booleans but can also take an URL argument
    'mixed_args' => [
        qw/ webtex mathjax katex / ],

    # These take a parameter in all cases (filter, lua-filter, metadata, variable
    # are all handled specially)
    'params' => [
        qw/
            data-dir defaults template wrap toc-depth number-offset
            top-level-division extract-media resource-path include-in-header
            include-before-body include-after-body highlight-style
            syntax-definition dpi eol columns tab-stop pdf-engine pdf-engine-opt
            reference-doc request-header abbreviations indented-code-classes
            default-image-extension shift-heading-level-by base-header-level
            track-changes reference-location markdown-headings slide-level
            email-obfuscation id-prefix title-prefix css epub-subdirectory
            epub-cover-image epub-metadata epub-embed-font epub-chapter-level
            ipynb-output bibliography csl citation-abbreviations log
          / ],
);

# If present in meta (outside the pdc section), these override all 'variables'
# settings from defaults.yaml.
my @pandoc_variables = qw/
    abstract abstract-title adjusting aspectratio author backgroundcolor
    beamerarticle beameroption biblatexoptions bibliography biblio-style
    biblio-title block-headings body category citecolor CJKmainfont
    CJKoptions classoption colorlinks colortheme contrastcolor
    curdir date date-meta description dir documentclass document-css
    filecolor fontcolor fontenc fontfamily fontfamilyoptions fontsize
    fonttheme footer footer-html footertext geometry header header-html
    header-includes headertext hyperrefoptions hyphenate include-after
    include-before includesource indent indenting innertheme institute
    interlinespace keywords lang layout lineheight linestretch
    linkcolor links-as-notes linkstyle lof logo lot mainfont
    mainfontoptions margin-bottom margin-left margin-right margin-top
    margin-top-margin-bottom mathfont meta-json microtypeoptions
    monobackgroundcolor monofont monofontoptions natbiboptions
    navigation numbersections outertheme outputfile pagenumbering
    pagestyle papersize pdfa pdfaiccprofile pdfaintent pointsize
    revealjs-url s5-url sansfont sansfontoptions secnumdepth section
    section-titles slideous-url slidy-url sourcefile subject subtitle
    thanks theme themeoptions title titlegraphic title-slide-attributes
    toc toccolor toc-depth toc-title urlcolor
/;
# keeps track of variables specified in the meta block (see above)
my %vars_in_meta = ();

my $conf_dir = "$ENV{HOME}/.config/pdc";
my @css_search_path = ($conf_dir,
                       "$ENV{HOME}/.local/share/pandoc/css",
                       "$ENV{HOME}/.local/share/pandoc",
                       "$ENV{HOME}/.pandoc/css",
                       "$ENV{HOME}/.pandoc");

# Global options
my (@formats, $config_file, $output_dir, $include_yaml, $target_name, $help);
GetOptions ("to|formats|t:s" => \@formats,
            "config|c:s" => \$config_file,
            "output-dir|d:s" => \$output_dir,
            "include-yaml|i:s" => \$include_yaml,
            "target-name|n:s" => \$target_name,
            "help|h" => \$help);
die usage() if $help;
@formats = split(/,/, join(',',@formats));
$config_file ||= "$conf_dir/defaults.yaml";
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
$conf->{formats} ||= ['html5'];

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
    my $fmt = $format eq 'pdf' ? target_pdf_format($conf) : $format;
    my @pre_cmd = ();
    # TODO: maybe make it possible to set list of markdown extensions, or
    # markdown base variant + extensions?
    my @version_info = qx/pandoc --version/ or die "error running pandoc: $!";
    my $version = $1 if @version_info && $version_info[0] =~ /^pandoc\s+([\d\.]+)/;
    $version ||= '0';
    my $major_version = $1 if $version =~ /^\D*(\d)/;
    my $source_format = $conf->{'source-format'} || $conf->{'from'} || 'markdown';
    my $core_cmd = ['pandoc', '-f', $source_format];
    my @post_cmd = ();
    push @$core_cmd, "-t", $fmt;
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

sub target_pdf_format {
    # NOTE: quite sensitive to pandoc version.
    my $conf = shift;
    my %eng2fmt = (
        'pdflatex' => 'latex',
        'lualatex' => 'latex',
        'xelatex' => 'latex',
        'latexmk' => 'latex',
        'tectonic' => 'latex',
        'context' => 'context',
        'wkhtmltopdf' => 'html',
        'weasyprint' => 'html',
        'pagedjs-cli' => 'html',
        'prince' => 'html',
        'pdfroff' => 'ms',
        );
    my $eng = $conf->{'format-pdf'} ? $conf->{'format-pdf'}->{'pdf-engine'} : $conf->{'pdf-engine'};
    $eng ||= 'xelatex';
    my $fmt = $eng2fmt{$eng} || 'latex';
    return $fmt;
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
        elsif ($param_name eq 'extract-media' && $val =~ /^(true|1|on|yes|auto)$/i) {
            $val = "./pdc-extracted-media";
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
    my $lua_filters = $c->val('lua-filters') || [];
    foreach my $filter (@$filters) {
        push @$core_cmd, "--filter=$filter";
    }
    foreach my $lfil (@$lua_filters) {
        push @$core_cmd, "--lua-filter=$lfil";
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
    my $engine = $c->val('pdf-engine');
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
    # Special processing if --extract-media has been used
    if (-d "./pdc-extracted-media" && $output_dir =~ /\.pdc/) {
        if (-d "$output_dir/pdc-extracted-media") {
            rmtree("$output_dir/pdc-extracted-media.old") if -d "$output_dir/pdc-extracted-media.old";
            rename("$output_dir/pdc-extracted-media", "$output_dir/pdc-extracted-media.old");
        }
        if (rename("./pdc-extracted-media", "$output_dir/pdc-extracted-media")) {
            rmtree("$output_dir/pdc-extracted-media.old") if -d "$output_dir/pdc-extracted-media.old";
        } else {
            warn "Could not move pdc-extracted-media to $output_dir\n";
        }
    }
}

sub get_generate_pdf {
    # generate-pdf config option
    my ($c, $post_cmd, $fmt, $output_file, $ext, $pdfext) = @_;
    my $generate_pdf = $c->val('generate-pdf');
    if ($generate_pdf && $fmt =~ /^(?:latex|beamer|context|html5?|ms)$/ && $ext !~ /pdf/) {
        my $pdf_output_file = $output_file;
        $pdf_output_file =~ s/$ext$/$pdfext/;
        my (@cmd, @cleanup, $action);
        if ($fmt =~ /html/) {
            my $vars = $c->val('variables') || {};
            my @opts = ();
            foreach my $side (qw/top right bottom left/) {
                my $k = "margin-$side";
                push(@opts, "--$k", ($vars->{$k}||"25mm"));
            }
            push(@opts, '--page-size', $vars->{papersize}) if $vars->{papersize};
            # TODO: respect pdf-engine and pdf-engine-opt
            @cmd = ('wkhtmltopdf', @opts, $output_file, $pdf_output_file);
        }
        elsif ($fmt eq 'context') {
            # 'context' can only create the pdf in the current working directory.
            # Also, it gets confused by multiple dots in filenames, hence
            # we process the .mkiv file under a temporary name.
            my ($path, $bare_pof) = ($pdf_output_file =~ m{(.*)/(.*)});
            my $bare_of = $output_file;
            $bare_of =~ s{.*[/]}{};
            my $cwd = getcwd();
            $action = sub {
                chdir $path or die "Could not chdir to $path";
                my $tmpname = "pdctmp-" . time;
                my $tmppdf = $tmpname . '.pdf';
                my $tmpexpdir = $tmpname . '-export';
                $tmpname .= '.mkiv';
                copy($bare_of, $tmpname);
                my @ctx_cmd = qw/context --batchmode --noconsole --silent=mtx* --purgeall/;
                push @ctx_cmd, $tmpname;
                print "[CMD context (in destdir)]: ", join(' ', @ctx_cmd), "\n";
                system @ctx_cmd;
                if (-f $tmppdf) {
                    rename($tmppdf, $bare_pof);
                    unlink $tmpname if -f $tmpname;
                    rmtree($tmpexpdir) if -d $tmpexpdir;
                }
                chdir $cwd or die "Could not chdir to $cwd";
            };
        }
        elsif ($fmt eq 'ms') {
            push @cmd, qw/pdfroff -ms -pdfmark -mspdf -e -t -k -KUTF-8/;
            push @cmd, "--pdf-output=$pdf_output_file";
            push @cmd, $output_file;
        }
        else {
            push @cmd, qw/latexmk -cd -silent/;
            my $eng = $c->val('pdf-engine') || 'xelatex';
            $eng = 'pdf' if $eng eq 'pdflatex';
            # TODO: handle pdf-engine-opt
            push @cmd, "-$eng";
            push @cmd, $output_file;
            @cleanup = (qw/latexmk -cd -c/, $output_file);
        }
        push @$post_cmd, \@cmd if @cmd;
        push @$post_cmd, $action if ref $action eq 'CODE';
        push @$post_cmd, \@cleanup if @cleanup;
    }
    elsif ($generate_pdf && $ext !~ /pdf/) {
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
        interpolate_env($pdc);
        return $pdc;
    } else {
        warn "WARNING: No meta block at start of document - using defaults only\n";
        return {};
    }
}

sub interpolate_env {
    # Replace strings like '${HOME}' with environment variables.
    # Also handles the special variable USERDATA.
    # This is similar to Pandoc defaults files (-D switch).
    my $c = shift;
    my $userdata = "$ENV{HOME}/.local/share/pandoc";
    if (-d "$ENV{HOME}/.pandoc" && !-e $userdata) {
        $userdata = "$ENV{HOME}/.pandoc";
    }
    foreach my $k (keys %$c) {
        if (ref $c->{$k} eq 'HASH') {
            interpolate_env($c->{$k});
        }
        elsif (ref $c->{$k} eq 'ARRAY') {
            foreach my $v (@{$c->{$k}}) {
                if ($v && !ref($v)) {
                    $v =~ s/\$\{USERDATA\}/$userdata/g;
                    $v =~ s/\$\{(\w+)\}/$ENV{$1}/g;
                }
            }
        }
        elsif ($c->{$k} && ! ref($c->{$k})) {
            $c->{$k} =~ s/\$\{USERDATA\}/$userdata/g;
            $c->{$k} =~ s/\$\{(\w+)\}/$ENV{$1}/g;
        }
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
    if (!-f $config_file && -f "$conf_dir/$config_file") {
        $config_file = "$conf_dir/$config_file";
    }
    die "config file $config_file does not exist" unless -f $config_file;
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

  -c YAML_FILE or --config=YAML_FILE

    Specify main config file. The default is ~/.config/pdc/defaults.yaml.
    This file must exist. A file name without a leading directory path will
    be looked for first in the working directory and then in ~/.config/pdc/.

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
