# pdc - pandoc wrapper

The `pdc` wrapper around [pandoc](https://github.com/jgm/pandoc) makes it possible to convert a pandoc document to multiple output formats in one go and to control almost any conversion setting from the YAML meta block at the top of the file. Defaults are kept in a central configuration file so as to reduce or eliminate the need for specialized settings in each document.

## Installation

- Place `pdc.pl` in your `$PATH` and make sure it is executable. Optionally, rename it to `pdc`.
- Create the directory `~/.config/pdc/` and copy `defaults.yaml` there.
- Edit your copy of `defaults.yaml` to suit your needs.

## Requirements

Obviously, perl, pandoc and pandoc-citeproc need to be installed and in your `$PATH`. The normal requirements for pandoc itself also apply.

The script requires the YAML perl module to be installed. It assumes a Unix-like environment, e.g. Linux or OS X, and will probably not work well on Windows without modification.

Some configuration options, notably turning on `--biblatex` or `--natbib` when producing PDF, require `latexmk` to be installed and in your `$PATH`.

## Usage

In order to process a Markdown document (e.g. `myfile.md`) with `pdc`, simply run `pdc myfile.md`. Assuming that you have not changed the default settings and not overriden the default behaviour through command line arguments (for which see below), a subdirectory called `myfile.pdc` will be created in the same directory as `myfile.md`, and output files for three formats (pdf, latex and html5) will be placed there.

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

Note that `format-latex` affects the PDF format, since the latter is simply a LaTeX document compiled to PDF.

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
formats: ['html5', 'epub']
format-html5:
    template: engels_blog.html5
    csl: 'turabian-fullnote-bibliography.csl'
format-epub:
    epub-cover-image: '/Users/engels/Pictures/spectre_big.jpg'
```

Take a look at `defaults.yaml` for further information on the supported conversion settings. Most settings map directly on to `pandoc` command line options, while the rest is explained using comments.

## Command line arguments

- `-h` or `--help`: Outputs a brief help message.

- `-t FORMAT` or `--to=FORMAT` or `--formats=FORMAT`: Overrides the list of formats specified in the meta block or in `defaults.yaml`. A list may be specified either by repeating the argument (e.g. `--to pdf --to html`) or by specifying a single comma-separated string (e.g `--formats=pdf,html`).

- `-i YAML_FILE` or `--include-yaml=YAML_FILE`: Sets or overrides the `include` key in the meta block. YAML files will be searched for in the `.config/pdc/` directory.

- `-d DIRNAME` or `--output-dir=DIRNAME`: Output files to this directory. Corresponds to (and overrides) the `output-dir` setting in the meta block.

-  `-n TARGETNAME` or `--target-name=TARGETNAME`: Overrides the basename of the target file(s), which by default is the same as the name of the first source file specified. This is mostly useful when there are multiple source files, e.g. `pdc -n book ch1.md ch2.md ch3.md`. Note that if `output-dir` is `auto`, this also affects the name of the output directory; in the above example, the export files would therefore be placed in the directory `book.pdc`.

## Automatically preprocessing source files

It is possible to tell `pdc` to run the markdown files through a preprocessor before converting them. In order to do this, you set the key `preprocess-command` in your settings, either at the top level or for a specific format. In the main, however, you would wish to turn this on globally for all output formats, since it relates to the source files. On the other hand, `preprocess-args` would often be different for different outputs, since you would commonly wish to include or exclude specific sections of your document based on the output format.

The command specified in `preprocess-command` must read from standard input and write to standard output.

If one uses [m4](https://www.gnu.org/software/m4/manual/index.html), the preprocessing settings might look like this:

```yaml
preprocess-command: 'm4 -P ~/.config/pdc/macros.m4 -'
general:
    preprocess-args: '-DFALLBACK'
format-html5:
    preprocess-args: '-DHTML -DHTML5'
general-latex:
    preprocess-args: '-DTEX'
```

The corresponding configuration for [gpp](https://logological.org/gpp) would actually be identical except for the preprocessing command itself.

```yaml
preprocess-command: 'gpp -H -I~/.config/pdc/macros.gpp'
general:
    preprocess-args: '-DFALLBACK'
format-html5:
    preprocess-args: '-DHTML -DHTML5'
general-latex:
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
    formats: ['latex', 'html5']
    format-html5:
        template: 'website.longread.html5'
        postprocess: ['send_to_site.py --target-dir=essays/']
    format-latex:
        include-before-body: titlepage.tex
        toc: true
        template: 'fancy.latex'
        postprocess:
            'perl fixups.pl'
            'latexmk -cd -silent -xelatex'
            'latexmk -cd -silent -c'
            'send_to_web.py --look-for=pdf --dest=files/pdfs/essays/'
```

### `generate-pdf`

Converting the output to PDF is in fact an especially common kind of post-processing. Normally one can simply add 'pdf' to `formats`, but (as we saw above) this is not always the optimal solution. Also, one may want to generate two or more pdf files at once, for instance when producing both slides and an article from the same source file. For such cases, the `generate-pdf` configuration option is provided, often obviating the need for using `postprocess`. It is valid for the output formats `latex`, `beamer`, `context`, `html`, and `html5` (Note that PDF support for the latter requires [wkhtmltopdf](http://wkhtmltopdf.org/) to be installed). Here is a somewhat typical usage example:

```yaml
pdc:
    formats: ['latex', 'beamer']
    preprocess-command: 'm4 -P'
    m4-config: "m4_changequote(`<<', `>>')"
    format-beamer:
        preprocess-args: "-DSLIDES"
        pdf-exension: beamer.pdf
        generate-pdf: true
    format-latex:
        preprocess-args: "-DARTICLE"
        generate-pdf: true
```

Note the `m4-config` option here; it is merely a small trick for changing the quote settings for `m4` in a nonobtrusive way and as early in the document as possible. It does not affect `pdc` itself.

If both `postprocess` and `generate-pdf` are present, all the steps specified in `postprocess` are called before pdf generation is attended to. One needs to be aware of this, because it means that if one wishes to do something special both *before* and *after* a PDF file is created one should turn `generate-pdf` off and instead do everything in `postprocess`. (Such was the case in the illustrative example for `postprocess` above).

## Copyright and license

Copyright: Baldur A. Kristinsson, 2016 and later.

All source files in this package, including the documentation, are open source software under the terms of [Perl's Artistic License 2.0](http://www.perlfoundation.org/artistic_license_2_0)
