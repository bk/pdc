# pdc - pandoc wrapper

The `pdc` wrapper around [pandoc](https://github.com/jgm/pandoc) makes it possible to convert a pandoc document to multiple output formats in one go and to control almost any conversion setting from the YAML meta block at the top of the file. Defaults are kept in a central configuration file so as to reduce or eliminate the need for specialized settings in each document.

## Installation

- Place `pdc.pl` in your `$PATH` and make sure it is executable. Alternatively, create a symlink to it under your preferred name (e.g. `pdc`).
- Create the directory `~/.config/pdc/` and copy `defaults.yaml` there.
- Edit your copy of `defaults.yaml` to suit your needs.

## Command line options

The following options can be specified before the list of files to be processed, i.e. `pdc [OPTIONS] FILES`.

- `-c YAML_FILE` or `--config=YAML_FILE`: Specify main config file. The default is `~/.config/pdc/defaults.yaml`. This file must exist. A file name without a leading directory path will be looked for first in the working directory and then in `~/.config/pdc/`.

- `-t FORMAT` or `--to=FORMAT` or `--formats=FORMAT`: Output format override. May be repeated, e.g. `--to pdf --to html`, or specified as a single comma-separated string, e.g `-t pdf,html`.

- `-i YAML_FILE` or `--include-yaml=YAML_FILE`: Read extra config file and merge with settings in document. Corresponds to `include` key in `pdc` section of document meta. Will be looked for in `~/.config/pdc/` unless found via the working directory.

- `-d DIRNAME` or `--output-dir=DIRNAME`: Output files to this directory. If set to the special value `auto` (the default), the output directory will have the same name as the (first) input file (or as the filename specified with the `-n` switch), except that the extension is replaced with `.pdc`. The default output directory for files generated from `myfile.md` is thus `myfile.pdc`. If set to a false value or the empty string, the output directory will be the current working directory.

- `-n TARGETNAME` or `--target-name=TARGETNAME`: Name (without directory or extension) of output files. The default is the same basename as the first input file. This is mostly useful when there are multiple source files, e.g. `pdc -n book ch1.md ch2.md ch3.md`. Note that if `output-dir` is `auto`, this also affects the name of the output directory; in the above example, the export files would therefore be placed in the directory `book.pdc`.

- `-h` or `--help`: Shows a summary of the options.

## Requirements

Obviously, both perl and pandoc need to be installed and in your `$PATH`. The normal requirements for pandoc's software environment also apply. For instance, some options require LaTeX to be installed.

The script requires the `YAML` Perl module to be installed. It assumes a Unix-like environment, such as Linux or OS X, and will not work well on Windows without modification.

Some configuration options require the presence of specific programs in your `$PATH`. These mainly relate to PDF production and will be described further below (in the section Generating PDF).

## Usage

In order to process a Markdown document (e.g. `myfile.md`) with `pdc`, simply run `pdc myfile.md`. Assuming that you have not changed the default settings and not overriden the default behaviour through command line arguments (for which see below), a subdirectory called `myfile.pdc` will be created in the same directory as `myfile.md`, and output files for three formats (pdf, latex and html) will be placed there.

Like with pandoc, you can also specify multiple source files which together will be turned into a single target document for each of the configured formats. However, unlike pandoc, `pdc` does not read markdown source from STDIN, so do not attempt to pipe data to it.

In order to select formats and otherwise customize the conversion process, add a `pdc` section to your document meta block, like in this example:

```yaml
---
title: The Communist Manifesto
author:
    - Karl Marx
    - Friedrich Engels
date: 1848-02-21
lang: en-GB
bibliography: /home/km/bib/manifesto.bib
csl: chicago-author-date.csl
pdc:
    formats: ['pdf', 'docx', 'epub']
    format-latex:
        template: manifesto.latex
    format-epub:
        epub-cover-image: '/home/km/img/spectre_big.jpg'
...
```

Note that `format-latex` affects the PDF format, since the latter (in this case) is simply a LaTeX document compiled to PDF. (There are other options for PDF generation, for which see below.)

Now, let's suppose that Karl and Friedrich collaborate on this document through a shared Github repository, but it is tedious for Friedrich to be constantly changing the `pdc` section of the file in his working directory to point to the correct cover image. Also, he would like to add a version of the manifesto to his blog (where he uses a different citation style) and is not really interested in the PDF or Word formats.

The solution in such a case is to change the `pdc` section so as to use the `include` option:

```yaml
---
title: The Communist Manifesto
author:
    - Karl Marx
    - Friedrich Engels
date: 1848-02-21
lang: en-GB
bibliography: manifesto.bib
csl: chicago-author-date.csl
pdc:
    include: manifesto.yaml
...
```

Marx's version of `manifesto.yaml` (most conveniently placed into `~/.config/pdc/`) will then be:

```yaml
formats: ['pdf', 'docx', 'epub']
format-latex:
    template: manifesto.latex
format-epub:
    epub-cover-image: '/home/km/img/spectre_big.jpg'
```

as we saw above, while Engels's version of this file perhaps might look like this:

```yaml
formats: ['html', 'epub']
format-html5:
    template: engels_blog.html
    csl: 'turabian-fullnote-bibliography.csl'
format-epub:
    epub-cover-image: '/Users/engels/Pictures/spectre_big.jpg'
```

Take a look at `defaults.yaml` for further information on the supported conversion settings. Most settings map directly on to `pandoc` command line options, while the rest is explained using comments.


## Preprocessing source files

It is possible to tell `pdc` to run the markdown files through a preprocessor before converting them. In order to do this, you set the key `preprocess-command` in your settings, either at the top level or for a specific format. Generally speaking, you would wish to turn this on globally for all output formats, since it relates to the markdown source itself. However, `preprocess-args` might often be different for different outputs, since you would commonly wish to include or exclude specific sections of your document based on the output format.

The command specified in `preprocess-command` must read from standard input and write to standard output.

If one uses [m4](https://www.gnu.org/software/m4/manual/index.html), the preprocessing settings might look like this:

```yaml
preprocess-command: 'm4 -P ~/.config/pdc/macros.m4 -'
preprocess-args: '-DFALLBACK'
format-html:
    preprocess-args: '-DHTML'
format-latex:
    preprocess-args: '-DTEX'
```

The corresponding configuration for [gpp](https://logological.org/gpp) would actually be identical except for the preprocessing command itself.

```yaml
preprocess-command: 'gpp -H -I~/.config/pdc/macros.gpp'
preprocess-args: '-DFALLBACK'
format-html:
    preprocess-args: '-DHTML'
format-latex:
    preprocess-args: '-DTEX'
```

An interesting blog entry describing the advantages of using gpp with pandoc can be found [here](https://randomdeterminism.wordpress.com/2012/06/01/how-i-stopped-worring-and-started-using-markdown-like-tex/).

In many cases, preprocessing represents an efficient and highly configurable alternative to using pandoc filters.

## Post-processing output files

### `postprocess`

Sometimes you need to do something with an output file after `pandoc` is done with it, e.g. run it through a fix-up filter of some kind or placing it onto your web site. By adding a `postprocess` section to the configuration for the appropriate format, `pdc` will run these commands for you automatically each time it is invoked. It is possible to run several preprocess commands for the same output format. Each preprocess command receives the name of the output file as its only argument.

The following example from a document meta block shows an instance where the latex output from pandoc had some small imperfections that needed to be smoothed out before actually generating the pdf. The pdf generation is therefore relegated to a post-processing step, rather than being explicitly listed in `formats`. In this way, one can almost always avoid having to write a makefile or shell script (or running the entire repetitive sequence of commands by hand).

```yaml
pdc:
    formats: ['latex', 'html']
    format-html:
        template: 'website.longread.html'
        postprocess: ['send_to_site.py --target-dir=essays/']
    format-latex:
        include-before-body: titlepage.tex
        toc: true
        template: 'fancy.latex'
        postprocess:
            - 'perl fixups.pl'
            - 'latexmk -cd -silent -xelatex'
            - 'latexmk -cd -silent -c'
            - 'send_to_web.py --look-for=pdf --dest=files/pdfs/essays/'
```

## Generating PDF

There are three ways of generating PDF files using pdc:

1. Adding `pdf` to `formats` with optional tweaks under `format-pdf`. This normally uses Pandoc's native PDF production methods, which differ somewhat between versions. The main configuration options here are `pdf-engine` and `pdf-engine-opt`. For further information on these, see the documentation for your Pandoc version. The `pdf-engine` configured in the default `defaults.yaml` file is `xelatex`. The only wrinkle here is that if `biblatex` or `natbib` are set to a true value and you use a LaTeX-based `pdf-engine` (i.e. one of `pdflatex`, `lualatex`, `xelatex`, `tectonic` or `latexmk`), then `latexmk` is run by `pdc` rather than Pandoc and needs to be in your `$PATH`.

2. Setting `generate-pdf` to a true value for one or more of the following formats: `latex`, `beamer`, `context`, `html`, `html5`, `html4`, `ms`, `odt`, `docx`, or `rtf`. The `latex` and `beamer` formats require `latexmk` to be in `$PATH` for the conversion to work; `context` requires `context`; the `html` formats require `wkhtmltopdf`; `ms` requires `pdfroff`; and `odt`, `docx` and `rtf` require `libreoffice`. If you produce more than one PDF file for the same input file, unique filenames may be guaranteed by setting `pdf-extension`.

3. Take care of the PDF generation manually in the `postprocess` section, as in the example above. This is obviously the most flexible option, but also involves the most work.

Note that `pdc`'s `wkhtmltopdf` conversion for the HTML formats is currently rather basic. In particular, it does not respect custom margin settings and may yield suboptimal results for embedded math. Setting `pdf-engine` to `wkhtmltopdf` and specifying `pdf` as an output format will often be preferable to using the `generate-pdf` option in this case.

An example of `generate-pdf` usage, where both slides and an article are generated from the same Markdown document, with some assistance from the `m4` preprocessor:

```yaml
pdc:
    formats: ['latex', 'beamer']
    preprocess-command: 'm4 -P'
    m4-config: "m4_changequote(`<<', `>>')"
    format-beamer:
        preprocess-args: "-DSLIDES"
        pdf-extension: slides.pdf
        generate-pdf: true
    format-latex:
        preprocess-args: "-DARTICLE"
        generate-pdf: true
```

The purpose of the `pdf-extension` setting is to ensure that one PDF document is not overwritten by another. (The default value of this setting is of course simply `pdf`).

Note the `m4-config` option here; it is merely a small trick for changing the quote settings for `m4` in a nonobtrusive way and as early in the document as possible. It does not affect `pdc` itself, nor has it any special meaning to Pandoc.

If both `postprocess` and `generate-pdf` are present, all the steps specified in `postprocess` are called before `generate-pdf`-triggered PDF production is attended to. One needs to be aware of this, because it means that if one wishes to do something special both *before* and *after* a PDF file is created one should turn `generate-pdf` off and instead do everything in `postprocess`. (Such was the case in the illustrative example for `postprocess` above).


## Pandoc variables

Pandoc has the concept of [variables](http://pandoc.org/MANUAL.html#variables-set-by-pandoc). In short, these are attributes which may be set in the meta block or from the command line, are visible to templates and may alter pandoc's behaviour with regard to specific output formats.

When using `pdc`, these variables of course still work, but it is possible to set defaults for them in `defaults.yaml` or override them (perhaps for the purpose of differentiating between the settings for different output formats). The rules of precedence with regard to variables for the format `X` are as follows:

1. If a variable is specified in a `variables` section at the top level in `defaults.yaml`, it affects the output for all formats, including format `X`;
2. *unless* it is overridden in `defaults.yaml` in the `variables` subsection of `format-X`;
3. *unless* it is specified as a normal pandoc variable (i.e. outside the `pdc` section) in the topmost meta block of the document itself;
4. *unless* it is specified inside the `pdc` section of the document meta block, under the `variables` key;
5. *unless* it is specified inside the `pdc` section of the document meta block under the `variable` subkey of the `format-X` key.

As a rule, when variables are set specifically for `pdc`-produced output, one should place them inside `format-*` sections. If they apply to several formats (or only one format is being produced), they should be in the topmost level of the meta block (i.e. outside the `pdc` section), so as to maintain the greatest possible compatibility with other tools.

Note that there is some overlap between command line arguments and variables in pandoc. Command line arguments override variables of the same name set in the document meta block, while variables set on the command line override both. This behaviour is reflected in `pdc`, and may sometimes lead to unexpected results:

* There are four pre-defined pandoc variables which share a name with a command-line argument: `title`, `toc`, `bibliography, csl`.
* There are three further variables which have direct pandoc command-line equivalents although the names are not quite identical: `header-includes` (which corresponds to `--include-in-header`), `include-before` (corresponding to `--include-before-body`), and `include-after` (corresponding to `--include-after-body`).


## Compatibility

`pdc` is primarily intended for use with Pandoc version 2.x (2.18 at the time of writing). It was, however, originally written for Pandoc 1.17 and will continue to work with the 1.x series as long as one avoids putting a few incompatible options in `defaults.yaml`.

## Copyright and license

Copyright: Baldur A. Kristinsson, 2016 and later.

All source files in this package, including the documentation, are open source software under the terms of [Perl's Artistic License 2.0](http://www.perlfoundation.org/artistic_license_2_0)
