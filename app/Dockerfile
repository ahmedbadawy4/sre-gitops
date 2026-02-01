FROM httpd:2.4-alpine

ENV ENVIRONMENT=unknown

COPY index.html /usr/local/apache2/htdocs/index.html
COPY health /usr/local/apache2/htdocs/health
COPY cgi-bin/ /usr/local/apache2/cgi-bin/
COPY httpd.conf /usr/local/apache2/conf/httpd.conf

RUN chmod +x /usr/local/apache2/cgi-bin/version /usr/local/apache2/cgi-bin/metrics

EXPOSE 8080
