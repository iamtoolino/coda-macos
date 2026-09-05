# Optional Navidrome artwork cache tuning

Coda works with Navidrome's default configuration. Increasing the server's artwork cache can make
covers appear faster, particularly with a large library or server hardware that takes longer to
resize images.

## Why this can help Coda

Coda aims to keep artwork sharp, including on Retina displays, so it requests high-quality images
for browsing and Now Playing. A larger Navidrome artwork cache keeps more resized images ready to
serve immediately instead of first re-encoding them from the source artwork.

## Choosing a size

Navidrome's default image-cache limit is `100MB`.

- `1GB` is a good starting point.
- If server storage permits, use `5GB` to `10GB` to keep more artwork ready.

## Docker Compose

Add `ND_IMAGECACHESIZE` to the Navidrome service's environment:

```yaml
services:
  navidrome:
    environment:
      ND_IMAGECACHESIZE: "1GB"
```

Use an explicit unit such as `MB` or `GB`.

Then run this from the directory containing your Compose file to recreate the container:

```sh
docker compose up -d --force-recreate navidrome
```

## Configuration file

For installations using `navidrome.toml`, set:

```toml
ImageCacheSize = "1GB"
```

Restart Navidrome after changing the configuration.

## Navidrome documentation

- [Configuration options](https://www.navidrome.org/docs/usage/configuration/options/)
- [Artwork location, formats, and quality](https://www.navidrome.org/docs/usage/library/artwork/)
- [Installing Navidrome with Docker](https://www.navidrome.org/docs/installation/docker/)
