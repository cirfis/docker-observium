# Docker container for Observium Community Edition
FROM ubuntu:18.04

LABEL maintainer "cirfis"
LABEL version="1.2"
LABEL description="Docker container for Observium Community Edition"

ARG OBSERVIUM_ADMIN_USER=${OBSERVIUM_ADMIN_USER:-cirfis}
ARG OBSERVIUM_ADMIN_PASS=${OBSERVIUM_ADMIN_PASS:-passw0rd}
ARG OBSERVIUM_DB_HOST=${OBSERVIUM_DB_HOST:-mysql.cirfis.org}
ARG OBSERVIUM_DB_USER=${OBSERVIUM_DB_USER:-cirfis}
ARG OBSERVIUM_DB_PASS=${OBSERVIUM_DB_PASS:-cirfis}
ARG OBSERVIUM_DB_NAME=${OBSERVIUM_DB_NAME:-observium}
ARG LOG_LEVEL=${LOG_LEVEL:-LOG_INFO}
ARG WRITE_THREADS=${WRITE_THREADS:-4}
ARG FLUSH_TIMEOUT=${FLUSH_TIMEOUT:-2h}
ARG TZ=${TZ:-America/Detroit}
ARG PGID=${PGID:-1000}
ARG PUID=${PUID:-1000}

# set environment variables
ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US.UTF-8
ENV OBSERVIUM_DB_HOST=$OBSERVIUM_DB_HOST
ENV OBSERVIUM_DB_USER=$OBSERVIUM_DB_USER
ENV OBSERVIUM_DB_PASS=$OBSERVIUM_DB_PASS
ENV OBSERVIUM_DB_NAME=$OBSERVIUM_DB_NAME
ENV LOG_LEVEL=$LOG_LEVEL
ENV WRITE_THREADS=$WRITE_THREADS
ENV FLUSH_TIMEOUT=$FLUSH_TIMEOUT
ENV TZ=$TZ
ENV PGID=$PGID
ENV PUID=$PUID

# install prerequisites
RUN echo 'debconf debconf/frontend select Noninteractive' | debconf-set-selections && \
    apt update && \
    apt install -y software-properties-common && \
    add-apt-repository ppa:ondrej/php && \
    apt-get update && \
    apt-get install -y libapache2-mod-php7.3 php7.3-cli php7.3-mysql php7.3-mysqli php7.3-gd php7.3-json \
      snmp fping mysql-client python-mysqldb rrdtool subversion whois mtr-tiny ipmitool libvirt-bin \
      graphviz imagemagick apache2 cron supervisor wget locales tzdata rrdcached && \
    apt-get clean && \
    locale-gen en_US.UTF-8


# Fix Permissions
RUN mkdir -p /opt/observium /opt/observium/lock /opt/observium/logs /opt/observium/rrd /opt/observium/rrd-journal /var/run/rrdcached
COPY observium_perms /opt/observium/observium_perms	
RUN chmod a+x /opt/observium/observium_perms
      
# install observium package
RUN cd /opt && \
    wget http://www.observium.org/observium-community-latest.tar.gz && \
    tar zxvf observium-community-latest.tar.gz && \
    rm observium-community-latest.tar.gz

# check version
RUN [ -f /opt/observium/VERSION ] && cat /opt/observium/VERSION

# configure observium package
RUN cd /opt/observium && \
    cp config.php.default config.php && \
    sed -i -e "s/= 'localhost';/= getenv('OBSERVIUM_DB_HOST');/g" config.php && \
    sed -i -e "s/= 'USERNAME';/= getenv('OBSERVIUM_DB_USER');/g" config.php && \
    sed -i -e "s/= 'PASSWORD';/= getenv('OBSERVIUM_DB_PASS');/g" config.php && \
    sed -i -e "s/= 'observium';/= getenv('OBSERVIUM_DB_NAME');/g" config.php && \
    echo "\$config['base_url'] = getenv('OBSERVIUM_BASE_URL');" >> config.php && \
    echo "\$config['rrdcached'] = getenv('OBSERVIUM_RRDCACHED_HOST');" >> config.php

COPY observium-init /opt/observium/observium-init.sh
RUN chmod a+x /opt/observium/observium-init.sh

# configure php modules
RUN phpenmod mcrypt

# enable OPCACHE
COPY observium-opcache /tmp/opcache
RUN echo "" >> /etc/php/7.3/mods-available/opcache.ini && \
    cat /tmp/opcache >> /etc/php/7.3/mods-available/opcache.ini && \
    rm -f /tmp/opcache
# install opcache tmpdir
COPY php-cli-opcache.conf /etc/tmpfiles.d/
RUN systemd-tmpfiles --create /etc/tmpfiles.d/php-cli-opcache.conf


# configure apache modules
RUN a2dismod mpm_event && \
    a2enmod mpm_prefork && \
    a2enmod php7.3 && \
    a2enmod rewrite 

# configure apache configuration
RUN mv /etc/apache2/sites-available/000-default.conf /etc/apache2/sites-available/000-default.conf.orig
COPY observium-apache24 /etc/apache2/sites-available/000-default.conf
RUN rm -fr /var/www

# configure observium cron job
#COPY observium-cron /etc/cron.d/observium
COPY observium-cron /tmp/observium
RUN echo "" >> /etc/crontab && \
    cat /tmp/observium >> /etc/crontab && \
    rm -f /tmp/observium

# Fix Permissions
RUN find /opt/observium \( ! -user www-data -o ! -group www-data \) -exec chown www-data:www-data {} \; && \
	chown -R www-data:www-data  /var/run/rrdcached

# configure container interfaces
COPY supervisord.conf /etc/supervisor/conf.d/supervisord.conf

# configure rrdcached healthcheck
HEALTHCHECK --interval=30s --timeout=5s --start-period=5m \
  CMD echo PING | nc 127.0.0.1 42217 | grep PONG || exit 1

EXPOSE 42217/tcp
EXPOSE 80/tcp

VOLUME ["/opt/observium/lock", "/opt/observium/logs", "/opt/observium/rrd", "/opt/observium/rrd-journal"]

CMD ["/usr/bin/supervisord"]
