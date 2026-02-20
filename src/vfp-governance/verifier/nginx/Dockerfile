FROM nginx:1.25

# drop in your nginx.conf
COPY nginx.conf /etc/nginx/nginx.conf

# certs are mounted at runtime to /etc/nginx/certs (see compose)
EXPOSE 8443
CMD ["nginx", "-g", "daemon off;"]
