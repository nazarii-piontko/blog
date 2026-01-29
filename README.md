# NP Blog

Personal tech blog covering .NET, algorithms, distributed systems, and AWS.

**Live site:** [npiontko.pro](https://www.npiontko.pro)

## Tech Stack

- [Jekyll 4.4](https://jekyllrb.com/) - Static site generator
- [minimal-mistakes](https://mmistakes.github.io/minimal-mistakes/) - Theme (dark skin)
- Docker - Containerized builds
- Custom PlantUML plugin for inline UML diagrams

## Local Development

### Prerequisites

- Docker

### Build Docker Image

```bash
./jekyll-image-build.sh
```

### Run Development Server

```bash
./jekyll.sh serve
```

Site will be available at `http://localhost:4000`

### Build Only

One-time build:
```bash
./jekyll.sh build
```

Build with watch mode:
```bash
./jekyll.sh build --watch
```

## Project Structure

```
_posts/           # Blog posts (YYYY-MM-DD-slug.markdown)
_includes/        # Theme customizations
_layouts/         # Layout overrides
_plugins/         # Custom plugins (PlantUML)
assets/posts/     # Post-specific images and media
```

## License

This work is licensed under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
