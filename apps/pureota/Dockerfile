FROM nginx:1.27-alpine

RUN apk add --no-cache curl jq postgresql16-client

COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY index.html /usr/share/nginx/html/index.html
COPY db-check.sh /usr/local/bin/db-check.sh
RUN chmod +x /usr/local/bin/db-check.sh

RUN mkdir -p /usr/share/nginx/html/tier-data

EXPOSE 80

COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
