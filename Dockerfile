FROM docker.io/nginx:alpine

RUN apk add --update-cache --repository http://dl-cdn.alpinelinux.org/alpine/edge/community/ zola git curl

COPY . /blog

RUN rm -r /usr/share/nginx/html
RUN cd /blog && zola build --output-dir /usr/share/nginx/html
