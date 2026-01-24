# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Personal tech blog built with Jekyll 4.4 using the minimal-mistakes theme (dark skin). Content focuses on .NET, algorithms, distributed systems, and AWS.

## Build Commands

All builds run through Docker. Build the Docker image first:
```bash
./jekyll-image-build.sh
```

Development with watch mode:
```bash
./jekyll.sh build --watch
```

One-time production build:
```bash
./jekyll.sh build
```

Serve locally (includes watch):
```bash
./jekyll.sh serve
```

VS Code task "Run Jekyll" also available for watch mode builds.

## Architecture

**Theme**: minimal-mistakes-jekyll with customizations in `_includes/` and `_layouts/`

**Custom PlantUML Plugin** (`_plugins/jekyll-plantuml.rb`): Renders UML diagrams inline. Usage in posts:
```
{% plantuml %}
... PlantUML markup ...
{% endplantuml %}
```
Generates SVG files in `/uml/` directory, cached by content MD5 hash.

**Post Assets**: Each post's images/videos go in `/assets/posts/<post-slug>/`. Reference with relative paths like `/assets/posts/aspire-localstack/logo.png`.

**Post Front Matter**: Posts use `layout: single` with `classes: wide`. Include `header.teaser` for thumbnails.

## Writing Posts

Posts go in `_posts/` with naming format `YYYY-MM-DD-slug.markdown`. Standard front matter:
```yaml
---
layout: single
classes: wide
title: Post Title
excerpt: Brief description for previews
tags: tag1 tag2 tag3
date: YYYY-MM-DD
toc: false
header:
  teaser: /assets/posts/slug/logo.png
---
```
