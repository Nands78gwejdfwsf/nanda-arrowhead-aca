FROM nginx:1.27-alpine

COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY index.html /usr/share/nginx/html/index.html

RUN mkdir -p /usr/share/nginx/html/tier-data

EXPOSE 80
