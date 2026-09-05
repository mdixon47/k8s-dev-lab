# Static site + reverse proxy to the API, built the same way as the API image (make image).
# nginx-unprivileged runs as uid 101, listens on 8080, and keeps pid/cache under /tmp, so the
# pod can run with a read-only root filesystem and the "restricted" Pod Security profile.
FROM nginxinc/nginx-unprivileged:1.27-alpine
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY site/ /usr/share/nginx/html/
EXPOSE 8080
