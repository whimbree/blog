# Multi-stage build: Zola 0.19.2 only ships a glibc binary (no musl),
# so we build the site on Debian and copy the static output into Alpine nginx.
# This also keeps the final image small — no build tools, no Zola binary.
#
# Local preview (Zola has a known bug where --base-url strips port numbers,
# so use port 80 to avoid it):
#   sudo docker build --build-arg BASE_URL=http://localhost -t blog:local .
#   sudo docker run --rm -p 80:80 blog:local
#   open http://localhost

FROM --platform=linux/amd64 debian:bookworm-slim AS build

RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates && \
    curl -sL https://github.com/getzola/zola/releases/download/v0.19.2/zola-v0.19.2-x86_64-unknown-linux-gnu.tar.gz | tar xz -C /usr/local/bin/

COPY . /blog
ARG BASE_URL=https://blog.bspwr.com
RUN cd /blog && zola build --base-url "$BASE_URL" --output-dir /out

FROM docker.io/nginx:alpine
RUN rm -r /usr/share/nginx/html
COPY --from=build /out /usr/share/nginx/html
