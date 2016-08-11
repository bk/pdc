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

In order to process a Markdown document (e.g. `myfile.md`) with `pdc`, simply run `pdc myfile.md`. Assuming that you have not changed the default settings, a subdirectory called `myfile.pdc` will be created in the same directory as `myfile.md`, and output files for three formats (pdf, latex and html5) will be placed there.

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

Now, let's say Karl and Friedrich collaborate on this document through a shared Github repository, but it is tedious for Friedrich to be constantly changing the `pdc` section of the file in his working directory to point to the correct cover image. Also, he would like to add a version of the manifesto to his blog and is not really interested in the pdf or docx versions. 

The solution in such a case is to use the `include` option:

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

as we saw above, while Engels's version of this file will look like this:

```yaml
formats: ['html5', 'epub']
format-html5:
    template: engels_blog.html5
format-epub:
    epub-cover-image: '/Users/engels/Pictures/spectre_big.jpg'
```

Read `defaults.yaml` for further information on the supported conversion settings.

## Planned features

- Configurable post-processing of target files by running a shell script or other external command on them.
- Making the naming and placement of the output directory more configurable.
- Making `formats` and `include` overridable from the command line, and probably the output directory as well.
- Integrated preprocessor support using e.g. [m4](https://www.gnu.org/software/m4/manual/index.html) or [gpp](https://logological.org/gpp). An interesting blog entry describing the advantages of using gpp with pandoc can be found [here](https://randomdeterminism.wordpress.com/2012/06/01/how-i-stopped-worring-and-started-using-markdown-like-tex/).

## Copyright and license

Copyright: Baldur A. Kristinsson, 2016 and later.

All source files in this package, including the documentation, are open source software under the terms of [Perl's Artistic License 2.0](http://www.perlfoundation.org/artistic_license_2_0)
